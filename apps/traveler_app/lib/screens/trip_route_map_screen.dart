import 'dart:async';

import 'package:flutter/material.dart';

import '../models/travel_models.dart';
import '../services/location_service.dart';
import '../services/mapbox_service.dart';
import '../services/route_progress.dart';
import '../services/travel_repository.dart';
import '../theme/lakbay_theme.dart';
import '../widgets/lakbay_mapbox_widget.dart';

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
  bool _showHotelsOnMap = true;
  BackendRouteResult? _backendRoute;
  bool _loadingRoadRoute = false;

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
  /// reroute or a remaining-distance figure.
  List<GeoPoint> get _followableRoute {
    final route = _backendRoute;
    if (route == null) return const [];
    if (route.segments.isNotEmpty) {
      if (route.segments.any((segment) => segment.isEstimated)) return const [];
      return [for (final segment in route.segments) ...segment.points];
    }
    return route.geometryPoints;
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
        widget.trip,
        optimize: optimize,
        destinationIds: destinationIds,
      );
      if (!mounted) return;
      setState(() {
        if (result != null) _backendRoute = result;
        _loadingRoadRoute = false;
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
    final nextIdx = (_selectedDayIndex + 1) % widget.trip.days.length;
    setState(() => _selectedDayIndex = nextIdx);
    if (_pageController.hasClients) {
      _pageController.animateToPage(
        nextIdx,
        duration: const Duration(milliseconds: 450),
        curve: Curves.easeOutCubic,
      );
    }
    final day = widget.trip.days[nextIdx];
    _mapKey.currentState?.flyTo(day.lat, day.lng, zoom: 10.2);
  }

  List<LakbayMapMarker> _buildMarkers() {
    final markers = <LakbayMapMarker>[];
    for (int i = 0; i < widget.trip.days.length; i++) {
      final d = widget.trip.days[i];
      final media = widget.repo.resolveDayMarkerMedia(widget.trip, d);
      markers.add(
        LakbayMapMarker(
          id: 'day_${d.dayNumber}',
          lat: d.lat,
          lng: d.lng,
          badgeText: 'D${d.dayNumber}',
          title: d.cityTitle,
          subtitle: d.summary,
          imageUrl: media.imageUrl,
          imageAsset: media.imageAsset,
          isPrimary: i == _selectedDayIndex,
          isOrigin: i == 0,
          isDestination: i == widget.trip.days.length - 1,
        ),
      );
    }
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
    if (widget.repo.hasUserLocation) {
      markers.add(
        LakbayMapMarker(
          id: 'user_gps',
          lat: widget.repo.userLat!,
          lng: widget.repo.userLng!,
          title: 'You (${widget.repo.effectiveOriginLabel})',
          subtitle: 'Current GPS location',
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

  @override
  Widget build(BuildContext context) {
    final waypoints = widget.trip.routeWaypoints;
    final totalKm = MapboxService.calculateRouteDistanceKm(waypoints);
    final selectedDay = widget.trip.days[_selectedDayIndex];

    return Scaffold(
      appBar: AppBar(
        backgroundColor: LakbayColors.tealDeep,
        foregroundColor: Colors.white,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.trip.title,
              style: const TextStyle(
                fontFamily: 'FigGrotesk',
                fontWeight: FontWeight.w700,
                fontSize: 16,
              ),
            ),
            Text(
              _backendRoute != null
                  ? '${widget.trip.daysCount} Stops • ${_backendRoute!.totalDistanceKm.toStringAsFixed(1)} km • ${_backendRoute!.totalDurationMinutes} min ${_backendRoute!.geometryPoints.length >= 2 ? 'road route' : 'estimate'}'
                  : '${widget.trip.daysCount} Stops • ${totalKm.toStringAsFixed(0)} km Region XI Route',
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
            initialLat: selectedDay.lat,
            initialLng: selectedDay.lng,
            initialZoom: 8.8,
            routePoints: waypoints,
            roadGeometry: _backendRoute?.geometryPoints ?? const [],
            routeSegments: _backendRoute?.segments ?? const [],
            markers: [..._buildMarkers(), ..._pierMarkers()],
            livePosition: widget.repo.livePosition,
            followUser: _followUser,
            onFollowUserChanged: (follow) =>
                setState(() => _followUser = follow),
            selectedMarkerId: 'day_${selectedDay.dayNumber}',
            borderRadius: 0,
            controlsBottomOffset: 210,
            onMarkerTap: (marker) {
              if (marker.id.startsWith('day_')) {
                final dayNum =
                    int.tryParse(marker.id.replaceFirst('day_', '')) ?? 1;
                final idx = (dayNum - 1).clamp(0, widget.trip.days.length - 1);
                setState(() => _selectedDayIndex = idx);
                _pageController.animateToPage(
                  idx,
                  duration: const Duration(milliseconds: 320),
                  curve: Curves.easeOutCubic,
                );
              }
            },
          ),

          // Floating pills, live status and boat crossings, stacked top-down.
          Positioned(
            top: 62,
            left: 12,
            right: 12,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    ActionChip(
                      onPressed: _toggleRouteTour,
                      backgroundColor: _isTourPlaying
                          ? LakbayColors.primary
                          : Colors.black.withValues(alpha: 0.75),
                      side: BorderSide(
                        color: Colors.white.withValues(alpha: 0.28),
                      ),
                      avatar: Icon(
                        _isTourPlaying
                            ? Icons.pause_rounded
                            : Icons.play_arrow_rounded,
                        color: Colors.white,
                        size: 18,
                      ),
                      label: Text(
                        _isTourPlaying
                            ? 'Playing Route Tour...'
                            : 'Play Route Tour',
                        style: const TextStyle(
                          color: Colors.white,
                          fontFamily: 'FigGrotesk',
                          fontWeight: FontWeight.w700,
                          fontSize: 12,
                        ),
                      ),
                    ),
                    if (widget.repo.isSignedIn &&
                        widget.trip.effectiveBackendDestinationIds.length >= 2)
                      ActionChip(
                        onPressed: _loadingRoadRoute
                            ? null
                            : () => _loadRoadRoute(optimize: true),
                        backgroundColor: Colors.black.withValues(alpha: 0.75),
                        side: BorderSide(
                          color: Colors.white.withValues(alpha: 0.28),
                        ),
                        avatar: const Icon(
                          Icons.alt_route_rounded,
                          color: Colors.white,
                          size: 18,
                        ),
                        label: Text(
                          _loadingRoadRoute ? 'Routing...' : 'Optimize Order',
                          style: const TextStyle(
                            color: Colors.white,
                            fontFamily: 'FigGrotesk',
                            fontWeight: FontWeight.w700,
                            fontSize: 12,
                          ),
                        ),
                      ),
                  ],
                ),
                if (_liveTracking && widget.repo.livePosition != null) ...[
                  const SizedBox(height: 8),
                  _LiveStatusChip(
                    rerouting: _rerouting,
                    remainingText: _remainingText(),
                    accuracyMeters: widget.repo.livePosition!.accuracyMeters,
                  ),
                ],
                for (final crossing
                    in _backendRoute?.seaCrossings ??
                        const <SeaCrossingInfo>[]) ...[
                  const SizedBox(height: 6),
                  _SeaCrossingCard(crossing: crossing),
                ],
              ],
            ),
          ),

          // Swipeable Bottom Carousel of Day Stops synced with Mapbox Camera
          Positioned(
            left: 0,
            right: 0,
            bottom: 28,
            height: 170,
            child: PageView.builder(
              controller: _pageController,
              itemCount: widget.trip.days.length,
              onPageChanged: (idx) {
                setState(() => _selectedDayIndex = idx);
              },
              itemBuilder: (context, index) {
                final day = widget.trip.days[index];
                final isSelected = index == _selectedDayIndex;
                return AnimatedContainer(
                  duration: const Duration(milliseconds: 220),
                  margin: EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: isSelected ? 0 : 8,
                  ),
                  padding: const EdgeInsets.all(15),
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
