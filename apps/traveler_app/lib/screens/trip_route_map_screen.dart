import 'dart:async';

import 'package:flutter/material.dart';

import '../models/travel_models.dart';
import '../services/location_service.dart';
import '../services/mapbox_service.dart';
import '../services/route_progress.dart';
import '../services/travel_repository.dart';
import '../theme/lakbay_theme.dart';
import '../widgets/lakbay_mapbox_widget.dart';
import '../services/access_notices.dart';
import '../services/nearby_places.dart';
import '../widgets/access_notice_card.dart';

class TripRouteMapScreen extends StatefulWidget {
  final ItineraryTrip trip;
  final TravelRepository repo;

  const TripRouteMapScreen({super.key, required this.trip, required this.repo});

  @override
  State<TripRouteMapScreen> createState() => _TripRouteMapScreenState();
}

class _TripRouteMapScreenState extends State<TripRouteMapScreen> {
  final PageController _pageController = PageController(viewportFraction: 0.88);
  final GlobalKey<LakbayMapboxMapState> _mapKey =
      GlobalKey<LakbayMapboxMapState>();

  int _selectedDayIndex = 0;
  bool _showHotelsOnMap = false;
  ItineraryTrip? _liveTrip;
  BackendRouteResult? _backendRoute;
  bool _loadingRoadRoute = false;
  bool _fittedRouteOnce = false;
  bool _showNearby = true;

  ItineraryTrip get _activeTrip => _liveTrip ?? widget.trip;

  BackendRouteResult? _routeResultFromTrip(ItineraryTrip trip) {
    final segs = trip.routeSegments;
    if (segs.isEmpty) return null;
    final summary = trip.optimizationSummary;
    return BackendRouteResult(
      routeProvider: summary?.costSource ?? 'cached',
      isEstimated: segs.every((s) => s.isEstimated),
      totalDistanceKm: summary?.optimizedDistanceKm ??
          MapboxService.calculateRouteDistanceKm(trip.routeWaypoints),
      totalDurationMinutes: summary?.optimizedTransitMinutes.round() ?? 0,
      geometryPoints: [for (final s in segs) ...s.points],
      warnings: trip.routeWarnings,
      orderedDestinationIds: trip.effectiveBackendDestinationIds,
      segments: segs,
      seaCrossings: trip.seaCrossings,
    );
  }

  int _markerDayNumberForIndex(int idx) {
    final days = _activeTrip.days;
    if (days.isEmpty) return 1;
    var k = idx.clamp(0, days.length - 1);
    while (k > 0 && days[k].isContinuationDay) {
      k--;
    }
    return days[k].dayNumber;
  }

  String _primaryMarkerIdForSelectedDay() {
    final days = _activeTrip.days;
    if (days.isEmpty) return 'day_1';
    final dayNum = _markerDayNumberForIndex(_selectedDayIndex);
    final day = days.firstWhere(
      (d) => d.dayNumber == dayNum,
      orElse: () => days.first,
    );
    final hasStops = day.stops.any((s) => s.category != 'stay');
    return hasStops ? 'stop_${day.dayNumber}_0' : 'day_${day.dayNumber}';
  }

  // Live tracking
  bool _liveTracking = false;
  bool _followUser = false;
  bool _rerouting = false;
  LivePosition? _lastHandledFix;
  RouteProjection? _progress;
  int _reachedDays = 0;
  final OffRouteDetector _offRoute = OffRouteDetector();

  @override
  void initState() {
    super.initState();
    _backendRoute = _routeResultFromTrip(_activeTrip);
    _loadRoadRoute(optimize: false);
    widget.repo.addListener(_onRepoChanged);
    widget.repo.startLiveTracking().then((started) {
      if (!started) return;
      if (!mounted) {
        widget.repo.stopLiveTracking();
        return;
      }
      setState(() => _liveTracking = true);
    });
  }

  /// The drawn route the traveler is expected to follow: provider geometry
  /// only. Estimated (straight) parts are excluded so they never trigger a
  /// reroute or a remaining-distance figure. A dashed off-road last stretch
  /// next to a real road keeps the road part followable.
  List<GeoPoint> get _followableRoute {
    final route = _backendRoute;
    if (route == null) return const [];
    if (route.segments.isNotEmpty) {
      if (route.isEstimated) return const [];
      return [
        for (final segment in route.segments)
          if (!segment.isEstimated) ...segment.points,
      ];
    }
    return route.geometryPoints;
  }

