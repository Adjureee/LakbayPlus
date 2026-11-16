import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../services/api_service.dart';
import 'admin_widgets.dart';

/// Same limits as the API (`UPLOAD_MAX_IMAGE_BYTES`, allowed image types).
const destinationPhotoMaxBytes = 5 * 1024 * 1024;

/// A photo chosen on this computer, before upload.
class PickedPhoto {
  final String name;
  final Uint8List bytes;
  const PickedPhoto(this.name, this.bytes);
}

/// Opens the browser's file chooser. Tests replace this.
@visibleForTesting
Future<PickedPhoto?> Function() pickDestinationPhoto = _pickWithFilePicker;

Future<PickedPhoto?> _pickWithFilePicker() async {
  final file = await FilePicker.pickFile(
    type: FileType.custom,
    allowedExtensions: const ['jpg', 'jpeg', 'png', 'webp'],
  );
  if (file == null) return null;
  return PickedPhoto(file.name, await file.readAsBytes());
}

/// The image type from the file's first bytes, matching the API's check.
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

/// Picks a photo, previews it, uploads it after confirmation, and returns the
/// saved destination, or null when cancelled or failed (a message is shown).
Future<Map<String, dynamic>?> replaceDestinationPhoto(
  BuildContext context, {
  required ApiService api,
  required Map<String, dynamic> destination,
  VoidCallback? onUploadStarted,
}) async {
  final messenger = ScaffoldMessenger.of(context);
  void say(String text) =>
      messenger.showSnackBar(SnackBar(content: Text(text)));

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
