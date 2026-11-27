import '../core/day_labels.dart';
import 'package:flutter/material.dart';
import '../models/travel_models.dart';
import '../services/mapbox_service.dart';
import '../services/route_summary.dart';
import '../services/travel_repository.dart';
import '../theme/lakbay_theme.dart';
import '../widgets/lakbay_destination_media.dart';
import '../widgets/lakbay_mapbox_widget.dart';
import '../widgets/route_trail.dart';
import '../widgets/trip_management_sheets.dart';
import 'trip_route_map_screen.dart';
import '../services/access_notices.dart';
import '../widgets/access_notice_card.dart';
import 'memories_screen.dart';
import 'commute_directions_screen.dart';

class TripDetailScreen extends StatefulWidget {
  final ItineraryTrip trip;
  final TravelRepository repo;
  final String? initialManagementSheet; // 'collaborate' | 'budget'

  const TripDetailScreen({
    super.key,
    required this.trip,
    required this.repo,
    this.initialManagementSheet,
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
  late String _selectedTravelMode = widget.repo.preferredTravelMode;
  BackendRouteResult? _route;
  List<String> _routeWarnings = const [];
  bool _updatingStatus = false;
  final Set<String> _packedItems = {};
  final GlobalKey<LakbayMapboxMapState> _desktopMapKey =
      GlobalKey<LakbayMapboxMapState>();
  int? _focusedDayNumber;
  String? _focusedMarkerId;

  ItineraryTrip get _activeTrip => _liveTrip ?? widget.trip;

  /// The real route for the current mode, from where the traveler is.
  Future<void> _loadRoute() async {
    final route = await widget.repo.fetchRoadRouteForTrip(
      _activeTrip,
      travelMode: _selectedTravelMode,
    );
    if (mounted && route != null) setState(() => _route = route);
  }

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
    final weatherCode = trip.wmoWeatherCode;
    if (trip.avgTemp.trim().isNotEmpty && weatherCode != null) {
      if (weatherCode >= 51 ||
          trip.avgTemp.toLowerCase().contains('rain') ||
          trip.avgTemp.toLowerCase().contains('shower')) {
        items.addAll(['Compact Umbrella / Rain Poncho', 'Dry Bag for Electronics']);
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
    final msg = updated.optimizationSummary?.savingsHeadline ??
        'Route order optimized across Davao Region stops!';
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        backgroundColor: LakbayColors.tealDeep,
      ),
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
      _route = routeRes;
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
    _loadRoute();
    final targetSheet = widget.initialManagementSheet;
    if (targetSheet != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (targetSheet == 'collaborate') {
          showTripCollaborationSheet(
            context,
            repo: widget.repo,
            trip: _activeTrip,
          );
        } else if (targetSheet == 'budget') {
          showTripBudgetAndPdfSheet(
            context,
            repo: widget.repo,
            trip: _activeTrip,
          );
        }
      });
    }
  }