  /// The API's own explanation for dashed parts, shown on the map instead of
  /// a generic message. Null while loading or when the route has no gaps.
  String? _routeNoticeText() {
    final route = _backendRoute;
    if (route == null) {
      if (_loadingRoadRoute) return 'Finding the road route…';
      return null;
    }
    const keywords = [
      'road ends',
      'starting point is about',
      'could not be routed',
      'Haversine',
      'straight-line',
    ];
    for (final warning in route.warnings) {
      if (keywords.any(warning.contains)) {
        if (warning.contains('Haversine')) {
          return 'No road reaches every stop yet — dashed lines show stop order only.';
        }
        return warning;
      }
    }
    return null;
  }

  void _onRepoChanged() {
    final fix = widget.repo.livePosition;
    if (!mounted || fix == null || identical(fix, _lastHandledFix)) return;
    _lastHandledFix = fix;

    final days = widget.trip.days;
    final arrived = detectArrival(
      lat: fix.lat,
      lng: fix.lng,
      stops: [for (final d in days) GeoPoint(lat: d.lat, lng: d.lng)],
      reachedCount: _reachedDays,
    );
    if (arrived != null) {
      _reachedDays = arrived + 1;
      _offRoute.reset();
      final next = (arrived + 1).clamp(0, days.length - 1);
      if (next != _selectedDayIndex && _pageController.hasClients) {
        _pageController.animateToPage(
          next,
          duration: const Duration(milliseconds: 320),
          curve: Curves.easeOutCubic,
        );
      }
      _selectedDayIndex = next;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(content: Text('You arrived at ${days[arrived].cityTitle}.')),
      );
    }

