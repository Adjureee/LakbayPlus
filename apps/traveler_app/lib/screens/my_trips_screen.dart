import 'package:flutter/material.dart';
import '../models/travel_models.dart';
import '../services/travel_repository.dart';
import '../theme/lakbay_theme.dart';
import '../widgets/lakbay_image.dart';
import '../widgets/notifications_sheet.dart';
import 'trip_detail_screen.dart';

class MyTripsScreen extends StatefulWidget {
  final TravelRepository repo;

  const MyTripsScreen({super.key, required this.repo});

  @override
  State<MyTripsScreen> createState() => _MyTripsScreenState();
}

class _MyTripsScreenState extends State<MyTripsScreen> {
  final TextEditingController _searchController = TextEditingController();
  String _selectedFilter = 'All';
  bool _sortAlphabetical = false;

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _showCreateTripDialog() {
    final destController = TextEditingController();
    int days = 3;
    String vibe = 'Island Hopping & Highlands';

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) {
          return Padding(
            padding: EdgeInsets.only(
              left: 20,
              right: 20,
              top: 20,
              bottom: MediaQuery.of(ctx).viewInsets.bottom + 24,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  'Create Davao Region Trip',
                  style: TextStyle(
                    fontFamily: 'FigGrotesk',
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                    color: LakbayColors.tealDeep,
                  ),
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: destController,
                  decoration: InputDecoration(
                    labelText: 'Destination in Region XI',
                    hintText: 'e.g. Samal Island, Mati, or Mt. Apo',
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                Row(
                  children: [
                    const Text(
                      'Duration:',
                      style: TextStyle(fontWeight: FontWeight.w600),
                    ),
                    const Spacer(),
                    IconButton(
                      onPressed: days > 2
                          ? () => setSheetState(() => days--)
                          : null,
                      icon: const Icon(Icons.remove_circle_outline),
                    ),
                    Text(
                      '$days days',
                      style: const TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 16,
                      ),
                    ),
                    IconButton(
                      onPressed: days < 14
                          ? () => setSheetState(() => days++)
                          : null,
                      icon: const Icon(Icons.add_circle_outline),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                ElevatedButton(
                  onPressed: () {
                    // The AI drafts it from what the traveler typed; the trip
                    // is saved from the chat once they like it.
                    final where = destController.text.trim();
                    Navigator.of(ctx).pop();
                    widget.repo.planInChat(
                      'Plan a $days-day $vibe trip'
                      '${where.isEmpty ? '' : ' to $where'}.',
                    );
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: LakbayColors.primary,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(24),
                    ),
                  ),
                  child: const Text(
                    'Plan with Lakbay AI',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final query = _searchController.text.trim().toLowerCase();
    final allTrips = widget.repo.savedTrips;

    final filtered = allTrips.where((t) {
      if (query.isNotEmpty &&
          !t.title.toLowerCase().contains(query) &&
          !t.destination.toLowerCase().contains(query)) {
        return false;
      }
      if (_selectedFilter == 'Past') return false;
      if (_selectedFilter == 'Planning') {
        return t.id.startsWith('ai_trip_');
      }
      return true;
    }).toList();

    if (_sortAlphabetical) {
      filtered.sort((a, b) => a.title.compareTo(b.title));
    }

    final heroTrip = allTrips.isNotEmpty ? allTrips.first : null;

    return Scaffold(
      backgroundColor: LakbayColors.canvasBg,
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 110),
          children: [
            // Search Trips... + Add button
            Row(
              children: [
                Expanded(
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(28),
                      border: Border.all(color: LakbayColors.cardBorder),
                    ),
                    child: TextField(
                      controller: _searchController,
                      onChanged: (_) => setState(() {}),
                      decoration: const InputDecoration(
                        icon: Icon(
                          Icons.search_rounded,
                          color: LakbayColors.textSecondary,
                        ),
                        hintText: 'Search Trips...',
                        border: InputBorder.none,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                NotificationBellButton(
                  repo: widget.repo,
                  elevation: 0,
                ),
                const SizedBox(width: 8),
                Material(
                  color: LakbayColors.primary,
                  shape: const CircleBorder(),
                  child: IconButton(
                    tooltip: 'Create Trip',
                    onPressed: _showCreateTripDialog,
                    icon: const Icon(Icons.add_rounded, color: Colors.white),
                  ),
                ),
              ],
            ),

            if (widget.repo.invitations.isNotEmpty) ...[
              const SizedBox(height: 12),
              for (final inv in widget.repo.invitations)
                Container(
                  margin: const EdgeInsets.only(bottom: 8),
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: LakbayColors.primarySoft,
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(
                      color: LakbayColors.primary.withValues(alpha: 0.3),
                    ),
                  ),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.group_add_outlined,
                        color: LakbayColors.tealDeep,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              inv.tripTitle,
                              style: const TextStyle(
                                fontWeight: FontWeight.w800,
                                color: LakbayColors.tealDeep,
                              ),
                            ),
                            Text(
                              'Invited by ${inv.invitedByName} • ${inv.role}',
                              style: const TextStyle(
                                fontSize: 12.5,
                                color: LakbayColors.textSecondary,
                              ),
                            ),
                          ],
                        ),
                      ),
                      TextButton(
                        onPressed: () => widget.repo.answerInvitation(
                          inv.tripId,
                          accept: false,
                        ),
                        child: const Text('Decline'),
                      ),
                      FilledButton(
                        onPressed: () => widget.repo.answerInvitation(
                          inv.tripId,
                          accept: true,
                        ),
                        child: const Text('Accept'),
                      ),
                    ],
                  ),
                ),
            ],

            const SizedBox(height: 16),

            // Featured "Starts tomorrow" Hero Card (Image 7)
            if (heroTrip != null && query.isEmpty) ...[
              GestureDetector(
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) =>
                        TripDetailScreen(repo: widget.repo, trip: heroTrip),
                  ),
                ),
                child: Container(
                  height: 210,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(24),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.14),
                        blurRadius: 16,
                        offset: const Offset(0, 6),
                      ),
                    ],
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      LakbayNetworkOrAssetImage(
                        networkUrl: heroTrip.remoteImageUrl,
                        assetPath: heroTrip.heroAsset,
                      ),
                      Container(
                        decoration: const BoxDecoration(
                          gradient: LinearGradient(
                            colors: [
                              Color(0x11000000),
                              Color(0xBB071E26),
                            ],
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                          ),
                        ),
                      ),
                      Positioned(
                        top: 14,
                        left: 14,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 6,
                          ),
                          decoration: BoxDecoration(
                            color: LakbayColors.primaryLight,
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: const Text(
                            'Starts tomorrow',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w800,
                              color: LakbayColors.primaryDark,
                            ),
                          ),
                        ),
                      ),
                      Positioned(
                        left: 16,
                        right: 16,
                        bottom: 16,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              heroTrip.title,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontFamily: 'FigGrotesk',
                                fontSize: 22,
                                fontWeight: FontWeight.w800,
                                color: Colors.white,
                                height: 1.15,
                              ),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              '${heroTrip.daysCount} Days • ${heroTrip.adults + heroTrip.children} travellers • ${heroTrip.destination}',
                              style: TextStyle(
                                fontSize: 12.5,
                                color: Colors.white.withValues(alpha: 0.9),
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
            ],

            // Filter Chips + Sort Icon (Image 7)
            Row(
              children: [
                Expanded(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        for (final f in ['All', 'Upcoming', 'Planning', 'Past'])
                          Padding(
                            padding: const EdgeInsets.only(right: 8),
                            child: ChoiceChip(
                              label: Text(f),
                              selected: _selectedFilter == f,
                              onSelected: (_) =>
                                  setState(() => _selectedFilter = f),
                              selectedColor: LakbayColors.tealDeep,
                              backgroundColor: Colors.white,
                              labelStyle: TextStyle(
                                color: _selectedFilter == f
                                    ? Colors.white
                                    : LakbayColors.tealDeep,
                                fontWeight: FontWeight.w700,
                                fontSize: 13,
                              ),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(22),
                                side: const BorderSide(
                                  color: LakbayColors.cardBorder,
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                Material(
                  color: Colors.white,
                  shape: const CircleBorder(),
                  child: IconButton(
                    tooltip: _sortAlphabetical ? 'Sort: Default' : 'Sort: A-Z',
                    onPressed: () =>
                        setState(() => _sortAlphabetical = !_sortAlphabetical),
                    icon: Icon(
                      Icons.swap_vert_rounded,
                      color: _sortAlphabetical
                          ? LakbayColors.primary
                          : LakbayColors.tealDeep,
                    ),
                  ),
                ),
              ],
            ),

            const SizedBox(height: 14),

            if (filtered.isEmpty)
              Container(
                padding: const EdgeInsets.all(28),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(22),
                  border: Border.all(color: LakbayColors.cardBorder),
                ),
                child: Column(
                  children: [
                    const Icon(
                      Icons.map_outlined,
                      size: 40,
                      color: LakbayColors.textSecondary,
                    ),
                    const SizedBox(height: 10),
                    Text(
                      'No $_selectedFilter trips yet',
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 16,
                        color: LakbayColors.tealDeep,
                      ),
                    ),
                    const SizedBox(height: 4),
                    const Text(
                      'Ask Lakbay+ in Chat to generate a Davao Region itinerary.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 13,
                        color: LakbayColors.textSecondary,
                      ),
                    ),
                  ],
                ),
              )
            else
              for (final trip in filtered)
                _TripListTile(
                  trip: trip,
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) =>
                          TripDetailScreen(repo: widget.repo, trip: trip),
                    ),
                  ),
                  onDelete: () {
                    widget.repo.removeSavedTrip(trip.id);
                    setState(() {});
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text('Removed "${trip.title}"'),
                        backgroundColor: LakbayColors.tealDeep,
                      ),
                    );
                  },
                ),
          ],
        ),
      ),
    );
  }
}