  Future<void> _loadLiveDetails() async {
    if (_loadingLive) return;
    _loadingLive = true;
    try {
      final base = widget.trip;
      final needsRoute = base.routeSegments.isEmpty &&
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

  void _openFullRouteMap({int? dayIndex, String? stopId}) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => TripRouteMapScreen(
          trip: _activeTrip,
          repo: widget.repo,
          initialDayIndex: dayIndex,
          initialStopId: stopId,
        ),
      ),
    );
  }

  List<SeaCrossingInfo> _effectiveCrossings(ItineraryTrip trip) {
    final routeCrossings = _route?.seaCrossings ?? const <SeaCrossingInfo>[];
    return routeCrossings.isNotEmpty ? routeCrossings : trip.seaCrossings;
  }

  List<LakbayMapMarker> _pierMarkersForTrip(ItineraryTrip trip) {
    final markers = <LakbayMapMarker>[];
    final seen = <String>{};
    for (final crossing in _effectiveCrossings(trip)) {
      for (final (name, lat, lng) in [
        (crossing.boardPort, crossing.boardLat, crossing.boardLng),
        (crossing.landPort, crossing.landLat, crossing.landLng),
      ]) {
        if (!seen.add(name)) continue;
        markers.add(
          LakbayMapMarker(
            id: 'pier_${markers.length}',
            lat: lat,
            lng: lng,
            badgeText: '⚓',
            title: name,
            subtitle: crossing.vesselLabel,
            isCompact: true,
            isFerryPier: true,
          ),
        );
      }
    }
    return markers;
  }

  List<LakbayMapMarker> _buildTripMapMarkers(
    ItineraryTrip trip, {
    int? activeDayNumber,
  }) {
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
              subtitle: stop.description.isNotEmpty
                  ? stop.description
                  : day.cityTitle,
              imageUrl: media.imageUrl,
              imageAsset: media.imageAsset,
              dayNumber: day.dayNumber,
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
            subtitle: day.summary,
            imageUrl: media.imageUrl,
            imageAsset: media.imageAsset,
            dayNumber: day.dayNumber,
          ),
        );
      }
    }
    final defaultActiveDay = activeDayNumber ??
        (trip.days.isNotEmpty ? trip.days.first.dayNumber : null);
    return [
      for (var i = 0; i < stopMarkers.length; i++)
        LakbayMapMarker(
          id: stopMarkers[i].id,
          lat: stopMarkers[i].lat,
          lng: stopMarkers[i].lng,
          badgeText: stopMarkers[i].badgeText,
          title: stopMarkers[i].title,
          subtitle: stopMarkers[i].subtitle,
          imageUrl: stopMarkers[i].imageUrl,
          imageAsset: stopMarkers[i].imageAsset,
          dayNumber: stopMarkers[i].dayNumber,
          isPrimary: defaultActiveDay != null
              ? stopMarkers[i].dayNumber == defaultActiveDay
              : i == 0,
          isOrigin: i == 0,
          isDestination: i == stopMarkers.length - 1,
        ),
      ..._pierMarkersForTrip(trip),
      if (widget.repo.originLat != null && widget.repo.originLng != null)
        LakbayMapMarker(
          id: 'user_gps',
          lat: widget.repo.originLat!,
          lng: widget.repo.originLng!,
          title: 'You (${widget.repo.effectiveOriginLabel})',
          isUserLocation: true,
        ),
    ];
  }

  (double lat, double lng, double zoom) _overviewCameraFrame(
    ItineraryTrip trip,
  ) {
    final segments = _route != null && _route!.segments.isNotEmpty
        ? _route!.segments
        : trip.routeSegments;
    final originLat = widget.repo.originLat;
    final originLng = widget.repo.originLng;
    final waypoints = trip.routeWaypoints;
    final hasNearbyOrigin = originLat != null &&
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
      for (final seg in segments) ...seg.points,
      if (hasNearbyOrigin) GeoPoint(lat: originLat, lng: originLng),
    ];
    if (previewBoundsPts.isEmpty) {
      return (trip.centerLat, trip.centerLng, 8.4);
    }
    return MapboxService.computeBoundsCenterAndZoom(previewBoundsPts);
  }

  void _filterDesktopDay(ItineraryTrip trip, int? dayNumber) {
    setState(() {
      _focusedDayNumber = dayNumber;
      if (dayNumber != null) {
        final day =
            trip.days.where((d) => d.dayNumber == dayNumber).firstOrNull;
        final nonStay =
            day?.stops.where((s) => s.category != 'stay').toList() ?? const [];
        _focusedMarkerId = nonStay.isNotEmpty
            ? 'stop_${dayNumber}_0'
            : 'day_$dayNumber';
      }
    });
    if (dayNumber == null) {
      _desktopMapKey.currentState?.fitBounds();
      return;
    }
    final pts = <GeoPoint>[
      for (final d in trip.days)
        if (d.dayNumber == dayNumber)
          ...(d.stops.where((s) => s.category != 'stay').isNotEmpty
              ? [
                  for (final s in d.stops.where((s) => s.category != 'stay'))
                    GeoPoint(lat: s.lat, lng: s.lng),
                ]
              : [GeoPoint(lat: d.lat, lng: d.lng)]),
    ];
    _desktopMapKey.currentState?.seekTrailToDay(dayNumber);
    if (pts.isNotEmpty) {
      _desktopMapKey.currentState?.fitBounds(points: pts);
    }
  }

  void _focusOnMapStop({
    required int dayIndex,
    required int dayNumber,
    required String? markerId,
    required double lat,
    required double lng,
  }) {
    final isDesktop = MediaQuery.sizeOf(context).width >= 960;
    if (!isDesktop) {
      _openFullRouteMap(dayIndex: dayIndex, stopId: markerId);
      return;
    }
    setState(() {
      _focusedDayNumber = dayNumber;
      _focusedMarkerId = markerId;
    });
    _desktopMapKey.currentState?.seekTrailToDay(dayNumber);
    _desktopMapKey.currentState?.flyTo(lat, lng, zoom: 11.8);
  }

  Widget _buildDesktopRightMapPane(ItineraryTrip trip) {
    final waypoints = trip.routeWaypoints;
    final segments = _route != null && _route!.segments.isNotEmpty
        ? _route!.segments
        : trip.routeSegments;
    final markers = _buildTripMapMarkers(
      trip,
      activeDayNumber: _focusedDayNumber,
    );
    final (lat, lng, zoom) = _overviewCameraFrame(trip);
    final dayNumbers = <int>[
      for (final d in trip.days)
        if (!d.isContinuationDay) d.dayNumber,
    ];
    final activeMarker = _focusedMarkerId == null
        ? null
        : markers.where((m) => m.id == _focusedMarkerId).firstOrNull;

    return Stack(
      fit: StackFit.expand,
      children: [
        LakbayMapboxMap(
          key: _desktopMapKey,
          repo: widget.repo,
          initialLat: lat,
          initialLng: lng,
          initialZoom: zoom,
          routePoints: waypoints,
          roadGeometry: _route?.geometryPoints ?? const [],
          routeSegments: segments,
          markers: markers,
          selectedMarkerId: _focusedMarkerId,
          focusedDayNumber: _focusedDayNumber,
          showLegend: true,
          isLoadingRoute: _loadingLive,
          boundsPadding: const EdgeInsets.fromLTRB(44, 102, 44, 56),
          controlsBottomOffset: 24,
          borderRadius: 0,
          onMarkerTap: (marker) {
            int? tappedDay;
            if (marker.id.startsWith('stop_')) {
              final parts = marker.id.split('_');
              if (parts.length >= 2) tappedDay = int.tryParse(parts[1]);
            } else if (marker.id.startsWith('day_')) {
              tappedDay = int.tryParse(marker.id.replaceFirst('day_', ''));
            } else {
              tappedDay = marker.dayNumber;
            }
            setState(() {
              _focusedMarkerId = marker.id;
              if (tappedDay != null) {
                _focusedDayNumber = tappedDay;
              }
            });
            if (tappedDay != null) {
              _desktopMapKey.currentState?.seekTrailToDay(tappedDay);
              if (_tabController.index != 1) {
                _tabController.animateTo(1);
              }
            }
          },
        ),
        Positioned(
          top: 50,
          left: 12,
          right: 12,
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                ChoiceChip(
                  label: const Text(
                    'All Days',
                    style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700),
                  ),
                  selected: _focusedDayNumber == null,
                  showCheckmark: false,
                  backgroundColor: Colors.white.withValues(alpha: 0.94),
                  selectedColor: LakbayColors.tealDeep,
                  labelStyle: TextStyle(
                    color: _focusedDayNumber == null
                        ? Colors.white
                        : LakbayColors.tealDeep,
                  ),
                  visualDensity: VisualDensity.compact,
                  onSelected: (_) => _filterDesktopDay(trip, null),
                ),
                for (final dNum in dayNumbers) ...[
                  const SizedBox(width: 6),
                  ChoiceChip(
                    avatar: Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: _focusedDayNumber == dNum
                            ? Colors.white
                            : RouteTrail.colorForDay(
                                dNum,
                                RouteTrailMode.road,
                              ),
                        shape: BoxShape.circle,
                      ),
                    ),
                    label: Text(
                      'Day $dNum',
                      style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w700,
                        color: _focusedDayNumber == dNum
                            ? Colors.white
                            : LakbayColors.tealDeep,
                      ),
                    ),
                    selected: _focusedDayNumber == dNum,
                    showCheckmark: false,
                    backgroundColor: Colors.white.withValues(alpha: 0.94),
                    selectedColor: RouteTrail.colorForDay(
                      dNum,
                      RouteTrailMode.road,
                    ),
                    visualDensity: VisualDensity.compact,
                    onSelected: (_) => _filterDesktopDay(
                      trip,
                      _focusedDayNumber == dNum ? null : dNum,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
        Positioned(
          top: 10,
          left: 108,
          child: FilledButton.icon(
            onPressed: _openFullRouteMap,
            style: FilledButton.styleFrom(
              backgroundColor: LakbayColors.tealDeep,
              visualDensity: VisualDensity.compact,
            ),
            icon: const Icon(Icons.open_in_full_rounded, size: 15),
            label: const Text('Full Map'),
          ),
        ),
        if (activeMarker != null)
          Positioned(
            left: 12,
            bottom: 118,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 340),
              child: Material(
                color: Colors.white.withValues(alpha: 0.96),
                borderRadius: BorderRadius.circular(14),
                elevation: 4,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 8,
                  ),
                  child: Row(
                    children: [
                      if (activeMarker.badgeText.isNotEmpty) ...[
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 7,
                            vertical: 3,
                          ),
                          decoration: BoxDecoration(
                            color: LakbayColors.tealDeep,
                            borderRadius: BorderRadius.circular(7),
                          ),
                          child: Text(
                            activeMarker.badgeText,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 10.5,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                      ],
                      Expanded(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              activeMarker.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontFamily: 'FigGrotesk',
                                fontWeight: FontWeight.w700,
                                fontSize: 13,
                                color: LakbayColors.tealDeep,
                              ),
                            ),
                            if (activeMarker.subtitle?.isNotEmpty == true)
                              Text(
                                activeMarker.subtitle!,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 11,
                                  color: LakbayColors.textSecondary,
                                ),
                              ),
                          ],
                        ),
                      ),
                      IconButton(
                        tooltip: 'Dismiss',
                        visualDensity: VisualDensity.compact,
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(
                          minWidth: 28,
                          minHeight: 28,
                        ),
                        icon: const Icon(Icons.close_rounded, size: 16),
                        onPressed: () =>
                            setState(() => _focusedMarkerId = null),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  /// Places in this trip that exist in the catalog, for commute directions.
  List<CommuteStopRef> _commuteStops() {
    final seen = <int>{};
    final stops = <CommuteStopRef>[];
    for (final day in widget.trip.days) {
      for (final stop in day.stops) {
        final id = stop.destinationId;
        if (id != null && seen.add(id)) {
          stops.add(CommuteStopRef(id, stop.title));
        }
      }
    }
    if (stops.isEmpty) {
      for (final id in widget.trip.effectiveBackendDestinationIds) {
        if (seen.add(id)) stops.add(CommuteStopRef(id, widget.trip.title));
      }
    }
    return stops;
  }

  @override
  Widget build(BuildContext context) {
    final trip = _activeTrip;
    final isSaved = widget.repo.savedTrips.any((t) => t.id == trip.id);
    final isBucketed = widget.repo.isTripInBucketList(trip.id);

    return Scaffold(
      backgroundColor: LakbayColors.canvasBg,
      body: LayoutBuilder(
        builder: (context, constraints) {
          final isDesktop = constraints.maxWidth >= 960;
          final nestedScrollView = NestedScrollView(
            headerSliverBuilder: (context, innerBoxIsScrolled) => [
              SliverAppBar(
            expandedHeight: 220,
            pinned: true,
            backgroundColor: LakbayColors.tealDeep,
            foregroundColor: Colors.white,
            actions: [
              IconButton(
                tooltip: 'Play route animation',
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
                  LakbayDestinationMedia(
                    posterUrl: _activeTrip.remoteImageUrl,
                    assetPath: _activeTrip.heroAsset,
                    mediaUrl: _activeTrip.mediaUrl,
                    mediaType: _activeTrip.mediaType,
                    mediaDurationSeconds: _activeTrip.mediaDurationSeconds,
                    category: _activeTrip.vibeTag,
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
                                DayLabels.badge(trip.daysCount, trip.vibeTag),
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
                                trip.hasCostEstimate
                                    ? 'Est. ${widget.repo.formatPrice(trip.totalEstimatedCostUsd)}'
                                    : 'Cost not listed',
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
                _buildOverviewTab(_activeTrip, hideEmbeddedMap: isDesktop),
                _buildDayByDayTab(_activeTrip),
                _buildStaysAndFlightsTab(_activeTrip),
              ],
            ),
          );
          if (isDesktop) {
            return Row(
              children: [
                Expanded(flex: 5, child: nestedScrollView),
                const VerticalDivider(width: 1),
                Expanded(
                  flex: 6,
                  child: SafeArea(
                    left: false,
                    child: _buildDesktopRightMapPane(_activeTrip),
                  ),
                ),
              ],
            );
          }
          return nestedScrollView;
        },
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
                      [
                        trip.hasCostEstimate
                            ? widget.repo.formatPrice(trip.totalEstimatedCostUsd)
                            : 'Cost not listed',
                        if (trip.travelerCount != null) '${trip.travelerCount} pax',
                      ].join(' \u2022 '),
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

  Future<void> _confirmAndCompleteTrip(ItineraryTrip trip) async {
    if (_updatingStatus || trip.isArchived || trip.isCompleted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Mark as Completed'),
        content: Text(
          'Mark "${trip.title}" as completed? You can still export PDFs and reopen this trip anytime.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Mark as Completed'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _updatingStatus = true);
    final result = await widget.repo.setTripStatus(trip, 'completed');
    if (!mounted) return;
    setState(() {
      _updatingStatus = false;
      if (result.ok) {
        _liveTrip = result.trip;
      }
    });
    if (!result.ok) {
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(
          SnackBar(
            content: Text(
              result.error ?? 'Could not mark trip as completed.',
            ),
          ),
        );
    }
  }

  Future<void> _reopenTrip(ItineraryTrip trip) async {
    if (_updatingStatus || trip.isArchived || !trip.isCompleted) return;
    setState(() => _updatingStatus = true);
    final result = await widget.repo.setTripStatus(trip, 'planned');
    if (!mounted) return;
    setState(() {
      _updatingStatus = false;
      if (result.ok) {
        _liveTrip = result.trip;
      }
    });
    if (!result.ok) {
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(
          SnackBar(
            content: Text(result.error ?? 'Could not reopen trip.'),
          ),
        );
    }
  }

  Widget _buildLifecycleSection(ItineraryTrip trip) {
    final statusLabel = trip.isCompleted
        ? 'Completed'
        : trip.isArchived
            ? 'Archived'
            : trip.backendStatus == 'ongoing'
                ? 'Ongoing'
                : 'Planned';
    final statusColor = trip.isCompleted
        ? LakbayColors.successGreen
        : trip.isArchived
            ? LakbayColors.textSecondary
            : LakbayColors.primaryDark;

    Widget buildBadge() => Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: statusColor.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Text(
            statusLabel,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: statusColor,
            ),
          ),
        );

    final subtitleText = trip.isCompleted
        ? 'Trip finished — PDF export and itinerary stay available.'
        : trip.isArchived
            ? 'Archived trips are read-only for new memories.'
            : trip.isEndDatePassed
                ? 'Trip end date has passed — ready to wrap up?'
                : 'Trip in progress — wrap up whenever you return.';

    Widget? buildActionButton() {
      if (trip.isArchived) return null;
      if (trip.isCompleted) {
        return OutlinedButton.icon(
          style: OutlinedButton.styleFrom(
            visualDensity: VisualDensity.compact,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          ),
          onPressed: _updatingStatus ? null : () => _reopenTrip(trip),
          icon: const Icon(Icons.replay_rounded, size: 17),
          label: Text(_updatingStatus ? 'Updating...' : 'Reopen Trip'),
        );
      }
      return FilledButton.tonalIcon(
        style: FilledButton.styleFrom(
          visualDensity: VisualDensity.compact,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        ),
        onPressed: _updatingStatus ? null : () => _confirmAndCompleteTrip(trip),
        icon: const Icon(Icons.check_circle_outline_rounded, size: 17),
        label: Text(
          _updatingStatus ? 'Updating...' : 'Mark Trip as Completed',
        ),
      );
    }

    final actionButton = buildActionButton();

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: LakbayColors.cardBorder),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          if (constraints.maxWidth >= 500) {
            return Row(
              children: [
                buildBadge(),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    subtitleText,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 12.5,
                      color: LakbayColors.textSecondary,
                    ),
                  ),
                ),
                if (actionButton != null) ...[
                  const SizedBox(width: 10),
                  actionButton,
                ],
              ],
            );
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  buildBadge(),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      subtitleText,
                      style: const TextStyle(
                        fontSize: 12.5,
                        color: LakbayColors.textSecondary,
                      ),
                    ),
                  ),
                ],
              ),
              if (actionButton != null) ...[
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  children: [actionButton],
                ),
              ],
            ],
          );
        },
      ),
    );
  }

  Widget _buildOverviewTab(
    ItineraryTrip trip, {
    bool hideEmbeddedMap = false,
  }) {
    final waypoints = trip.routeWaypoints;
    final markers = _buildTripMapMarkers(
      trip,
      activeDayNumber: _focusedDayNumber,
    );
    final combinedWarnings = <String>{
      ...trip.routeWarnings,
      ..._routeWarnings,
    }.toList();
    final optSummary = trip.optimizationSummary;

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 20),
      children: [
        _buildLifecycleSection(trip),
        const SizedBox(height: 10),
        Row(
          children: [
            // Weather and best months are shown only when real data exists.
            if (trip.avgTemp.trim().isNotEmpty) ...[
              _buildInfoChip(
                iconWidget: trip.wmoWeatherCode == null
                    ? const Icon(Icons.wb_sunny_rounded,
                        color: LakbayColors.primary, size: 20)
                    : Image.asset(
                        'assets/png/weather/${trip.wmoWeatherCode}.png',
                        width: 22,
                        height: 22,
                        errorBuilder: (_, _, _) => const Icon(
                            Icons.wb_sunny_rounded,
                            color: LakbayColors.primary,
                            size: 20),
                      ),
                label: 'Weather now',
                value: trip.avgTemp,
              ),
              const SizedBox(width: 10),
            ],
            if (trip.bestMonths.trim().isNotEmpty) ...[
              _buildInfoChip(
                iconWidget: const Icon(Icons.calendar_month_rounded,
                    color: LakbayColors.primary, size: 20),
                label: 'Best time',
                value: trip.bestMonths,
              ),
              const SizedBox(width: 10),
            ],
            Builder(builder: (_) {
              final chip = RouteSummaryText.chip(
                route: _route,
                stops: trip.routeWaypoints,
                origin: widget.repo.routeOrigin,
                mode: _selectedTravelMode,
              );
              return _buildInfoChip(
                iconWidget: const Icon(Icons.route_rounded,
                    color: LakbayColors.primary, size: 20),
                label: chip == null
                    ? RouteSummaryText.modeLabel(_selectedTravelMode)
                    : '${RouteSummaryText.modeLabel(_selectedTravelMode)} • ${chip.qualifier}',
                value: chip?.value ?? 'Not set',
              );
            }),
          ],
        ),
        if (optSummary != null) ...[
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: LakbayColors.tealWash.withValues(alpha: 0.45),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: LakbayColors.cardBorder),
            ),
            child: Row(
              children: [
                const Icon(
                  Icons.auto_graph_rounded,
                  color: LakbayColors.tealDeep,
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
                          color: LakbayColors.tealDeep,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '${optSummary.methodLabel} · ${optSummary.sourceLabel}'
                        '${optSummary.minutesSaved >= 1 ? ' · Saves ${optSummary.minutesSaved.round()} min' : ''}',
                        style: const TextStyle(
                          fontSize: 11.5,
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
            ChoiceChip(
              avatar: const Icon(Icons.directions_bike_outlined, size: 16),
              label: const Text('Cycling'),
              selected: _selectedTravelMode == 'cycling',
              onSelected: (_) => _changeTravelMode('cycling'),
            ),
          ],
        ),
        if (_commuteStops().isNotEmpty) ...[
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              key: const ValueKey('open-commute-directions'),
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => CommuteDirectionsScreen(
                    repo: widget.repo,
                    trip: trip,
                    stops: _commuteStops(),
                  ),
                ),
              ),
              icon: const Icon(Icons.directions_transit_rounded, size: 18),
              label: const Text('How to get there by commute'),
            ),
          ),
        ],
        if (combinedWarnings.isNotEmpty) ...[
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Colors.amber.shade50,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.amber.shade300),
            ),
            child: Text(
              combinedWarnings.join('\n'),
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
              label: const Text('Add memory'),
              onPressed: () => showAddTripMemorySheet(
                context,
                repo: widget.repo,
                initialTrip: trip,
              ),
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
        if (!hideEmbeddedMap)
          Builder(
          builder: (context) {
            final segments = _route != null && _route!.segments.isNotEmpty
                ? _route!.segments
                : trip.routeSegments;
            final (previewLat, previewLng, previewZoom) =
                _overviewCameraFrame(trip);
            return Container(
              height: 240,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(22),
                border: Border.all(color: LakbayColors.cardBorder),
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
                    roadGeometry: _route?.geometryPoints ?? const [],
                    routeSegments: segments,
                    markers: markers,
                    showControls: false,
                    showLegend: true,
                    isLoadingRoute: _loadingLive,
                    focusedDayNumber: _focusedDayNumber,
                    onMarkerTap: (_) => _openFullRouteMap(),
                    onMapTap: (_, _) => _openFullRouteMap(),
                  ),
                  Positioned(
                    bottom: 10,
                    right: 10,
                    child: Material(
                      color: LakbayColors.tealDeep.withValues(alpha: 0.88),
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
                                  fontFamily: 'FigGrotesk',
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
        for (final notice in accessNoticesForTrip(trip)) ...[
          AccessNoticeCard(notice: notice),
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
        if (_activeTrip.isCatalogFallback) ...[
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: LakbayColors.tealWash.withValues(alpha: 0.45),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: LakbayColors.primary.withValues(alpha: 0.3),
              ),
            ),
            child: Row(
              children: [
                const Icon(
                  Icons.route_rounded,
                  color: LakbayColors.tealDeep,
                  size: 20,
                ),
                const SizedBox(width: 10),
                const Expanded(
                  child: Text(
                    "Built from Lakbay's catalog, without AI",
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 13,
                      color: LakbayColors.tealDeep,
                    ),
                  ),
                ),
                ElevatedButton.icon(
                  onPressed: _isRefining
                      ? null
                      : () => _handleAiRefine(
                          'Keep these destinations and improve timing, pacing, and local tips.'),
                  style: ElevatedButton.styleFrom(
                    minimumSize: Size.zero,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                  ),
                  icon: const Icon(Icons.auto_awesome_rounded, size: 15),
                  label: const Text(
                    'Improve with AI',
                    style: TextStyle(fontSize: 12),
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

        // Travel notes from the catalog; hidden when there are none.
        if (trip.expertTip.trim().isNotEmpty) Container(
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
              const LakbayAvatar(size: 46),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      trip.expertName.trim().isNotEmpty
                          ? trip.expertName
                          : 'Travel notes',
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
                if (day.wmoWeatherCode != null)
                  Image.asset(
                    'assets/png/weather/${day.wmoWeatherCode}.png',
                    width: 22,
                    height: 22,
                    errorBuilder: (_, _, _) => const SizedBox.shrink(),
                  ),
                IconButton(
                  tooltip: 'View on map',
                  onPressed: () =>
                      _openFullRouteMap(dayIndex: trip.days.indexOf(day)),
                  icon: const Icon(Icons.location_on_outlined,
                      color: LakbayColors.primary, size: 20),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 18),
        _buildTripMemoriesSection(trip),
      ],
    );
  }

  Widget _buildTripMemoriesSection(ItineraryTrip trip) {
    return ListenableBuilder(
      listenable: widget.repo,
      builder: (context, _) {
        final tripMemories = widget.repo.memoriesForTrip(trip);
        final outboxCount = tripMemories.where((m) => m.isOutbox).length;
        return Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: LakbayColors.cardBorder),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Expanded(
                    child: Text(
                      'Trip Memories',
                      style: TextStyle(
                        fontFamily: 'FigGrotesk',
                        fontWeight: FontWeight.w700,
                        fontSize: 16,
                        color: LakbayColors.tealDeep,
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: () {
                      widget.repo.setActiveNavIndex(3);
                      Navigator.of(context).popUntil((r) => r.isFirst);
                    },
                    child: const Text('View album'),
                  ),
                  const SizedBox(width: 4),
                  FilledButton.icon(
                    onPressed: trip.isArchived
                        ? null
                        : () => showAddTripMemorySheet(
                              context,
                              repo: widget.repo,
                              initialTrip: trip,
                            ),
                    icon: const Icon(Icons.add_a_photo_outlined, size: 16),
                    label: const Text('Add memory'),
                  ),
                ],
              ),
              if (trip.isArchived)
                const Padding(
                  padding: EdgeInsets.only(top: 6),
                  child: Text(
                    'Read-only archive.',
                    style: TextStyle(
                      fontSize: 12.5,
                      color: LakbayColors.textSecondary,
                    ),
                  ),
                )
              else if (tripMemories.isEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    trip.hasEnded
                        ? 'Trip finished — capture your first memory from ${trip.title}!'
                        : 'Save photos and moments from ${trip.title} for your group.',
                    style: const TextStyle(
                      fontSize: 13,
                      color: LakbayColors.textSecondary,
                    ),
                  ),
                )
              else ...[
                if (outboxCount > 0)
                  Padding(
                    padding: const EdgeInsets.only(top: 6, bottom: 6),
                    child: Text(
                      '$outboxCount photo(s) pending upload in your outbox.',
                      style: const TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFFE65100),
                      ),
                    ),
                  ),
                const SizedBox(height: 8),
                SizedBox(
                  height: 84,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    itemCount: tripMemories.length,
                    separatorBuilder: (_, _) => const SizedBox(width: 8),
                    itemBuilder: (context, idx) {
                      final m = tripMemories[idx];
                      return Container(
                        width: 112,
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: m.isOutbox
                              ? const Color(0xFFFFF8E1)
                              : LakbayColors.canvasBg,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: m.isOutbox
                                ? const Color(0xFFFFB74D)
                                : LakbayColors.cardBorder,
                          ),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              m.caption ?? m.locationTag ?? 'Trip photo',
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                                color: LakbayColors.tealDeep,
                              ),
                            ),
                            if (m.isOutbox)
                              InkWell(
                                onTap: () => widget.repo.retryOutboxMemory(m),
                                child: const Text(
                                  'Not uploaded · Retry',
                                  style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w700,
                                    color: Color(0xFFE65100),
                                  ),
                                ),
                              )
                            else
                              Text(
                                '♥ ${m.likeCount}',
                                style: const TextStyle(
                                  fontSize: 11.5,
                                  color: LakbayColors.primary,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
              ],
            ],
          ),
        );
      },
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

  /// Says why a day has no weather, and lets the traveler add the start date.
  Widget _buildForecastNote(ItineraryTrip trip) {
    final hasWeather = trip.days.any((d) => d.wmoWeatherCode != null);
    if (hasWeather) return const SizedBox.shrink();
    final start = trip.startDate;
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: LakbayColors.canvasBg,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          const Icon(Icons.wb_cloudy_outlined,
              size: 20, color: LakbayColors.tealDeep),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              start == null
                  ? 'Add your travel date to see the weather forecast.'
                  : 'The forecast shows within 5 days of travel.',
              style: const TextStyle(
                fontSize: 12.5,
                color: LakbayColors.textSecondary,
              ),
            ),
          ),
          TextButton(
            onPressed: () async {
              final now = DateTime.now();
              final picked = await showDatePicker(
                context: context,
                initialDate: start ?? now,
                firstDate: now.subtract(const Duration(days: 1)),
                lastDate: now.add(const Duration(days: 730)),
              );
              if (picked == null || !mounted) return;
              final updated = await widget.repo.setTripStartDate(_activeTrip, picked);
              if (mounted) setState(() => _liveTrip = updated);
            },
            child: Text(start == null ? 'Set date' : 'Change date'),
          ),
        ],
      ),
    );
  }

  Widget _buildDayByDayTab(ItineraryTrip trip) {
    return ListView.builder(
      padding: const EdgeInsets.all(20),
      itemCount: trip.days.length + 1,
      itemBuilder: (context, idx) {
        if (idx == 0) {
          final canOptimize =
              trip.routeWaypoints.length >= 2 || trip.days.length >= 2;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildForecastNote(trip),
              Padding(
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
          ),
            ],
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
                border: Border.all(
                  color: day.overloadWarning != null
                      ? Colors.amber.shade400
                      : LakbayColors.cardBorder,
                ),
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
                          color: day.isContinuationDay
                              ? LakbayColors.tealDeep
                              : LakbayColors.primary,
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
                      if (day.totalHours != null && !day.isContinuationDay) ...[
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 7,
                            vertical: 3,
                          ),
                          decoration: BoxDecoration(
                            color: day.overloadWarning != null
                                ? Colors.amber.shade100
                                : LakbayColors.canvasBg,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            '${day.totalHours!.toStringAsFixed(1)} h',
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                              color: day.overloadWarning != null
                                  ? Colors.deepOrange
                                  : LakbayColors.tealDeep,
                            ),
                          ),
                        ),
                        const SizedBox(width: 6),
                      ],
                      if (day.wmoWeatherCode != null && day.tempCelsius != null) ...[
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
                      ],
                      IconButton(
                        tooltip: 'See this day on the map',
                        onPressed: () => _openFullRouteMap(dayIndex: index),
                        icon: const Icon(Icons.map_outlined,
                            color: LakbayColors.tealAccent, size: 20),
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
                        color: LakbayColors.tealWash,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: const Text(
                        'Leisure / Continuation Day — no road transit required',
                        style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w600,
                          color: LakbayColors.tealDeep,
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
                        color: Colors.amber.shade50,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: Colors.amber.shade300),
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
                      color: LakbayColors.textSecondary,
                    ),
                  ),
                  const Divider(height: 22),
                  for (int sIdx = 0; sIdx < day.stops.length; sIdx++) ...[
                    if (sIdx > 0 &&
                        day.stops[sIdx].travelFromPrevMinutes != null &&
                        day.stops[sIdx].travelFromPrevMinutes! > 0)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8, left: 68),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              day.stops[sIdx].isSeaCrossingFromPrev ||
                                      day.stops[sIdx].travelFromPrevMode ==
                                          TransportMode.ferry
                                  ? Icons.directions_boat_rounded
                                  : Icons.directions_car_outlined,
                              size: 14,
                              color: LakbayColors.tealAccent,
                            ),
                            const SizedBox(width: 6),
                            Text(
                              '${day.stops[sIdx].isSeaCrossingFromPrev ? 'Boat + drive' : 'Drive'}: ~${day.stops[sIdx].travelFromPrevMinutes} min'
                              '${day.stops[sIdx].travelFromPrevKm != null ? ' (${day.stops[sIdx].travelFromPrevKm!.toStringAsFixed(1)} km)' : ''}',
                              style: const TextStyle(
                                fontSize: 11.5,
                                fontWeight: FontWeight.w600,
                                color: LakbayColors.tealAccent,
                              ),
                            ),
                          ],
                        ),
                      ),
                    Builder(
                      builder: (context) {
                        final stop = day.stops[sIdx];
                        final nonStayIdx = stop.category == 'stay'
                            ? -1
                            : day.stops
                                .sublist(0, sIdx)
                                .where((s) => s.category != 'stay')
                                .length;
                        final markerId = nonStayIdx >= 0
                            ? 'stop_${day.dayNumber}_$nonStayIdx'
                            : 'day_${day.dayNumber}';
                        final isFocused = _focusedMarkerId == markerId;
                        return Container(
                          margin: const EdgeInsets.only(bottom: 8),
                          decoration: BoxDecoration(
                            color: isFocused ? LakbayColors.primarySoft : null,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(
                                child: InkWell(
                                  borderRadius: BorderRadius.circular(12),
                                  onTap: () => _focusOnMapStop(
                                    dayIndex: index,
                                    dayNumber: day.dayNumber,
                                    markerId: markerId,
                                    lat: stop.lat,
                                    lng: stop.lng,
                                  ),
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 4,
                                      vertical: 4,
                                    ),
                                    child: Row(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        SizedBox(
                                          width: 64,
                                          child: Text(
                                            stop.time,
                                            style: const TextStyle(
                                              fontWeight: FontWeight.w600,
                                              fontSize: 12,
                                              color: LakbayColors.tealAccent,
                                            ),
                                          ),
                                        ),
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              Wrap(
                                                spacing: 6,
                                                crossAxisAlignment:
                                                    WrapCrossAlignment.center,
                                                children: [
                                                  Text(
                                                    stop.title,
                                                    style: const TextStyle(
                                                      fontFamily: 'FigGrotesk',
                                                      fontWeight:
                                                          FontWeight.w600,
                                                      fontSize: 14.5,
                                                    ),
                                                  ),
                                                  if (_stayLengthLabel(
                                                          stop.stayDurationType) !=
                                                      null)
                                                    Container(
                                                      padding: const EdgeInsets
                                                          .symmetric(
                                                        horizontal: 6,
                                                        vertical: 2,
                                                      ),
                                                      decoration: BoxDecoration(
                                                        color: LakbayColors
                                                            .canvasBg,
                                                        borderRadius:
                                                            BorderRadius
                                                                .circular(6),
                                                      ),
                                                      child: Row(
                                                        mainAxisSize:
                                                            MainAxisSize.min,
                                                        children: [
                                                          const Icon(
                                                            Icons
                                                                .schedule_rounded,
                                                            size: 11,
                                                            color: LakbayColors
                                                                .textSecondary,
                                                          ),
                                                          const SizedBox(
                                                            width: 3,
                                                          ),
                                                          Text(
                                                            'Typical visit: ${_stayLengthLabel(stop.stayDurationType)!}',
                                                            style:
                                                                const TextStyle(
                                                              fontSize: 10.5,
                                                              fontWeight:
                                                                  FontWeight
                                                                      .w600,
                                                              color: LakbayColors
                                                                  .textSecondary,
                                                            ),
                                                          ),
                                                        ],
                                                      ),
                                                    ),
                                                ],
                                              ),
                                              const SizedBox(height: 2),
                                              Text(
                                                stop.description,
                                                style: const TextStyle(
                                                  fontSize: 12.5,
                                                  color: LakbayColors
                                                      .textSecondary,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
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
                        );
                      },
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
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 20),
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
          'Stays from the Lakbay catalog',
          style: TextStyle(
            fontFamily: 'FigGrotesk',
            fontWeight: FontWeight.w700,
            fontSize: 19,
          ),
        ),
        const SizedBox(height: 12),
        if (trip.hotels.isEmpty)
          Container(
            width: double.infinity,
            margin: const EdgeInsets.only(bottom: 14),
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: LakbayColors.cardBorder),
            ),
            child: const Text(
              'No stays are listed for this place yet.',
              style: TextStyle(
                fontSize: 13.5,
                color: LakbayColors.textSecondary,
              ),
            ),
          ),
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
                Row(
                  children: [
                    const Icon(Icons.hotel_rounded,
                        color: LakbayColors.tealDeep, size: 20),
                    const SizedBox(width: 8),
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
                    // Only when the catalog has a rating.
                    if (h.rating != null)
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
                  [
                    if (h.stars != null) '★' * h.stars!,
                    if (h.capacity != null) 'Sleeps ${h.capacity}',
                    h.sourceLabel,
                  ].join(' • '),
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
                      h.pricePhp == null
                          ? 'Price not listed'
                          : '${widget.repo.formatPrice(h.pricePhp! / widget.repo.phpPerUsd)}'
                              ' ${h.chargingUnitLabel ?? '(unit not listed)'}',
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
