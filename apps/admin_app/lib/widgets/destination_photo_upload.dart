import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../core/image_urls.dart';
import '../services/api_service.dart';
import 'admin_widgets.dart';

/// Same limits as the API (`UPLOAD_MAX_IMAGE_BYTES`, allowed image types).
const destinationPhotoMaxBytes = 5 * 1024 * 1024;

/// Limits for `/destinations/{id}/media` (`uploads.py`).
const destinationMediaImageMaxBytes = 10 * 1024 * 1024;
const destinationMediaVideoMaxBytes = 15 * 1024 * 1024;
const destinationMediaMaxDurationSeconds = 15.0;

/// A photo or clip chosen on this computer, before upload.
class PickedPhoto {
  final String name;
  final Uint8List bytes;
  const PickedPhoto(this.name, this.bytes);
}

/// Opens the browser's file chooser for static photos. Tests replace this.
@visibleForTesting
Future<PickedPhoto?> Function() pickDestinationPhoto = _pickWithFilePicker;

/// Opens the browser's file chooser for photos, GIFs, or short video clips.
@visibleForTesting
Future<PickedPhoto?> Function() pickDestinationMedia = _pickMediaWithFilePicker;

Future<PickedPhoto?> _pickWithFilePicker() async {
  final file = await FilePicker.pickFile(
    type: FileType.custom,
    allowedExtensions: const ['jpg', 'jpeg', 'png', 'webp'],
  );
  if (file == null) return null;
  return PickedPhoto(file.name, await file.readAsBytes());
}

Future<PickedPhoto?> _pickMediaWithFilePicker() async {
  final file = await FilePicker.pickFile(
    type: FileType.custom,
    allowedExtensions: const ['jpg', 'jpeg', 'png', 'webp', 'gif', 'mp4', 'webm'],
  );
  if (file == null) return null;
  return PickedPhoto(file.name, await file.readAsBytes());
}

/// The static image type from the file's first bytes, matching `/image`.
String? detectPhotoContentType(Uint8List bytes) {
  bool startsWith(List<int> prefix) =>
      bytes.length >= prefix.length &&
      Iterable<int>.generate(prefix.length).every((i) => bytes[i] == prefix[i]);
  if (startsWith(const [0xFF, 0xD8, 0xFF])) return 'image/jpeg';
  if (startsWith(const [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])) {
    return 'image/png';
  }
  if (bytes.length >= 12 &&
      startsWith(const [0x52, 0x49, 0x46, 0x46]) &&
      String.fromCharCodes(bytes.sublist(8, 12)) == 'WEBP') {
    return 'image/webp';
  }
  return null;
}

/// Detects JPEG, PNG, WebP, GIF (`GIF87a`/`GIF89a`), MP4 (`ftyp`), or WebM
/// (`0x1A 0x45 0xDF 0xA3`) from magic bytes, matching `/media`.
String? detectMediaContentType(Uint8List bytes) {
  final photo = detectPhotoContentType(bytes);
  if (photo != null) return photo;
  bool startsWith(List<int> prefix) =>
      bytes.length >= prefix.length &&
      Iterable<int>.generate(prefix.length).every((i) => bytes[i] == prefix[i]);
  if (startsWith(const [0x47, 0x49, 0x46, 0x38, 0x37, 0x61]) ||
      startsWith(const [0x47, 0x49, 0x46, 0x38, 0x39, 0x61])) {
    return 'image/gif';
  }
  if (bytes.length >= 12 &&
      bytes[4] == 0x66 &&
      bytes[5] == 0x74 &&
      bytes[6] == 0x79 &&
      bytes[7] == 0x70) {
    return 'video/mp4';
  }
  if (startsWith(const [0x1A, 0x45, 0xDF, 0xA3])) {
    return 'video/webm';
  }
  return null;
}

bool isVideoContentType(String contentType) =>
    contentType == 'video/mp4' || contentType == 'video/webm';

