import 'package:flutter/material.dart';
import '../models/travel_models.dart';
import '../services/mapbox_service.dart';
import '../services/travel_repository.dart';
import '../theme/lakbay_theme.dart';
import '../widgets/lakbay_image.dart';
import '../widgets/lakbay_mapbox_widget.dart';
import '../widgets/trip_management_sheets.dart';
import 'trip_route_map_screen.dart';

class TripDetailScreen extends StatefulWidget {
  final ItineraryTrip trip;
  final TravelRepository repo;

  const TripDetailScreen({
    super.key,
    required this.trip,
    required this.repo,
  });

  @override
  State<TripDetailScreen> createState() => _TripDetailScreenState();
}

class _TripDetailScreenState extends State<TripDetailScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  ItineraryTrip? _liveTrip;
  bool _loadingLive = false;
  bool _isRefining = false;
  String _selectedTravelMode = 'driving';
  List<String> _routeWarnings = const [];
  final Set<String> _packedItems = {};

  ItineraryTrip get _activeTrip => _liveTrip ?? widget.trip;

  List<String> _derivePackingChecklist(ItineraryTrip trip) {
    final items = <String>{};
    if (trip.whatToBring != null && trip.whatToBring!.trim().isNotEmpty) {
      for (final raw in trip.whatToBring!.split(RegExp(r'[,;\n]'))) {
        final clean = raw.trim();
        if (clean.isNotEmpty) items.add(clean);
      }
    }
    if (trip.wmoWeatherCode >= 51 ||
        trip.avgTemp.toLowerCase().contains('rain') ||
        trip.avgTemp.toLowerCase().contains('shower')) {
      items.addAll(['Compact Umbrella / Rain Poncho', 'Dry Bag for Electronics']);
    } else {
      items.addAll(['SPF50+ Sunscreen & Shades', 'Refillable Water Bottle']);
    }
    if (items.isEmpty) {
      items.addAll([
        'Valid ID & Cash (₱ Small Bills)',
        'Comfortable Walking Shoes',
        'Powerbank & Light Jacket',
      ]);
    }
    return items.take(8).toList();
  }

  Future<void> _handleOptimizeRoute() async {
    setState(() => _isRefining = true);
    final updated = await widget.repo.optimizeStopsForTrip(
      _activeTrip,
      travelMode: _selectedTravelMode,
    );
    final routeRes = await widget.repo.fetchRoadRouteForTrip(
      updated,
      optimize: true,
      travelMode: _selectedTravelMode,
    );
    if (!mounted) return;
    setState(() {
      _liveTrip = updated;
      if (routeRes != null) _routeWarnings = routeRes.warnings;
      _isRefining = false;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Route order optimized across Davao Region stops!'),
        backgroundColor: LakbayColors.tealDeep,
      ),
    );
  }

  Future<void> _changeTravelMode(String mode) async {
    setState(() {
      _selectedTravelMode = mode;
      _isRefining = true;
    });
    widget.repo.setPreferredTravelMode(mode);
    final routeRes = await widget.repo.fetchRoadRouteForTrip(
      _activeTrip,
      travelMode: mode,
    );
    if (!mounted) return;
    setState(() {
      _routeWarnings = routeRes?.warnings ?? const [];
      _isRefining = false;
    });
  }

  Future<void> _handleAiRefine(String instruction) async {
    setState(() => _isRefining = true);
    final refined = await widget.repo.refineTripWithAi(_activeTrip, instruction);
    if (!mounted) return;
    setState(() {
      if (refined != null) _liveTrip = refined;
      _isRefining = false;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          refined != null
              ? 'Updated itinerary: "$instruction"'
              : 'AI refinement saved locally — inspect or customize stops below.',
        ),
        backgroundColor: LakbayColors.tealDeep,
      ),
    );
  }

  Future<void> _showAddStopDialog(int dayIndex) async {
    final timeCtrl = TextEditingController(text: '02:00 PM');
    final titleCtrl = TextEditingController();
    final descCtrl = TextEditingController();
    final added = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Add Stop to Day ${dayIndex + 1}'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: timeCtrl,
              decoration: const InputDecoration(labelText: 'Time (e.g. 02:00 PM)'),
            ),
            TextField(
              controller: titleCtrl,
              decoration: const InputDecoration(labelText: 'Stop Name'),
            ),
            TextField(
              controller: descCtrl,
              decoration: const InputDecoration(labelText: 'Notes / Activity'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Add Stop'),
          ),
        ],
      ),
    );
    if (added == true && titleCtrl.text.trim().isNotEmpty) {
      final days = List<ItineraryDay>.from(_activeTrip.days);
      final day = days[dayIndex];
      final updatedStops = List<ItineraryStop>.from(day.stops)
        ..add(
          ItineraryStop(
            time: timeCtrl.text.trim().isNotEmpty ? timeCtrl.text.trim() : '02:00 PM',
            title: titleCtrl.text.trim(),
            description: descCtrl.text.trim().isNotEmpty
                ? descCtrl.text.trim()
                : 'Custom Davao Region stop added by traveler.',
            category: 'Custom',
            costEstimateUsd: 8,
            lat: day.lat,
            lng: day.lng,
          ),
        );
      days[dayIndex] = day.copyWith(stops: updatedStops);
      final nextTrip = _activeTrip.copyWith(days: days);
      setState(() => _liveTrip = nextTrip);
      widget.repo.updateTripDetails(nextTrip);
    }
    timeCtrl.dispose();
    titleCtrl.dispose();
    descCtrl.dispose();
  }

  void _removeStop(int dayIndex, int stopIndex) {
    final days = List<ItineraryDay>.from(_activeTrip.days);
    final day = days[dayIndex];
    if (day.stops.length <= 1) return;
    final updatedStops = List<ItineraryStop>.from(day.stops)..removeAt(stopIndex);
    days[dayIndex] = day.copyWith(stops: updatedStops);
    final nextTrip = _activeTrip.copyWith(days: days);
    setState(() => _liveTrip = nextTrip);
    widget.repo.updateTripDetails(nextTrip);
  }

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    _loadLiveDetails();
  }

  Future<void> _loadLiveDetails() async {
    if (_loadingLive) return;
    _loadingLive = true;
    try {
      final enriched = await widget.repo.loadLiveDetailsForTrip(widget.trip);
      if (!mounted) return;
      setState(() {
        _liveTrip = enriched;
        _loadingLive = false;
      });
    } catch (_) {
      _loadingLive = false;
    }
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  String _transitSprite(TransportMode mode) {
    switch (mode) {
      case TransportMode.flight:
        return 'assets/map_sprites/means-plane.png';
      case TransportMode.ferry:
        return 'assets/map_sprites/means-boat.png';
      case TransportMode.bus:
        return 'assets/map_sprites/means-bus.png';
      case TransportMode.train:
        return 'assets/map_sprites/means-train.png';
      case TransportMode.car:
        return 'assets/map_sprites/means-car.png';
    }
  }

  void _openFullRouteMap() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) =>
            TripRouteMapScreen(trip: widget.trip, repo: widget.repo),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final trip = _activeTrip;
    final isSaved = widget.repo.savedTrips.any((t) => t.id == trip.id);
    final isBucketed = widget.repo.isTripInBucketList(trip.id);

    return Scaffold(
      backgroundColor: LakbayColors.canvasBg,
      body: NestedScrollView(
        headerSliverBuilder: (context, innerBoxIsScrolled) => [
          SliverAppBar(
            expandedHeight: 280,
            pinned: true,
            backgroundColor: LakbayColors.tealDeep,
            foregroundColor: Colors.white,
            actions: [
              IconButton(
                tooltip: 'Play Animated Mapbox Route',
                onPressed: _openFullRouteMap,
                icon: const Icon(Icons.map_rounded, color: Colors.white),
              ),
              IconButton(
                tooltip: 'Save to Bucket List',
                onPressed: () {
                  widget.repo.toggleBucketListTrip(trip.id);
                  setState(() {});
                },
                icon: Icon(
                  isBucketed
                      ? Icons.favorite_rounded
                      : Icons.favorite_border_rounded,
                  color: isBucketed ? LakbayColors.primary : Colors.white,
                ),
              ),
              IconButton(
                tooltip: 'Save to My Trips',
                onPressed: () {
                  widget.repo.saveTripToMyTrips(trip);
                  setState(() {});
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('Saved "${trip.title}" to My Trips!'),
                      backgroundColor: LakbayColors.tealDeep,
                    ),
                  );
                },
                icon: Icon(
                  isSaved
                      ? Icons.bookmark_added_rounded
                      : Icons.bookmark_add_outlined,
                ),
              ),
            ],
            flexibleSpace: FlexibleSpaceBar(
              background: Stack(
                fit: StackFit.expand,
                children: [
                  LakbayNetworkOrAssetImage(
                    networkUrl: _activeTrip.remoteImageUrl,
                    assetPath: _activeTrip.heroAsset,
                  ),
                  Container(
                    decoration: const BoxDecoration(
                      gradient: LakbayColors.darkOverlayGradient,
                    ),
                  ),
                  Positioned(
                    left: 20,
                    right: 20,
                    bottom: 58,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Wrap(
                          spacing: 8,
                          runSpacing: 6,
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 10, vertical: 4),
                              decoration: BoxDecoration(
                                color: LakbayColors.primary,
                                borderRadius: BorderRadius.circular(20),
                              ),
                              child: Text(
                                '${trip.daysCount} DAYS • ${trip.vibeTag.toUpperCase()}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 10, vertical: 4),
                              decoration: BoxDecoration(
                                color: Colors.black.withValues(alpha: 0.45),
                                borderRadius: BorderRadius.circular(20),
                              ),
                              child: Text(
                                'Est. ${widget.repo.formatPrice(trip.totalEstimatedCostUsd)}',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Text(
                          trip.title,
                          style: const TextStyle(
                            fontFamily: 'FigGrotesk',
                            fontSize: 25,
                            fontWeight: FontWeight.w700,
                            color: Colors.white,
                            height: 1.15,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            bottom: TabBar(
              controller: _tabController,
              indicatorColor: LakbayColors.primary,
              indicatorWeight: 3,
              labelColor: Colors.white,
              unselectedLabelColor: Colors.white70,
              labelPadding: const EdgeInsets.symmetric(horizontal: 6),
              labelStyle: const TextStyle(
                fontFamily: 'FigGrotesk',
                fontWeight: FontWeight.w700,
                fontSize: 13,
              ),
              tabs: const [
                Tab(text: 'Overview'),
                Tab(text: 'Day-by-Day'),
                Tab(text: 'Stays & Transit'),
              ],
            ),
          ),
        ],
        body: TabBarView(
          controller: _tabController,
          children: [
            _buildOverviewTab(_activeTrip),
            _buildDayByDayTab(_activeTrip),
            _buildStaysAndFlightsTab(_activeTrip),
          ],
        ),
      ),
      bottomNavigationBar: SafeArea(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          decoration: BoxDecoration(
            color: Colors.white,
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.06),
                blurRadius: 12,
                offset: const Offset(0, -4),
              ),
            ],
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Est. Total',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        color: LakbayColors.textSecondary,
                      ),
                    ),
                    Text(
                      '${widget.repo.formatPrice(trip.totalEstimatedCostUsd)} • ${trip.adults + trip.children} pax',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontFamily: 'FigGrotesk',
                        fontWeight: FontWeight.w700,
                        fontSize: 15,
                        color: LakbayColors.tealDeep,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filledTonal(
                tooltip: 'Collaborate (Members & Tasks)',
                onPressed: () => showTripCollaborationSheet(
                  context,
                  repo: widget.repo,
                  trip: trip,
                ),
                icon: const Icon(Icons.group_add_outlined),
              ),
              const SizedBox(width: 6),
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 12,
                  ),
                ),
                onPressed: () {
                  widget.repo.saveTripToMyTrips(trip);
                  showTripBudgetAndPdfSheet(
                    context,
                    repo: widget.repo,
                    trip: trip,
                  );
                },
                icon: const Icon(Icons.account_balance_wallet_outlined, size: 18),
                label: const Text('Budget & PDF'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildOverviewTab(ItineraryTrip trip) {
    final waypoints = trip.routeWaypoints;
    final totalKm = MapboxService.calculateRouteDistanceKm(waypoints);
    final markers = [
      for (int i = 0; i < trip.days.length; i++)
        () {
          final day = trip.days[i];
          final media = widget.repo.resolveDayMarkerMedia(trip, day);
          return LakbayMapMarker(
            id: 'day_${day.dayNumber}',
            lat: day.lat,
            lng: day.lng,
            badgeText: 'D${day.dayNumber}',
            title: day.cityTitle,
            imageUrl: media.imageUrl,
            imageAsset: media.imageAsset,
            isPrimary: i == 0,
            isOrigin: i == 0,
            isDestination: i == trip.days.length - 1,
          );
        }(),
      if (widget.repo.hasUserLocation)
        LakbayMapMarker(
          id: 'user_gps',
          lat: widget.repo.userLat!,
          lng: widget.repo.userLng!,
          title: 'You (${widget.repo.effectiveOriginLabel})',
          isUserLocation: true,
        ),
    ];

    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Row(
          children: [
            _buildInfoChip(
              iconWidget: Image.asset(
                'assets/png/weather/${trip.wmoWeatherCode}.png',
                width: 22,
                height: 22,
                errorBuilder: (_, _, _) => const Icon(Icons.wb_sunny_rounded,
                    color: LakbayColors.primary, size: 20),
              ),
              label: 'Davao Weather',
              value: trip.avgTemp,
            ),
            const SizedBox(width: 10),
            _buildInfoChip(
              iconWidget: const Icon(Icons.calendar_month_rounded,
                  color: LakbayColors.primary, size: 20),
              label: 'Best Months',
              value: trip.bestMonths,
            ),
            const SizedBox(width: 10),
            _buildInfoChip(
              iconWidget: const Icon(Icons.route_rounded,
                  color: LakbayColors.primary, size: 20),
              label: 'Region XI Route',
              value: '${totalKm.toStringAsFixed(0)} km',
            ),
          ],
        ),
        const SizedBox(height: 20),

        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            ChoiceChip(
              avatar: const Icon(Icons.directions_car_outlined, size: 16),
              label: const Text('Private Car'),
              selected: _selectedTravelMode == 'driving',
              onSelected: (_) => _changeTravelMode('driving'),
            ),
            ChoiceChip(
              avatar: const Icon(Icons.directions_bus_outlined, size: 16),
              label: const Text('Public Transit'),
              selected: _selectedTravelMode == 'public_transport',
              onSelected: (_) => _changeTravelMode('public_transport'),
            ),
            ChoiceChip(
              avatar: const Icon(Icons.directions_walk_outlined, size: 16),
              label: const Text('Walking'),
              selected: _selectedTravelMode == 'walking',
              onSelected: (_) => _changeTravelMode('walking'),
            ),
          ],
        ),
        if (_routeWarnings.isNotEmpty) ...[
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Colors.amber.shade50,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.amber.shade300),
            ),
            child: Text(
              _routeWarnings.join('\n'),
              style: const TextStyle(fontSize: 12.5, color: LakbayColors.tealDeep),
            ),
          ),
        ],
        const SizedBox(height: 12),

        Row(
          children: [
            const Expanded(
              child: Text(
                'Animated Route',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontFamily: 'FigGrotesk',
                  fontWeight: FontWeight.w700,
                  fontSize: 18,
                ),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton.tonalIcon(
              onPressed: _openFullRouteMap,
              style: FilledButton.styleFrom(
                backgroundColor: LakbayColors.primaryLight,
                foregroundColor: LakbayColors.primaryDark,
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
              ),
              icon: const Icon(Icons.play_arrow_rounded, size: 18),
              label: const Text('Play Tour'),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            ActionChip(
              avatar: const Icon(Icons.group_add_outlined, size: 17),
              label: const Text('Collaborate'),
              onPressed: () => showTripCollaborationSheet(
                context,
                repo: widget.repo,
                trip: trip,
              ),
            ),
            ActionChip(
              avatar: const Icon(Icons.pie_chart_outline_rounded, size: 17),
              label: const Text('Budget & Split'),
              onPressed: () => showTripBudgetAndPdfSheet(
                context,
                repo: widget.repo,
                trip: trip,
              ),
            ),
            ActionChip(
              avatar: const Icon(Icons.photo_library_outlined, size: 17),
              label: const Text('Memories'),
              onPressed: () {
                widget.repo.setActiveNavIndex(3);
                Navigator.of(context).popUntil((r) => r.isFirst);
              },
            ),
            ActionChip(
              avatar: const Icon(Icons.rate_review_outlined, size: 17),
              label: const Text('Review & Survey'),
              onPressed: () => showTripReviewAndAssessmentSheet(
                context,
                repo: widget.repo,
                trip: trip,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Container(
          height: 240,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(22),
            border: Border.all(color: LakbayColors.cardBorder),
          ),
          child: LakbayMapboxMap(
            repo: widget.repo,
            initialLat: trip.centerLat,
            initialLng: trip.centerLng,
            initialZoom: 8.4,
            routePoints: waypoints,
            markers: markers,
            onMarkerTap: (_) => _openFullRouteMap(),
          ),
        ),
        const SizedBox(height: 22),

        const Text(
          'Why You’ll Love This Davao Route',
          style: TextStyle(
            fontFamily: 'FigGrotesk',
            fontWeight: FontWeight.w700,
            fontSize: 20,
          ),
        ),
        const SizedBox(height: 10),
        if (trip.overviewText.isNotEmpty) ...[
          Text(
            trip.overviewText,
            style: const TextStyle(
              fontSize: 13.5,
              height: 1.45,
              color: LakbayColors.textSecondary,
            ),
          ),
          const SizedBox(height: 16),
        ],
        if (trip.advisories.isNotEmpty) ...[
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: Colors.amber.shade50,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: Colors.amber.shade300),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Row(
                  children: [
                    Icon(Icons.health_and_safety_rounded,
                        color: Colors.deepOrange, size: 18),
                    SizedBox(width: 8),
                    Text(
                      'Smart Planning Advisories',
                      style: TextStyle(
                        fontFamily: 'FigGrotesk',
                        fontWeight: FontWeight.w700,
                        fontSize: 14.5,
                        color: LakbayColors.tealDeep,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                for (final adv in trip.advisories.take(4))
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Text(
                      '• $adv',
                      style: const TextStyle(
                        fontSize: 12.5,
                        color: LakbayColors.textPrimary,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 16),
        ],
        const Text(
          'Refine with Lakbay+ AI',
          style: TextStyle(
            fontFamily: 'FigGrotesk',
            fontWeight: FontWeight.w700,
            fontSize: 17,
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            ActionChip(
              avatar: const Icon(Icons.savings_outlined, size: 16),
              label: const Text('More budget-friendly'),
              onPressed: _isRefining
                  ? null
                  : () => _handleAiRefine('Optimize for a tighter budget'),
            ),
            ActionChip(
              avatar: const Icon(Icons.child_care_rounded, size: 16),
              label: const Text('Kid-friendly pace'),
              onPressed: _isRefining
                  ? null
                  : () => _handleAiRefine('Make pace kid-friendly and relaxed'),
            ),
            ActionChip(
              avatar: const Icon(Icons.beach_access_rounded, size: 16),
              label: const Text('Add chill scenic stop'),
              onPressed: _isRefining
                  ? null
                  : () => _handleAiRefine('Include chill coastal or viewpoint stop'),
            ),
          ],
        ),
        const SizedBox(height: 18),
        const Text(
          'What to Bring & Weather Packing Checklist',
          style: TextStyle(
            fontFamily: 'FigGrotesk',
            fontWeight: FontWeight.w700,
            fontSize: 17,
          ),
        ),
        const SizedBox(height: 8),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: LakbayColors.cardBorder),
          ),
          child: Wrap(
            spacing: 8,
            runSpacing: 6,
            children: _derivePackingChecklist(trip)
                .map(
                  (item) => FilterChip(
                    label: Text(item, style: const TextStyle(fontSize: 12)),
                    selected: _packedItems.contains(item),
                    selectedColor: LakbayColors.primaryLight,
                    onSelected: (checked) {
                      setState(() {
                        if (checked) {
                          _packedItems.add(item);
                        } else {
                          _packedItems.remove(item);
                        }
                      });
                    },
                  ),
                )
                .toList(),
          ),
        ),
        const SizedBox(height: 18),
        const SizedBox(height: 8),
        Text(
          trip.overviewText,
          style: const TextStyle(
            fontSize: 15,
            height: 1.5,
            color: LakbayColors.textSecondary,
          ),
        ),
        const SizedBox(height: 20),

        // Expert Curator Card with APK .webp avatar
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: LakbayColors.primarySoft,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
                color: LakbayColors.primary.withValues(alpha: 0.25)),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ClipOval(
                child: Image.asset(
                  trip.expertAvatarAsset,
                  width: 46,
                  height: 46,
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) => const LakbayAvatar(size: 46),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      trip.expertName,
                      style: const TextStyle(
                        fontFamily: 'FigGrotesk',
                        fontWeight: FontWeight.w700,
                        fontSize: 14,
                        color: LakbayColors.primaryDark,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '"${trip.expertTip}"',
                      style: const TextStyle(
                        fontSize: 13.5,
                        height: 1.4,
                        color: LakbayColors.textPrimary,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 22),

        const Text(
          'Route Highlights Snapshot',
          style: TextStyle(
            fontFamily: 'FigGrotesk',
            fontWeight: FontWeight.w700,
            fontSize: 18,
          ),
        ),
        const SizedBox(height: 12),
        ...trip.days.map(
          (day) => Container(
            margin: const EdgeInsets.only(bottom: 10),
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: LakbayColors.cardBorder),
            ),
            child: Row(
              children: [
                Container(
                  width: 38,
                  height: 38,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: LakbayColors.tealDeep,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    'D${day.dayNumber}',
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                      fontSize: 13,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        day.cityTitle,
                        style: const TextStyle(
                          fontFamily: 'FigGrotesk',
                          fontWeight: FontWeight.w600,
                          fontSize: 15,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        day.summary,
                        style: const TextStyle(
                          fontSize: 12.5,
                          color: LakbayColors.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
                Image.asset(
                  'assets/png/weather/${day.wmoWeatherCode}.png',
                  width: 22,
                  height: 22,
                  errorBuilder: (_, _, _) => const SizedBox.shrink(),
                ),
                IconButton(
                  tooltip: 'View on Mapbox',
                  onPressed: _openFullRouteMap,
                  icon: const Icon(Icons.location_on_outlined,
                      color: LakbayColors.primary, size: 20),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildDayByDayTab(ItineraryTrip trip) {
    return ListView.builder(
      padding: const EdgeInsets.all(20),
      itemCount: trip.days.length + 1,
      itemBuilder: (context, idx) {
        if (idx == 0) {
          return Padding(
            padding: const EdgeInsets.only(bottom: 14),
            child: Row(
              children: [
                const Expanded(
                  child: Text(
                    'Customize Daily Stops',
                    style: TextStyle(
                      fontFamily: 'FigGrotesk',
                      fontWeight: FontWeight.w700,
                      fontSize: 17,
                      color: LakbayColors.tealDeep,
                    ),
                  ),
                ),
                FilledButton.tonalIcon(
                  onPressed: trip.days.length >= 2 && !_isRefining
                      ? _handleOptimizeRoute
                      : null,
                  icon: _isRefining
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.alt_route_rounded, size: 17),
                  label: const Text('Optimize Route'),
                ),
              ],
            ),
          );
        }
        final index = idx - 1;
        final day = trip.days[index];
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (day.transportFromPrevious != null)
              Container(
                margin: const EdgeInsets.only(bottom: 12),
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                decoration: BoxDecoration(
                  color: LakbayColors.tealWash.withValues(alpha: 0.6),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Image.asset(
                      _transitSprite(day.transportFromPrevious!),
                      width: 18,
                      height: 18,
                      errorBuilder: (_, _, _) => const Icon(
                        Icons.directions_car_rounded,
                        size: 16,
                        color: LakbayColors.tealDeep,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      day.transportDuration ?? 'Transit leg included',
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: LakbayColors.tealDeep,
                      ),
                    ),
                  ],
                ),
              ),
            Container(
              margin: const EdgeInsets.only(bottom: 18),
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: LakbayColors.cardBorder),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 4),
                        decoration: BoxDecoration(
                          color: LakbayColors.primary,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Text(
                          'DAY ${day.dayNumber}',
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w700,
                            fontSize: 11,
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          day.cityTitle
                              .replaceFirst(RegExp(r'^Day \d+ • '), ''),
                          style: const TextStyle(
                            fontFamily: 'FigGrotesk',
                            fontWeight: FontWeight.w700,
                            fontSize: 17,
                          ),
                        ),
                      ),
                      Image.asset(
                        'assets/png/weather/${day.wmoWeatherCode}.png',
                        width: 22,
                        height: 22,
                        errorBuilder: (_, _, _) => const SizedBox.shrink(),
                      ),
                      const SizedBox(width: 4),
                      Text(
                        '${day.tempCelsius}°C',
                        style: const TextStyle(
                          fontFamily: 'FigGrotesk',
                          fontWeight: FontWeight.w700,
                          fontSize: 12.5,
                          color: LakbayColors.tealDeep,
                        ),
                      ),
                      IconButton(
                        tooltip: 'Inspect Day on Mapbox',
                        onPressed: _openFullRouteMap,
                        icon: const Icon(Icons.map_outlined,
                            color: LakbayColors.tealAccent, size: 20),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    day.summary,
                    style: const TextStyle(
                      fontSize: 13,
                      color: LakbayColors.textSecondary,
                    ),
                  ),
                  const Divider(height: 22),
                  for (int sIdx = 0; sIdx < day.stops.length; sIdx++) ...[
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SizedBox(
                            width: 68,
                            child: Text(
                              day.stops[sIdx].time,
                              style: const TextStyle(
                                fontWeight: FontWeight.w600,
                                fontSize: 12,
                                color: LakbayColors.tealAccent,
                              ),
                            ),
                          ),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  day.stops[sIdx].title,
                                  style: const TextStyle(
                                    fontFamily: 'FigGrotesk',
                                    fontWeight: FontWeight.w600,
                                    fontSize: 14.5,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  day.stops[sIdx].description,
                                  style: const TextStyle(
                                    fontSize: 12.5,
                                    color: LakbayColors.textSecondary,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          if (day.stops.length > 1)
                            IconButton(
                              tooltip: 'Remove stop',
                              visualDensity: VisualDensity.compact,
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(),
                              onPressed: () => _removeStop(index, sIdx),
                              icon: const Icon(
                                Icons.close_rounded,
                                size: 17,
                                color: LakbayColors.textMuted,
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton.icon(
                      onPressed: () => _showAddStopDialog(index),
                      icon: const Icon(Icons.add_rounded, size: 17),
                      label: const Text('Add Stop'),
                    ),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildStaysAndFlightsTab(ItineraryTrip trip) {
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        if (trip.flights.isNotEmpty) ...[
          const Text(
            'Flights to Davao International (DVO)',
            style: TextStyle(
              fontFamily: 'FigGrotesk',
              fontWeight: FontWeight.w700,
              fontSize: 19,
            ),
          ),
          const SizedBox(height: 12),
          ...trip.flights.map(
            (f) => Container(
              margin: const EdgeInsets.only(bottom: 12),
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: LakbayColors.cardBorder),
              ),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: LakbayColors.primaryLight,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Icon(Icons.flight_takeoff_rounded,
                        color: LakbayColors.primary),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${f.originCode} ↔ ${f.destinationCode} • ${f.duration}',
                          style: const TextStyle(
                            fontFamily: 'FigGrotesk',
                            fontWeight: FontWeight.w700,
                            fontSize: 16,
                          ),
                        ),
                        Text(
                          '${f.airline} (${f.isDirect ? "Direct" : "1 Stop"})',
                          style: const TextStyle(
                            fontSize: 12.5,
                            color: LakbayColors.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        widget.repo.formatPrice(f.priceRoundtripUsd),
                        style: const TextStyle(
                          fontFamily: 'FigGrotesk',
                          fontWeight: FontWeight.w700,
                          fontSize: 17,
                          color: LakbayColors.tealDeep,
                        ),
                      ),
                      const Text(
                        'per traveler',
                        style:
                            TextStyle(fontSize: 11, color: LakbayColors.textMuted),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 18),
        ] else ...[
          Container(
            margin: const EdgeInsets.only(bottom: 18),
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: LakbayColors.cardBorder),
            ),
            child: const Row(
              children: [
                Icon(Icons.directions_bus_rounded,
                    color: LakbayColors.tealAccent, size: 26),
                SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Regional Land & Ferry Transit',
                        style: TextStyle(
                          fontFamily: 'FigGrotesk',
                          fontWeight: FontWeight.w700,
                          fontSize: 15.5,
                          color: LakbayColors.tealDeep,
                        ),
                      ),
                      SizedBox(height: 3),
                      Text(
                        'Departing within Davao Region — no domestic airfare needed. Use buses, L300 vans, ferries (Sasa/Sta. Ana Wharf), or private car.',
                        style: TextStyle(
                          fontSize: 12.5,
                          color: LakbayColors.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
        const Text(
          'Handpicked Davao Region Stays',
          style: TextStyle(
            fontFamily: 'FigGrotesk',
            fontWeight: FontWeight.w700,
            fontSize: 19,
          ),
        ),
        const SizedBox(height: 12),
        ...trip.hotels.map(
          (h) => Container(
            margin: const EdgeInsets.only(bottom: 14),
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: LakbayColors.cardBorder),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: SizedBox(
                    height: 120,
                    width: double.infinity,
                    child: LakbayNetworkOrAssetImage(
                      networkUrl: h.remoteImageUrl ?? trip.remoteImageUrl,
                      assetPath: h.imageAsset,
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        h.name,
                        style: const TextStyle(
                          fontFamily: 'FigGrotesk',
                          fontWeight: FontWeight.w700,
                          fontSize: 17,
                        ),
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: LakbayColors.tealDeep,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        '${h.rating} ★',
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  '${"★" * h.stars} • ${h.partnerName}',
                  style: const TextStyle(
                    fontSize: 12.5,
                    color: LakbayColors.primary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: h.facilities
                      .map(
                        (fac) => Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 4),
                          decoration: BoxDecoration(
                            color: LakbayColors.canvasBg,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            fac,
                            style: const TextStyle(
                              fontSize: 11.5,
                              color: LakbayColors.textSecondary,
                            ),
                          ),
                        ),
                      )
                      .toList(),
                ),
                const SizedBox(height: 12),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      '${widget.repo.formatPrice(h.pricePerNightUsd)} / night',
                      style: const TextStyle(
                        fontFamily: 'FigGrotesk',
                        fontWeight: FontWeight.w700,
                        fontSize: 17,
                        color: LakbayColors.tealDeep,
                      ),
                    ),
                    OutlinedButton.icon(
                      onPressed: () {
                        widget.repo.saveTripToMyTrips(trip);
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text('Pinned ${h.name} reference to "${trip.title}"!'),
                            backgroundColor: LakbayColors.tealAccent,
                          ),
                        );
                      },
                      icon: const Icon(Icons.bookmark_added_outlined, size: 16),
                      label: const Text('Pin Stay'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        for (final destId in trip.effectiveBackendDestinationIds)
          ...widget.repo.transportRatesForDestination(destId).map(
                (tr) => Container(
                  margin: const EdgeInsets.only(bottom: 12),
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: LakbayColors.cardBorder),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.directions_bus_rounded,
                          color: LakbayColors.tealDeep),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '${tr.vehicleType} (${tr.transportMode})',
                              style: const TextStyle(
                                fontFamily: 'FigGrotesk',
                                fontWeight: FontWeight.w700,
                                fontSize: 15,
                              ),
                            ),
                            Text(
                              '${tr.routeFrom} → ${tr.routeTo}${tr.durationText != null ? ' • ${tr.durationText}' : ''}',
                              style: const TextStyle(
                                fontSize: 12,
                                color: LakbayColors.textSecondary,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Text(
                        '₱${tr.pricePhp.toStringAsFixed(0)}',
                        style: const TextStyle(
                          fontFamily: 'FigGrotesk',
                          fontWeight: FontWeight.w700,
                          fontSize: 15.5,
                          color: LakbayColors.primary,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
      ],
    );
  }

  Widget _buildInfoChip({
    required Widget iconWidget,
    required String label,
    required String value,
  }) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 10),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: LakbayColors.cardBorder),
        ),
        child: Column(
          children: [
            iconWidget,
            const SizedBox(height: 4),
            Text(
              label,
              style: const TextStyle(
                fontSize: 11,
                color: LakbayColors.textMuted,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              value,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontFamily: 'FigGrotesk',
                fontWeight: FontWeight.w700,
                fontSize: 13,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
