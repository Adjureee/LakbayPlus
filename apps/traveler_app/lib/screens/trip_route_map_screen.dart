import '../core/day_labels.dart';
import 'dart:async';

import 'package:flutter/material.dart';

import '../models/travel_models.dart';
import '../services/location_service.dart';
import '../services/mapbox_service.dart';
import '../services/route_progress.dart';
import '../services/route_summary.dart';
import '../services/lakbay_api_catalog_service.dart';
import '../services/travel_repository.dart';
import '../theme/lakbay_theme.dart';
import '../widgets/lakbay_mapbox_widget.dart';
import '../widgets/route_trail.dart';
import '../services/access_notices.dart';
import '../services/nearby_places.dart';
import '../widgets/access_notice_card.dart';

class TripRouteMapScreen extends StatefulWidget {
  final ItineraryTrip trip;
  final TravelRepository repo;
  final int? initialDayIndex;
  final String? initialStopId;

  const TripRouteMapScreen({
    super.key,
    required this.trip,
    required this.repo,
    this.initialDayIndex,
    this.initialStopId,
  });

  @override
  State<TripRouteMapScreen> createState() => _TripRouteMapScreenState();
}

class _TripRouteMapScreenState extends State<TripRouteMapScreen> {
  late final PageController _pageController;
  final GlobalKey<LakbayMapboxMapState> _mapKey =
      GlobalKey<LakbayMapboxMapState>();

  int _selectedDayIndex = 0;
  int? _filteredDayNumber;
  String? _selectedMarkerId;
  bool _showHotelsOnMap = false;
  ItineraryTrip? _liveTrip;
  BackendRouteResult? _backendRoute;
  late String _travelMode = widget.repo.preferredTravelMode;
  bool _loadingRoadRoute = false;
  String? _routeError;
  bool _fittedRouteOnce = false;
  bool _showNearby = true;
  late MapboxStylePreset _lastMapStyle = widget.repo.activeMapStyle;
  late bool _lastShowLiveTraffic = widget.repo.showLiveTraffic;

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

  String? _markerIdForDay(int dayNumber, {int stopIdx = 0}) {
    final days = _activeTrip.days;
    if (days.isEmpty) return null;
    final day = days.firstWhere(
      (d) => d.dayNumber == dayNumber && !d.isContinuationDay,
      orElse: () => days.firstWhere(
        (d) => d.dayNumber == dayNumber,
        orElse: () => days.first,
      ),
    );
    final nonStayStops = day.stops.where((s) => s.category != 'stay').toList();
    if (nonStayStops.isNotEmpty) {
      final clampedStop = stopIdx.clamp(0, nonStayStops.length - 1);
      return 'stop_${day.dayNumber}_$clampedStop';
    }
    return 'day_${day.dayNumber}';
  }

