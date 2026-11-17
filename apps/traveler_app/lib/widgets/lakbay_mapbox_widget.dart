import 'dart:math' as math;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import '../models/travel_models.dart';
import '../services/location_service.dart';
import '../services/mapbox_service.dart';
import '../services/travel_repository.dart';
import '../theme/lakbay_theme.dart';
import 'route_trail.dart';
import '../design/lakbay_type.dart';

class LakbayMapMarker {
  final String id;
  final double lat;
  final double lng;
  final String badgeText;
  final String title;
  final String? subtitle;
  final String? imageUrl;
  final String? imageAsset;
  final bool isPrimary;
  final bool isOrigin;
  final bool isDestination;
  final bool isUserLocation;
  final bool isCompact;

  /// A catalog place near the trip but not part of it: drawn small and muted.
  final bool isNearby;

  const LakbayMapMarker({
    required this.id,
    required this.lat,
    required this.lng,
    this.badgeText = '',
    required this.title,
    this.subtitle,
    this.imageUrl,
    this.imageAsset,
    this.isPrimary = false,
    this.isOrigin = false,
    this.isDestination = false,
    this.isUserLocation = false,
    this.isCompact = false,
    this.isNearby = false,
  });

  bool get hasThumbnail =>
      (imageUrl != null && imageUrl!.trim().isNotEmpty) ||
      (imageAsset != null && imageAsset!.trim().isNotEmpty);
}

class LakbayMapboxMap extends StatefulWidget {
  final TravelRepository repo;
  final double initialLat;
  final double initialLng;
  final double initialZoom;
  final List<GeoPoint> routePoints;
  final List<GeoPoint> roadGeometry;

  /// Road/sea parts from a pier-aware route. When set, it replaces
  /// [roadGeometry]: roads are solid, boat crossings dashed blue, and
  /// estimated parts dashed grey with no vehicle on them.
  final List<RouteSegmentGeometry> routeSegments;
  /// Why part or all of the road route is missing, from the route API.
  /// Replaces the generic "road route unavailable" notice when set.
  final String? routeNotice;
  final List<LakbayMapMarker> markers;

  /// Live GPS fix drawn as a moving dot with heading and accuracy circle.
  final LivePosition? livePosition;

  /// Keep the camera centered on [livePosition]. Panning the map turns it off
  /// through [onFollowUserChanged].
  final bool followUser;
  final ValueChanged<bool>? onFollowUserChanged;
  final String? selectedMarkerId;
  final ValueChanged<LakbayMapMarker>? onMarkerTap;
  final void Function(double lat, double lng)? onMapTap;
  final bool showControls;
  final bool interactive;
  final bool animateRoute;
  final bool clampToDavao;
  final double borderRadius;
  final double controlsBottomOffset;

  /// Space kept clear at the top for the host screen's own buttons, used
  /// for route notices when [showControls] is false.
  final double overlayTopInset;

  const LakbayMapboxMap({
    super.key,
    required this.repo,
    required this.initialLat,
    required this.initialLng,
    this.initialZoom = 8.4,
    this.routePoints = const [],
    this.roadGeometry = const [],
    this.routeSegments = const [],
    this.routeNotice,
    this.markers = const [],
    this.livePosition,
    this.followUser = false,
    this.onFollowUserChanged,
    this.selectedMarkerId,
    this.onMarkerTap,
    this.onMapTap,
    this.showControls = true,
    this.interactive = true,
    this.animateRoute = true,
    this.clampToDavao = false,
    this.borderRadius = 20,
    this.controlsBottomOffset = 36,
    this.overlayTopInset = 0,
  });

  @override
  State<LakbayMapboxMap> createState() => LakbayMapboxMapState();
}

