import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import '../widgets/lakbay_image.dart';

import '../models/travel_models.dart';
import '../services/travel_repository.dart';
import '../theme/lakbay_theme.dart';
import 'auth_screen.dart';

/// Shared add-memory bottom sheet usable from the Memories tab, Trip detail,
/// and post-trip prompts.
Future<void> showAddTripMemorySheet(
  BuildContext context, {
  required TravelRepository repo,
  ItineraryTrip? initialTrip,
  Uint8List? testImageBytes,
  String? testImageName,
}) async {
  if (!repo.isSignedIn) {
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Sign in required'),
        content: const Text(
          'Sign in or create an account to upload and share photos from your Davao Region trips.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              Navigator.of(context).push(
                MaterialPageRoute<bool>(
                  builder: (_) => AuthScreen(
                    repo: repo,
                    initialRegisterMode: false,
                  ),
                ),
              );
            },
            child: const Text('Sign in'),
          ),
        ],
      ),
    );
    return;
  }

  final trips = repo.savedTrips;
  if (trips.isEmpty) {
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Plan a trip first'),
        content: const Text(
          'Memories belong to a trip. Plan or save a Davao Region trip first, then upload photos here.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Not now'),
          ),
          FilledButton.icon(
            onPressed: () {
              Navigator.of(ctx).pop();
              repo.setActiveNavIndex(2);
              Navigator.of(context).popUntil((r) => r.isFirst);
            },
            icon: const Icon(Icons.auto_awesome_rounded, size: 18),
            label: const Text('Plan a trip'),
          ),
        ],
      ),
    );
    return;
  }

  var selectedTrip = initialTrip != null
      ? trips.firstWhere(
          (t) => t.id == initialTrip.id,
          orElse: () => trips.first,
        )
      : trips.firstWhere((t) => !t.isArchived, orElse: () => trips.first);

  final captionCtrl = TextEditingController();
  final locationCtrl = TextEditingController(text: selectedTrip.destination);
  XFile? pickedFile;
  Uint8List? pickedBytes = testImageBytes;
  String? pickedName = testImageName;
  bool saving = false;
  String? uploadStatus;
  String? errorMessage;

  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.white,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
    builder: (sheetContext) {
      return StatefulBuilder(
        builder: (context, setSheetState) {
          Future<void> pickImage(ImageSource source) async {
            try {
              final file = await ImagePicker().pickImage(
                source: source,
                imageQuality: 85,
                maxWidth: 1600,
              );
              if (file == null) return;
              final bytes = await file.readAsBytes();
              if (!sheetContext.mounted) return;
              setSheetState(() {
                pickedFile = file;
                pickedBytes = bytes;
                pickedName = file.name;
                errorMessage = null;
              });
            } catch (e) {
              if (!sheetContext.mounted) return;
              setSheetState(() {
                errorMessage = 'Could not read selected photo: $e';
              });
            }
          }

          final hasSelectedPhoto = pickedBytes != null || pickedFile != null;
          final isArchivedTrip = selectedTrip.isArchived;

          return SafeArea(
            top: false,
            child: Padding(
              padding: EdgeInsets.fromLTRB(
                20,
                16,
                20,
                MediaQuery.of(context).viewInsets.bottom +
                    MediaQuery.of(context).viewPadding.bottom +
                    24,
              ),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Center(
                      child: Container(
                        width: 40,
                        height: 4,
                        margin: const EdgeInsets.only(bottom: 14),
                        decoration: BoxDecoration(
                          color: Colors.grey.shade300,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                    const Text(
                      'Add Trip Memory',
                      style: TextStyle(
                        fontFamily: 'FigGrotesk',
                        fontSize: 20,
                        fontWeight: FontWeight.w700,
                        color: LakbayColors.tealDeep,
                      ),
                    ),
                    const SizedBox(height: 12),
                    DropdownButtonFormField<String>(
                      initialValue: selectedTrip.id,
                      isExpanded: true,
                      decoration: InputDecoration(
                        labelText: 'Trip',
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 10,
                        ),
                      ),
                      items: [
                        for (final t in trips)
                          DropdownMenuItem(
                            value: t.id,
                            child: Text(
                              t.isArchived ? '${t.title} (Archived)' : t.title,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                      ],
                      onChanged: saving
                          ? null
                          : (value) {
                              if (value == null) return;
                              final match = trips.firstWhere((t) => t.id == value);
                              setSheetState(() {
                                selectedTrip = match;
                                locationCtrl.text = match.destination;
                                errorMessage = null;
                              });
                            },
                    ),
                    if (isArchivedTrip) ...[
                      const SizedBox(height: 10),
                      Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: const Color(0xFFFFF3E0),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: const Row(
                          children: [
                            Icon(
                              Icons.lock_outline,
                              size: 16,
                              color: Color(0xFFE65100),
                            ),
                            SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                'This trip is archived and read-only. Pick an active trip above.',
                                style: TextStyle(
                                  fontSize: 12.5,
                                  color: Color(0xFF8D3B00),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: saving || isArchivedTrip
                                ? null
                                : () => pickImage(ImageSource.gallery),
                            icon: const Icon(Icons.photo_library_outlined),
                            label: const Text('Gallery'),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: saving || isArchivedTrip
                                ? null
                                : () => pickImage(ImageSource.camera),
                            icon: const Icon(Icons.camera_alt_outlined),
                            label: const Text('Camera'),
                          ),
                        ),
                      ],
                    ),
                    if (pickedBytes != null) ...[
                      const SizedBox(height: 10),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(14),
                        child: Image.memory(
                          pickedBytes!,
                          height: 160,
                          width: double.infinity,
                          fit: BoxFit.cover,
                          errorBuilder: (_, _, _) => const SizedBox(
                            height: 160,
                            child: Center(
                              child: Icon(Icons.photo_outlined, size: 36),
                            ),
                          ),
                        ),
                      ),
                    ] else if (pickedFile != null) ...[
                      const SizedBox(height: 10),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(14),
                        child: kIsWeb
                            ? Image.network(
                                pickedFile!.path,
                                height: 160,
                                width: double.infinity,
                                fit: BoxFit.cover,
                              )
                            : Image.file(
                                File(pickedFile!.path),
                                height: 160,
                                width: double.infinity,
                                fit: BoxFit.cover,
                                errorBuilder: (_, _, _) => const SizedBox(
                                  height: 160,
                                  child: Center(
                                    child: Icon(Icons.photo_outlined, size: 36),
                                  ),
                                ),
                              ),
                      ),
                    ],
                    const SizedBox(height: 12),
                    TextField(
                      controller: captionCtrl,
                      decoration: InputDecoration(
                        labelText: 'Caption / Moment',
                        hintText: 'e.g., Sunset view at Hagimit Falls',
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: locationCtrl,
                      decoration: InputDecoration(
                        labelText: 'Location Tag',
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                    ),
                    if (errorMessage != null) ...[
                      const SizedBox(height: 10),
                      Text(
                        errorMessage!,
                        style: const TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                          color: Colors.redAccent,
                        ),
                      ),
                    ],
                    const SizedBox(height: 16),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: LakbayColors.primary,
                          foregroundColor: Colors.white,
                          minimumSize: const Size(double.infinity, 48),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 20,
                            vertical: 14,
                          ),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                        ),
                        onPressed: saving || !hasSelectedPhoto || isArchivedTrip
                            ? null
                            : () async {
                                setSheetState(() {
                                  saving = true;
                                  errorMessage = null;
                                  uploadStatus = 'Uploading photo…';
                                });
                                try {
                                  final created =
                                      await repo.uploadAndAddMemory(
                                    trip: selectedTrip,
                                    localFilePath: pickedFile?.path,
                                    imageBytes: pickedBytes,
                                    fileName: pickedName,
                                    caption: captionCtrl.text.trim(),
                                    locationTag: locationCtrl.text.trim(),
                                    onProgress: (status) {
                                      if (!sheetContext.mounted) return;
                                      setSheetState(
                                        () => uploadStatus = status,
                                      );
                                    },
                                  );
                                  if (!sheetContext.mounted) return;
                                  Navigator.of(sheetContext).pop();
                                  if (context.mounted && created != null) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(
                                        content: Text(
                                          created.isOutbox
                                              ? 'Not uploaded yet — saved to your outbox. Tap Retry anytime.'
                                              : 'Memory added to ${selectedTrip.title}.',
                                        ),
                                        backgroundColor: LakbayColors.tealDeep,
                                      ),
                                    );
                                  }
                                } catch (e) {
                                  if (!sheetContext.mounted) return;
                                  setSheetState(() {
                                    saving = false;
                                    uploadStatus = null;
                                    errorMessage = e.toString();
                                  });
                                }
                              },
                        icon: saving
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.white,
                                ),
                              )
                            : const Icon(Icons.cloud_upload_outlined),
                        label: Text(
                          saving ? (uploadStatus ?? 'Uploading…') : 'Save Memory',
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      );
    },
  );
}