class _TripListTile extends StatelessWidget {
  final ItineraryTrip trip;
  final VoidCallback onTap;
  final VoidCallback? onDelete;

  const _TripListTile({
    required this.trip,
    required this.onTap,
    this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final isPlanning = trip.id.startsWith('ai_trip_') ||
        trip.id.startsWith('ai_opt_') ||
        trip.id.startsWith('multi_');

    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: LakbayColors.cardBorder),
        ),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(14),
              child: LakbayNetworkOrAssetImage(
                networkUrl: trip.remoteImageUrl,
                assetPath: trip.heroAsset,
                width: 58,
                height: 58,
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    trip.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontFamily: 'FigGrotesk',
                      fontWeight: FontWeight.w700,
                      fontSize: 15.5,
                      color: LakbayColors.tealDeep,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${isPlanning ? 'Planning' : 'Upcoming'} • ${trip.daysCount} Days • ${trip.destination}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 12.5,
                      color: LakbayColors.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
            if (onDelete != null)
              IconButton(
                tooltip: 'Archive Trip',
                onPressed: onDelete,
                icon: const Icon(
                  Icons.delete_outline_rounded,
                  color: LakbayColors.textMuted,
                  size: 20,
                ),
              ),
            const Icon(
              Icons.chevron_right_rounded,
              color: LakbayColors.textSecondary,
            ),
          ],
        ),
      ),
    );
  }
}