class LakbayMapboxMapState extends State<LakbayMapboxMap>
    with TickerProviderStateMixin {
  late double _centerLat;
  late double _centerLng;
  late double _zoom;

  double get currentLat => _centerLat;
  double get currentLng => _centerLng;
  double get currentZoom => _zoom;

  late AnimationController _cameraAnimController;
  late AnimationController _pulseController;
  late RouteTrail _trail;
  late RouteTrailController _trailController;
  bool _trailInitializedDeps = false;
  bool _flyAlongTrail = false;

  RouteTrailController get trailController => _trailController;

  double _startLat = 0;
  double _startLng = 0;
  double _startZoom = 8.4;
  double _targetLat = 0;
  double _targetLng = 0;
  double _targetZoom = 8.4;
  double _gestureStartZoom = 8.4;
  Offset _prevFocalPoint = Offset.zero;

  RouteTrail _buildTrailFromWidget() {
    if (widget.routeSegments.isNotEmpty) {
      return RouteTrail.fromRoute(
        segments: widget.routeSegments,
        waypoints: widget.routePoints,
      );
    }
    if (_hasRoutedGeometry) {
      return RouteTrail.fromRoute(
        segments: const [],
        roadGeometry: widget.roadGeometry,
        waypoints: widget.routePoints,
      );
    }
    return RouteTrail.empty();
  }

  void _onTrailTick() {
    if (!mounted) return;
    if (_flyAlongTrail &&
        !_trailController.isSettled &&
        !_cameraAnimController.isAnimating) {
      final pt = _trailController.currentPoint;
      if (pt != null) {
        final (nLat, nLng) = widget.clampToDavao
            ? MapboxService.clampToDavaoRegion(pt.lat, pt.lng)
            : (pt.lat.clamp(-84.0, 84.0), ((pt.lng + 180.0) % 360.0) - 180.0);
        if ((nLat - _centerLat).abs() > 1e-4 ||
            (nLng - _centerLng).abs() > 1e-4) {
          setState(() {
            _centerLat = nLat;
            _centerLng = nLng;
          });
        }
      }
    }
  }

  void replayTrail() => _trailController.replay();

  void seekTrailToDay(int dayNumber) => _trailController.seekToDay(dayNumber);

  @override
  void initState() {
    super.initState();
    _centerLat = widget.initialLat;
    _centerLng = widget.initialLng;
    _zoom = widget.initialZoom;

    _cameraAnimController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 620),
    )..addListener(() {
        final t = Curves.easeInOutCubic.transform(_cameraAnimController.value);
        setState(() {
          _centerLat = _startLat + (_targetLat - _startLat) * t;
          _centerLng = _startLng + (_targetLng - _startLng) * t;
          _zoom = _startZoom + (_targetZoom - _startZoom) * t;
        });
      });

    _trail = _buildTrailFromWidget();
    _trailController = RouteTrailController(
      vsync: this,
      trail: _trail,
      disableAnimations: !widget.animateRoute,
      autoPlay: false,
    )..addListener(_onTrailTick);

    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1600),
    )..repeat();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final disableSystemAnim = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    final disableAnim = disableSystemAnim || !widget.animateRoute;
    if (!_trailInitializedDeps) {
      _trailInitializedDeps = true;
      _trailController.updateTrail(
        _trail,
        disableAnimations: disableAnim,
        autoPlay: widget.animateRoute && !disableSystemAnim,
      );
      if (widget.animateRoute &&
          !disableSystemAnim &&
          _trail.hasAnimatedTrail &&
          !_trailController.isPlaying) {
        _trailController.replay();
      }
    } else if (disableAnim != _trailController.disableAnimations) {
      _trailController.updateTrail(
        _trail,
        disableAnimations: disableAnim,
        autoPlay: !disableAnim,
      );
    }
  }

  @override
  void didUpdateWidget(covariant LakbayMapboxMap oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.selectedMarkerId != null &&
        widget.selectedMarkerId != oldWidget.selectedMarkerId) {
      final found = widget.markers
          .where((m) => m.id == widget.selectedMarkerId)
          .firstOrNull;
      if (found != null) {
        flyTo(found.lat, found.lng, zoom: math.max(_zoom, 9.6));
      }
    }
    final live = widget.livePosition;
    final followJustEnabled = widget.followUser && !oldWidget.followUser;
    if (live != null &&
        widget.followUser &&
        (followJustEnabled ||
            live.lat != oldWidget.livePosition?.lat ||
            live.lng != oldWidget.livePosition?.lng)) {
      flyTo(live.lat, live.lng,
          zoom: followJustEnabled ? math.max(_zoom, 15.0) : _zoom);
    }

    final disableSystemAnim = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    final disableAnim = disableSystemAnim || !widget.animateRoute;
    final nextTrail = _buildTrailFromWidget();
    final changed =
        (nextTrail.totalAnimatedMeters - _trail.totalAnimatedMeters).abs() > 1.0 ||
            nextTrail.animatedLegs.length != _trail.animatedLegs.length ||
            nextTrail.estimatedLegs.length != _trail.estimatedLegs.length ||
            widget.animateRoute != oldWidget.animateRoute;
    if (changed) {
      _trail = nextTrail;
      _trailController.updateTrail(
        _trail,
        disableAnimations: disableAnim,
        autoPlay: widget.animateRoute && !disableSystemAnim,
      );
    }
  }

  /// True only when every drawn part follows provider geometry.
  bool get _hasRoutedGeometry => widget.routeSegments.isNotEmpty
      ? widget.routeSegments.every((segment) => !segment.isEstimated)
      : widget.roadGeometry.length >= 2;

  void flyTo(double lat, double lng, {double? zoom}) {
    _startLat = _centerLat;
    _startLng = _centerLng;
    _startZoom = _zoom;

    if (widget.clampToDavao) {
      final (cLat, cLng) = MapboxService.clampToDavaoRegion(lat, lng);
      _targetLat = cLat;
      _targetLng = cLng;
    } else {
      _targetLat = lat.clamp(-84.0, 84.0);
      _targetLng = ((lng + 180.0) % 360.0) - 180.0;
    }
    _targetZoom = (zoom ?? _zoom).clamp(4.0, 17.5);
    _cameraAnimController.forward(from: 0);
  }

  void fitBounds() {
    final routePts = <GeoPoint>[
      ...widget.routePoints,
      for (final seg in widget.routeSegments) ...seg.points,
      if (widget.routeSegments.isEmpty) ...widget.roadGeometry,
    ];
    final pts = <GeoPoint>[
      ...routePts,
      for (final m in widget.markers)
        if (!m.isUserLocation ||
            routePts.isEmpty ||
            routePts.any(
              (p) =>
                  MapboxService.haversineKm(p.lat, p.lng, m.lat, m.lng) <= 120.0,
            ))
          GeoPoint(lat: m.lat, lng: m.lng),
    ];
    if (pts.isEmpty) {
      flyTo(widget.initialLat, widget.initialLng, zoom: widget.initialZoom);
      return;
    }
    final (cLat, cLng, cZoom) = MapboxService.computeBoundsCenterAndZoom(pts);
    flyTo(cLat, cLng, zoom: cZoom);
  }

  @override
  void dispose() {
    _cameraAnimController.dispose();
    _trailController.removeListener(_onTrailTick);
    _trailController.dispose();
    _pulseController.dispose();
    super.dispose();
  }

  Offset _latLngToViewportOffset(double lat, double lng, Size viewportSize) {
    final int tileZ = _zoom.floor().clamp(1, 16);
    final double scale = math.pow(2.0, _zoom - tileZ).toDouble();
    final double tileSize = 256.0 * scale;

    final (centerTileX, centerTileY) =
        MapboxService.latLngToTileXY(_centerLat, _centerLng, tileZ.toDouble());
    final (ptTileX, ptTileY) =
        MapboxService.latLngToTileXY(lat, lng, tileZ.toDouble());

    final dx = (ptTileX - centerTileX) * tileSize + (viewportSize.width / 2.0);
    final dy =
        (ptTileY - centerTileY) * tileSize + (viewportSize.height / 2.0);
    return Offset(dx, dy);
  }

  (double lat, double lng) _viewportOffsetToLatLng(
    Offset offset,
    Size viewportSize,
  ) {
    final int tileZ = _zoom.floor().clamp(1, 16);
    final double scale = math.pow(2.0, _zoom - tileZ).toDouble();
    final double tileSize = 256.0 * scale;

    final (centerTileX, centerTileY) =
        MapboxService.latLngToTileXY(_centerLat, _centerLng, tileZ.toDouble());
    final ptTileX =
        centerTileX + (offset.dx - viewportSize.width / 2.0) / tileSize;
    final ptTileY =
        centerTileY + (offset.dy - viewportSize.height / 2.0) / tileSize;
    return MapboxService.tileXYToLatLng(ptTileX, ptTileY, tileZ.toDouble());
  }

  void _handleScaleStart(ScaleStartDetails details) {
    if (!widget.interactive) return;
    if (widget.followUser) widget.onFollowUserChanged?.call(false);
    if (_flyAlongTrail) {
      setState(() => _flyAlongTrail = false);
    }
    _cameraAnimController.stop();
    _gestureStartZoom = _zoom;
    _prevFocalPoint = details.localFocalPoint;
  }

  void _handleScaleUpdate(ScaleUpdateDetails details, Size viewportSize) {
    if (!widget.interactive) return;
    final panDelta = details.localFocalPoint - _prevFocalPoint;
    _prevFocalPoint = details.localFocalPoint;

    final (cX, cY) =
        MapboxService.latLngToTileXY(_centerLat, _centerLng, _zoom);
    var shiftedCenterX = cX - (panDelta.dx / 256.0);
    var shiftedCenterY = cY - (panDelta.dy / 256.0);

    final newZoom = (details.scale - 1.0).abs() > 0.0005
        ? (_gestureStartZoom +
                (math.log(details.scale.clamp(0.2, 5.0)) / math.ln2))
            .clamp(4.0, 17.5)
        : _zoom;

    if ((newZoom - _zoom).abs() > 1e-4) {
      final fx =
          (details.localFocalPoint.dx - viewportSize.width / 2.0) / 256.0;
      final fy =
          (details.localFocalPoint.dy - viewportSize.height / 2.0) / 256.0;
      final zoomRatio = math.pow(2.0, newZoom - _zoom).toDouble();
      shiftedCenterX = (shiftedCenterX + fx) * zoomRatio - fx;
      shiftedCenterY = (shiftedCenterY + fy) * zoomRatio - fy;
    }

    final (newLat, newLng) =
        MapboxService.tileXYToLatLng(shiftedCenterX, shiftedCenterY, newZoom);

    setState(() {
      _zoom = newZoom;
      if (widget.clampToDavao) {
        final (cLat, cLng) = MapboxService.clampToDavaoRegion(newLat, newLng);
        _centerLat = cLat;
        _centerLng = cLng;
      } else {
        _centerLat = newLat.clamp(-84.0, 84.0);
        _centerLng = ((newLng + 180.0) % 360.0) - 180.0;
      }
    });
  }

  void _handlePointerScroll(PointerScrollEvent event, Size viewportSize) {
    if (!widget.interactive || event.scrollDelta.dy == 0) return;
    final zoomStep = event.scrollDelta.dy < 0 ? 0.55 : -0.55;
    final newZoom = (_zoom + zoomStep).clamp(4.0, 17.5);
    if ((newZoom - _zoom).abs() < 1e-4) return;
    final (cX, cY) =
        MapboxService.latLngToTileXY(_centerLat, _centerLng, _zoom);
    final fx = (event.localPosition.dx - viewportSize.width / 2.0) / 256.0;
    final fy = (event.localPosition.dy - viewportSize.height / 2.0) / 256.0;
    final zoomRatio = math.pow(2.0, newZoom - _zoom).toDouble();
    final nextX = (cX + fx) * zoomRatio - fx;
    final nextY = (cY + fy) * zoomRatio - fy;
    final (newLat, newLng) =
        MapboxService.tileXYToLatLng(nextX, nextY, newZoom);
    setState(() {
      _zoom = newZoom;
      _centerLat = newLat.clamp(-84.0, 84.0);
      _centerLng = ((newLng + 180.0) % 360.0) - 180.0;
    });
  }

  String _spriteForTransportMode(TransportMode mode) {
    switch (mode) {
      case TransportMode.flight:
        return 'assets/map_sprites/map_flight.png';
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

  void _showMapboxConfigDialog() {
    final tokenController =
        TextEditingController(text: widget.repo.mapbox.accessToken);
    final staticPreviewUrl = widget.repo.mapbox.buildStaticRouteImageUrl(
      waypoints: widget.routePoints,
      centerLat: _centerLat,
      centerLng: _centerLng,
      zoom: _zoom,
      style: widget.repo.activeMapStyle,
    );

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(
          left: 22,
          right: 22,
          top: 22,
          bottom: MediaQuery.of(ctx).viewInsets.bottom + 24,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: LakbayColors.tealWash,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Icon(Icons.map_rounded,
                      color: LakbayColors.tealDeep),
                ),
                const SizedBox(width: 10),
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Mapbox Style & API Configuration',
                        style: TextStyle(
                          fontFamily: LkType.displayFamily,
                          fontWeight: FontWeight.w700,
                          fontSize: 19,
                        ),
                      ),
                      Text(
                        'Configure MAPBOX_ACCESS_TOKEN for Davao vector tiles & Static Route API',
                        style: TextStyle(
                          fontSize: 12,
                          color: LakbayColors.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  icon: const Icon(Icons.close_rounded),
                ),
              ],
            ),
            const SizedBox(height: 16),
            TextField(
              controller: tokenController,
              decoration: InputDecoration(
                labelText: 'MAPBOX_ACCESS_TOKEN (Public pk.eyJ1... token)',
                hintText: 'pk.eyJ1IjoieW91ci11c2VybmFtZSIsImEiOiJ...',
                prefixIcon: const Icon(Icons.key_rounded,
                    color: LakbayColors.primary),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
              ),
            ),
            const SizedBox(height: 12),
            if (staticPreviewUrl != null)
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: LakbayColors.canvasBg,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  'Active Static Route API URL:\n$staticPreviewUrl',
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 11,
                    color: LakbayColors.tealDeep,
                    fontFamily: 'monospace',
                  ),
                ),
              ),
            const SizedBox(height: 16),
            ElevatedButton.icon(
              onPressed: () {
                widget.repo.setMapboxToken(tokenController.text);
                Navigator.of(ctx).pop();
                setState(() {});
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(
                      widget.repo.mapbox.hasValidToken
                          ? 'Mapbox Access Token activated!'
                          : 'Using built-in Davao coastal map tiles (no pk. token set).',
                    ),
                    backgroundColor: LakbayColors.tealDeep,
                  ),
                );
              },
              icon: const Icon(Icons.check_circle_outline_rounded),
              label: const Text('Save Mapbox Settings'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final style = widget.repo.activeMapStyle;
    final isDarkStyle = style == MapboxStylePreset.navigationNight ||
        style == MapboxStylePreset.satelliteStreets;

    return ClipRRect(
      borderRadius: BorderRadius.circular(widget.borderRadius),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final size = Size(constraints.maxWidth, constraints.maxHeight);
          final hasTrailData =
              _trail.hasAnimatedTrail || _trail.estimatedLegs.isNotEmpty;
          final effectiveRoute = _hasRoutedGeometry
              ? widget.roadGeometry
              : widget.routePoints;
          final projectedRoute = effectiveRoute
              .map((p) => _latLngToViewportOffset(p.lat, p.lng, size))
              .toList();
          final projectedAnimatedLegs = [
            for (final leg in _trail.animatedLegs)
              (
                leg,
                leg.points
                    .map((p) => _latLngToViewportOffset(p.lat, p.lng, size))
                    .toList(),
              ),
          ];
          final projectedEstimatedLegs = [
            for (final leg in _trail.estimatedLegs)
              (
                leg,
                leg.points
                    .map((p) => _latLngToViewportOffset(p.lat, p.lng, size))
                    .toList(),
              ),
          ];
          final showTrailControls = widget.showControls &&
              widget.animateRoute &&
              _trail.hasAnimatedTrail &&
              !(MediaQuery.maybeDisableAnimationsOf(context) ?? false);

          return Listener(
            onPointerSignal: (event) {
              if (event is PointerScrollEvent) {
                _handlePointerScroll(event, size);
              }
            },
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onScaleStart: widget.interactive ? _handleScaleStart : null,
              onScaleUpdate: widget.interactive
                  ? (details) => _handleScaleUpdate(details, size)
                  : null,
              onDoubleTap: widget.interactive
                  ? () => flyTo(_centerLat, _centerLng, zoom: _zoom + 1.1)
                  : null,
              onTapUp: widget.interactive && widget.onMapTap != null
                  ? (details) {
                      final (lat, lng) =
                          _viewportOffsetToLatLng(details.localPosition, size);
                      widget.onMapTap!(lat, lng);
                    }
                  : null,
              child: Stack(
              fit: StackFit.expand,
              children: [
                // 1. Stylized Ocean/Topographic Base Layer
                CustomPaint(
                  size: size,
                  painter: _MapGraticuleBackgroundPainter(
                    centerLat: _centerLat,
                    centerLng: _centerLng,
                    zoom: _zoom,
                    isDark: isDarkStyle,
                  ),
                ),

                // 2. Web-Mercator Slippy Raster Tiles (Mapbox Styles API or Carto Fallback)
                ..._buildSlippyTiles(size, style),

                // 3a. No road geometry: never draw a vehicle crossing land or sea.
                // Show only dashed stop-order connectors and say so.
                if (!hasTrailData && projectedRoute.length >= 2) ...[
                  CustomPaint(
                    size: size,
                    painter: _UnroutedConnectorPainter(
                      points: projectedRoute,
                      isDark: isDarkStyle,
                    ),
                  ),
                  if (widget.interactive)
                    Positioned(
                      left: 12,
                      right: widget.showControls ? 68 : 12,
                      bottom: widget.showControls
                          ? widget.controlsBottomOffset + 4
                          : null,
                      top: widget.showControls
                          ? null
                          : 12 + widget.overlayTopInset,
                      child: IgnorePointer(
                        child: widget.routeNotice != null
                            ? _buildUnroutedNotice(widget.routeNotice!)
                            : _buildUnroutedNotice(),
                      ),
                    ),
                ],

                // 3b. Progressive per-day road trail + dashed boat crossings +
                //     static dashed grey estimated connectors (never animated).
                if (hasTrailData) ...[
                  RepaintBoundary(
                    child: AnimatedBuilder(
                      animation: _trailController,
                      builder: (context, _) {
                        final activeLeg = _trailController.currentLeg;
                        final activePoint = _trailController.currentPoint;
                        final showVehicleHead = widget.animateRoute &&
                            _trail.estimatedLegs.isEmpty &&
                            !_trailController.disableAnimations &&
                            !_trailController.isSettled &&
                            activeLeg != null &&
                            activeLeg.mode != RouteTrailMode.estimated &&
                            activePoint != null;
                        final headOffset = showVehicleHead
                            ? _latLngToViewportOffset(
                                activePoint.lat,
                                activePoint.lng,
                                size,
                              )
                            : null;

                        return Stack(
                          fit: StackFit.expand,
                          children: [
                            CustomPaint(
                              size: size,
                              painter: RouteTrailPainter(
                                trail: _trail,
                                animatedProjectedLegs: projectedAnimatedLegs,
                                estimatedProjectedLegs: projectedEstimatedLegs,
                                currentDistanceMeters:
                                    _trailController.currentDistanceMeters,
                                isSettled: _trailController.isSettled,
                                isDark: isDarkStyle,
                              ),
                            ),
                            if (showVehicleHead && headOffset != null)
                              _buildTrailVehicleSprite(
                                screenPos: headOffset,
                                bearingRadians:
                                    _trailController.currentBearingRadians,
                                mode: activeLeg.mode == RouteTrailMode.sea
                                    ? TransportMode.ferry
                                    : TransportMode.car,
                                dayNumber: activeLeg.dayNumber,
                              ),
                          ],
                        );
                      },
                    ),
                  ),
                  if (_trail.estimatedLegs.isNotEmpty && widget.interactive)
                    Positioned(
                      left: 12,
                      right: widget.showControls ? 68 : 12,
                      bottom: widget.showControls
                          ? widget.controlsBottomOffset +
                              (showTrailControls ? 46 : 4)
                          : null,
                      top: widget.showControls
                          ? null
                          : 12 + widget.overlayTopInset,
                      child: IgnorePointer(
                        child: _buildUnroutedNotice(
                          widget.routeNotice ??
                              'Part of this road route is unavailable — grey dashed lines are estimates.',
                        ),
                      ),
                    ),
                ],

                // 4. Interactive Pin Markers + Pulsing CircleAnnotation Halo + APK Pin Sprites
                ...widget.markers.map((marker) {
                  // When a live GPS layer is active, anchor the "You" badge neatly
                  // below the live dot instead of drawing a second blue dot.
                  final lat = (marker.isUserLocation && widget.livePosition != null)
                      ? widget.livePosition!.lat
                      : marker.lat;
                  final lng = (marker.isUserLocation && widget.livePosition != null)
                      ? widget.livePosition!.lng
                      : marker.lng;
                  final offset = _latLngToViewportOffset(lat, lng, size);
                  if (offset.dx < -60 ||
                      offset.dx > size.width + 60 ||
                      offset.dy < -60 ||
                      offset.dy > size.height + 60) {
                    return const SizedBox.shrink();
                  }
                  final isSelected = widget.selectedMarkerId == marker.id;
                  return Positioned(
                    left: offset.dx - 55,
                    top: (marker.isUserLocation && widget.livePosition != null)
                        ? offset.dy + 12
                        : offset.dy - 74,
                    width: 110,
                    height: (marker.isUserLocation && widget.livePosition != null)
                        ? 24
                        : 74,
                    child: Align(
                      alignment:
                          (marker.isUserLocation && widget.livePosition != null)
                              ? Alignment.topCenter
                              : Alignment.bottomCenter,
                      child: GestureDetector(
                        onTap: () {
                          flyTo(lat, lng, zoom: math.max(_zoom, 9.6));
                          widget.onMarkerTap?.call(marker);
                        },
                        child: _buildMarkerWidget(
                          marker,
                          isSelected,
                          showUserDot: widget.livePosition == null,
                        ),
                      ),
                    ),
                  );
                }),

                // 5. Top Bar: Single Compact Map Layers & Token Menu
                if (widget.showControls)
                  Positioned(
                    top: 10,
                    left: 12,
                    child: PopupMenuButton<String>(
                      onSelected: (value) {
                        if (value == '__token__') {
                          _showMapboxConfigDialog();
                          return;
                        }
                        final chosen = MapboxStylePreset.values
                            .where((s) => s.id == value)
                            .firstOrNull;
                        if (chosen != null) {
                          widget.repo.setMapboxStyle(chosen);
                          setState(() {});
                        }
                      },
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                      itemBuilder: (_) => [
                        ...MapboxStylePreset.values.map(
                          (s) => PopupMenuItem<String>(
                            value: s.id,
                            child: Row(
                              children: [
                                Icon(
                                  s == style
                                      ? Icons.radio_button_checked_rounded
                                      : Icons.layers_outlined,
                                  size: 18,
                                  color: LakbayColors.primary,
                                ),
                                const SizedBox(width: 8),
                                Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      s.title,
                                      style: const TextStyle(
                                        fontFamily: LkType.displayFamily,
                                        fontWeight: FontWeight.w700,
                                        fontSize: 13.5,
                                      ),
                                    ),
                                    Text(
                                      s.subtitle,
                                      style: const TextStyle(
                                        fontSize: 11,
                                        color: LakbayColors.textSecondary,
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ),
                        const PopupMenuDivider(),
                        PopupMenuItem<String>(
                          value: '__token__',
                          child: Row(
                            children: [
                              Icon(
                                widget.repo.mapbox.hasValidToken
                                    ? Icons.verified_rounded
                                    : Icons.key_rounded,
                                size: 17,
                                color: widget.repo.mapbox.hasValidToken
                                    ? LakbayColors.successGreen
                                    : LakbayColors.cocoaOrange,
                              ),
                              const SizedBox(width: 8),
                              Text(
                                widget.repo.mapbox.hasValidToken
                                    ? 'Mapbox Token (Live)'
                                    : 'Set Mapbox Access Token',
                                style: const TextStyle(
                                  fontFamily: LkType.displayFamily,
                                  fontWeight: FontWeight.w600,
                                  fontSize: 13,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 6,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.70),
                          borderRadius: BorderRadius.circular(18),
                          border: Border.all(
                            color: Colors.white.withValues(alpha: 0.22),
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(
                              Icons.layers_rounded,
                              color: LakbayColors.primary,
                              size: 14,
                            ),
                            const SizedBox(width: 5),
                            Text(
                              style.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 11.5,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(width: 3),
                            const Icon(
                              Icons.keyboard_arrow_down_rounded,
                              color: Colors.white70,
                              size: 15,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),

                // 5b. Live GPS position: accuracy circle, dot, heading arrow.
                if (widget.livePosition != null)
                  _buildLivePositionLayer(widget.livePosition!, size),

                // 6. Right-Side Location, Zoom & Fit-Route Controls
                if (widget.showControls)
                  Positioned(
                    right: 12,
                    bottom: widget.controlsBottomOffset,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (widget.livePosition != null &&
                            widget.onFollowUserChanged != null) ...[
                          _buildMapIconButton(
                            icon: widget.followUser
                                ? Icons.navigation_rounded
                                : Icons.navigation_outlined,
                            tooltip: widget.followUser
                                ? 'Stop Following Me'
                                : 'Follow My Location',
                            onTap: () => widget.onFollowUserChanged!
                                .call(!widget.followUser),
                          ),
                          const SizedBox(height: 6),
                        ],
                        if (widget.repo.hasUserLocation) ...[
                          _buildMapIconButton(
                            icon: Icons.my_location_rounded,
                            tooltip: 'Center on My Location',
                            onTap: () {
                              final lat = widget.repo.userLat;
                              final lng = widget.repo.userLng;
                              if (lat != null && lng != null) {
                                flyTo(lat, lng, zoom: math.max(_zoom, 10.6));
                              }
                            },
                          ),
                          const SizedBox(height: 6),
                        ],
                        Container(
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.94),
                            borderRadius: BorderRadius.circular(12),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withValues(alpha: 0.16),
                                blurRadius: 8,
                                offset: const Offset(0, 2),
                              ),
                            ],
                          ),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Tooltip(
                                message: 'Zoom In',
                                child: InkWell(
                                  borderRadius: const BorderRadius.vertical(
                                    top: Radius.circular(12),
                                  ),
                                  onTap: () => flyTo(
                                    _centerLat,
                                    _centerLng,
                                    zoom: _zoom + 1.0,
                                  ),
                                  child: const SizedBox(
                                    width: 36,
                                    height: 34,
                                    child: Icon(
                                      Icons.add_rounded,
                                      size: 19,
                                      color: LakbayColors.tealDeep,
                                    ),
                                  ),
                                ),
                              ),
                              Container(
                                width: 22,
                                height: 1,
                                color: Colors.black.withValues(alpha: 0.08),
                              ),
                              Tooltip(
                                message: 'Zoom Out',
                                child: InkWell(
                                  borderRadius: const BorderRadius.vertical(
                                    bottom: Radius.circular(12),
                                  ),
                                  onTap: () => flyTo(
                                    _centerLat,
                                    _centerLng,
                                    zoom: _zoom - 1.0,
                                  ),
                                  child: const SizedBox(
                                    width: 36,
                                    height: 34,
                                    child: Icon(
                                      Icons.remove_rounded,
                                      size: 19,
                                      color: LakbayColors.tealDeep,
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 6),
                        _buildMapIconButton(
                          icon: Icons.center_focus_strong_rounded,
                          tooltip: 'Fit Route Stops',
                          onTap: fitBounds,
                        ),
                      ],
                    ),
                  ),

                // 6b. Bottom-Left Replay & Fly-Along Controls for Active Route Trail
                if (showTrailControls)
                  Positioned(
                    left: 12,
                    bottom: widget.controlsBottomOffset,
                    child: AnimatedBuilder(
                      animation: _trailController,
                      builder: (context, _) {
                        final settled = _trailController.isSettled;
                        final playing = _trailController.isPlaying;
                        return Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            _buildTrailPillButton(
                              key: const ValueKey('trail_replay_button'),
                              icon: settled
                                  ? Icons.replay_rounded
                                  : (playing
                                      ? Icons.pause_rounded
                                      : Icons.play_arrow_rounded),
                              label: settled
                                  ? 'Replay'
                                  : (playing ? 'Pause' : 'Play'),
                              active: playing && !settled,
                              onTap: () {
                                if (settled) {
                                  _trailController.replay();
                                } else if (playing) {
                                  _trailController.pause();
                                } else {
                                  _trailController.play();
                                }
                              },
                            ),
                            const SizedBox(width: 6),
                            _buildTrailPillButton(
                              key: const ValueKey('trail_fly_along_button'),
                              icon: Icons.flight_takeoff_rounded,
                              label: 'Fly along',
                              active: _flyAlongTrail,
                              onTap: () {
                                setState(() {
                                  _flyAlongTrail = !_flyAlongTrail;
                                });
                                if (_flyAlongTrail &&
                                    _trailController.isSettled) {
                                  _trailController.replay();
                                }
                              },
                            ),
                          ],
                        );
                      },
                    ),
                  ),

                // 7. Bottom-Left Mapbox Attribution (compact, non-intrusive)
                Positioned(
                  left: 10,
                  bottom: 8,
                  child: IgnorePointer(
                    child: Container(
                      padding:
                          const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.42),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        '© Mapbox',
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.88),
                          fontSize: 9.5,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildTrailPillButton({
    Key? key,
    required IconData icon,
    required String label,
    required bool active,
    required VoidCallback onTap,
  }) {
    return Material(
      key: key,
      color: active
          ? LakbayColors.primary
          : Colors.black.withValues(alpha: 0.72),
      borderRadius: BorderRadius.circular(18),
      elevation: 4,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(18),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 15, color: Colors.white),
              const SizedBox(width: 5),
              Text(
                label,
                style: const TextStyle(
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
    );
  }

  /// Rotating car or boat sprite rendered at the active progressive trail head.
  Widget _buildTrailVehicleSprite({
    required Offset screenPos,
    required double bearingRadians,
    required TransportMode mode,
    required int dayNumber,
  }) {
    final borderColor = mode == TransportMode.ferry
        ? RouteTrail.seaRouteColor
        : RouteTrail.colorForDay(dayNumber, RouteTrailMode.road);
    return Positioned(
      key: const ValueKey('trail_vehicle_sprite'),
      left: screenPos.dx - 16,
      top: screenPos.dy - 16,
      child: Transform.rotate(
        angle: mode == TransportMode.ferry ? 0.0 : bearingRadians,
        child: Container(
          width: 32,
          height: 32,
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            color: Colors.white,
            shape: BoxShape.circle,
            border: Border.all(color: borderColor, width: 2.2),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.28),
                blurRadius: 8,
              ),
            ],
          ),
          child: Image.asset(
            _spriteForTransportMode(mode),
            fit: BoxFit.contain,
            errorBuilder: (_, _, _) => Icon(
              mode == TransportMode.ferry
                  ? Icons.directions_boat_rounded
                  : Icons.navigation_rounded,
              size: 16,
              color: borderColor,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildUnroutedNotice([
    String message =
        'Road route unavailable — dashed lines show stop order only.',
  ]) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.64),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          const Icon(Icons.info_outline_rounded, size: 14, color: Colors.white),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(color: Colors.white, fontSize: 11),
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _buildSlippyTiles(Size viewportSize, MapboxStylePreset style) {
    final int tileZ = _zoom.floor().clamp(1, 16);
    final int maxTileIndex = 1 << tileZ;
    final double scale = math.pow(2.0, _zoom - tileZ).toDouble();
    final double tileSize = 256.0 * scale;

    final (centerTileX, centerTileY) =
        MapboxService.latLngToTileXY(_centerLat, _centerLng, tileZ.toDouble());

    final int centerXFloor = centerTileX.floor();
    final int centerYFloor = centerTileY.floor();

    final int horizTiles = ((viewportSize.width / tileSize) / 2).ceil() + 1;
    final int vertTiles = ((viewportSize.height / tileSize) / 2).ceil() + 1;

    final tiles = <Widget>[];
    for (int dx = -horizTiles; dx <= horizTiles; dx++) {
      for (int dy = -vertTiles; dy <= vertTiles; dy++) {
        final int rawX = centerXFloor + dx;
        final int rawY = centerYFloor + dy;
        if (rawY < 0 || rawY >= maxTileIndex) continue;

        final int wrappedX =
            ((rawX % maxTileIndex) + maxTileIndex) % maxTileIndex;

        final double screenLeft =
            (rawX - centerTileX) * tileSize + (viewportSize.width / 2.0);
        final double screenTop =
            (rawY - centerTileY) * tileSize + (viewportSize.height / 2.0);

        final url = widget.repo.mapbox.buildTileUrl(
          style: style,
          z: tileZ,
          x: wrappedX,
          y: rawY,
        );

        tiles.add(
          Positioned(
            key: ValueKey('${style.id}_${tileZ}_${rawX}_$rawY'),
            left: screenLeft,
            top: screenTop,
            width: tileSize + 0.6,
            height: tileSize + 0.6,
            child: Image.network(
              url,
              fit: BoxFit.fill,
              errorBuilder: (_, _, _) => const SizedBox.shrink(),
            ),
          ),
        );
      }
    }
    return tiles;
  }

  Widget _buildMarkerImageThumb(LakbayMapMarker marker) {
    final url = marker.imageUrl?.trim() ?? '';
    final asset = marker.imageAsset?.trim() ?? '';
    if (url.isNotEmpty) {
      return Image.network(
        url,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => asset.isNotEmpty
            ? Image.asset(
                asset,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => const Icon(
                  Icons.place_rounded,
                  size: 18,
                  color: LakbayColors.tealDeep,
                ),
              )
            : const Icon(
                Icons.place_rounded,
                size: 18,
                color: LakbayColors.tealDeep,
              ),
      );
    }
    if (asset.isNotEmpty) {
      return Image.asset(
        asset,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => const Icon(
          Icons.place_rounded,
          size: 18,
          color: LakbayColors.tealDeep,
        ),
      );
    }
    return const Icon(
      Icons.place_rounded,
      size: 18,
      color: LakbayColors.tealDeep,
    );
  }

  Widget _buildMarkerWidget(
    LakbayMapMarker marker,
    bool isSelected, {
    bool showUserDot = true,
  }) {
    if (marker.isUserLocation) {
      if (!showUserDot) {
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
          decoration: BoxDecoration(
            color: LakbayColors.tealDeep,
            borderRadius: BorderRadius.circular(8),
          ),
          child: const Text(
            'You',
            style: TextStyle(
              color: Colors.white,
              fontSize: 9.5,
              fontWeight: FontWeight.w700,
            ),
          ),
        );
      }
      return Stack(
        alignment: Alignment.center,
        clipBehavior: Clip.none,
        children: [
          AnimatedBuilder(
            animation: _pulseController,
            builder: (_, _) {
              final t = _pulseController.value;
              return Transform.scale(
                scale: 0.8 + (t * 1.1),
                child: Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: const Color(0xFF1A73E8)
                        .withValues(alpha: (1.0 - t) * 0.45),
                  ),
                ),
              );
            },
          ),
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 18,
                height: 18,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: const Color(0xFF1A73E8),
                  border: Border.all(color: Colors.white, width: 2.5),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.3),
                      blurRadius: 6,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 2),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
                decoration: BoxDecoration(
                  color: LakbayColors.tealDeep,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Text(
                  'You',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 9.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
        ],
      );
    }

    if ((marker.isCompact || marker.isNearby) &&
        !isSelected &&
        !marker.isPrimary) {
      final isPier = marker.badgeText == '⚓';
      final pinColor = isPier
          ? const Color(0xFF1E88E5)
          : marker.isNearby
              ? const Color(0xFF8A9A9A)
              : LakbayColors.tealDeep;
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: isPier ? 24 : (marker.isNearby ? 14 : 18),
            height: isPier ? 24 : (marker.isNearby ? 14 : 18),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: isPier ? Colors.white : pinColor,
              border: Border.all(
                color: isPier ? pinColor : Colors.white,
                width: isPier ? 2.0 : 2.2,
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.25),
                  blurRadius: 5,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: isPier
                ? Icon(
                    Icons.directions_boat_rounded,
                    size: 13,
                    color: pinColor,
                  )
                : null,
          ),
          CustomPaint(
            size: const Size(8, 5),
            painter: _PinTrianglePainter(color: pinColor),
          ),
        ],
      );
    }

    if (marker.hasThumbnail) {
      final ringColor = isSelected || marker.isPrimary
          ? LakbayColors.primary
          : LakbayColors.tealDeep;
      final thumbSize = isSelected || marker.isPrimary ? 44.0 : 38.0;
      return Stack(
        alignment: Alignment.bottomCenter,
        clipBehavior: Clip.none,
        children: [
          if (isSelected || marker.isPrimary)
            Positioned(
              bottom: 10,
              child: AnimatedBuilder(
                animation: _pulseController,
                builder: (_, _) {
                  final t = _pulseController.value;
                  return Transform.scale(
                    scale: 0.8 + (t * 0.65),
                    child: Container(
                      width: thumbSize + 6,
                      height: thumbSize + 6,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: LakbayColors.primary
                            .withValues(alpha: (1.0 - t) * 0.42),
                      ),
                    ),
                  );
                },
              ),
            ),
          AnimatedScale(
            scale: isSelected ? 1.1 : 1.0,
            duration: const Duration(milliseconds: 200),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Container(
                      width: thumbSize,
                      height: thumbSize,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: Colors.white,
                        border: Border.all(
                          color: ringColor,
                          width: isSelected ? 3.0 : 2.2,
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.32),
                            blurRadius: 8,
                            offset: const Offset(0, 3),
                          ),
                        ],
                      ),
                      padding: const EdgeInsets.all(1.5),
                      child: ClipOval(child: _buildMarkerImageThumb(marker)),
                    ),
                    if (marker.badgeText.isNotEmpty)
                      Positioned(
                        right: -6,
                        bottom: -3,
                        child: Container(
                          constraints: const BoxConstraints(maxWidth: 68),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 5,
                            vertical: 1.5,
                          ),
                          decoration: BoxDecoration(
                            color: ringColor,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: Colors.white, width: 1.1),
                          ),
                          child: Text(
                            marker.badgeText,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontFamily: LkType.displayFamily,
                              color: Colors.white,
                              fontWeight: FontWeight.w800,
                              fontSize: 9.5,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
                CustomPaint(
                  size: const Size(12, 7),
                  painter: _PinTrianglePainter(color: ringColor),
                ),
              ],
            ),
          ),
        ],
      );
    }

    final spritePath = marker.isOrigin
        ? 'assets/map_sprites/map_from.png'
        : (marker.isDestination
            ? 'assets/map_sprites/map_to.png'
            : 'assets/map_sprites/map-pin-filled.png');

    return Stack(
      alignment: Alignment.center,
      clipBehavior: Clip.none,
      children: [
          if (isSelected || marker.isPrimary)
            AnimatedBuilder(
              animation: _pulseController,
              builder: (_, _) {
                final t = _pulseController.value;
                return Transform.scale(
                  scale: 0.7 + (t * 0.9),
                  child: Container(
                    width: 42,
                    height: 42,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: LakbayColors.primary
                          .withValues(alpha: (1.0 - t) * 0.45),
                    ),
                  ),
                );
              },
            ),
          AnimatedScale(
            scale: isSelected ? 1.16 : 1.0,
            duration: const Duration(milliseconds: 220),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    gradient: isSelected || marker.isPrimary
                        ? LakbayColors.brandGradient
                        : LakbayColors.deepTealGradient,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: Colors.white,
                      width: isSelected ? 2.2 : 1.4,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.32),
                        blurRadius: 8,
                        offset: const Offset(0, 3),
                      ),
                    ],
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Image.asset(
                        spritePath,
                        width: 12,
                        height: 12,
                        errorBuilder: (_, _, _) => const SizedBox.shrink(),
                      ),
                      const SizedBox(width: 4),
                      Text(
                        marker.badgeText,
                        style: const TextStyle(
                          fontFamily: LkType.displayFamily,
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                ),
                CustomPaint(
                  size: const Size(12, 7),
                  painter: _PinTrianglePainter(
                    color: isSelected || marker.isPrimary
                        ? LakbayColors.primary
                        : LakbayColors.tealDeep,
                  ),
                ),
              ],
            ),
          ),
        ],
      );
  }

  Widget _buildLivePositionLayer(LivePosition live, Size size) {
    final center = _latLngToViewportOffset(live.lat, live.lng, size);
    // Web-Mercator meters per screen pixel at this latitude and zoom (256px tiles).
    final metersPerPixel = 156543.03392 *
        math.cos(live.lat * math.pi / 180) /
        math.pow(2, _zoom);
    final accuracyRadius =
        (live.accuracyMeters / metersPerPixel).clamp(0.0, 400.0);
    const liveBlue = Color(0xFF1A73E8);
    return IgnorePointer(
      child: CustomPaint(
        size: size,
        painter: _LivePositionPainter(
          center: center,
          accuracyRadius: accuracyRadius,
          headingRadians: live.headingDegrees == null
              ? null
              : live.headingDegrees! * math.pi / 180,
          color: liveBlue,
        ),
      ),
    );
  }

  Widget _buildMapIconButton({
    required IconData icon,
    required String tooltip,
    required VoidCallback onTap,
  }) {
    return Material(
      color: Colors.black.withValues(alpha: 0.72),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: Colors.white.withValues(alpha: 0.22)),
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Tooltip(
          message: tooltip,
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Icon(icon, color: Colors.white, size: 20),
          ),
        ),
      ),
    );
  }
}

