import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../models/travel_models.dart';
import '../services/friendly_error.dart';
import '../services/travel_repository.dart';

import '../design/design.dart';

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

  Future<void> _confirmDelete(TripMemoryItem memory) async {
    final ok = await showLkConfirm(
      context,
      title: 'Delete this memory?',
      message: 'The photo and its caption will be deleted.',
      confirmLabel: 'Delete memory',
    );
    if (!ok || !mounted) return;
    final repo = widget.repo;
    final index = repo.takeMemory(memory);
    if (index < 0) return;
    var undone = false;
    showLkUndoSnack(
      context,
      message: 'Memory deleted',
      onUndo: () {
        undone = true;
        repo.restoreMemory(memory, index);
      },
    ).closed.then((_) {
      if (!undone) repo.commitMemoryRemoval(memory);
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

  void _openAddMemorySheet() {
    final trips = widget.repo.savedTrips;
    if (trips.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Save a Davao Region trip first before adding memories.',
          ),
          backgroundColor: LkColors.s3,
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
      backgroundColor: LkColors.s1,
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
                  const SnackBar(
                    content: Text("Couldn't open that photo. Try another one."),
                  ),
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
                            color: LkColors.strokeStrong,
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                      ),
                      Text(
                        'Add Trip Memory',
                        style: TextStyle(
                          fontFamily: LkType.displayFamily,
                          fontSize: 20,
                          fontWeight: FontWeight.w700,
                          color: LkColors.text,
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
                                excludeFromSemantics: true,
                                )
                              : Image.file(
                                  File(pickedFile!.path),
                                  height: 160,
                                  width: double.infinity,
                                  fit: BoxFit.cover,
                                excludeFromSemantics: true,
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
                            backgroundColor: LkColors.mango,
                            foregroundColor: LkColors.mangoInk,
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
                                                "Couldn't save the memory. "
                                                '${friendlyError(e)}',
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
    String groupOf(TripMemoryItem m) {
      final tag = (m.locationTag ?? '').trim();
      if (tag.isNotEmpty) return tag;
      final dest = (m.destinationName ?? '').trim();
      return dest.isNotEmpty ? dest : 'Other moments';
    }

    final filtered = _selectedTripFilter == null
        ? allMemories
        : allMemories.where((m) => groupOf(m) == _selectedTripFilter).toList();

    final filterLabels = {for (final m in allMemories) groupOf(m)}.toList();
    // Grouped by place, in the order they first appear.
    final groups = <String, List<TripMemoryItem>>{};
    for (final m in filtered) {
      groups.putIfAbsent(groupOf(m), () => []).add(m);
    }
    final bottomClear = MediaQuery.paddingOf(context).bottom;

    return Scaffold(
      backgroundColor: LkColors.bg,
      body: SafeArea(
        bottom: false,
        child: RefreshIndicator(
          onRefresh: _refresh,
          child: CustomScrollView(
            slivers: [
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(
                    LkSpace.gutter,
                    LkSpace.l,
                    LkSpace.gutter,
                    LkSpace.m,
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Semantics(
                              header: true,
                              child: Text('Memories', style: LkType.h1),
                            ),
                            const SizedBox(height: LkSpace.xxs),
                            Text(
                              'Photos from your Davao Region trips',
                              style: LkType.caption,
                            ),
                          ],
                        ),
                      ),
                      LkButton(
                        label: 'Add photo',
                        icon: Icons.add_a_photo_outlined,
                        onPressed: _openAddMemorySheet,
                      ),
                    ],
                  ),
                ),
              ),
              if (filterLabels.length > 1)
                SliverToBoxAdapter(
                  child: SizedBox(
                    height: kLkMinTarget,
                    child: ListView(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(
                        horizontal: LkSpace.gutter,
                      ),
                      children: [
                        Padding(
                          padding: const EdgeInsets.only(right: LkSpace.s),
                          child: Center(
                            child: ChoiceChip(
                              label: const Text('All'),
                              selected: _selectedTripFilter == null,
                              onSelected: (_) =>
                                  setState(() => _selectedTripFilter = null),
                            ),
                          ),
                        ),
                        for (final label in filterLabels)
                          Padding(
                            padding: const EdgeInsets.only(right: LkSpace.s),
                            child: Center(
                              child: ChoiceChip(
                                label: Text(label),
                                selected: _selectedTripFilter == label,
                                onSelected: (_) =>
                                    setState(() => _selectedTripFilter = label),
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
                      padding: const EdgeInsets.all(LkSpace.gutter),
                      child: LkEmptyState(
                        icon: Icons.photo_album_outlined,
                        title: 'No trip memories yet',
                        message:
                            'Add photos from your Samal, Mati, Buda or '
                            'Davao City trips.',
                        actionLabel: 'Add your first photo',
                        onAction: _openAddMemorySheet,
                      ),
                    ),
                  ),
                )
              else
                for (final entry in groups.entries) ...[
                  SliverToBoxAdapter(
                    child: LkSectionHeader(
                      title: entry.key,
                      padding: const EdgeInsets.fromLTRB(
                        LkSpace.gutter,
                        LkSpace.l,
                        LkSpace.gutter,
                        LkSpace.s,
                      ),
                    ),
                  ),
                  SliverPadding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: LkSpace.gutter,
                    ),
                    sliver: SliverList.separated(
                      itemCount: entry.value.length,
                      separatorBuilder: (_, _) =>
                          const SizedBox(height: LkSpace.m),
                      itemBuilder: (context, index) {
                        final memory = entry.value[index];
                        return LkRiseIn(
                          key: ValueKey('memory-${memory.tripMemoryId}-$index'),
                          delay: LkRiseIn.stagger(index),
                          child: _MemoryCard(
                            memory: memory,
                            onLike: () => widget.repo.likeMemory(memory),
                            onDelete: () => _confirmDelete(memory),
                          ),
                        );
                      },
                    ),
                  ),
                ],
              SliverToBoxAdapter(
                child: SizedBox(height: bottomClear + LkSpace.xl),
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
        color: LkColors.s1,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: LkColors.stroke),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            height: 210,
            width: double.infinity,
            child: hasLocalFile
                ? Image.file(File(memory.localFilePath!), fit: BoxFit.cover, excludeFromSemantics: true)
                : ((memory.imageUrl.isNotEmpty || webBlobUrl.isNotEmpty)
                      ? Image.network(
                          memory.imageUrl.isNotEmpty
                              ? memory.imageUrl
                              : webBlobUrl,
                          fit: BoxFit.cover,
                          errorBuilder: (_, _, _) => _fallbackTile(),
                        excludeFromSemantics: true,
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
                        Icon(
                          Icons.location_on_outlined,
                          size: 14,
                          color: LkColors.lagoon,
                        ),
                        const SizedBox(width: 4),
                        Expanded(
                          child: Text(
                            memory.locationTag!,
                            style: TextStyle(
                              fontSize: 12.5,
                              fontWeight: FontWeight.w600,
                              color: LkColors.lagoon,
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
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: LkColors.text,
                    ),
                  ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Text(
                      memory.uploadedByFullName,
                      style: TextStyle(
                        fontSize: 12.5,
                        color: LkColors.muted,
                      ),
                    ),
                    const Spacer(),
                    Semantics(
                      button: true,
                      label: 'Like, ${memory.likeCount} likes',
                      excludeSemantics: true,
                      child: InkWell(
                        onTap: onLike,
                        borderRadius: BorderRadius.circular(12),
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(
                            minHeight: kLkMinTarget,
                            minWidth: kLkMinTarget,
                          ),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  Icons.favorite_outline,
                                  size: 18,
                                  color: LkColors.lagoon,
                                ),
                                const SizedBox(width: 4),
                                Text('${memory.likeCount}'),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                    IconButton(
                      icon: Icon(
                        Icons.delete_outline,
                        size: 19,
                        color: LkColors.muted,
                      ),
                      onPressed: onDelete,
                      tooltip: 'Delete memory',
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
    color: LkColors.s2,
    child: Center(
      child: Icon(Icons.photo_outlined, size: 42, color: LkColors.faint),
    ),
  );
}
