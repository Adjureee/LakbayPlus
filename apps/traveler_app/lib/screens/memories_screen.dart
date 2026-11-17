import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../models/travel_models.dart';
import '../services/travel_repository.dart';
import '../theme/lakbay_theme.dart';

class MemoriesScreen extends StatefulWidget {
  final TravelRepository repo;

  const MemoriesScreen({super.key, required this.repo});

  @override
  State<MemoriesScreen> createState() => _MemoriesScreenState();
}

class _MemoriesScreenState extends State<MemoriesScreen> {
  String? _selectedTripFilter;
  bool _refreshing = false;

  @override
  void initState() {
    super.initState();
    _refresh();
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

  void _openAddMemorySheet() {
    final trips = widget.repo.savedTrips;
    if (trips.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Save a Davao Region trip first before adding memories.',
          ),
          backgroundColor: LakbayColors.tealDeep,
        ),
      );
      return;
    }

    var selectedTrip = trips.first;
    final captionCtrl = TextEditingController();
    final locationCtrl = TextEditingController(text: selectedTrip.destination);
    XFile? pickedFile;
    bool saving = false;

    showModalBottomSheet<void>(
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
                if (file != null) {
                  setSheetState(() => pickedFile = file);
                }
              } catch (e) {
                if (!sheetContext.mounted) return;
                ScaffoldMessenger.of(sheetContext).showSnackBar(
                  SnackBar(content: Text('Could not pick photo: $e')),
                );
              }
            }

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
                                t.title,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                        ],
                        onChanged: (value) {
                          if (value == null) return;
                          final match = trips.firstWhere((t) => t.id == value);
                          setSheetState(() {
                            selectedTrip = match;
                            locationCtrl.text = match.destination;
                          });
                        },
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: saving
                                  ? null
                                  : () => pickImage(ImageSource.gallery),
                              icon: const Icon(Icons.photo_library_outlined),
                              label: const Text('Gallery'),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: saving
                                  ? null
                                  : () => pickImage(ImageSource.camera),
                              icon: const Icon(Icons.camera_alt_outlined),
                              label: const Text('Camera'),
                            ),
                          ),
                        ],
                      ),
                      if (pickedFile != null) ...[
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
                          onPressed: saving || pickedFile == null
                              ? null
                              : () async {
                                  setSheetState(() => saving = true);
                                  try {
                                    await widget.repo.uploadAndAddMemory(
                                      trip: selectedTrip,
                                      localFilePath: pickedFile!.path,
                                      caption: captionCtrl.text.trim(),
                                      locationTag: locationCtrl.text.trim(),
                                    );
                                    if (sheetContext.mounted) {
                                      Navigator.of(sheetContext).pop();
                                    }
                                  } catch (e) {
                                    setSheetState(() => saving = false);
                                    if (sheetContext.mounted) {
                                      ScaffoldMessenger.of(sheetContext)
                                          .showSnackBar(
                                            SnackBar(
                                              content: Text(
                                                'Failed to save memory: $e',
                                              ),
                                            ),
                                          );
                                    }
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
                          label: Text(saving ? 'Uploading...' : 'Save Memory'),
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

  @override
  Widget build(BuildContext context) {
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
                        onPressed: _openAddMemorySheet,
                        icon: const Icon(Icons.add_a_photo_outlined, size: 18),
                        label: const Text('Add Photo'),
                      ),
                    ],
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
                              onSelected: (_) =>
                                  setState(() => _selectedTripFilter = label),
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
                              color: LakbayColors.primary.withValues(
                                alpha: 0.12,
                              ),
                              shape: BoxShape.circle,
                            ),
                            child: const Icon(
                              Icons.photo_album_outlined,
                              size: 36,
                              color: LakbayColors.primary,
                            ),
                          ),
                          const SizedBox(height: 16),
                          const Text(
                            'No trip memories yet',
                            style: TextStyle(
                              fontFamily: 'FigGrotesk',
                              fontSize: 19,
                              fontWeight: FontWeight.w700,
                              color: LakbayColors.tealDeep,
                            ),
                          ),
                          const SizedBox(height: 6),
                          const Text(
                            'Capture and store photos from your Samal, Mati, Buda, or Davao City journeys.',
                            textAlign: TextAlign.center,
                            style: TextStyle(
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
                            onPressed: _openAddMemorySheet,
                            icon: const Icon(
                              Icons.add_photo_alternate_outlined,
                            ),
                            label: const Text('Upload First Memory'),
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
                        onLike: () => widget.repo.likeMemory(memory),
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
  }
}

class _MemoryCard extends StatelessWidget {
  final TripMemoryItem memory;
  final VoidCallback onLike;
  final VoidCallback onDelete;

  const _MemoryCard({
    required this.memory,
    required this.onLike,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final hasLocalFile =
        !kIsWeb &&
        memory.localFilePath != null &&
        File(memory.localFilePath!).existsSync();
    final webBlobUrl =
        kIsWeb &&
            memory.imageUrl.isEmpty &&
            (memory.localFilePath ?? '').startsWith('blob:')
        ? memory.localFilePath!
        : '';

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
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
            child: hasLocalFile
                ? Image.file(File(memory.localFilePath!), fit: BoxFit.cover)
                : ((memory.imageUrl.isNotEmpty || webBlobUrl.isNotEmpty)
                      ? Image.network(
                          memory.imageUrl.isNotEmpty
                              ? memory.imageUrl
                              : webBlobUrl,
                          fit: BoxFit.cover,
                          errorBuilder: (_, _, _) => _fallbackTile(),
                        )
                      : _fallbackTile()),
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
      child: Icon(Icons.photo_outlined, size: 42, color: LakbayColors.tealDeep),
    ),
  );
}