class _PinTrianglePainter extends CustomPainter {
  final Color color;

  const _PinTrianglePainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()
      ..moveTo(0, 0)
      ..lineTo(size.width / 2, size.height)
      ..lineTo(size.width, 0)
      ..close();
    canvas.drawPath(path, Paint()..color = color);
  }

  @override
  bool shouldRepaint(covariant _PinTrianglePainter oldDelegate) =>
      oldDelegate.color != color;
}

class _LivePositionPainter extends CustomPainter {
  final Offset center;
  final double accuracyRadius;
  final double? headingRadians;
  final Color color;

  const _LivePositionPainter({
    required this.center,
    required this.accuracyRadius,
    required this.headingRadians,
    required this.color,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (accuracyRadius > 10) {
      canvas.drawCircle(
          center, accuracyRadius, Paint()..color = color.withValues(alpha: 0.12));
      canvas.drawCircle(
        center,
        accuracyRadius,
        Paint()
          ..color = color.withValues(alpha: 0.35)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1,
      );
    }
    final heading = headingRadians;
    if (heading != null) {
      // Heading cone pointing the direction of travel (0 = north, clockwise).
      final cone = Path()
        ..moveTo(center.dx, center.dy)
        ..arcTo(
          Rect.fromCircle(center: center, radius: 30),
          heading - math.pi / 2 - 0.45,
          0.9,
          false,
        )
        ..close();
      canvas.drawPath(
        cone,
        Paint()
          ..shader = RadialGradient(colors: [
            color.withValues(alpha: 0.55),
            color.withValues(alpha: 0.0),
          ]).createShader(Rect.fromCircle(center: center, radius: 30)),
      );
    }
    canvas.drawCircle(center, 11, Paint()..color = Colors.white);
    canvas.drawCircle(center, 8, Paint()..color = color);
  }

  @override
  bool shouldRepaint(covariant _LivePositionPainter oldDelegate) =>
      oldDelegate.center != center ||
      oldDelegate.accuracyRadius != accuracyRadius ||
      oldDelegate.headingRadians != headingRadians;
}

/// Stop-order connectors shown when no road route is available. Thin, grey
/// and dashed so they never read as a drivable path.
class _UnroutedConnectorPainter extends CustomPainter {
  final List<Offset> points;
  final bool isDark;