  String _primaryMarkerIdForSelectedDay() {
    if (_activeTrip.days.isEmpty) return 'day_1';
    final dayNum = _markerDayNumberForIndex(_selectedDayIndex);
    return _markerIdForDay(dayNum) ?? 'day_$dayNum';
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
    final days = _activeTrip.days;
    _selectedDayIndex = widget.initialDayIndex != null && days.isNotEmpty
        ? widget.initialDayIndex!.clamp(0, days.length - 1)
        : 0;
    _pageController = PageController(
      viewportFraction: 0.88,
      initialPage: _selectedDayIndex,
    );
    if (widget.initialDayIndex != null && days.isNotEmpty) {
      _filteredDayNumber = _markerDayNumberForIndex(_selectedDayIndex);
    }
    _selectedMarkerId = widget.initialStopId ?? _primaryMarkerIdForSelectedDay();
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
    if (!mounted) return;
    if (_lastMapStyle != widget.repo.activeMapStyle ||
        _lastShowLiveTraffic != widget.repo.showLiveTraffic) {
      _lastMapStyle = widget.repo.activeMapStyle;
      _lastShowLiveTraffic = widget.repo.showLiveTraffic;
      setState(() {});
    }
    final fix = widget.repo.livePosition;
    if (fix == null || identical(fix, _lastHandledFix)) return;
    _lastHandledFix = fix;

    final days = _activeTrip.days;
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
      _selectedMarkerId = _primaryMarkerIdForSelectedDay();
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
      for (final d in _activeTrip.days.skip(_reachedDays)) ?d.apiDestinationId,
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

  /// Switches between private car, public transit and walking and loads that
  /// mode's own route.
  Future<void> _changeTravelMode(String mode) async {
    if (mode == _travelMode) return;
    setState(() {
      _travelMode = mode;
      _backendRoute = null; // the old mode's route would be wrong for this one
      _routeError = null;
    });
    widget.repo.setPreferredTravelMode(mode);
    await _loadRoadRoute(optimize: false);
  }

  Future<void> _loadRoadRoute({
    required bool optimize,
    List<int>? destinationIds,
  }) async {
    if (_loadingRoadRoute) return;
    setState(() {
      _loadingRoadRoute = true;
      _routeError = null;
    });
    try {
      final result = await widget.repo.fetchRoadRouteForTrip(
        _activeTrip,
        optimize: optimize,
        travelMode: _travelMode,
        destinationIds: destinationIds,
      );
      if (!mounted) return;
      final hadSegments = _backendRoute?.segments.isNotEmpty ?? false;
      setState(() {
        if (result != null) {
          _backendRoute = result;
          _routeError = null;
        } else if (_activeTrip.effectiveBackendDestinationIds.length >= 2) {
          _routeError = 'Road directions unavailable';
        }
        _loadingRoadRoute = false;
      });
      if (result != null && result.segments.isNotEmpty && (!hadSegments || !_fittedRouteOnce)) {
        _fittedRouteOnce = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          if (_filteredDayNumber != null) {
            _fitDayBounds(_filteredDayNumber!);
          } else {
            _mapKey.currentState?.fitBounds();
          }
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _loadingRoadRoute = false;
          _routeError = 'Road route lookup failed';
        });
      }
    }
  }

  Future<void> _handleOptimizeOrder() async {
    if (_loadingRoadRoute) return;
    setState(() {
      _loadingRoadRoute = true;
      _routeError = null;
    });
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
        _selectedMarkerId = _primaryMarkerIdForSelectedDay();
        if (routeResult != null) _backendRoute = routeResult;
        _loadingRoadRoute = false;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (_filteredDayNumber != null) {
          _fitDayBounds(_filteredDayNumber!);
        } else {
          _mapKey.currentState?.fitBounds();
        }
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _loadingRoadRoute = false;
          _routeError = 'Could not optimize route order';
        });
      }
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

  List<SeaCrossingInfo> get _activeCrossings {
    final routeCrossings = _backendRoute?.seaCrossings ?? const <SeaCrossingInfo>[];
    return routeCrossings.isNotEmpty ? routeCrossings : _activeTrip.seaCrossings;
  }

  List<GeoPoint> _pointsForDay(int dayNumber) {
    final trip = _activeTrip;
    final pts = <GeoPoint>[];
    for (final d in trip.days) {
      if (d.dayNumber != dayNumber) continue;
      final nonStay = d.stops.where((s) => s.category != 'stay').toList();
      if (nonStay.isNotEmpty) {
        for (final s in nonStay) {
          pts.add(GeoPoint(lat: s.lat, lng: s.lng));
        }
      } else {
        pts.add(GeoPoint(lat: d.lat, lng: d.lng));
      }
      if (d.stops.any((s) => s.isSeaCrossingFromPrev)) {
        for (final c in _activeCrossings) {
          pts.add(GeoPoint(lat: c.boardLat, lng: c.boardLng));
          pts.add(GeoPoint(lat: c.landLat, lng: c.landLng));
        }
      }
    }
    return pts;
  }

  void _fitDayBounds(int dayNumber) {
    final dayPts = _pointsForDay(dayNumber);
    if (dayPts.isNotEmpty) {
      _mapKey.currentState?.fitBounds(points: dayPts);
    }
  }

  void _selectDayFilter(int? dayNumber) {
    final days = _activeTrip.days;
    setState(() {
      _filteredDayNumber = dayNumber;
      if (dayNumber != null && days.isNotEmpty) {
        final matched = days.indexWhere((d) => d.dayNumber == dayNumber);
        if (matched >= 0) {
          _selectedDayIndex = matched;
        }
        _selectedMarkerId = _markerIdForDay(dayNumber);
      } else if (days.isNotEmpty) {
        _selectedMarkerId = _primaryMarkerIdForSelectedDay();
      }
    });
    if (dayNumber == null) {
      if (days.isNotEmpty) {
        _mapKey.currentState?.seekTrailToDay(_markerDayNumberForIndex(_selectedDayIndex));
      }
      _mapKey.currentState?.fitBounds();
      return;
    }
    final idx = days.indexWhere((d) => d.dayNumber == dayNumber);
    if (idx >= 0) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_pageController.hasClients) return;
        _pageController.animateToPage(
          idx,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOutCubic,
        );
      });
    }
    _mapKey.currentState?.seekTrailToDay(dayNumber);
    _fitDayBounds(dayNumber);
  }

  void _focusStop({
    required String markerId,
    int? dayNumber,
    double? lat,
    double? lng,
    bool flyToPin = true,
  }) {
    final days = _activeTrip.days;
    final idx = dayNumber != null
        ? days.indexWhere((d) => d.dayNumber == dayNumber)
        : -1;
    setState(() {
      _selectedMarkerId = markerId;
      if (idx >= 0) {
        _selectedDayIndex = idx;
      }
      if (_filteredDayNumber != null && dayNumber != null && _filteredDayNumber != dayNumber) {
        _filteredDayNumber = dayNumber;
      }
    });
    if (dayNumber != null) {
      _mapKey.currentState?.seekTrailToDay(dayNumber);
    }
    if (idx >= 0 && _pageController.hasClients) {
      _pageController.animateToPage(
        idx,
        duration: const Duration(milliseconds: 320),
        curve: Curves.easeOutCubic,
      );
    }
    if (flyToPin && lat != null && lng != null) {
      _mapKey.currentState?.flyTo(lat, lng, zoom: 11.8);
    }
  }

  List<LakbayMapMarker> _pierMarkers() {
    final markers = <LakbayMapMarker>[];
    final seen = <String>{};
    for (final crossing in _activeCrossings) {
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
    final nextDayNum = _markerDayNumberForIndex(nextIdx);
    setState(() {
      _selectedDayIndex = nextIdx;
      _selectedMarkerId = _markerIdForDay(nextDayNum);
    });
    if (_pageController.hasClients) {
      _pageController.animateToPage(
        nextIdx,
        duration: const Duration(milliseconds: 450),
        curve: Curves.easeOutCubic,
      );
    }
    final day = days[nextIdx];
    _mapKey.currentState?.seekTrailToDay(nextDayNum);
    _mapKey.currentState?.flyTo(day.lat, day.lng, zoom: 10.2);
  }

  List<LakbayMapMarker> _buildMarkers() {
    final trip = _activeTrip;
    final activeDayNum = _filteredDayNumber ?? _markerDayNumberForIndex(_selectedDayIndex);
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
              dayNumber: d.dayNumber,
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
            dayNumber: d.dayNumber,
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
          dayNumber: stopMarkers[i].dayNumber,
        ),
    ];
    if (_showHotelsOnMap) {
      for (final h in _activeTrip.hotels) {
        final hotelUrl =
            (h.remoteImageUrl != null &&
                (h.remoteImageUrl!.startsWith('http://') ||
                    h.remoteImageUrl!.startsWith('https://')))
            ? h.remoteImageUrl
            : (_activeTrip.remoteImageUrl != null &&
                      (_activeTrip.remoteImageUrl!.startsWith('http://') ||
                          _activeTrip.remoteImageUrl!.startsWith('https://'))
                  ? _activeTrip.remoteImageUrl
                  : null);
        markers.add(
          LakbayMapMarker(
            id: h.id,
            lat: h.lat,
            lng: h.lng,
            badgeText: 'Stay',
            title: h.name,
            subtitle: [if (h.stars != null) '${h.stars}★', h.city].join(' • '),
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
    final trip = _activeTrip;
    final waypoints = trip.routeWaypoints;
    final staticUrl = widget.repo.mapbox.buildStaticRouteImageUrl(
      waypoints: waypoints,
      centerLat: trip.centerLat,
      centerLng: trip.centerLng,
      zoom: 8.6,
      style: widget.repo.activeMapStyle,
    );
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
                      'Route card',
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
                        initialLat: trip.centerLat,
                        initialLng: trip.centerLng,
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
                      initialLat: trip.centerLat,
                      initialLng: trip.centerLng,
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
                    trip.title,
                    style: const TextStyle(
                      fontFamily: 'FigGrotesk',
                      fontWeight: FontWeight.w700,
                      fontSize: 18,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    [
                      DayLabels.countTitle(trip.daysCount),
                      RouteSummaryText.line(
                            route: _backendRoute,
                            stops: waypoints,
                            origin: widget.repo.routeOrigin,
                            mode: _travelMode,
                          ) ??
                          'Distance not available yet',
                      if (trip.hotels.isNotEmpty) trip.hotels.first.name,
                    ].join(' \u2022 '),
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
                          ? 'Map image ready to share.'
                          : 'The map image is not available right now.',
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

  /// The access trails of the trip's places that have one, and a note either way.
  ({List<List<GeoPoint>> trails, String? notice}) _trailsForTrip(ItineraryTrip trip) {
    final ids = <int>{
      for (final day in trip.days)
        for (final stop in day.stops)
          if (stop.destinationId != null) stop.destinationId!,
    };
    if (ids.isEmpty) return (trails: const [], notice: null);
    final trails = <List<GeoPoint>>[];
    for (final id in ids) {
      final place =
          widget.repo.allTrips.where((t) => t.apiDestinationId == id).firstOrNull;
      final encoded = place?.accessTrailPolyline;
      if (encoded == null || encoded.isEmpty) continue;
      final points = LakbayApiCatalogService.decodePolyline5(encoded);
      if (points.length >= 2) trails.add(points);
    }
    return (
      trails: trails,
      notice: trails.isEmpty
          ? 'No access trail is listed for these places yet'
          : 'Dashed brown line: access trail',
    );
  }

  ({LakbayMapMarker marker, ItineraryDay? day, ItineraryStop? stop})?
  _activeStopContext(List<LakbayMapMarker> allMarkers, ItineraryTrip trip) {
    final targetId = _selectedMarkerId ?? _primaryMarkerIdForSelectedDay();
    LakbayMapMarker? marker;
    for (final m in allMarkers) {
      if (m.id == targetId) {
        marker = m;
        break;
      }
    }
    if (marker == null) return null;

    ItineraryDay? matchedDay;
    ItineraryStop? matchedStop;
    if (marker.id.startsWith('stop_')) {
      final parts = marker.id.split('_');
      if (parts.length >= 3) {
        final dayNum = int.tryParse(parts[1]);
        final sIdx = int.tryParse(parts[2]);
        if (dayNum != null) {
          matchedDay = trip.days
              .where((d) => d.dayNumber == dayNum && !d.isContinuationDay)
              .firstOrNull;
          if (matchedDay != null && sIdx != null) {
            final nonStay = matchedDay.stops
                .where((s) => s.category != 'stay')
                .toList();
            if (sIdx >= 0 && sIdx < nonStay.length) {
              matchedStop = nonStay[sIdx];
            }
          }
        }
      }
    } else if (marker.id.startsWith('day_')) {
      final dayNum = int.tryParse(marker.id.replaceFirst('day_', ''));
      if (dayNum != null) {
        matchedDay =
            trip.days.where((d) => d.dayNumber == dayNum).firstOrNull;
      }
    }
    return (marker: marker, day: matchedDay, stop: matchedStop);
  }

  void _handleMarkerTap(LakbayMapMarker marker) {
    if (marker.id.startsWith('nearby_')) {
      _showNearbySheet(marker.id);
      return;
    }
    if (marker.id.startsWith('pier_')) {
      final crossings = _activeCrossings;
      if (crossings.isNotEmpty) {
        _showSeaCrossingsSheet(crossings);
      }
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
    } else {
      dayNum = marker.dayNumber;
    }

    setState(() {
      _selectedMarkerId = marker.id;
      if (dayNum != null && _activeTrip.days.isNotEmpty) {
        final days = _activeTrip.days;
        final matchedIdx = days.indexWhere((d) => d.dayNumber == dayNum);
        final idx = matchedIdx >= 0
            ? matchedIdx
            : (dayNum - 1).clamp(0, days.length - 1);
        _selectedDayIndex = idx;
        if (_filteredDayNumber != null && _filteredDayNumber != dayNum) {
          _filteredDayNumber = dayNum;
        }
        _mapKey.currentState?.seekTrailToDay(days[idx].dayNumber);
        if (_pageController.hasClients) {
          _pageController.animateToPage(
            idx,
            duration: const Duration(milliseconds: 320),
            curve: Curves.easeOutCubic,
          );
        }
      }
    });
  }

  Widget _buildMapWidget({
    required ItineraryTrip trip,
    required List<GeoPoint> waypoints,
    required List<LakbayMapMarker> allMarkers,
    required double initLat,
    required double initLng,
    required double initZoom,
    required EdgeInsets boundsPadding,
    required double controlsBottomOffset,
    required bool showLegend,
  }) {
    final trailData = _trailsForTrip(trip);
    return LakbayMapboxMap(
      key: _mapKey,
      repo: widget.repo,
      initialLat: initLat,
      initialLng: initLng,
      initialZoom: initZoom,
      routePoints: waypoints,
      roadGeometry: _backendRoute?.geometryPoints ?? const [],
      routeSegments: _backendRoute?.segments ?? const [],
      routeNotice: _routeNoticeText(),
      trails: trailData.trails,
      trailNotice: trailData.notice,
      markers: allMarkers,
      livePosition: widget.repo.livePosition,
      followUser: _followUser,
      onFollowUserChanged: (follow) => setState(() => _followUser = follow),
      selectedMarkerId: _selectedMarkerId,
      focusedDayNumber: _filteredDayNumber,
      showLegend: showLegend,
      boundsPadding: boundsPadding,
      isLoadingRoute: _loadingRoadRoute,
      routeError: _routeError,
      onRetryRoute: () => _loadRoadRoute(optimize: false),
      borderRadius: 0,
      controlsBottomOffset: controlsBottomOffset,
      onMarkerTap: _handleMarkerTap,
    );
  }

  Widget _buildQuickActionStrip(ItineraryTrip trip, List<NearbyPlace> nearby) {
    final crossings = _activeCrossings;
    String shortPort(String name) => name
        .split('(')
        .first
        .trim()
        .replaceFirst(RegExp(r'\s+(?:RoRo\s+)?(?:Wharf|Landing|Pier).*$'), '');

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          FilterChip(
            key: const ValueKey('traffic-toggle-chip'),
            avatar: Icon(
              Icons.traffic_rounded,
              size: 15,
              color: !widget.repo.canToggleLiveTraffic
                  ? LakbayColors.textSecondary
                  : widget.repo.showLiveTraffic
                      ? LakbayColors.primary
                      : LakbayColors.tealDeep,
            ),
            label: Text(
              'Traffic',
              style: TextStyle(
                fontFamily: 'FigGrotesk',
                fontWeight: FontWeight.w700,
                fontSize: 11.5,
                color: widget.repo.canToggleLiveTraffic
                    ? LakbayColors.tealDeep
                    : LakbayColors.textSecondary,
              ),
            ),
            selected: widget.repo.showLiveTraffic,
            showCheckmark: false,
            backgroundColor: Colors.white.withValues(alpha: 0.94),
            selectedColor: Colors.white,
            disabledColor: Colors.white.withValues(alpha: 0.72),
            visualDensity: VisualDensity.compact,
            tooltip: !widget.repo.canToggleLiveTraffic
                ? 'Traffic is unavailable on Satellite view.'
                : widget.repo.showLiveTraffic
                    ? 'Hide live traffic'
                    : 'Show live traffic',
            onSelected: widget.repo.canToggleLiveTraffic
                ? (value) {
                    widget.repo.setLiveTrafficEnabled(value);
                    setState(() {});
                  }
                : null,
          ),
          if (trip.effectiveBackendDestinationIds.length >= 2 ||
              trip.days.length >= 2) ...[
            const SizedBox(width: 8),
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
                        _loadingRoadRoute ? 'Routing...' : 'Optimize Order',
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
          ],
          if (nearby.isNotEmpty) ...[
            const SizedBox(width: 8),
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
          ],
          if (_liveTracking && widget.repo.livePosition != null) ...[
            const SizedBox(width: 8),
            _LiveStatusChip(
              rerouting: _rerouting,
              remainingText: _remainingText(),
              accuracyMeters: widget.repo.livePosition!.accuracyMeters,
            ),
          ],
          if (crossings.isNotEmpty) ...[
            const SizedBox(width: 8),
            Builder(
              builder: (context) {
                final mins = crossings.fold<int>(
                  0,
                  (sum, c) => sum + c.crossingMinutes,
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
        ],
      ),
    );
  }

  Widget? _buildTrafficNoticeBanner() {
    if (!widget.repo.canToggleLiveTraffic) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.70),
          borderRadius: BorderRadius.circular(12),
        ),
        child: const Text(
          'Traffic is unavailable on Satellite view.',
          style: TextStyle(
            color: Colors.white,
            fontSize: 11,
            fontWeight: FontWeight.w500,
          ),
        ),
      );
    }
    if (widget.repo.showLiveTraffic) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.70),
          borderRadius: BorderRadius.circular(12),
        ),
        child: const Text(
          'Live traffic data is limited in this region',
          style: TextStyle(
            color: Colors.white,
            fontSize: 11,
            fontWeight: FontWeight.w500,
          ),
        ),
      );
    }
    return null;
  }

  Widget _buildDayFilterStrip(ItineraryTrip trip) {
    final dayNumbers = <int>[
      for (final d in trip.days)
        if (!d.isContinuationDay) d.dayNumber,
    ];
    if (dayNumbers.isEmpty) return const SizedBox.shrink();

    Widget buildPill({
      required Key key,
      required bool selected,
      required Color activeColor,
      required String label,
      required VoidCallback onTap,
      Color? dotColor,
    }) {
      return Material(
        key: key,
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(18),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
            decoration: BoxDecoration(
              color: selected
                  ? activeColor
                  : Colors.white.withValues(alpha: 0.96),
              borderRadius: BorderRadius.circular(18),
              border: Border.all(
                color: selected
                    ? Colors.white.withValues(alpha: 0.9)
                    : activeColor.withValues(alpha: 0.45),
                width: selected ? 1.4 : 1.0,
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.14),
                  blurRadius: 6,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (dotColor != null) ...[
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: selected ? Colors.white : dotColor,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 6),
                ],
                Text(
                  label,
                  style: TextStyle(
                    fontFamily: 'FigGrotesk',
                    fontWeight: FontWeight.w700,
                    fontSize: 11.5,
                    color: selected ? Colors.white : LakbayColors.tealDeep,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          buildPill(
            key: const ValueKey('day-filter-all'),
            selected: _filteredDayNumber == null,
            activeColor: LakbayColors.tealDeep,
            label: 'All Days',
            onTap: () => _selectDayFilter(null),
          ),
          for (final dayNum in dayNumbers) ...[
            const SizedBox(width: 6),
            Builder(
              builder: (context) {
                final selected = _filteredDayNumber == dayNum;
                final dayColor = RouteTrail.colorForDay(
                  dayNum,
                  RouteTrailMode.road,
                );
                return buildPill(
                  key: ValueKey('day-filter-$dayNum'),
                  selected: selected,
                  activeColor: dayColor,
                  dotColor: dayColor,
                  label: 'Day $dayNum',
                  onTap: () => _selectDayFilter(selected ? null : dayNum),
                );
              },
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildActiveStopCallout(
    ({LakbayMapMarker marker, ItineraryDay? day, ItineraryStop? stop}) ctx,
  ) {
    final marker = ctx.marker;
    final stop = ctx.stop;
    final badgeColor = marker.isFerryPier
        ? const Color(0xFF1565C0)
        : marker.dayNumber != null
            ? RouteTrail.colorForDay(marker.dayNumber!, RouteTrailMode.road)
            : LakbayColors.tealDeep;
    final travelBits = <String>[
      if (stop?.time.isNotEmpty == true) stop!.time,
      if (stop?.travelFromPrevMinutes != null &&
          stop!.travelFromPrevMinutes! > 0)
        '${stop.travelFromPrevMinutes} min leg',
      if (stop?.travelFromPrevKm != null && stop!.travelFromPrevKm! > 0)
        '${stop.travelFromPrevKm!.toStringAsFixed(1)} km',
      if (stop?.isSeaCrossingFromPrev == true) 'Boat crossing',
    ];
    final subtitleText = travelBits.isNotEmpty
        ? travelBits.join(' • ')
        : (marker.subtitle?.isNotEmpty == true
            ? marker.subtitle!
            : 'Pinned trip stop');

    return Material(
      key: const ValueKey('active-stop-callout'),
      color: Colors.white.withValues(alpha: 0.96),
      borderRadius: BorderRadius.circular(16),
      elevation: 4,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: badgeColor,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                marker.badgeText.isNotEmpty ? marker.badgeText : 'PIN',
                style: const TextStyle(
                  color: Colors.white,
                  fontFamily: 'FigGrotesk',
                  fontWeight: FontWeight.w700,
                  fontSize: 10.5,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    marker.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontFamily: 'FigGrotesk',
                      fontWeight: FontWeight.w700,
                      fontSize: 13,
                      color: LakbayColors.tealDeep,
                    ),
                  ),
                  Text(
                    subtitleText,
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
              tooltip: 'Focus stop',
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
              icon: const Icon(
                Icons.center_focus_strong_rounded,
                size: 18,
                color: LakbayColors.tealDeep,
              ),
              onPressed: () =>
                  _mapKey.currentState?.flyTo(marker.lat, marker.lng, zoom: 12.2),
            ),
            IconButton(
              tooltip: 'Dismiss stop card',
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
              icon: const Icon(
                Icons.close_rounded,
                size: 16,
                color: LakbayColors.textSecondary,
              ),
              onPressed: () => setState(() => _selectedMarkerId = null),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyMapCard() {
    return Container(
      key: const ValueKey('empty-route-state'),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.96),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: LakbayColors.cardBorder),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.14),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Row(
        children: [
          const Icon(
            Icons.map_outlined,
            color: LakbayColors.tealDeep,
            size: 26,
          ),
          const SizedBox(width: 10),
          const Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'No itinerary stops mapped yet',
                  style: TextStyle(
                    fontFamily: 'FigGrotesk',
                    fontWeight: FontWeight.w700,
                    fontSize: 13.5,
                    color: LakbayColors.tealDeep,
                  ),
                ),
                Text(
                  'Add stops to preview day routes and sea crossings.',
                  style: TextStyle(
                    fontSize: 11.5,
                    color: LakbayColors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          TextButton(
            onPressed: () => _mapKey.currentState?.fitBounds(),
            child: const Text('Fit Davao'),
          ),
        ],
      ),
    );
  }

  Widget _buildDesktopSidebar(ItineraryTrip trip) {
    final crossings = _activeCrossings;
    return Container(
      width: 360,
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border(
          right: BorderSide(color: LakbayColors.cardBorder),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Route & Stop Timeline',
                  style: TextStyle(
                    fontFamily: 'FigGrotesk',
                    fontWeight: FontWeight.w700,
                    fontSize: 15,
                    color: LakbayColors.tealDeep,
                  ),
                ),
                const SizedBox(height: 8),
                _buildDayFilterStrip(trip),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: trip.days.isEmpty
                ? Padding(
                    padding: const EdgeInsets.all(16),
                    child: Center(child: _buildEmptyMapCard()),
                  )
                : ListView.separated(
                    padding: const EdgeInsets.all(12),
                    itemCount: trip.days.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 10),
                    itemBuilder: (context, index) {
                      final day = trip.days[index];
                      final isSelectedDay = index == _selectedDayIndex;
                      final dayColor = RouteTrail.colorForDay(
                        day.dayNumber,
                        RouteTrailMode.road,
                      );
                      final nonStayStops =
                          day.stops.where((s) => s.category != 'stay').toList();
                      return Container(
                        decoration: BoxDecoration(
                          color: isSelectedDay
                              ? dayColor.withValues(alpha: 0.06)
                              : LakbayColors.canvasBg,
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(
                            color: isSelectedDay
                                ? dayColor
                                : LakbayColors.cardBorder,
                            width: isSelectedDay ? 1.5 : 1,
                          ),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            InkWell(
                              borderRadius: const BorderRadius.vertical(
                                top: Radius.circular(14),
                              ),
                              onTap: () => _selectDayFilter(day.dayNumber),
                              child: Padding(
                                padding: const EdgeInsets.fromLTRB(
                                  12,
                                  10,
                                  12,
                                  8,
                                ),
                                child: Row(
                                  children: [
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 8,
                                        vertical: 3,
                                      ),
                                      decoration: BoxDecoration(
                                        color: dayColor,
                                        borderRadius: BorderRadius.circular(8),
                                      ),
                                      child: Text(
                                        'DAY ${day.dayNumber}',
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontWeight: FontWeight.w700,
                                          fontSize: 10.5,
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
                                          fontSize: 14,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                            if (nonStayStops.isEmpty)
                              InkWell(
                                onTap: () => _focusStop(
                                  markerId: 'day_${day.dayNumber}',
                                  dayNumber: day.dayNumber,
                                  lat: day.lat,
                                  lng: day.lng,
                                ),
                                child: Padding(
                                  padding: const EdgeInsets.fromLTRB(
                                    12,
                                    0,
                                    12,
                                    10,
                                  ),
                                  child: Text(
                                    day.summary,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontSize: 12,
                                      color: LakbayColors.textSecondary,
                                    ),
                                  ),
                                ),
                              )
                            else
                              for (int sIdx = 0; sIdx < nonStayStops.length; sIdx++)
                                Builder(
                                  builder: (context) {
                                    final stop = nonStayStops[sIdx];
                                    final markerId = 'stop_${day.dayNumber}_$sIdx';
                                    final isFocusedStop =
                                        _selectedMarkerId == markerId;
                                    return InkWell(
                                      onTap: () => _focusStop(
                                        markerId: markerId,
                                        dayNumber: day.dayNumber,
                                        lat: stop.lat,
                                        lng: stop.lng,
                                      ),
                                      child: Container(
                                        padding: const EdgeInsets.fromLTRB(
                                          12,
                                          6,
                                          12,
                                          8,
                                        ),
                                        decoration: BoxDecoration(
                                          color: isFocusedStop
                                              ? dayColor.withValues(alpha: 0.14)
                                              : null,
                                          border: Border(
                                            top: BorderSide(
                                              color: LakbayColors.cardBorder
                                                  .withValues(alpha: 0.6),
                                            ),
                                          ),
                                        ),
                                        child: Row(
                                          children: [
                                            Container(
                                              width: 24,
                                              height: 24,
                                              alignment: Alignment.center,
                                              decoration: BoxDecoration(
                                                color: isFocusedStop
                                                    ? dayColor
                                                    : Colors.white,
                                                shape: BoxShape.circle,
                                                border: Border.all(
                                                  color: dayColor,
                                                ),
                                              ),
                                              child: Text(
                                                '${sIdx + 1}',
                                                style: TextStyle(
                                                  fontSize: 11,
                                                  fontWeight: FontWeight.w700,
                                                  color: isFocusedStop
                                                      ? Colors.white
                                                      : dayColor,
                                                ),
                                              ),
                                            ),
                                            const SizedBox(width: 8),
                                            Expanded(
                                              child: Column(
                                                crossAxisAlignment:
                                                    CrossAxisAlignment.start,
                                                children: [
                                                  Text(
                                                    stop.title,
                                                    maxLines: 1,
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                    style: const TextStyle(
                                                      fontWeight: FontWeight.w600,
                                                      fontSize: 12.5,
                                                    ),
                                                  ),
                                                  Text(
                                                    [
                                                      if (stop.time.isNotEmpty)
                                                        stop.time,
                                                      if (stop.isSeaCrossingFromPrev)
                                                        'Ferry leg',
                                                      if (stop.travelFromPrevMinutes !=
                                                              null &&
                                                          stop.travelFromPrevMinutes! >
                                                              0)
                                                        '${stop.travelFromPrevMinutes}m travel',
                                                    ].join(' · '),
                                                    maxLines: 1,
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                    style: const TextStyle(
                                                      fontSize: 11,
                                                      color: LakbayColors
                                                          .textSecondary,
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            ),
                                            if (stop.isSeaCrossingFromPrev &&
                                                crossings.isNotEmpty)
                                              IconButton(
                                                tooltip: 'Ferry crossing details',
                                                visualDensity:
                                                    VisualDensity.compact,
                                                icon: const Icon(
                                                  Icons.directions_boat_rounded,
                                                  size: 16,
                                                  color: Color(0xFF1E88E5),
                                                ),
                                                onPressed: () =>
                                                    _showSeaCrossingsSheet(
                                                  crossings,
                                                ),
                                              ),
                                          ],
                                        ),
                                      ),
                                    );
                                  },
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

  @override
  Widget build(BuildContext context) {
    final trip = _activeTrip;
    final waypoints = trip.routeWaypoints;
    final nearby = _nearbyPlaces();
    final allMarkers = <LakbayMapMarker>[
      ..._nearbyMarkers(nearby),
      ..._buildMarkers(),
      ..._pierMarkers(),
    ];
    final (initLat, initLng, initZoom) = _initialCameraFrame(trip, waypoints);
    final activeCallout = _selectedMarkerId == null
        ? null
        : _activeStopContext(allMarkers, trip);
    final trafficBanner = _buildTrafficNoticeBanner();

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
              [
                '${waypoints.length} ${waypoints.length == 1 ? 'Stop' : 'Stops'}',
                RouteSummaryText.line(
                      route: _backendRoute,
                      stops: waypoints,
                      origin: widget.repo.routeOrigin,
                      mode: _travelMode,
                    ) ??
                    (_loadingRoadRoute
                        ? 'Finding the route\u2026'
                        : 'Set your starting point to see the distance'),
              ].join(' \u2022 '),
              style: const TextStyle(fontSize: 11.5, color: Colors.white70),
            ),
          ],
        ),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(46),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            child: Row(
              children: [
                for (final (mode, label, icon) in const [
                  ('driving', 'Private car', Icons.directions_car_outlined),
                  ('public_transport', 'Public transit', Icons.directions_bus_outlined),
                  ('walking', 'Walking', Icons.directions_walk_outlined),
                  ('cycling', 'Cycling', Icons.directions_bike_outlined),
                ])
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      avatar: Icon(icon, size: 16),
                      label: Text(label),
                      selected: _travelMode == mode,
                      onSelected: (_) => _changeTravelMode(mode),
                      visualDensity: VisualDensity.compact,
                    ),
                  ),
              ],
            ),
          ),
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
      body: LayoutBuilder(
        builder: (context, constraints) {
          final isDesktop = constraints.maxWidth >= 900;
          final showLegend = constraints.maxHeight >= 540 || isDesktop;

          if (isDesktop) {
            return Row(
              children: [
                _buildDesktopSidebar(trip),
                Expanded(
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      _buildMapWidget(
                        trip: trip,
                        waypoints: waypoints,
                        allMarkers: allMarkers,
                        initLat: initLat,
                        initLng: initLng,
                        initZoom: initZoom,
                        boundsPadding: const EdgeInsets.fromLTRB(48, 108, 60, 48),
                        controlsBottomOffset: 24,
                        showLegend: showLegend,
                      ),
                      Positioned(
                        top: 50,
                        left: 12,
                        right: 12,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            _buildQuickActionStrip(trip, nearby),
                            if (trafficBanner != null) ...[
                              const SizedBox(height: 4),
                              trafficBanner,
                            ],
                          ],
                        ),
                      ),
                      if (activeCallout != null)
                        Positioned(
                          left: 12,
                          bottom: 118,
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 380),
                            child: _buildActiveStopCallout(activeCallout),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            );
          }

          final hasCallout = activeCallout != null;
          if (!isDesktop &&
              trip.days.isNotEmpty &&
              !_pageController.hasClients) {
            final targetPage = _selectedDayIndex.clamp(0, trip.days.length - 1);
            if (targetPage != _pageController.initialPage) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (mounted &&
                    _pageController.hasClients &&
                    (_pageController.page?.round() ?? 0) != _selectedDayIndex) {
                  _pageController.jumpToPage(
                    _selectedDayIndex.clamp(0, _activeTrip.days.length - 1),
                  );
                }
              });
            }
          }
          return Stack(
            fit: StackFit.expand,
            children: [
              _buildMapWidget(
                trip: trip,
                waypoints: waypoints,
                allMarkers: allMarkers,
                initLat: initLat,
                initLng: initLng,
                initZoom: initZoom,
                boundsPadding: EdgeInsets.fromLTRB(
                  36,
                  136,
                  56,
                  trip.days.isEmpty ? 120 : (hasCallout ? 232 : 176),
                ),
                controlsBottomOffset:
                    trip.days.isEmpty ? 116 : (hasCallout ? 228 : 170),
                showLegend: showLegend,
              ),
              Positioned(
                top: 50,
                left: 12,
                right: 12,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _buildQuickActionStrip(trip, nearby),
                    if (trip.days.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      _buildDayFilterStrip(trip),
                    ],
                    if (trafficBanner != null) ...[
                      const SizedBox(height: 4),
                      trafficBanner,
                    ],
                  ],
                ),
              ),
              if (activeCallout != null)
                Positioned(
                  left: 12,
                  right: 64,
                  bottom: trip.days.isEmpty ? 108 : 164,
                  child: _buildActiveStopCallout(activeCallout),
                ),
              if (trip.days.isEmpty)
                Positioned(
                  left: 12,
                  right: 12,
                  bottom: 14,
                  child: _buildEmptyMapCard(),
                )
              else
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 14,
                  height: 144,
                  child: PageView.builder(
                    controller: _pageController,
                    itemCount: trip.days.length,
                    onPageChanged: (idx) {
                      if (idx < 0 || idx >= trip.days.length) return;
                      final dayNum = _markerDayNumberForIndex(idx);
                      setState(() {
                        _selectedDayIndex = idx;
                        _selectedMarkerId = _markerIdForDay(dayNum);
                        if (_filteredDayNumber != null) {
                          _filteredDayNumber = dayNum;
                        }
                      });
                      _mapKey.currentState?.seekTrailToDay(dayNum);
                      if (_filteredDayNumber != null) {
                        _fitDayBounds(dayNum);
                      }
                    },
                    itemBuilder: (context, index) {
                      final day = trip.days[index];
                      final isSelected = index == _selectedDayIndex;
                      final dayColor = RouteTrail.colorForDay(
                        day.dayNumber,
                        RouteTrailMode.road,
                      );
                      final nonStayStops =
                          day.stops.where((s) => s.category != 'stay').toList();
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
                                ? dayColor
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
                                InkWell(
                                  onTap: () => _selectDayFilter(
                                    _filteredDayNumber == day.dayNumber
                                        ? null
                                        : day.dayNumber,
                                  ),
                                  borderRadius: BorderRadius.circular(10),
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 10,
                                      vertical: 4,
                                    ),
                                    decoration: BoxDecoration(
                                      color: dayColor,
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
                                if (day.wmoWeatherCode != null &&
                                    day.tempCelsius != null) ...[
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
                              ],
                            ),
                            const SizedBox(height: 4),
                            Text(
                              day.summary,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 12,
                                color: LakbayColors.textSecondary,
                              ),
                            ),
                            const Spacer(),
                            if (accessNoticeForDay(day) case final notice?)
                              AccessNoticePill(notice: notice)
                            else if (nonStayStops.isNotEmpty)
                              SizedBox(
                                height: 26,
                                child: ListView.separated(
                                  scrollDirection: Axis.horizontal,
                                  itemCount: nonStayStops.length,
                                  separatorBuilder: (_, _) =>
                                      const SizedBox(width: 6),
                                  itemBuilder: (_, sIdx) {
                                    final stop = nonStayStops[sIdx];
                                    final markerId =
                                        'stop_${day.dayNumber}_$sIdx';
                                    final focused =
                                        _selectedMarkerId == markerId;
                                    return InkWell(
                                      borderRadius: BorderRadius.circular(12),
                                      onTap: () => _focusStop(
                                        markerId: markerId,
                                        dayNumber: day.dayNumber,
                                        lat: stop.lat,
                                        lng: stop.lng,
                                      ),
                                      child: Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 8,
                                          vertical: 3,
                                        ),
                                        decoration: BoxDecoration(
                                          color: focused
                                              ? dayColor
                                              : dayColor.withValues(
                                                  alpha: 0.12,
                                                ),
                                          borderRadius:
                                              BorderRadius.circular(12),
                                          border: Border.all(
                                            color: focused
                                                ? dayColor
                                                : dayColor.withValues(
                                                    alpha: 0.35,
                                                  ),
                                          ),
                                        ),
                                        child: Text(
                                          '${sIdx + 1}. ${stop.title}',
                                          style: TextStyle(
                                            fontSize: 11,
                                            fontWeight: FontWeight.w600,
                                            color: focused
                                                ? Colors.white
                                                : LakbayColors.tealDeep,
                                          ),
                                        ),
                                      ),
                                    );
                                  },
                                ),
                              )
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
                                      day.cityTitle,
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
          );
        },
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