    final route = _followableRoute;
    _progress = projectOntoRoute(fix.lat, fix.lng, route);
    final needsReroute =
        !_rerouting &&
        !_loadingRoadRoute &&
        _offRoute.update(
          lat: fix.lat,
          lng: fix.lng,
          accuracyMeters: fix.accuracyMeters,
          route: route,
          now: DateTime.now(),
        );
    setState(() {});
    if (needsReroute) _rerouteFromHere();
  }

  /// New route from the live position to the stops not reached yet.
  Future<void> _rerouteFromHere() async {
    final remaining = [
      for (final d in widget.trip.days.skip(_reachedDays)) ?d.apiDestinationId,
    ];
    if (_reachedDays > 0 && remaining.isEmpty) return;
    setState(() => _rerouting = true);
    try {
      await _loadRoadRoute(
        optimize: false,
        destinationIds: _reachedDays > 0 ? remaining : null,
      );
    } finally {
      if (mounted) setState(() => _rerouting = false);
    }
  }

  Future<void> _loadRoadRoute({
    required bool optimize,
    List<int>? destinationIds,
  }) async {
    if (_loadingRoadRoute) return;
    setState(() => _loadingRoadRoute = true);
    try {
      final result = await widget.repo.fetchRoadRouteForTrip(
        _activeTrip,
        optimize: optimize,
        destinationIds: destinationIds,
      );
      if (!mounted) return;
      final hadSegments = _backendRoute?.segments.isNotEmpty ?? false;
      setState(() {
        if (result != null) _backendRoute = result;
        _loadingRoadRoute = false;
      });
      if (result != null && result.segments.isNotEmpty && (!hadSegments || !_fittedRouteOnce)) {
        _fittedRouteOnce = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _mapKey.currentState?.fitBounds();
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loadingRoadRoute = false);
    }
  }

  Future<void> _handleOptimizeOrder() async {
    if (_loadingRoadRoute) return;
    setState(() => _loadingRoadRoute = true);
    try {
      final updated = await widget.repo.optimizeStopsForTrip(_activeTrip);
      if (!mounted) return;
      final cached = _routeResultFromTrip(updated);
      final routeResult = cached ??
          await widget.repo.fetchRoadRouteForTrip(
            updated,
            optimize: true,
          );
      if (!mounted) return;
      setState(() {
        _liveTrip = updated;
        _selectedDayIndex = updated.days.isEmpty
            ? 0
            : _selectedDayIndex.clamp(0, updated.days.length - 1);
        if (routeResult != null) _backendRoute = routeResult;
        _loadingRoadRoute = false;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _mapKey.currentState?.fitBounds();
      });
    } catch (_) {
      if (mounted) setState(() => _loadingRoadRoute = false);
    }
  }

  bool _isTourPlaying = false;
  Timer? _tourTimer;

  @override
  void dispose() {
    widget.repo.removeListener(_onRepoChanged);
    if (_liveTracking) widget.repo.stopLiveTracking();
    _tourTimer?.cancel();
    _pageController.dispose();
    super.dispose();
  }

  /// "2.4 km · ~6 min left" from the live position along the drawn route.
  String? _remainingText() {
    final progress = _progress;
    final route = _backendRoute;
    if (progress == null || route == null) return null;
    final text = formatDistanceMeters(progress.remainingMeters);
    final totalMeters = route.totalDistanceKm * 1000;
    if (totalMeters <= 0 || route.totalDurationMinutes <= 0) {
      return '$text left';
    }
    final minutes =
        (route.totalDurationMinutes * progress.remainingMeters / totalMeters)
            .ceil();
    return '$text · ~$minutes min left';
  }

  List<NearbyPlace> _nearbyPlaces() =>
      nearbyPlacesForTrip(_activeTrip, widget.repo.allTrips);

  List<LakbayMapMarker> _nearbyMarkers(List<NearbyPlace> nearby) => [
        if (_showNearby)
          for (final item in nearby)
            LakbayMapMarker(
              id: 'nearby_${item.place.id}',
              lat: item.place.lat,
              lng: item.place.lng,
              title: item.place.title,
              subtitle:
                  '${item.distanceKm.toStringAsFixed(1)} km from ${item.nearestStopName}',
              imageUrl:
                  item.place.hasRemoteThumbnail ? item.place.thumbnailUrl : null,
              isNearby: true,
            ),
      ];

  Future<void> _showNearbySheet(String markerId) async {
    final placeId = markerId.replaceFirst('nearby_', '');
    final item =
        _nearbyPlaces().where((n) => n.place.id == placeId).firstOrNull;
    if (item == null) return;
    final place = item.place;
    final add = await showModalBottomSheet<bool>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (place.hasRemoteThumbnail)
                ClipRRect(
                  borderRadius: BorderRadius.circular(16),
                  child: Image.network(
                    place.thumbnailUrl,
                    height: 150,
                    width: double.infinity,
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => const SizedBox.shrink(),
                  ),
                ),
              const SizedBox(height: 12),
              Text(
                place.title,
                style: const TextStyle(
                  fontFamily: 'FigGrotesk',
                  fontWeight: FontWeight.w700,
                  fontSize: 18,
                  color: LakbayColors.tealDeep,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                '${place.municipalityLabel} · '
                '${item.distanceKm.toStringAsFixed(1)} km from ${item.nearestStopName}',
                style: const TextStyle(
                  fontSize: 12.5,
                  color: LakbayColors.textSecondary,
                ),
              ),
              if (place.description?.isNotEmpty == true) ...[
                const SizedBox(height: 8),
                Text(
                  place.description!,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13, height: 1.4),
                ),
              ],
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: () => Navigator.of(ctx).pop(true),
                  icon: const Icon(Icons.add_location_alt_rounded),
                  label: const Text('Add to trip'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (add == true && mounted) _addNearbyToTrip(place);
  }

  void _addNearbyToTrip(ExploreTrip place) {
    final before = _activeTrip;
    final updated = addPlaceToTrip(before, place);
    if (identical(updated, before)) return;
    widget.repo.updateTripDetails(updated);
    final day = updated.days.firstWhere(
      (d) => d.stops.any((s) => s.title == place.title),
      orElse: () => updated.days.first,
    );
    setState(() {
      _liveTrip = updated;
      _backendRoute = null;
      _fittedRouteOnce = false;
    });
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(content: Text('Added ${place.title} to Day ${day.dayNumber}.')),
    );
    _loadRoadRoute(optimize: false);
  }

  List<LakbayMapMarker> _pierMarkers() {
    final markers = <LakbayMapMarker>[];
    final seen = <String>{};
    for (final crossing
        in _backendRoute?.seaCrossings ?? const <SeaCrossingInfo>[]) {
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
          ),
        );
      }
    }
    return markers;
  }

  void _toggleRouteTour() {
    if (_isTourPlaying) {
      _tourTimer?.cancel();
      setState(() => _isTourPlaying = false);
      return;
    }

    setState(() => _isTourPlaying = true);
    _advanceTourStep();
    _tourTimer = Timer.periodic(const Duration(milliseconds: 2400), (_) {
      if (!mounted) return;
      _advanceTourStep();
    });
  }

  void _advanceTourStep() {
    final days = _activeTrip.days;
    if (days.isEmpty) return;
    final nextIdx = (_selectedDayIndex + 1) % days.length;
    setState(() => _selectedDayIndex = nextIdx);
    if (_pageController.hasClients) {
      _pageController.animateToPage(
        nextIdx,
        duration: const Duration(milliseconds: 450),
        curve: Curves.easeOutCubic,
      );
    }
    final day = days[nextIdx];
    _mapKey.currentState?.flyTo(day.lat, day.lng, zoom: 10.2);
  }

  List<LakbayMapMarker> _buildMarkers() {
    final trip = _activeTrip;
    final activeDayNum = _markerDayNumberForIndex(_selectedDayIndex);
    final stopMarkers = <LakbayMapMarker>[];
    for (int i = 0; i < trip.days.length; i++) {
      final d = trip.days[i];
      if (d.isContinuationDay) continue;
      final dayStops = d.stops.where((s) => s.category != 'stay').toList();
      if (dayStops.isNotEmpty) {
        for (int sIdx = 0; sIdx < dayStops.length; sIdx++) {
          final stop = dayStops[sIdx];
          final media = widget.repo.resolveDayMarkerMedia(
            trip,
            ItineraryDay(
              dayNumber: d.dayNumber,
              cityTitle: stop.title,
              summary: stop.description,
              lat: stop.lat,
              lng: stop.lng,
              stops: const [],
              apiDestinationId: stop.destinationId,
            ),
          );
          final badge =
              dayStops.length == 1 ? 'D${d.dayNumber}' : 'D${d.dayNumber}.${sIdx + 1}';
          stopMarkers.add(
            LakbayMapMarker(
              id: 'stop_${d.dayNumber}_$sIdx',
              lat: stop.lat,
              lng: stop.lng,
              badgeText: badge,
              title: stop.title,
              subtitle: stop.description.isNotEmpty ? stop.description : d.cityTitle,
              imageUrl: media.imageUrl,
              imageAsset: media.imageAsset,
              isPrimary: d.dayNumber == activeDayNum,
            ),
          );
        }
      } else {
        final media = widget.repo.resolveDayMarkerMedia(trip, d);
        stopMarkers.add(
          LakbayMapMarker(
            id: 'day_${d.dayNumber}',
            lat: d.lat,
            lng: d.lng,
            badgeText: 'D${d.dayNumber}',
            title: d.cityTitle,
            subtitle: d.summary,
            imageUrl: media.imageUrl,
            imageAsset: media.imageAsset,
            isPrimary: d.dayNumber == activeDayNum,
          ),
        );
      }
    }
    final markers = <LakbayMapMarker>[
      for (int i = 0; i < stopMarkers.length; i++)
        LakbayMapMarker(
          id: stopMarkers[i].id,
          lat: stopMarkers[i].lat,
          lng: stopMarkers[i].lng,
          badgeText: stopMarkers[i].badgeText,
          title: stopMarkers[i].title,
          subtitle: stopMarkers[i].subtitle,
          imageUrl: stopMarkers[i].imageUrl,
          imageAsset: stopMarkers[i].imageAsset,
          isPrimary: stopMarkers[i].isPrimary,
          isOrigin: i == 0,
          isDestination: i == stopMarkers.length - 1,
        ),
    ];
    if (_showHotelsOnMap) {
      for (final h in widget.trip.hotels) {
        final hotelUrl =
            (h.remoteImageUrl != null &&
                (h.remoteImageUrl!.startsWith('http://') ||
                    h.remoteImageUrl!.startsWith('https://')))
            ? h.remoteImageUrl
            : (widget.trip.remoteImageUrl != null &&
                      (widget.trip.remoteImageUrl!.startsWith('http://') ||
                          widget.trip.remoteImageUrl!.startsWith('https://'))
                  ? widget.trip.remoteImageUrl
                  : null);
        markers.add(
          LakbayMapMarker(
            id: h.id,
            lat: h.lat,
            lng: h.lng,
            badgeText: 'Stay',
            title: h.name,
            subtitle: '${h.stars}★ • ${h.city}',
            imageUrl: hotelUrl,
            imageAsset: h.imageAsset,
          ),
        );
      }
    }
    if (widget.repo.originLat != null && widget.repo.originLng != null) {
      markers.add(
        LakbayMapMarker(
          id: 'user_gps',
          lat: widget.repo.originLat!,
          lng: widget.repo.originLng!,
          title: 'You (${widget.repo.effectiveOriginLabel})',
          subtitle: widget.repo.hasManualOrigin
              ? 'Chosen starting place'
              : 'Current GPS location',
          isUserLocation: true,
        ),
      );
    }
    return markers;
  }

  void _showStaticRouteCardModal() {
    final waypoints = widget.trip.routeWaypoints;
    final staticUrl = widget.repo.mapbox.buildStaticRouteImageUrl(
      waypoints: waypoints,
      centerLat: widget.trip.centerLat,
      centerLng: widget.trip.centerLng,
      zoom: 8.6,
      style: widget.repo.activeMapStyle,
    );
    final totalKm = MapboxService.calculateRouteDistanceKm(waypoints);

    showDialog(
      context: context,
      builder: (ctx) => Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        clipBehavior: Clip.antiAlias,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              padding: const EdgeInsets.all(16),
              decoration: const BoxDecoration(
                gradient: LakbayColors.deepTealGradient,
              ),
              child: Row(
                children: [
                  const Icon(
                    Icons.picture_as_pdf_rounded,
                    color: Colors.white,
                    size: 22,
                  ),
                  const SizedBox(width: 10),
                  const Expanded(
                    child: Text(
                      'Mapbox Static Davao Route Card',
                      style: TextStyle(
                        fontFamily: 'FigGrotesk',
                        fontWeight: FontWeight.w700,
                        fontSize: 17.5,
                        color: Colors.white,
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.of(ctx).pop(),
                    icon: const Icon(Icons.close_rounded, color: Colors.white),
                  ),
                ],
              ),
            ),
            SizedBox(
              height: 210,
              child: staticUrl != null
                  ? Image.network(
                      staticUrl,
                      fit: BoxFit.cover,
                      errorBuilder: (_, _, _) => LakbayMapboxMap(
                        repo: widget.repo,
                        initialLat: widget.trip.centerLat,
                        initialLng: widget.trip.centerLng,
                        initialZoom: 8.4,
                        routePoints: waypoints,
                        markers: _buildMarkers(),
                        showControls: false,
                        interactive: false,
                        animateRoute: false,
                        borderRadius: 0,
                      ),
                    )
                  : LakbayMapboxMap(
                      repo: widget.repo,
                      initialLat: widget.trip.centerLat,
                      initialLng: widget.trip.centerLng,
                      initialZoom: 8.4,
                      routePoints: waypoints,
                      markers: _buildMarkers(),
                      showControls: false,
                      interactive: false,
                      animateRoute: false,
                      borderRadius: 0,
                    ),
            ),
            Padding(
              padding: const EdgeInsets.all(18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.trip.title,
                    style: const TextStyle(
                      fontFamily: 'FigGrotesk',
                      fontWeight: FontWeight.w700,
                      fontSize: 18,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${widget.trip.daysCount} Days • ${totalKm.toStringAsFixed(0)} km Region XI Route • ${widget.trip.hotels.first.name}',
                    style: const TextStyle(
                      fontSize: 13,
                      color: LakbayColors.textSecondary,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: LakbayColors.canvasBg,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      staticUrl != null
                          ? 'Mapbox Static Images API active (${widget.repo.activeMapStyle.id})'
                          : 'Tip: Tap "Mapbox Key" on the map to set MAPBOX_ACCESS_TOKEN for high-DPI Static Images export.',
                      style: const TextStyle(
                        fontSize: 11.5,
                        color: LakbayColors.tealDeep,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  (double lat, double lng, double zoom) _initialCameraFrame(
    ItineraryTrip trip,
    List<GeoPoint> waypoints,
  ) {
    final pts = <GeoPoint>[
      ...waypoints,
      for (final seg in _backendRoute?.segments ?? const <RouteSegmentGeometry>[])
        ...seg.points,
    ];
    final originLat = widget.repo.originLat;
    final originLng = widget.repo.originLng;
    if (originLat != null &&
        originLng != null &&
        (pts.isEmpty ||
            pts.any(
              (p) =>
                  MapboxService.haversineKm(p.lat, p.lng, originLat, originLng) <=
                  120.0,
            ))) {
      pts.add(GeoPoint(lat: originLat, lng: originLng));
    }
    if (pts.isEmpty) {
      final first = trip.days.firstOrNull;
      return (
        first?.lat ?? MapboxService.davaoCenterLat,
        first?.lng ?? MapboxService.davaoCenterLng,
        8.8,
      );
    }
    return MapboxService.computeBoundsCenterAndZoom(pts);
  }

  void _showSeaCrossingsSheet(List<SeaCrossingInfo> crossings) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 14, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 38,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.grey.shade300,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              crossings.length == 1
                  ? 'Boat Crossing Details'
                  : 'Boat Crossings (${crossings.length})',
              style: const TextStyle(
                fontFamily: 'FigGrotesk',
                fontWeight: FontWeight.w700,
                fontSize: 18,
                color: LakbayColors.tealDeep,
              ),
            ),
            const SizedBox(height: 10),
            for (final crossing in crossings) _SeaCrossingCard(crossing: crossing),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final trip = _activeTrip;
    final waypoints = trip.routeWaypoints;
    final nearby = _nearbyPlaces();
    final totalKm = MapboxService.calculateRouteDistanceKm(waypoints);
    final (initLat, initLng, initZoom) = _initialCameraFrame(trip, waypoints);

    return Scaffold(
      appBar: AppBar(
        backgroundColor: LakbayColors.tealDeep,
        foregroundColor: Colors.white,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              trip.title,
              style: const TextStyle(
                fontFamily: 'FigGrotesk',
                fontWeight: FontWeight.w700,
                fontSize: 16,
              ),
            ),
            Text(
              _backendRoute != null
                  ? '${waypoints.length} Stops • ${_backendRoute!.totalDistanceKm.toStringAsFixed(1)} km • ${_backendRoute!.totalDurationMinutes} min ${_backendRoute!.geometryPoints.length >= 2 ? 'road route' : 'estimate'}'
                  : '${waypoints.length} Stops • ${totalKm.toStringAsFixed(0)} km Region XI Route',
              style: const TextStyle(fontSize: 11.5, color: Colors.white70),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: _isTourPlaying ? 'Pause Route Tour' : 'Play Route Tour',
            onPressed: _toggleRouteTour,
            icon: Icon(
              _isTourPlaying
                  ? Icons.pause_circle_filled_rounded
                  : Icons.play_circle_fill_rounded,
              color: _isTourPlaying ? LakbayColors.cocoaOrange : Colors.white,
            ),
          ),
          IconButton(
            tooltip: 'Toggle Hotel Pins',
            onPressed: () =>
                setState(() => _showHotelsOnMap = !_showHotelsOnMap),
            icon: Icon(
              _showHotelsOnMap ? Icons.hotel_rounded : Icons.hotel_outlined,
              color: _showHotelsOnMap ? LakbayColors.primary : Colors.white70,
            ),
          ),
          IconButton(
            tooltip: 'Static Route Card & PDF Map',
            onPressed: _showStaticRouteCardModal,
            icon: const Icon(Icons.picture_as_pdf_rounded),
          ),
        ],
      ),
      body: Stack(
        fit: StackFit.expand,
        children: [
          LakbayMapboxMap(
            key: _mapKey,
            repo: widget.repo,
            initialLat: initLat,
            initialLng: initLng,
            initialZoom: initZoom,
            routePoints: waypoints,
            roadGeometry: _backendRoute?.geometryPoints ?? const [],
            routeSegments: _backendRoute?.segments ?? const [],
            routeNotice: _routeNoticeText(),
            // Nearby first so trip pins draw on top of them.
            markers: [
              ..._nearbyMarkers(nearby),
              ..._buildMarkers(),
              ..._pierMarkers(),
            ],
            livePosition: widget.repo.livePosition,
            followUser: _followUser,
            onFollowUserChanged: (follow) =>
                setState(() => _followUser = follow),
            selectedMarkerId: _primaryMarkerIdForSelectedDay(),
            borderRadius: 0,
            controlsBottomOffset: 170,
            onMarkerTap: (marker) {
              if (marker.id.startsWith('nearby_')) {
                _showNearbySheet(marker.id);
                return;
              }
              int? dayNum;
              if (marker.id.startsWith('day_')) {
                dayNum = int.tryParse(marker.id.replaceFirst('day_', ''));
              } else if (marker.id.startsWith('stop_')) {
                final parts = marker.id.split('_');
                if (parts.length >= 2) {
                  dayNum = int.tryParse(parts[1]);
                }
              }
              if (dayNum != null) {
                final days = _activeTrip.days;
                final matchedIdx = days.indexWhere((d) => d.dayNumber == dayNum);
                final idx = matchedIdx >= 0
                    ? matchedIdx
                    : (dayNum - 1).clamp(0, days.length - 1);
                setState(() => _selectedDayIndex = idx);
                _mapKey.currentState?.seekTrailToDay(days[idx].dayNumber);
                _pageController.animateToPage(
                  idx,
                  duration: const Duration(milliseconds: 320),
                  curve: Curves.easeOutCubic,
                );
              }
            },
          ),

          // Compact single-strip quick actions without cluttering the map.
          Positioned(
            top: 50,
            left: 12,
            right: 12,
            child: Wrap(
              spacing: 8,
              runSpacing: 6,
              children: [
                if (trip.effectiveBackendDestinationIds.length >= 2 ||
                    trip.days.length >= 2)
                  Material(
                    color: Colors.white.withValues(alpha: 0.94),
                    borderRadius: BorderRadius.circular(18),
                    elevation: 2,
                    child: InkWell(
                      onTap: _loadingRoadRoute ? null : _handleOptimizeOrder,
                      borderRadius: BorderRadius.circular(18),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 6,
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(
                              Icons.alt_route_rounded,
                              color: LakbayColors.tealDeep,
                              size: 15,
                            ),
                            const SizedBox(width: 5),
                            Text(
                              _loadingRoadRoute
                                  ? 'Routing...'
                                  : 'Optimize Order',
                              style: const TextStyle(
                                color: LakbayColors.tealDeep,
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
                if (nearby.isNotEmpty)
                  FilterChip(
                    avatar: Icon(
                      Icons.travel_explore_rounded,
                      size: 15,
                      color: _showNearby
                          ? LakbayColors.tealDeep
                          : LakbayColors.textSecondary,
                    ),
                    label: Text(
                      'Nearby (${nearby.length})',
                      style: const TextStyle(
                        fontFamily: 'FigGrotesk',
                        fontWeight: FontWeight.w700,
                        fontSize: 11.5,
                        color: LakbayColors.tealDeep,
                      ),
                    ),
                    selected: _showNearby,
                    showCheckmark: false,
                    backgroundColor: Colors.white.withValues(alpha: 0.94),
                    selectedColor: Colors.white,
                    visualDensity: VisualDensity.compact,
                    tooltip: _showNearby
                        ? 'Hide other places near this trip'
                        : 'Show other places near this trip',
                    onSelected: (value) => setState(() => _showNearby = value),
                  ),
                if (_liveTracking && widget.repo.livePosition != null)
                  _LiveStatusChip(
                    rerouting: _rerouting,
                    remainingText: _remainingText(),
                    accuracyMeters: widget.repo.livePosition!.accuracyMeters,
                  ),
                if ((_backendRoute?.seaCrossings ?? const <SeaCrossingInfo>[])
                    .isNotEmpty)
                  Builder(
                    builder: (context) {
                      final crossings = _backendRoute!.seaCrossings;
                      final mins = crossings.fold<int>(
                        0,
                        (sum, c) => sum + c.crossingMinutes,
                      );
                      String shortPort(String name) => name
                          .split('(')
                          .first
                          .trim()
                          .replaceFirst(
                            RegExp(r'\s+(?:RoRo\s+)?(?:Wharf|Landing|Pier).*$'),
                            '',
                          );
                      final label = crossings.length == 1
                          ? '${shortPort(crossings.first.boardPort)} → ${shortPort(crossings.first.landPort)} · ${mins}m'
                          : '${crossings.length} Crossings · ${mins}m';
                      return Material(
                        color: const Color(0xFF1E88E5).withValues(alpha: 0.94),
                        borderRadius: BorderRadius.circular(18),
                        elevation: 2,
                        child: InkWell(
                          onTap: () => _showSeaCrossingsSheet(crossings),
                          borderRadius: BorderRadius.circular(18),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 6,
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(
                                  Icons.directions_boat_rounded,
                                  color: Colors.white,
                                  size: 14,
                                ),
                                const SizedBox(width: 5),
                                Text(
                                  label,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontFamily: 'FigGrotesk',
                                    fontWeight: FontWeight.w700,
                                    fontSize: 11.5,
                                  ),
                                ),
                                const SizedBox(width: 2),
                                const Icon(
                                  Icons.expand_more_rounded,
                                  color: Colors.white70,
                                  size: 14,
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
              ],
            ),
          ),

          // Swipeable Bottom Carousel of Day Stops synced with Mapbox Camera
          Positioned(
            left: 0,
            right: 0,
            bottom: 14,
            height: 144,
            child: PageView.builder(
              controller: _pageController,
              itemCount: trip.days.length,
              onPageChanged: (idx) {
                setState(() => _selectedDayIndex = idx);
                if (idx >= 0 && idx < trip.days.length) {
                  _mapKey.currentState?.seekTrailToDay(trip.days[idx].dayNumber);
                }
              },
              itemBuilder: (context, index) {
                final day = trip.days[index];
                final isSelected = index == _selectedDayIndex;
                return AnimatedContainer(
                  duration: const Duration(milliseconds: 220),
                  margin: EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: isSelected ? 0 : 6,
                  ),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.96),
                    borderRadius: BorderRadius.circular(22),
                    border: Border.all(
                      color: isSelected
                          ? LakbayColors.primary
                          : LakbayColors.cardBorder,
                      width: isSelected ? 2 : 1,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.18),
                        blurRadius: 16,
                        offset: const Offset(0, 6),
                      ),
                    ],
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
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              day.cityTitle.replaceFirst(
                                RegExp(r'^Day \d+ • '),
                                '',
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontFamily: 'FigGrotesk',
                                fontWeight: FontWeight.w700,
                                fontSize: 15.5,
                              ),
                            ),
                          ),
                          Image.asset(
                            'assets/png/weather/${day.wmoWeatherCode}.png',
                            width: 22,
                            height: 22,
                            errorBuilder: (_, _, _) => const Icon(
                              Icons.wb_sunny_rounded,
                              size: 18,
                              color: LakbayColors.cocoaOrange,
                            ),
                          ),
                          const SizedBox(width: 4),
                          Text(
                            '${day.tempCelsius}°C',
                            style: const TextStyle(
                              fontFamily: 'FigGrotesk',
                              fontWeight: FontWeight.w700,
                              fontSize: 12,
                              color: LakbayColors.tealDeep,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Text(
                        day.summary,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 12.5,
                          color: LakbayColors.textSecondary,
                        ),
                      ),
                      const Spacer(),
                      if (accessNoticeForDay(day) case final notice?)
                        // A permit rule matters more than the stop list here.
                        AccessNoticePill(notice: notice)
                      else
                      Row(
                        children: [
                          const Icon(
                            Icons.place_rounded,
                            size: 15,
                            color: LakbayColors.tealAccent,
                          ),
                          const SizedBox(width: 4),
                          Expanded(
                            child: Text(
                              day.stops.map((s) => s.title).join(' → '),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 11.5,
                                fontWeight: FontWeight.w600,
                                color: LakbayColors.tealDeep,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// Boat leg summary: pier names, vessel, time, and whether data is verified.
class _SeaCrossingCard extends StatelessWidget {
  const _SeaCrossingCard({required this.crossing});

  final SeaCrossingInfo crossing;

  @override
  Widget build(BuildContext context) {
    final fare = crossing.fareVehicle ?? crossing.farePassenger;
    final details = [
      '${crossing.crossingMinutes} min crossing',
      if (crossing.typicalWaitMinutes > 0)
        '~${crossing.typicalWaitMinutes} min wait',
      if (fare != null)
        '₱${fare.toStringAsFixed(0)}${crossing.fareVehicle != null ? '/vehicle' : '/person'}',
      if (!crossing.allowsPrivateVehicle) 'no vehicles',
    ].join(' · ');
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.95),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF1E88E5), width: 1.2),
        boxShadow: [
          BoxShadow(color: Colors.black.withValues(alpha: 0.12), blurRadius: 6),
        ],
      ),
      child: Row(
        children: [
          const Icon(
            Icons.directions_boat_rounded,
            color: Color(0xFF1E88E5),
            size: 20,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '${crossing.vesselLabel}: ${crossing.boardPort} → ${crossing.landPort}',
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 12.5,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  crossing.verified
                      ? details
                      : '$details · schedule not yet verified',
                  style: TextStyle(fontSize: 11.5, color: Colors.grey.shade700),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _LiveStatusChip extends StatelessWidget {
  const _LiveStatusChip({
    required this.rerouting,
    required this.remainingText,
    required this.accuracyMeters,
  });

  final bool rerouting;
  final String? remainingText;
  final double accuracyMeters;

  @override
  Widget build(BuildContext context) {
    final label = rerouting
        ? 'Off route — finding a new route…'
        : remainingText ?? 'Live location on';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.75),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white.withValues(alpha: 0.28)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            rerouting ? Icons.alt_route_rounded : Icons.gps_fixed_rounded,
            size: 16,
            color: accuracyMeters <= 50
                ? const Color(0xFF4CAF50)
                : Colors.amber,
          ),
          const SizedBox(width: 8),
          Text(
            label,
            style: const TextStyle(
              color: Colors.white,
              fontFamily: 'FigGrotesk',
              fontWeight: FontWeight.w700,
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }
}