/// Best-effort pure-Dart parser for MP4 `moov -> mvhd` duration in seconds.
/// Returns `null` when the container lacks a readable `mvhd` box.
double? parseMp4DurationSeconds(Uint8List bytes) {
  final view = ByteData.sublistView(bytes);
  Iterable<({String type, int start, int end})> iterBoxes(
    int start,
    int end,
  ) sync* {
    var offset = start;
    while (offset + 8 <= end) {
      var size = view.getUint32(offset);
      final type = String.fromCharCodes(bytes.sublist(offset + 4, offset + 8));
      var headerLen = 8;
      if (size == 1) {
        if (offset + 16 > end) break;
        size = view.getUint64(offset + 8);
        headerLen = 16;
      } else if (size == 0) {
        size = end - offset;
      }
      if (size < headerLen) break;
      final boxEnd = (offset + size) > end ? end : offset + size;
      yield (type: type, start: offset + headerLen, end: boxEnd);
      offset = boxEnd;
    }
  }

  for (final box in iterBoxes(0, bytes.length)) {
    if (box.type != 'moov') continue;
    for (final child in iterBoxes(box.start, box.end)) {
      if (child.type != 'mvhd') continue;
      if (child.start >= child.end) return null;
      final version = bytes[child.start];
      if (version == 0 && child.end - child.start >= 20) {
        final timescale = view.getUint32(child.start + 12);
        final duration = view.getUint32(child.start + 16);
        return timescale > 0 ? duration / timescale : null;
      }
      if (version == 1 && child.end - child.start >= 32) {
        final timescale = view.getUint32(child.start + 20);
        final duration = view.getUint64(child.start + 24);
        return timescale > 0 ? duration / timescale : null;
      }
      return null;
    }
  }
  return null;
}

/// Picks a photo, previews it, uploads it after confirmation, and returns the
/// saved destination, or null when cancelled or failed (a message is shown).
Future<Map<String, dynamic>?> replaceDestinationPhoto(
  BuildContext context, {
  required ApiService api,
  required Map<String, dynamic> destination,
  VoidCallback? onUploadStarted,
}) async {
  final messenger = ScaffoldMessenger.of(context);
  void say(String text) {
    messenger.clearSnackBars();
    messenger.showSnackBar(SnackBar(content: Text(text)));
  }

  final picked = await pickDestinationPhoto();
  if (picked == null || !context.mounted) return null;
  final contentType = detectPhotoContentType(picked.bytes);
  if (contentType == null) {
    say('Choose a JPEG, PNG or WebP photo.');
    return null;
  }
  if (picked.bytes.length > destinationPhotoMaxBytes) {
    say(
      'That photo is ${(picked.bytes.length / 1048576).toStringAsFixed(1)} MB. '
      'The limit is 5 MB.',
    );
    return null;
  }

  final name = destination['name']?.toString() ?? 'this destination';
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text('Use this photo for $name?'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: Image.memory(
                picked.bytes,
                height: 260,
                width: 520,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => const SizedBox(
                  height: 80,
                  child: Center(child: Text('Preview unavailable')),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              'It replaces the current photo for travelers on their next '
              'catalog sync. The old photo is kept in Cloudinary.',
              style: Theme.of(dialogContext).textTheme.bodySmall,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, false),
          child: const Text('Cancel'),
        ),
        FilledButton.icon(
          onPressed: () => Navigator.pop(dialogContext, true),
          icon: const Icon(Icons.cloud_upload_outlined),
          label: const Text('Upload photo'),
        ),
      ],
    ),
  );
  if (confirmed != true || !context.mounted) return null;

  adminIsSaving.value = true;
  onUploadStarted?.call();
  try {
    final saved = await api.uploadDestinationPhoto(
      destination['destination_id'].toString(),
      UploadFile(
        bytes: picked.bytes,
        filename: picked.name,
        contentType: contentType,
      ),
    );
    say('Photo updated for $name.');
    return saved;
  } catch (error) {
    say('Photo was not uploaded: $error');
    return null;
  } finally {
    adminIsSaving.value = false;
  }
}

