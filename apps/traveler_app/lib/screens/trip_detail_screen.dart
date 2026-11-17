import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/travel_models.dart';
import '../services/mapbox_service.dart';
import '../services/travel_repository.dart';
import '../widgets/lakbay_image.dart';
import '../widgets/lakbay_mapbox_widget.dart';
import '../widgets/trip_management_sheets.dart';
import 'live_day_screen.dart';
import 'trip_route_map_screen.dart';
import '../services/access_notices.dart';
import '../widgets/access_notice_card.dart';
import '../widgets/estimate_note.dart';

import '../design/design.dart';
class TripDetailScreen extends StatefulWidget {
  final ItineraryTrip trip;
  final TravelRepository repo;

  /// Hero tag of the photo this screen was opened from, so it flies into
  /// the header.
  final String? heroTag;

  const TripDetailScreen({
    super.key,
    required this.trip,
    required this.repo,
    this.heroTag,
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
    // Weather-based items only when real weather has been loaded for the trip
    // (avgTemp is empty until then); otherwise only the catalog's own list.
    if (trip.avgTemp.trim().isNotEmpty) {
      if (trip.wmoWeatherCode >= 51 ||
          trip.avgTemp.toLowerCase().contains('rain') ||
          trip.avgTemp.toLowerCase().contains('shower')) {
        items.addAll([
          'Compact Umbrella / Rain Poncho',
          'Dry Bag for Electronics',
        ]);
      } else {
        items.addAll(['SPF50+ Sunscreen & Shades', 'Refillable Water Bottle']);
      }
    }
    return items.take(8).toList();
  }

  Future<void> _handleOptimizeRoute() async {
    setState(() => _isRefining = true);
    final updated = await widget.repo.optimizeStopsForTrip(
      _activeTrip,
      travelMode: _selectedTravelMode,
    );
    var nextWarnings = updated.routeWarnings;
    if (updated.routeSegments.isEmpty) {
      final routeRes = await widget.repo.fetchRoadRouteForTrip(
        updated,
        optimize: true,
        travelMode: _selectedTravelMode,
      );
      if (routeRes != null && routeRes.warnings.isNotEmpty) {
        nextWarnings = {...nextWarnings, ...routeRes.warnings}.toList();
      }
    }
    if (!mounted) return;
    setState(() {
      _liveTrip = updated;
      _routeWarnings = nextWarnings;
      _isRefining = false;
    });
    final msg =
        updated.optimizationSummary?.savingsHeadline ??
        'Route order optimized across Davao Region stops!';
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), backgroundColor: LkColors.s3),
    );
  }

  Future<void> _handleAddDayReplan() async {
    if (_isRefining) return;
    final nextDays = (_activeTrip.daysCount + 1).clamp(1, 14);
    setState(() => _isRefining = true);
    final updated = await widget.repo.replanTripWithSettings(
      _activeTrip,
      daysCount: nextDays,
      travelMode: _selectedTravelMode,
    );
    if (!mounted) return;
    setState(() {
      _liveTrip = updated;
      _routeWarnings = updated.routeWarnings;
      _isRefining = false;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'Re-planned to ${updated.daysCount} days to balance daily hours.',
        ),
        backgroundColor: LkColors.s3,
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
      if (routeRes != null) {
        _liveTrip = _activeTrip.copyWith(
          routeSegments: routeRes.segments.isNotEmpty
              ? routeRes.segments
              : _activeTrip.routeSegments,
          seaCrossings: routeRes.seaCrossings.isNotEmpty
              ? routeRes.seaCrossings
              : _activeTrip.seaCrossings,
          routeWarnings: routeRes.warnings,
        );
      }
      _routeWarnings = routeRes?.warnings ?? const [];
      _isRefining = false;
    });
  }

  Future<void> _handleAiRefine(String instruction) async {
    setState(() => _isRefining = true);
    final refined = await widget.repo.refineTripWithAi(
      _activeTrip,
      instruction,
    );
    if (!mounted) return;
    setState(() {
      if (refined != null) _liveTrip = refined;
      _isRefining = false;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          refined != null ? 'Updated itinerary: "$instruction"' : 'AI refinement saved locally — inspect or customize stops below.',
        ),
        backgroundColor: LkColors.s3,
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
              decoration: const InputDecoration(
                labelText: 'Time (e.g. 02:00 PM)',
              ),
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
            time: timeCtrl.text.trim().isNotEmpty
                ? timeCtrl.text.trim()
                : '02:00 PM',
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
    final updatedStops = List<ItineraryStop>.from(day.stops)
      ..removeAt(stopIndex);
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
      final base = widget.trip;
      final needsRoute =
          base.routeSegments.isEmpty &&
          base.effectiveBackendDestinationIds.isNotEmpty;
      final liveFuture = widget.repo.loadLiveDetailsForTrip(base);
      final routeFuture = needsRoute
          ? widget.repo.fetchRoadRouteForTrip(
              base,
              travelMode: _selectedTravelMode,
            )
          : Future<BackendRouteResult?>.value(null);
      var enriched = await liveFuture;
      final road = await routeFuture;
      if (road != null && road.segments.isNotEmpty) {
        enriched = enriched.copyWith(
          routeSegments: road.segments,
          seaCrossings: road.seaCrossings.isNotEmpty
              ? road.seaCrossings
              : enriched.seaCrossings,
          routeWarnings: road.warnings.isNotEmpty
              ? road.warnings
              : enriched.routeWarnings,
        );
      }
      if (!mounted) return;
      setState(() {
        _liveTrip = enriched;
        if (road != null && road.warnings.isNotEmpty) {
          _routeWarnings = road.warnings;
        }
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
            TripRouteMapScreen(trip: _activeTrip, repo: widget.repo),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final trip = _activeTrip;
    final isSaved = widget.repo.savedTrips.any((t) => t.id == trip.id);
    final isBucketed = widget.repo.isTripInBucketList(trip.id);

    return Scaffold(
      backgroundColor: LkColors.bg,
      body: NestedScrollView(
        headerSliverBuilder: (context, innerBoxIsScrolled) => [
          SliverAppBar(
            expandedHeight: 280,
            pinned: true,
            backgroundColor: LkColors.s3,
            foregroundColor: Colors.white,
            leading: Padding(
              padding: const EdgeInsets.only(left: LkSpace.s),
              child: Center(
                child: LkIconButton(
                  icon: Icons.arrow_back_rounded,
                  tooltip: 'Back',
                  style: LkIconButtonStyle.glass,
                  onPressed: () => Navigator.of(context).maybePop(),
                ),
              ),
            ),
            leadingWidth: kLkMinTarget + LkSpace.l,
            actions: [
              LkIconButton(
                icon: Icons.map_outlined,
                tooltip: 'Play Animated Mapbox Route',
                style: LkIconButtonStyle.glass,
                onPressed: _openFullRouteMap,
              ),
              const SizedBox(width: LkSpace.xs),
              LkIconButton(
                icon: isBucketed
                    ? Icons.favorite_rounded
                    : Icons.favorite_border_rounded,
                tooltip: isBucketed
                    ? 'Remove from Bucket List'
                    : 'Save to Bucket List',
                style: LkIconButtonStyle.glass,
                color: isBucketed ? LkColors.mango : null,
                onPressed: () {
                  widget.repo.toggleBucketListTrip(trip.id);
                  setState(() {});
                },
              ),
              const SizedBox(width: LkSpace.xs),
              LkIconButton(
                icon: isSaved
                    ? Icons.bookmark_added_rounded
                    : Icons.bookmark_add_outlined,
                tooltip: isSaved ? 'Saved to your trips' : 'Save to My Trips',
                style: LkIconButtonStyle.glass,
                color: isSaved ? LkColors.mango : null,
                onPressed: () {
                  HapticFeedback.lightImpact();
                  widget.repo.saveTripToMyTrips(trip);
                  setState(() {});
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Saved "${trip.title}" to your trips')),
                  );
                },
              ),
              const SizedBox(width: LkSpace.s),
            ],
            flexibleSpace: FlexibleSpaceBar(
              background: Stack(
                fit: StackFit.expand,
                children: [
                  _headerPhoto(),
                  Container(
                    decoration: const BoxDecoration(
                      gradient: LkColors.photoScrim,
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
                                horizontal: 10,
                                vertical: 4,
                              ),
                              decoration: BoxDecoration(
                                color: LkColors.s3,
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
                                horizontal: 10,
                                vertical: 4,
                              ),
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
                            fontFamily: LkType.displayFamily,
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
              indicatorColor: LkColors.mango,
              indicatorWeight: 3,
              indicatorSize: TabBarIndicatorSize.label,
              dividerColor: LkColors.stroke,
              labelColor: Colors.white,
              unselectedLabelColor: Colors.white70,
              labelPadding: const EdgeInsets.symmetric(horizontal: 6),
              labelStyle: const TextStyle(
                fontFamily: LkType.displayFamily,
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
            color: LkColors.s1,
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
                        color: LkColors.muted,
                      ),
                    ),
                    Text(
                      '${widget.repo.formatPrice(trip.totalEstimatedCostUsd)} • ${trip.adults + trip.children} pax',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontFamily: LkType.displayFamily,
                        fontWeight: FontWeight.w700,
                        fontSize: 15,
                        color: LkColors.text,
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
                icon: const Icon(
                  Icons.account_balance_wallet_outlined,
                  size: 18,
                ),
                label: const Text('Budget & PDF'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _pickStartDate(ItineraryTrip trip) async {
    final today = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: trip.startDate ?? today,
      firstDate: DateTime(today.year - 1),
      lastDate: DateTime(today.year + 2, 12, 31),
      helpText: 'First day of the trip',
    );
    if (picked == null || !mounted) return;
    final first = DateTime(picked.year, picked.month, picked.day);
    final days = trip.daysCount < 1 ? 1 : trip.daysCount;
    setState(() {
      _liveTrip = _activeTrip.copyWith(
        startDate: first,
        endDate: first.add(Duration(days: days - 1)),
      );
    });
    if (widget.repo.savedTrips.any((t) => t.id == trip.id)) {
      widget.repo.setTripStartDate(trip.id, first);
    }
  }

  Widget _headerPhoto() {
    final photo = LakbayNetworkOrAssetImage(
      networkUrl: _activeTrip.remoteImageUrl,
      assetPath: _activeTrip.heroAsset,
    );
    final tag = widget.heroTag;
    return tag == null ? photo : Hero(tag: tag, child: photo);
  }

  /// "Day 2 is live" while the trip is on; otherwise a preview of day 1.
  Widget _buildLiveDayCard(ItineraryTrip trip) {
    final now = DateTime.now();
    final live = trip.timingOn(now) == TripTiming.ongoing;
    final label = trip.whenLabel(now);
    return Material(
      color: live ? LkColors.mango : LkColors.s1,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: live ? LkColors.mango : LkColors.stroke),
      ),
      clipBehavior: Clip.antiAlias,
      child: ListTile(
        minTileHeight: 56,
        leading: Icon(
          live ? Icons.navigation_rounded : Icons.route_outlined,
          color: live ? LkColors.mangoInk : LkColors.lagoon,
        ),
        title: Text(
          live ? '${label ?? 'Today'}: your day is live' : 'Preview a day on the ground',
          style: TextStyle(
            fontWeight: FontWeight.w800,
            color: live ? LkColors.mangoInk : LkColors.text,
          ),
        ),
        subtitle: Text(
          live
              ? 'Next stop, progress and closing times.'
              : 'See day 1 the way it looks while you travel.',
          style: TextStyle(
            color: live
                ? LkColors.mangoInk.withValues(alpha: 0.8)
                : LkColors.muted,
          ),
        ),
        trailing: Icon(
          Icons.chevron_right_rounded,
          color: live ? LkColors.mangoInk : LkColors.muted,
        ),
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => LiveDayScreen(repo: widget.repo, trip: trip),
          ),
        ),
      ),
    );
  }

  Widget _buildDatesTile(ItineraryTrip trip) {
    final range = trip.dateRangeLabel;
    final when = trip.whenLabel(DateTime.now());
    return Material(
      color: LkColors.s1,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: LkColors.stroke),
      ),
      clipBehavior: Clip.antiAlias,
      child: ListTile(
        minTileHeight: 56,
        leading: const Icon(Icons.event_outlined, color: LkColors.text),
        title: Text(
          range ?? 'Add trip dates',
          style: const TextStyle(
            fontWeight: FontWeight.w700,
            color: LkColors.text,
          ),
        ),
        subtitle: Text(
          range == null
              ? 'Pick the first day so the trip shows as upcoming or past.'
              : (when ?? ''),
          style: const TextStyle(color: LkColors.muted),
        ),
        trailing: Text(
          range == null ? 'Add' : 'Change',
          style: const TextStyle(
            fontWeight: FontWeight.w700,
            color: LkColors.lagoon,
          ),
        ),
        onTap: () => _pickStartDate(trip),
      ),
    );
  }

  Widget _buildOverviewTab(ItineraryTrip trip) {
    final waypoints = trip.routeWaypoints;
    final totalKm =
        trip.optimizationSummary?.optimizedDistanceKm ??
        MapboxService.calculateRouteDistanceKm(waypoints);
    final stopMarkers = <LakbayMapMarker>[];
    for (final day in trip.days) {
      if (day.isContinuationDay) continue;
      final media = widget.repo.resolveDayMarkerMedia(trip, day);
      final dayStops = day.stops.where((s) => s.category != 'stay').toList();
      if (dayStops.isNotEmpty) {
        for (var sIdx = 0; sIdx < dayStops.length; sIdx++) {
          final stop = dayStops[sIdx];
          final badge = dayStops.length == 1
              ? 'D${day.dayNumber}'
              : 'D${day.dayNumber}.${sIdx + 1}';
          stopMarkers.add(
            LakbayMapMarker(
              id: 'stop_${day.dayNumber}_$sIdx',
              lat: stop.lat,
              lng: stop.lng,
              badgeText: badge,
              title: stop.title,
              imageUrl: media.imageUrl,
              imageAsset: media.imageAsset,
            ),
          );
        }
      } else {
        stopMarkers.add(
          LakbayMapMarker(
            id: 'day_${day.dayNumber}',
            lat: day.lat,
            lng: day.lng,
            badgeText: 'D${day.dayNumber}',
            title: day.cityTitle,
            imageUrl: media.imageUrl,
            imageAsset: media.imageAsset,
          ),
        );
      }
    }
    final markers = <LakbayMapMarker>[
      for (var i = 0; i < stopMarkers.length; i++)
        LakbayMapMarker(
          id: stopMarkers[i].id,
          lat: stopMarkers[i].lat,
          lng: stopMarkers[i].lng,
          badgeText: stopMarkers[i].badgeText,
          title: stopMarkers[i].title,
          imageUrl: stopMarkers[i].imageUrl,
          imageAsset: stopMarkers[i].imageAsset,
          isPrimary: i == 0,
          isOrigin: i == 0,
          isDestination: i == stopMarkers.length - 1,
        ),
      if (widget.repo.originLat != null && widget.repo.originLng != null)
        LakbayMapMarker(
          id: 'user_gps',
          lat: widget.repo.originLat!,
          lng: widget.repo.originLng!,
          title: 'You (${widget.repo.effectiveOriginLabel})',
          isUserLocation: true,
        ),
    ];
    final combinedWarnings = <String>{
      ...trip.routeWarnings,
      ..._routeWarnings,
    }.toList();
    final optSummary = trip.optimizationSummary;

    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        LkRiseIn(child: _buildDatesTile(trip)),
        const SizedBox(height: 14),
        LkRiseIn(delay: LkRiseIn.stagger(1), child: _buildLiveDayCard(trip)),
        const SizedBox(height: 14),
        Row(
          children: [
            // Weather and best months are shown only when real data exists.
            if (trip.avgTemp.trim().isNotEmpty) ...[
              _buildInfoChip(
                iconWidget: Image.asset(
                  'assets/png/weather/${trip.wmoWeatherCode}.png',
                  width: 22,
                  height: 22,
                  errorBuilder: (_, _, _) => const Icon(
                    Icons.wb_sunny_rounded,
                    color: LkColors.lagoon,
                    size: 20,
                  ),
                  excludeFromSemantics: true,
                ),
                label: 'Weather',
                value: trip.avgTemp,
              ),
              const SizedBox(width: 10),
            ],
            if (trip.bestMonths.trim().isNotEmpty) ...[
              _buildInfoChip(
                iconWidget: const Icon(
                  Icons.calendar_month_rounded,
                  color: LkColors.lagoon,
                  size: 20,
                ),
                label: 'Best time',
                value: trip.bestMonths,
              ),
              const SizedBox(width: 10),
            ],
            _buildInfoChip(
              iconWidget: const Icon(
                Icons.route_rounded,
                color: LkColors.lagoon,
                size: 20,
              ),
              label: 'Region XI Route',
              value: '${totalKm.toStringAsFixed(0)} km',
            ),
          ],
        ),
        if (optSummary != null) ...[
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: LkColors.s2.withValues(alpha: 0.45),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: LkColors.stroke),
            ),
            child: Row(
              children: [
                const Icon(
                  Icons.auto_graph_rounded,
                  color: LkColors.text,
                  size: 20,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        optSummary.savingsHeadline,
                        style: const TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: 13,
                          color: LkColors.text,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '${optSummary.methodLabel} · ${optSummary.sourceLabel}'
                        '${optSummary.minutesSaved >= 1 ? ' · Saves ${optSummary.minutesSaved.round()} min' : ''}',
                        style: const TextStyle(
                          fontSize: 11.5,
                          color: LkColors.muted,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
        const SizedBox(height: 16),

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
        if (combinedWarnings.isNotEmpty) ...[
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: LkColors.mangoSoft,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: LkColors.mango),
            ),
            child: Text(
              combinedWarnings.join('\n'),
              style: const TextStyle(
                fontSize: 12.5,
                color: LkColors.text,
              ),
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
                  fontFamily: LkType.displayFamily,
                  fontWeight: FontWeight.w700,
                  fontSize: 18,
                ),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton.tonalIcon(
              onPressed: _openFullRouteMap,
              style: FilledButton.styleFrom(
                backgroundColor: LkColors.s2,
                foregroundColor: LkColors.lagoon,
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
        Builder(
          builder: (context) {
            final originLat = widget.repo.originLat;
            final originLng = widget.repo.originLng;
            final hasNearbyOrigin =
                originLat != null &&
                originLng != null &&
                (waypoints.isEmpty ||
                    waypoints.any(
                      (p) =>
                          MapboxService.haversineKm(
                            p.lat,
                            p.lng,
                            originLat,
                            originLng,
                          ) <=
                          120.0,
                    ));
            final previewBoundsPts = <GeoPoint>[
              ...waypoints,
              for (final seg in trip.routeSegments) ...seg.points,
              if (hasNearbyOrigin) GeoPoint(lat: originLat, lng: originLng),
            ];
            final (
              previewLat,
              previewLng,
              previewZoom,
            ) = previewBoundsPts.isEmpty
                ? (trip.centerLat, trip.centerLng, 8.4)
                : MapboxService.computeBoundsCenterAndZoom(previewBoundsPts);
            return Container(
              height: 240,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(22),
                border: Border.all(color: LkColors.stroke),
              ),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  LakbayMapboxMap(
                    repo: widget.repo,
                    initialLat: previewLat,
                    initialLng: previewLng,
                    initialZoom: previewZoom,
                    routePoints: waypoints,
                    routeSegments: trip.routeSegments,
                    markers: markers,
                    showControls: false,
                    onMarkerTap: (_) => _openFullRouteMap(),
                    onMapTap: (_, _) => _openFullRouteMap(),
                  ),
                  Positioned(
                    top: 10,
                    right: 10,
                    child: Material(
                      color: LkColors.s3.withValues(alpha: 0.88),
                      borderRadius: BorderRadius.circular(18),
                      elevation: 3,
                      child: InkWell(
                        onTap: _openFullRouteMap,
                        borderRadius: BorderRadius.circular(18),
                        child: const Padding(
                          padding: EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 6,
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.open_in_full_rounded,
                                size: 13,
                                color: Colors.white,
                              ),
                              SizedBox(width: 5),
                              Text(
                                'Full Map',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontFamily: LkType.displayFamily,
                                  fontWeight: FontWeight.w700,
                                  fontSize: 11.5,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        ),
        const SizedBox(height: 22),

        const Text(
          'Why You’ll Love This Davao Route',
          style: TextStyle(
            fontFamily: LkType.displayFamily,
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
              color: LkColors.muted,
            ),
          ),
          const SizedBox(height: 16),
        ],
        for (final notice in accessNoticesForTrip(trip)) ...[
          AccessNoticeCard(notice: notice),
          const SizedBox(height: 16),
        ],
        if (trip.advisories.isNotEmpty) ...[
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: LkColors.mangoSoft,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: LkColors.mango),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Row(
                  children: [
                    Icon(
                      Icons.health_and_safety_rounded,
                      color: Colors.deepOrange,
                      size: 18,
                    ),
                    SizedBox(width: 8),
                    Text(
                      'Smart Planning Advisories',
                      style: TextStyle(
                        fontFamily: LkType.displayFamily,
                        fontWeight: FontWeight.w700,
                        fontSize: 14.5,
                        color: LkColors.text,
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
                        color: LkColors.text,
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
            fontFamily: LkType.displayFamily,
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
                  : () => _handleAiRefine(
                      'Include chill coastal or viewpoint stop',
                    ),
            ),
          ],
        ),
        const SizedBox(height: 18),
        const Text(
          'What to Bring & Weather Packing Checklist',
          style: TextStyle(
            fontFamily: LkType.displayFamily,
            fontWeight: FontWeight.w700,
            fontSize: 17,
          ),
        ),
        const SizedBox(height: 8),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: LkColors.s1,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: LkColors.stroke),
          ),
          child: Wrap(
            spacing: 8,
            runSpacing: 6,
            children: _derivePackingChecklist(trip)
                .map(
                  (item) => FilterChip(
                    label: Text(item, style: const TextStyle(fontSize: 12)),
                    selected: _packedItems.contains(item),
                    selectedColor: LkColors.s2,
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
            color: LkColors.muted,
          ),
        ),
        const SizedBox(height: 20),

        // Travel notes from the catalog; hidden when there are none.
        if (trip.expertTip.trim().isNotEmpty)
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: LkColors.s2,
              borderRadius: BorderRadius.circular(18),
              border: Border.all(
                color: LkColors.lagoon.withValues(alpha: 0.25),
              ),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(
                  Icons.tips_and_updates_outlined,
                  color: LkColors.lagoon,
                  size: 24,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Travel notes',
                        style: TextStyle(
                          fontFamily: LkType.displayFamily,
                          fontWeight: FontWeight.w700,
                          fontSize: 14,
                          color: LkColors.lagoon,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        trip.expertTip.trim(),
                        style: const TextStyle(
                          fontSize: 13.5,
                          height: 1.4,
                          color: LkColors.text,
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
            fontFamily: LkType.displayFamily,
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
              color: LkColors.s1,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: LkColors.stroke),
            ),
            child: Row(
              children: [
                Container(
                  width: 38,
                  height: 38,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: LkColors.s3,
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
                          fontFamily: LkType.displayFamily,
                          fontWeight: FontWeight.w600,
                          fontSize: 15,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        day.summary,
                        style: const TextStyle(
                          fontSize: 12.5,
                          color: LkColors.muted,
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
                  excludeFromSemantics: true,
                ),
                IconButton(
                  tooltip: 'View on Mapbox',
                  onPressed: _openFullRouteMap,
                  icon: const Icon(
                    Icons.location_on_outlined,
                    color: LkColors.lagoon,
                    size: 20,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  String? _stayLengthLabel(String? stayType) {
    if (stayType == null || stayType.trim().isEmpty) return null;
    switch (normalizeStayDurationType(stayType)) {
      case 'short':
        return '1–2 h';
      case 'half_day':
        return 'Half day';
      case 'full_day':
        return 'Full day';
      case 'overnight':
        return 'Overnight';
      case 'multi_day':
        return 'Multi-day';
      default:
        return null;
    }
  }

  Widget _buildDayByDayTab(ItineraryTrip trip) {
    return ListView.builder(
      padding: const EdgeInsets.all(20),
      itemCount: trip.days.length + 1,
      itemBuilder: (context, idx) {
        if (idx == 0) {
          final canOptimize =
              trip.routeWaypoints.length >= 2 || trip.days.length >= 2;
          return Padding(
            padding: const EdgeInsets.only(bottom: 14),
            child: Row(
              children: [
                const Expanded(
                  child: Text(
                    'Customize Daily Stops',
                    style: TextStyle(
                      fontFamily: LkType.displayFamily,
                      fontWeight: FontWeight.w700,
                      fontSize: 17,
                      color: LkColors.text,
                    ),
                  ),
                ),
                FilledButton.tonalIcon(
                  onPressed: canOptimize && !_isRefining
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
            if (day.transportFromPrevious != null && !day.isContinuationDay)
              Container(
                margin: const EdgeInsets.only(bottom: 12),
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: LkColors.s2.withValues(alpha: 0.6),
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
                        color: LkColors.text,
                      ),
                      excludeFromSemantics: true,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      day.transportDuration ?? 'Transit leg included',
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: LkColors.text,
                      ),
                    ),
                  ],
                ),
              ),
            Container(
              margin: const EdgeInsets.only(bottom: 18),
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: LkColors.s1,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: day.overloadWarning != null
                      ? LkColors.mango
                      : LkColors.stroke,
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: day.isContinuationDay
                              ? LkColors.s3
                              : LkColors.s3,
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
                          day.cityTitle.replaceFirst(
                            RegExp(r'^Day \d+ • '),
                            '',
                          ),
                          style: const TextStyle(
                            fontFamily: LkType.displayFamily,
                            fontWeight: FontWeight.w700,
                            fontSize: 17,
                          ),
                        ),
                      ),
                      if (day.totalHours != null && !day.isContinuationDay) ...[
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 7,
                            vertical: 3,
                          ),
                          decoration: BoxDecoration(
                            color: day.overloadWarning != null
                                ? LkColors.mangoSoft
                                : LkColors.bg,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            '${day.totalHours!.toStringAsFixed(1)} h',
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                              color: day.overloadWarning != null
                                  ? Colors.deepOrange
                                  : LkColors.text,
                            ),
                          ),
                        ),
                        const SizedBox(width: 6),
                      ],
                      // Only live weather (loaded for day 1, as current
                      // conditions); planned days have no forecast.
                      if (day.dayNumber == 1 &&
                          trip.avgTemp.trim().isNotEmpty) ...[
                        Tooltip(
                          message: 'Weather now',
                          child: Image.asset(
                            'assets/png/weather/${day.wmoWeatherCode}.png',
                            width: 22,
                            height: 22,
                            errorBuilder: (_, _, _) => const SizedBox.shrink(),
                            excludeFromSemantics: true,
                          ),
                        ),
                        const SizedBox(width: 4),
                        Text(
                          '${day.tempCelsius}°C',
                          style: const TextStyle(
                            fontFamily: LkType.displayFamily,
                            fontWeight: FontWeight.w700,
                            fontSize: 12.5,
                            color: LkColors.text,
                          ),
                        ),
                      ],
                      IconButton(
                        tooltip: 'Inspect Day on Mapbox',
                        onPressed: _openFullRouteMap,
                        icon: const Icon(
                          Icons.map_outlined,
                          color: LkColors.lagoon,
                          size: 20,
                        ),
                      ),
                    ],
                  ),
                  if (day.isContinuationDay) ...[
                    const SizedBox(height: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: LkColors.s2,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: const Text(
                        'Leisure / Continuation Day — no road transit required',
                        style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w600,
                          color: LkColors.text,
                        ),
                      ),
                    ),
                  ],
                  if (day.overloadWarning != null) ...[
                    const SizedBox(height: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 8,
                      ),
                      decoration: BoxDecoration(
                        color: LkColors.mangoSoft,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: LkColors.mango),
                      ),
                      child: Row(
                        children: [
                          const Icon(
                            Icons.schedule_rounded,
                            size: 17,
                            color: Colors.deepOrange,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              day.overloadWarning!,
                              style: const TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                                color: Colors.deepOrange,
                              ),
                            ),
                          ),
                          TextButton(
                            onPressed: _isRefining ? null : _handleAddDayReplan,
                            child: const Text('Add a day'),
                          ),
                        ],
                      ),
                    ),
                  ],
                  const SizedBox(height: 4),
                  Text(
                    day.summary,
                    style: const TextStyle(
                      fontSize: 13,
                      color: LkColors.muted,
                    ),
                  ),
                  const Divider(height: 22),
                  for (int sIdx = 0; sIdx < day.stops.length; sIdx++)
                    _StopTimelineRow(
                      number: sIdx + 1,
                      stop: day.stops[sIdx],
                      isFirst: sIdx == 0,
                      isLast: sIdx == day.stops.length - 1,
                      stayLabel:
                          _stayLengthLabel(day.stops[sIdx].stayDurationType),
                      onRemove: day.stops.length > 1
                          ? () => _removeStop(index, sIdx)
                          : null,
                    ),
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
              fontFamily: LkType.displayFamily,
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
                color: LkColors.s1,
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: LkColors.stroke),
              ),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: LkColors.s2,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Icon(
                      Icons.flight_takeoff_rounded,
                      color: LkColors.lagoon,
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${f.originCode} ↔ ${f.destinationCode} • ${f.duration}',
                          style: const TextStyle(
                            fontFamily: LkType.displayFamily,
                            fontWeight: FontWeight.w700,
                            fontSize: 16,
                          ),
                        ),
                        Text(
                          '${f.airline} (${f.isDirect ? "Direct" : "1 Stop"})',
                          style: const TextStyle(
                            fontSize: 12.5,
                            color: LkColors.muted,
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
                          fontFamily: LkType.displayFamily,
                          fontWeight: FontWeight.w700,
                          fontSize: 17,
                          color: LkColors.text,
                        ),
                      ),
                      const Text(
                        'per traveler',
                        style: TextStyle(
                          fontSize: 11,
                          color: LkColors.muted,
                        ),
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
              color: LkColors.s1,
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: LkColors.stroke),
            ),
            child: const Row(
              children: [
                Icon(
                  Icons.directions_bus_rounded,
                  color: LkColors.lagoon,
                  size: 26,
                ),
                SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Regional Land & Ferry Transit',
                        style: TextStyle(
                          fontFamily: LkType.displayFamily,
                          fontWeight: FontWeight.w700,
                          fontSize: 15.5,
                          color: LkColors.text,
                        ),
                      ),
                      SizedBox(height: 3),
                      Text(
                        'Departing within Davao Region — no domestic airfare needed. Use buses, L300 vans, ferries (Sasa/Sta. Ana Wharf), or private car.',
                        style: TextStyle(
                          fontSize: 12.5,
                          color: LkColors.muted,
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
          'Places to stay',
          style: TextStyle(
            fontFamily: LkType.displayFamily,
            fontWeight: FontWeight.w700,
            fontSize: 19,
          ),
        ),
        const SizedBox(height: 6),
        const EstimateNote(),
        const SizedBox(height: 12),
        ...trip.hotels.map(
          (h) => Container(
            margin: const EdgeInsets.only(bottom: 14),
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: LkColors.s1,
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: LkColors.stroke),
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
                          fontFamily: LkType.displayFamily,
                          fontWeight: FontWeight.w700,
                          fontSize: 17,
                        ),
                      ),
                    ),
                    if (h.rating != null)
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: LkColors.s3,
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
                  [
                    if (h.stars != null) '★' * h.stars!,
                    h.partnerName,
                  ].join(' • '),
                  style: const TextStyle(
                    fontSize: 12.5,
                    color: LkColors.lagoon,
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
                            horizontal: 8,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: LkColors.bg,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            fac,
                            style: const TextStyle(
                              fontSize: 11.5,
                              color: LkColors.muted,
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
                        fontFamily: LkType.displayFamily,
                        fontWeight: FontWeight.w700,
                        fontSize: 17,
                        color: LkColors.text,
                      ),
                    ),
                    OutlinedButton.icon(
                      onPressed: () {
                        widget.repo.saveTripToMyTrips(trip);
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(
                              'Pinned ${h.name} reference to "${trip.title}"!',
                            ),
                            backgroundColor: LkColors.s3,
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
          ...widget.repo
              .transportRatesForDestination(destId)
              .map(
                (tr) => Container(
                  margin: const EdgeInsets.only(bottom: 12),
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: LkColors.s1,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: LkColors.stroke),
                  ),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.directions_bus_rounded,
                        color: LkColors.text,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '${tr.vehicleType} (${tr.transportMode})',
                              style: const TextStyle(
                                fontFamily: LkType.displayFamily,
                                fontWeight: FontWeight.w700,
                                fontSize: 15,
                              ),
                            ),
                            Text(
                              '${tr.routeFrom} → ${tr.routeTo}${tr.durationText != null ? ' • ${tr.durationText}' : ''}',
                              style: const TextStyle(
                                fontSize: 12,
                                color: LkColors.muted,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Text(
                        '₱${tr.pricePhp.toStringAsFixed(0)}',
                        style: const TextStyle(
                          fontFamily: LkType.displayFamily,
                          fontWeight: FontWeight.w700,
                          fontSize: 15.5,
                          color: LkColors.lagoon,
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
          color: LkColors.s1,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: LkColors.stroke),
        ),
        child: Column(
          children: [
            iconWidget,
            const SizedBox(height: 4),
            Text(
              label,
              style: const TextStyle(
                fontSize: 11,
                color: LkColors.muted,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              value,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontFamily: LkType.displayFamily,
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

/// One stop in the Day-by-Day plan: a numbered dot on a dotted line, the
/// time and place, and how you get there from the stop before.
class _StopTimelineRow extends StatelessWidget {
  const _StopTimelineRow({
    required this.number,
    required this.stop,
    required this.isFirst,
    required this.isLast,
    required this.stayLabel,
    required this.onRemove,
  });

  final int number;
  final ItineraryStop stop;
  final bool isFirst;
  final bool isLast;
  final String? stayLabel;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final minutes = stop.travelFromPrevMinutes;
    final hasLeg = !isFirst && minutes != null && minutes > 0;
    final byBoat = stop.isSeaCrossingFromPrev ||
        stop.travelFromPrevMode == TransportMode.ferry;
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: 32,
            child: Column(
              children: [
                SizedBox(
                  height: hasLeg ? 40 : 4,
                  child: isFirst ? null : const _DottedLine(),
                ),
                Container(
                  width: 26,
                  height: 26,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: isFirst ? LkColors.mango : LkColors.s3,
                    shape: BoxShape.circle,
                    border: Border.all(color: LkColors.stroke),
                  ),
                  child: Text(
                    '$number',
                    style: LkType.micro.copyWith(
                      color: isFirst ? LkColors.mangoInk : LkColors.text,
                    ),
                  ),
                ),
                Expanded(
                  child: isLast ? const SizedBox() : const _DottedLine(),
                ),
              ],
            ),
          ),
          const SizedBox(width: LkSpace.m),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(bottom: LkSpace.l),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (hasLeg)
                    Padding(
                      padding: const EdgeInsets.only(bottom: LkSpace.s),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: LkSpace.s,
                          vertical: 5,
                        ),
                        decoration: const BoxDecoration(
                          color: LkColors.lagoonSoft,
                          borderRadius: LkRadius.chipAll,
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              byBoat
                                  ? Icons.directions_boat_filled_rounded
                                  : Icons.directions_car_rounded,
                              size: 14,
                              color: LkColors.lagoon,
                            ),
                            const SizedBox(width: LkSpace.xs),
                            Text(
                              [
                                byBoat ? 'Ferry + ride' : 'Ride',
                                '~$minutes min',
                                if (stop.travelFromPrevKm != null)
                                  '${stop.travelFromPrevKm!.toStringAsFixed(1)} km',
                              ].join(' · '),
                              style: LkType.micro.copyWith(
                                color: LkColors.lagoon,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              stop.time,
                              style: LkType.micro.copyWith(
                                color: LkColors.lagoon,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(stop.title, style: LkType.itemTitle),
                            if (stayLabel != null) ...[
                              const SizedBox(height: LkSpace.xxs),
                              Text(
                                stayLabel!,
                                style: LkType.micro.copyWith(
                                  color: LkColors.muted,
                                ),
                              ),
                            ],
                            if (stop.description.trim().isNotEmpty) ...[
                              const SizedBox(height: LkSpace.xxs),
                              Text(stop.description, style: LkType.caption),
                            ],
                          ],
                        ),
                      ),
                      if (onRemove != null)
                        LkIconButton(
                          icon: Icons.close_rounded,
                          tooltip: 'Remove stop',
                          style: LkIconButtonStyle.plain,
                          onPressed: onRemove,
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _DottedLine extends StatelessWidget {
  const _DottedLine();

  @override
  Widget build(BuildContext context) {
    return const CustomPaint(
      painter: _DottedLinePainter(),
      child: SizedBox(width: 2, height: double.infinity),
    );
  }
}

class _DottedLinePainter extends CustomPainter {
  const _DottedLinePainter();

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = LkColors.lagoon.withValues(alpha: 0.6)
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round;
    final x = size.width / 2;
    for (var y = 3.0; y < size.height - 2; y += 7) {
      canvas.drawLine(Offset(x, y), Offset(x, y + 2), paint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