class MemoriesScreen extends StatefulWidget {
  final TravelRepository repo;

  const MemoriesScreen({super.key, required this.repo});

  @override
  State<MemoriesScreen> createState() => _MemoriesScreenState();
}

class _MemoriesScreenState extends State<MemoriesScreen> {
  String? _selectedTripFilter;
  bool _refreshing = false;
  final Set<int> _retryingOutboxIds = <int>{};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _refresh();
    });
  }

  Future<void> _refresh() async {
    if (!widget.repo.isSignedIn || _refreshing) return;
    setState(() => _refreshing = true);
    try {
      await widget.repo.refreshMemoriesForSavedTrips();
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  Future<void> _retryOutboxItem(TripMemoryItem memory) async {
    if (_retryingOutboxIds.contains(memory.tripMemoryId)) return;
    setState(() => _retryingOutboxIds.add(memory.tripMemoryId));
    try {
      final confirmed = await widget.repo.retryOutboxMemory(memory);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            confirmed != null && !confirmed.isOutbox
                ? 'Memory uploaded and synced!'
                : 'Still offline or unreachable. Retry anytime.',
          ),
          backgroundColor: LakbayColors.tealDeep,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.toString())),
      );
    } finally {
      if (mounted) {
        setState(() => _retryingOutboxIds.remove(memory.tripMemoryId));
      }
    }
  }

  Future<void> _handleLike(TripMemoryItem memory) async {
    if (memory.isOutbox) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Upload this memory first before liking it.'),
        ),
      );
      return;
    }
    final ok = await widget.repo.likeMemory(memory);
    if (!mounted || ok) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Could not confirm like with server. Please try again.'),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.repo,
      builder: (context, _) {
        final allMemories = widget.repo.memories;
        final filtered = _selectedTripFilter == null
            ? allMemories
            : allMemories
                .where(
                  (m) =>
                      m.locationTag == _selectedTripFilter ||
                      m.destinationName == _selectedTripFilter,
                )
                .toList();

        final filterLabels = {
          for (final m in allMemories)
            if ((m.locationTag ?? '').trim().isNotEmpty) m.locationTag!.trim(),
        }.toList();

        final prompts = widget.repo.postTripMemoryPrompts;
        final hasTrips = widget.repo.savedTrips.isNotEmpty;

        return Scaffold(
          backgroundColor: const Color(0xFFF6F7F8),
          body: SafeArea(
            child: RefreshIndicator(
              onRefresh: _refresh,
              child: CustomScrollView(
                slivers: [
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
                      child: Row(
                        children: [
                          const Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Memories',
                                  style: TextStyle(
                                    fontFamily: 'FigGrotesk',
                                    fontSize: 28,
                                    fontWeight: FontWeight.w800,
                                    color: LakbayColors.tealDeep,
                                  ),
                                ),
                                SizedBox(height: 2),
                                Text(
                                  'Photos & moments from your Davao Region trips',
                                  style: TextStyle(
                                    fontSize: 13.5,
                                    color: Color(0xFF5D6B73),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          FilledButton.icon(
                            style: FilledButton.styleFrom(
                              backgroundColor: LakbayColors.primary,
                              foregroundColor: Colors.white,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(14),
                              ),
                            ),
                            onPressed: () => showAddTripMemorySheet(
                              context,
                              repo: widget.repo,
                            ),
                            icon:
                                const Icon(Icons.add_a_photo_outlined, size: 18),
                            label: const Text('Add Photo'),
                          ),
                        ],
                      ),
                    ),
                  ),
                  if (prompts.isNotEmpty)
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                        child: Container(
                          padding: const EdgeInsets.all(14),
                          decoration: BoxDecoration(
                            color: LakbayColors.primarySoft,
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(
                              color: LakbayColors.primary.withValues(alpha: 0.3),
                            ),
                          ),
                          child: Row(
                            children: [
                              const Icon(
                                Icons.auto_stories_outlined,
                                color: LakbayColors.tealDeep,
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Text(
                                  'How was ${prompts.first.title}? Capture a photo from your trip.',
                                  style: const TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600,
                                    color: LakbayColors.tealDeep,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              FilledButton.tonal(
                                onPressed: () => showAddTripMemorySheet(
                                  context,
                                  repo: widget.repo,
                                  initialTrip: prompts.first,
                                ),
                                child: const Text('Upload'),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  if (filterLabels.isNotEmpty)
                    SliverToBoxAdapter(
                      child: SizedBox(
                        height: 44,
                        child: ListView(
                          scrollDirection: Axis.horizontal,
                          padding: const EdgeInsets.symmetric(horizontal: 20),
                          children: [
                            Padding(
                              padding: const EdgeInsets.only(right: 8),
                              child: ChoiceChip(
                                label: const Text('All'),
                                selected: _selectedTripFilter == null,
                                onSelected: (_) =>
                                    setState(() => _selectedTripFilter = null),
                              ),
                            ),
                            for (final label in filterLabels)
                              Padding(
                                padding: const EdgeInsets.only(right: 8),
                                child: ChoiceChip(
                                  label: Text(label),
                                  selected: _selectedTripFilter == label,
                                  onSelected: (_) => setState(
                                    () => _selectedTripFilter = label,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  if (filtered.isEmpty)
                    SliverFillRemaining(
                      hasScrollBody: false,
                      child: Center(
                        child: Padding(
                          padding: const EdgeInsets.all(28),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Container(
                                width: 72,
                                height: 72,
                                decoration: BoxDecoration(
                                  color:
                                      LakbayColors.primary.withValues(alpha: 0.12),
                                  shape: BoxShape.circle,
                                ),
                                child: const Icon(
                                  Icons.photo_album_outlined,
                                  size: 36,
                                  color: LakbayColors.primary,
                                ),
                              ),
                              const SizedBox(height: 16),
                              Text(
                                hasTrips
                                    ? 'No trip memories yet'
                                    : 'Plan a trip to start your album',
                                style: const TextStyle(
                                  fontFamily: 'FigGrotesk',
                                  fontSize: 19,
                                  fontWeight: FontWeight.w700,
                                  color: LakbayColors.tealDeep,
                                ),
                              ),
                              const SizedBox(height: 6),
                              Text(
                                hasTrips
                                    ? 'Capture and store photos from your Samal, Mati, Buda, or Davao City journeys.'
                                    : 'Memories belong to a trip. Plan or save a Davao Region trip first, then upload photos here or from your trip page.',
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                  fontSize: 13.5,
                                  color: Color(0xFF5D6B73),
                                ),
                              ),
                              const SizedBox(height: 18),
                              ElevatedButton.icon(
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: LakbayColors.tealDeep,
                                  foregroundColor: Colors.white,
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 20,
                                    vertical: 12,
                                  ),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(14),
                                  ),
                                ),
                                onPressed: hasTrips
                                    ? () => showAddTripMemorySheet(
                                          context,
                                          repo: widget.repo,
                                        )
                                    : () => widget.repo.setActiveNavIndex(2),
                                icon: Icon(
                                  hasTrips
                                      ? Icons.add_photo_alternate_outlined
                                      : Icons.auto_awesome_rounded,
                                ),
                                label: Text(
                                  hasTrips ? 'Upload First Memory' : 'Plan a trip',
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    )
                  else
                    SliverPadding(
                      padding: const EdgeInsets.fromLTRB(20, 10, 20, 110),
                      sliver: SliverList.separated(
                        itemCount: filtered.length,
                        separatorBuilder: (_, _) => const SizedBox(height: 14),
                        itemBuilder: (context, index) {
                          final memory = filtered[index];
                          return _MemoryCard(
                            memory: memory,
                            retrying: _retryingOutboxIds
                                .contains(memory.tripMemoryId),
                            onRetry: memory.isOutbox
                                ? () => _retryOutboxItem(memory)
                                : null,
                            onLike: () => _handleLike(memory),
                            onDelete: () => widget.repo.deleteMemory(memory),
                          );
                        },
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _MemoryCard extends StatelessWidget {
  final TripMemoryItem memory;
  final bool retrying;
  final VoidCallback? onRetry;
  final VoidCallback onLike;
  final VoidCallback onDelete;

  const _MemoryCard({
    required this.memory,
    this.retrying = false,
    this.onRetry,
    required this.onLike,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final decodedBytes = (memory.localBytesBase64 != null &&
            memory.localBytesBase64!.isNotEmpty)
        ? base64Decode(memory.localBytesBase64!)
        : null;
    final hasLocalFile =
        !kIsWeb &&
        memory.localFilePath != null &&
        memory.localFilePath!.isNotEmpty &&
        File(memory.localFilePath!).existsSync();
    final webBlobUrl = kIsWeb &&
            memory.imageUrl.isEmpty &&
            (memory.localFilePath ?? '').startsWith('blob:')
        ? memory.localFilePath!
        : '';

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: memory.isOutbox
            ? Border.all(color: const Color(0xFFFFB74D), width: 1.4)
            : null,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            height: 210,
            width: double.infinity,
            child: decodedBytes != null
                ? Image.memory(
                    decodedBytes,
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => _fallbackTile(),
                  )
                : (hasLocalFile
                    ? Image.file(
                        File(memory.localFilePath!),
                        fit: BoxFit.cover,
                        errorBuilder: (_, _, _) => _fallbackTile(),
                      )
                    : ((memory.imageUrl.isNotEmpty || webBlobUrl.isNotEmpty)
                        ? Image.network(
                            memory.imageUrl.isNotEmpty
                                ? LakbayImageSizing.sized(memory.imageUrl, 720)
                                : webBlobUrl,
                            fit: BoxFit.cover,
                            cacheWidth: 720,
                            gaplessPlayback: true,
                            errorBuilder: (_, _, _) => _fallbackTile(),
                          )
                        : _fallbackTile())),
          ),
          if (memory.isOutbox)
            Container(
              width: double.infinity,
              color: const Color(0xFFFFF8E1),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              child: Row(
                children: [
                  const Icon(
                    Icons.cloud_off_rounded,
                    size: 16,
                    color: Color(0xFFE65100),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      memory.uploadStatus == 'pending'
                          ? 'Uploading to Lakbay Cloud…'
                          : 'Not uploaded yet.${memory.uploadError != null ? ' ${memory.uploadError}' : ''}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF8D3B00),
                      ),
                    ),
                  ),
                  if (onRetry != null)
                    TextButton(
                      onPressed: retrying ? null : onRetry,
                      child: Text(retrying ? 'Retrying…' : 'Retry'),
                    ),
                ],
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if ((memory.locationTag ?? '').isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Row(
                      children: [
                        const Icon(
                          Icons.location_on_outlined,
                          size: 14,
                          color: LakbayColors.primary,
                        ),
                        const SizedBox(width: 4),
                        Expanded(
                          child: Text(
                            memory.locationTag!,
                            style: const TextStyle(
                              fontSize: 12.5,
                              fontWeight: FontWeight.w600,
                              color: LakbayColors.primary,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ),
                if ((memory.caption ?? '').isNotEmpty)
                  Text(
                    memory.caption!,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: LakbayColors.tealDeep,
                    ),
                  ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Text(
                      memory.uploadedByFullName,
                      style: const TextStyle(
                        fontSize: 12.5,
                        color: Color(0xFF6B7780),
                      ),
                    ),
                    const Spacer(),
                    InkWell(
                      onTap: onLike,
                      borderRadius: BorderRadius.circular(12),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(
                              Icons.favorite_outline,
                              size: 18,
                              color: LakbayColors.primary,
                            ),
                            const SizedBox(width: 4),
                            Text('${memory.likeCount}'),
                          ],
                        ),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(
                        Icons.delete_outline,
                        size: 19,
                        color: Color(0xFF7D8A91),
                      ),
                      onPressed: onDelete,
                      tooltip: 'Remove memory',
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _fallbackTile() => Container(
        color: const Color(0xFFE9EEF0),
        child: const Center(
          child: Icon(
            Icons.photo_outlined,
            size: 42,
            color: LakbayColors.tealDeep,
          ),
        ),
      );
}