/// Picks a photo, animated GIF, or <=15s MP4/WebM clip, validates magic bytes,
/// size cap, and MP4 duration, previews it, uploads to `/media` with progress,
/// and returns the saved destination record (or null when cancelled/failed).
Future<Map<String, dynamic>?> uploadDestinationMediaFlow(
  BuildContext context, {
  required ApiService api,
  required Map<String, dynamic> destination,
  VoidCallback? onUploadStarted,
  void Function(double progress)? onProgress,
}) async {
  final messenger = ScaffoldMessenger.of(context);
  void say(String text) {
    messenger.clearSnackBars();
    messenger.showSnackBar(SnackBar(content: Text(text)));
  }

  final picked = await pickDestinationMedia();
  if (picked == null || !context.mounted) return null;

  final contentType = detectMediaContentType(picked.bytes);
  if (contentType == null) {
    say('Choose a JPEG, PNG, WebP, GIF, MP4, or WebM file.');
    return null;
  }

  final isVideo = isVideoContentType(contentType);
  final maxBytes = isVideo
      ? destinationMediaVideoMaxBytes
      : destinationMediaImageMaxBytes;
  if (picked.bytes.length > maxBytes) {
    final sizeMb = (picked.bytes.length / 1048576).toStringAsFixed(1);
    final limitMb = isVideo ? '15 MB' : '10 MB';
    say('That file is $sizeMb MB. The limit is $limitMb.');
    return null;
  }

  final parsedDuration = contentType == 'video/mp4'
      ? parseMp4DurationSeconds(picked.bytes)
      : null;
  if (parsedDuration != null &&
      parsedDuration > destinationMediaMaxDurationSeconds) {
    say(
      'That clip is ${parsedDuration.toStringAsFixed(1)}s long. '
      'Video clips must be 15 seconds or shorter.',
    );
    return null;
  }

  final name = destination['name']?.toString() ?? 'this destination';
  final posterUrl = destinationPosterUrl(destination, width: 320, height: 180);
  final sizeLabel = _formatSizeLabel(picked.bytes.length);
  final codecLabel = switch (contentType) {
    'image/gif' => 'GIF',
    'video/mp4' => 'MP4',
    'video/webm' => 'WEBM',
    _ => 'IMAGE',
  };

  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(
        isVideo
            ? 'Upload video clip for $name?'
            : (contentType == 'image/gif'
                  ? 'Upload GIF for $name?'
                  : 'Use this media for $name?'),
      ),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (!isVideo)
              ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: Image.memory(
                  picked.bytes,
                  height: 240,
                  width: 520,
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) => const SizedBox(
                    height: 80,
                    child: Center(child: Text('Preview unavailable')),
                  ),
                ),
              )
            else
              _VideoClipPreviewCard(
                filename: picked.name,
                codecLabel: codecLabel,
                sizeLabel: sizeLabel,
                durationSeconds: parsedDuration,
                posterUrl: posterUrl,
              ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                AdminBadge(label: codecLabel),
                Text(
                  sizeLabel,
                  style: Theme.of(dialogContext).textTheme.bodySmall,
                ),
                if (parsedDuration != null)
                  Text(
                    'Duration: ${parsedDuration.toStringAsFixed(1)}s',
                    style: Theme.of(dialogContext).textTheme.bodySmall,
                  ),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              isVideo || contentType == 'image/gif'
                  ? 'Your existing static poster (image_url) stays preserved as '
                        'the fallback thumbnail.'
                  : 'Replaces the primary image and updates media_url.',
              style: Theme.of(dialogContext).textTheme.bodySmall,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, false),
          child: const Text('Cancel'),
        ),
        FilledButton.icon(
          onPressed: () => Navigator.pop(dialogContext, true),
          icon: const Icon(Icons.cloud_upload_outlined),
          label: const Text('Upload media'),
        ),
      ],
    ),
  );
  if (confirmed != true || !context.mounted) return null;

  adminIsSaving.value = true;
  onUploadStarted?.call();
  try {
    final saved = await api.uploadDestinationMedia(
      destination['destination_id'].toString(),
      UploadFile(
        bytes: picked.bytes,
        filename: picked.name,
        contentType: contentType,
      ),
      onProgress: onProgress,
    );
    say('Media updated for $name.');
    return saved;
  } catch (error) {
    say('Media was not uploaded: $error');
    return null;
  } finally {
    adminIsSaving.value = false;
  }
}

class _VideoClipPreviewCard extends StatelessWidget {
  const _VideoClipPreviewCard({
    required this.filename,
    required this.codecLabel,
    required this.sizeLabel,
    required this.durationSeconds,
    required this.posterUrl,
  });