  const _UnroutedConnectorPainter({required this.points, required this.isDark});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = (isDark ? Colors.white : const Color(0xFF5B6770))
          .withValues(alpha: 0.75)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.2
      ..strokeCap = StrokeCap.round;
    const dash = 8.0;
    const gap = 7.0;
    for (int i = 1; i < points.length; i++) {
      final a = points[i - 1];
      final b = points[i];
      final length = (b - a).distance;
      if (length <= 0) continue;
      final dir = (b - a) / length;
      for (double d = 0; d < length; d += dash + gap) {
        final end = math.min(d + dash, length);
        canvas.drawLine(a + dir * d, a + dir * end, paint);
      }
    }
    for (final pt in points) {
      canvas.drawCircle(pt, 4.5, Paint()..color = Colors.white);
      canvas.drawCircle(pt, 2.8, Paint()..color = LakbayColors.tealDeep);
    }
  }

  @override
  bool shouldRepaint(covariant _UnroutedConnectorPainter oldDelegate) =>
      oldDelegate.points != points || oldDelegate.isDark != isDark;
}

class _MapGraticuleBackgroundPainter extends CustomPainter {
  final double centerLat;
  final double centerLng;
  final double zoom;
  final bool isDark;

  const _MapGraticuleBackgroundPainter({
    required this.centerLat,
    required this.centerLng,
    required this.zoom,
    required this.isDark,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final bgGradient = LinearGradient(
      colors: isDark
          ? const [Color(0xFF071E26), Color(0xFF0B3C49)]
          : const [Color(0xFFD8F1F5), Color(0xFFE9F7F8)],
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
    );
    canvas.drawRect(
      Offset.zero & size,
      Paint()..shader = bgGradient.createShader(Offset.zero & size),
    );

    final gridPaint = Paint()
      ..color = (isDark ? Colors.white : LakbayColors.tealAccent)
          .withValues(alpha: 0.12)
      ..strokeWidth = 1;

    const spacing = 48.0;
    final offsetX = (centerLng * zoom * 6) % spacing;
    final offsetY = (centerLat * zoom * 6) % spacing;

    for (double x = offsetX; x < size.width; x += spacing) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), gridPaint);
    }
    for (double y = offsetY; y < size.height; y += spacing) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), gridPaint);
    }
  }

  @override
  bool shouldRepaint(covariant _MapGraticuleBackgroundPainter oldDelegate) =>
      oldDelegate.centerLat != centerLat ||
      oldDelegate.centerLng != centerLng ||
      oldDelegate.zoom != zoom ||
      oldDelegate.isDark != isDark;
}