  final String filename;
  final String codecLabel;
  final String sizeLabel;
  final double? durationSeconds;
  final String? posterUrl;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: theme.dividerColor),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          if (posterUrl != null)
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Image.network(
                posterUrl!,
                width: 96,
                height: 64,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => _fallbackTile(theme),
              ),
            )
          else
            _fallbackTile(theme),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  filename,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleSmall,
                ),
                const SizedBox(height: 4),
                Text(
                  durationSeconds != null
                      ? '$codecLabel clip · $sizeLabel · ${durationSeconds!.toStringAsFixed(1)}s'
                      : '$codecLabel clip · $sizeLabel · Server verifies ≤ 15s',
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _fallbackTile(ThemeData theme) => Container(
    width: 96,
    height: 64,
    decoration: BoxDecoration(
      color: theme.colorScheme.primary.withValues(alpha: 0.12),
      borderRadius: BorderRadius.circular(8),
    ),
    child: Icon(
      Icons.movie_outlined,
      size: 28,
      color: theme.colorScheme.primary,
    ),
  );
}

String _formatSizeLabel(int bytes) {
  if (bytes >= 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  final kb = (bytes / 1024).clamp(1, 1024).round();
  return '$kb KB';
}

/// "Replace photo" button that shows progress while uploading.
class ReplacePhotoButton extends StatefulWidget {
  const ReplacePhotoButton({
    super.key,
    required this.api,
    required this.destination,
    required this.onUploaded,
  });

  final ApiService api;
  final Map<String, dynamic> destination;
  final ValueChanged<Map<String, dynamic>> onUploaded;

  @override
  State<ReplacePhotoButton> createState() => _ReplacePhotoButtonState();
}

class _ReplacePhotoButtonState extends State<ReplacePhotoButton> {
  bool _busy = false;
  bool _choosing = false;

  Future<void> _run() async {
    _choosing = true;
    final saved = await replaceDestinationPhoto(
      context,
      api: widget.api,
      destination: widget.destination,
      // Show progress only once the upload itself starts.
      onUploadStarted: () {
        if (mounted) setState(() => _busy = true);
      },
    );
    _choosing = false;
    if (!mounted) return;
    setState(() => _busy = false);
    if (saved != null) widget.onUploaded(saved);
  }

  @override
  Widget build(BuildContext context) => OutlinedButton.icon(
    onPressed: _busy || _choosing ? null : _run,
    icon: _busy
        ? const SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        : const Icon(Icons.add_photo_alternate_outlined),
    label: Text(_busy ? 'Uploading…' : 'Replace photo'),
  );
}

/// "Upload GIF / video" button that streams determinate upload progress to
/// `/destinations/{id}/media`.
class UploadMediaButton extends StatefulWidget {
  const UploadMediaButton({
    super.key,
    required this.api,
    required this.destination,
    required this.onUploaded,
    this.label = 'Upload GIF / video',
  });

  final ApiService api;
  final Map<String, dynamic> destination;
  final ValueChanged<Map<String, dynamic>> onUploaded;
  final String label;

  @override
  State<UploadMediaButton> createState() => _UploadMediaButtonState();
}

class _UploadMediaButtonState extends State<UploadMediaButton> {
  bool _busy = false;
  bool _choosing = false;
  final ValueNotifier<double?> _progress = ValueNotifier<double?>(null);

  @override
  void dispose() {
    _progress.dispose();
    super.dispose();
  }

  Future<void> _run() async {
    _choosing = true;
    _progress.value = null;
    final saved = await uploadDestinationMediaFlow(
      context,
      api: widget.api,
      destination: widget.destination,
      onUploadStarted: () {
        if (mounted) setState(() => _busy = true);
      },
      onProgress: (value) {
        _progress.value = value;
      },
    );
    _choosing = false;
    if (!mounted) return;
    setState(() => _busy = false);
    if (saved != null) widget.onUploaded(saved);
  }

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      ValueListenableBuilder<double?>(
        valueListenable: _progress,
        builder: (context, progress, _) {
          final pct = progress == null ? null : (progress * 100).round();
          return OutlinedButton.icon(
            onPressed: _busy || _choosing ? null : _run,
            icon: _busy
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.movie_creation_outlined),
            label: Text(
              _busy
                  ? (pct == null ? 'Uploading…' : 'Uploading $pct%…')
                  : widget.label,
            ),
          );
        },
      ),
      if (_busy)
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: SizedBox(
            width: 180,
            child: ValueListenableBuilder<double?>(
              valueListenable: _progress,
              builder: (context, progress, _) => LinearProgressIndicator(
                value: progress,
                minHeight: 4,
              ),
            ),
          ),
        ),
    ],
  );
}
