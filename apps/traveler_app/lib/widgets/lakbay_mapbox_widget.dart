import 'dart:math' as math;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import '../models/travel_models.dart';
import '../services/location_service.dart';
import '../services/mapbox_service.dart';
import '../services/travel_repository.dart';
import '../theme/lakbay_theme.dart';

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
  final List<LakbayMapMarker> markers;

  /// Live GPS fix drawn as a moving dot with heading and accuracy circle.
  final LivePosition? livePosition;

  /// Keep the camera centered on [livePosition]. Panning the map turns it off
  /// through [onFollowUserChanged].
  final bool followUser;
  final ValueChanged<bool>? onFollowUserChanged;
  final String? selectedMarkerId;
  final ValueChanged<LakbayMapMarker>? onMarkerTap;
  final bool showControls;
  final bool interactive;
  final bool animateRoute;
  final bool clampToDavao;
  final double borderRadius;
  final double controlsBottomOffset;

  const LakbayMapboxMap({
    super.key,
    required this.repo,
    required this.initialLat,
    required this.initialLng,
    this.initialZoom = 8.4,
    this.routePoints = const [],
    this.roadGeometry = const [],
    this.routeSegments = const [],
    this.markers = const [],
    this.livePosition,
    this.followUser = false,
    this.onFollowUserChanged,
    this.selectedMarkerId,
    this.onMarkerTap,
    this.showControls = true,
    this.interactive = true,
    this.animateRoute = true,
    this.clampToDavao = false,
    this.borderRadius = 20,
    this.controlsBottomOffset = 36,
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
  late AnimationController _routeAnimController;
  late AnimationController _pulseController;

  double _startLat = 0;
  double _startLng = 0;
  double _startZoom = 8.4;
  double _targetLat = 0;
  double _targetLng = 0;
  double _targetZoom = 8.4;
  double _gestureStartZoom = 8.4;
  Offset _prevFocalPoint = Offset.zero;

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

    _routeAnimController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 4800),
    );
    if (widget.animateRoute && _hasRoutedGeometry) {
      _routeAnimController.repeat();
    }

    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1600),
    )..repeat();
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
    final hasRoad = _hasRoutedGeometry;
    if (widget.animateRoute && hasRoad && !_routeAnimController.isAnimating) {
      _routeAnimController.repeat();
    } else if (!hasRoad && _routeAnimController.isAnimating) {
      _routeAnimController.stop();
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
    final pts = <GeoPoint>[
      ...widget.routePoints,
      ...widget.markers.map((m) => GeoPoint(lat: m.lat, lng: m.lng)),
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
    _routeAnimController.dispose();
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

  void _handleScaleStart(ScaleStartDetails details) {
    if (!widget.interactive) return;
    if (widget.followUser) widget.onFollowUserChanged?.call(false);
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
                          fontFamily: 'FigGrotesk',
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
          final segments = widget.routeSegments;
          final hasSegments = segments.isNotEmpty;
          final hasDetailedRoad =
              hasSegments ? _hasRoutedGeometry : widget.roadGeometry.length >= 2;
          final projectedSegments = [
            for (final segment in segments)
              (
                segment,
                segment.points
                    .map((p) => _latLngToViewportOffset(p.lat, p.lng, size))
                    .toList(),
              ),
          ];
          final effectiveRoute =
              hasDetailedRoad ? widget.roadGeometry : widget.routePoints;
          final projectedRoute = effectiveRoute
              .map((p) => _latLngToViewportOffset(p.lat, p.lng, size))
              .toList();

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
                if (!hasSegments && !hasDetailedRoad && projectedRoute.length >= 2) ...[
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
                      top: widget.showControls ? null : 12,
                      child: IgnorePointer(child: _buildUnroutedNotice()),
                    ),
                ],

                // 3c. Pier-aware route: road solid, sea dashed blue, estimates dashed grey.
                if (hasSegments) ...[
                  CustomPaint(
                    size: size,
                    painter: _SegmentedRoutePainter(
                      segments: projectedSegments,
                      isDark: isDarkStyle,
                    ),
                  ),
                  if (!hasDetailedRoad && widget.interactive)
                    Positioned(
                      left: 12,
                      right: widget.showControls ? 68 : 12,
                      bottom: widget.showControls
                          ? widget.controlsBottomOffset + 4
                          : null,
                      top: widget.showControls ? null : 12,
                      child: IgnorePointer(
                        child: _buildUnroutedNotice(
                          'Part of this road route is unavailable — grey dashed lines are estimates.',
                        ),
                      ),
                    ),
                  if (hasDetailedRoad && widget.animateRoute)
                    AnimatedBuilder(
                      animation: _routeAnimController,
                      builder: (context, _) => _buildSegmentSprite(
                        projectedSegments,
                        _routeAnimController.value,
                      ),
                    ),
                ],

                // 3b. Animated road route line-trim & moving sprite (road geometry only)
                if (!hasSegments && hasDetailedRoad && projectedRoute.length >= 2)
                  AnimatedBuilder(
                    animation: _routeAnimController,
                    builder: (context, _) {
                      final animVal = widget.animateRoute
                          ? _routeAnimController.value
                          : 1.0;

                      // Compute moving sprite position & bearing along active leg
                      final totalSegments = projectedRoute.length - 1;
                      final scaled = animVal * totalSegments;
                      final segIdx = scaled.floor().clamp(0, totalSegments - 1);
                      final segT = (scaled - segIdx).clamp(0.0, 1.0);

                      final p0 = projectedRoute[segIdx];
                      final p2 = projectedRoute[segIdx + 1];
                      final spritePos = Offset.lerp(p0, p2, segT) ?? p0;
                      final spriteAngle =
                          math.atan2(p2.dy - p0.dy, p2.dx - p0.dx);
                      final wpIdx = widget.routePoints.isEmpty
                          ? 0
                          : ((segIdx + 1) *
                                  widget.routePoints.length ~/
                                  projectedRoute.length)
                              .clamp(0, widget.routePoints.length - 1);
                      final legMode = widget.routePoints.isEmpty
                          ? TransportMode.car
                          : widget.routePoints[wpIdx].legMode;

                      return Stack(
                        fit: StackFit.expand,
                        children: [
                          CustomPaint(
                            size: size,
                            painter: _AnimatedRoutePolylinePainter(
                              points: projectedRoute,
                              progress: animVal,
                              isDark: isDarkStyle,
                            ),
                          ),
                          if (widget.animateRoute)
                            Positioned(
                              left: spritePos.dx - 16,
                              top: spritePos.dy - 16,
                              child: Transform.rotate(
                                angle: spriteAngle + (math.pi / 2),
                                child: Container(
                                  width: 32,
                                  height: 32,
                                  padding: const EdgeInsets.all(4),
                                  decoration: BoxDecoration(
                                    color: Colors.white,
                                    shape: BoxShape.circle,
                                    border: Border.all(
                                        color: LakbayColors.primary,
                                        width: 2),
                                    boxShadow: [
                                      BoxShadow(
                                        color: Colors.black
                                            .withValues(alpha: 0.28),
                                        blurRadius: 8,
                                      ),
                                    ],
                                  ),
                                  child: Image.asset(
                                    _spriteForTransportMode(legMode),
                                    fit: BoxFit.contain,
                                    errorBuilder: (_, _, _) => const Icon(
                                      Icons.navigation_rounded,
                                      size: 16,
                                      color: LakbayColors.primary,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                        ],
                      );
                    },
                  ),

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

                // 5. Top Bar: Mapbox Style Switcher & Token Status
                if (widget.showControls)
                  Positioned(
                    top: 12,
                    left: 12,
                    right: 12,
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Flexible(
                          child: PopupMenuButton<MapboxStylePreset>(
                            onSelected: (s) {
                              widget.repo.setMapboxStyle(s);
                              setState(() {});
                            },
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(16),
                            ),
                            itemBuilder: (_) => MapboxStylePreset.values
                                .map(
                                  (s) => PopupMenuItem(
                                    value: s,
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
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              s.title,
                                              style: const TextStyle(
                                                fontFamily: 'FigGrotesk',
                                                fontWeight: FontWeight.w700,
                                                fontSize: 13.5,
                                              ),
                                            ),
                                            Text(
                                              s.subtitle,
                                              style: const TextStyle(
                                                fontSize: 11,
                                                color:
                                                    LakbayColors.textSecondary,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ],
                                    ),
                                  ),
                                )
                                .toList(),
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 12, vertical: 7),
                              decoration: BoxDecoration(
                                color: Colors.black.withValues(alpha: 0.72),
                                borderRadius: BorderRadius.circular(20),
                                border: Border.all(
                                    color:
                                        Colors.white.withValues(alpha: 0.25)),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Icon(Icons.layers_rounded,
                                      color: LakbayColors.primary, size: 15),
                                  const SizedBox(width: 6),
                                  Flexible(
                                    child: Text(
                                      style.title,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 12,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 4),
                                  const Icon(Icons.keyboard_arrow_down_rounded,
                                      color: Colors.white70, size: 16),
                                ],
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        InkWell(
                          onTap: _showMapboxConfigDialog,
                          borderRadius: BorderRadius.circular(20),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 10, vertical: 7),
                            decoration: BoxDecoration(
                              color: widget.repo.mapbox.hasValidToken
                                  ? LakbayColors.tealDeep
                                      .withValues(alpha: 0.88)
                                  : Colors.black.withValues(alpha: 0.68),
                              borderRadius: BorderRadius.circular(20),
                              border: Border.all(
                                  color: Colors.white.withValues(alpha: 0.25)),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  widget.repo.mapbox.hasValidToken
                                      ? Icons.verified_rounded
                                      : Icons.key_rounded,
                                  color: widget.repo.mapbox.hasValidToken
                                      ? LakbayColors.successGreen
                                      : LakbayColors.cocoaOrange,
                                  size: 14,
                                ),
                                const SizedBox(width: 5),
                                Text(
                                  widget.repo.mapbox.hasValidToken
                                      ? 'Mapbox Live'
                                      : 'Mapbox Key',
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 11.5,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
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
                        _buildMapIconButton(
                          icon: Icons.add_rounded,
                          tooltip: 'Zoom In',
                          onTap: () =>
                              flyTo(_centerLat, _centerLng, zoom: _zoom + 1.0),
                        ),
                        const SizedBox(height: 6),
                        _buildMapIconButton(
                          icon: Icons.remove_rounded,
                          tooltip: 'Zoom Out',
                          onTap: () =>
                              flyTo(_centerLat, _centerLng, zoom: _zoom - 1.0),
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

                // 7. Bottom-Left Mapbox Attribution Pill
                Positioned(
                  left: 10,
                  bottom: 8,
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.55),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      '© Mapbox • ${_centerLat.toStringAsFixed(2)}°N, ${_centerLng.toStringAsFixed(2)}°E',
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.9),
                        fontSize: 10,
                        fontWeight: FontWeight.w500,
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

  /// A vehicle sprite moving along routed segments: a car on roads, a boat on
  /// sea crossings.
  Widget _buildSegmentSprite(
    List<(RouteSegmentGeometry, List<Offset>)> segments,
    double progress,
  ) {
    final points = <Offset>[];
    final modes = <TransportMode>[];
    for (final (segment, projected) in segments) {
      for (int i = 0; i < projected.length; i++) {
        if (points.isNotEmpty && i == 0 && points.last == projected[i]) continue;
        points.add(projected[i]);
        modes.add(segment.mode);
      }
    }
    if (points.length < 2) return const SizedBox.shrink();
    final scaled = progress * (points.length - 1);
    final index = scaled.floor().clamp(0, points.length - 2);
    final t = (scaled - index).clamp(0.0, 1.0);
    final a = points[index];
    final b = points[index + 1];
    final position = Offset.lerp(a, b, t) ?? a;
    final angle = math.atan2(b.dy - a.dy, b.dx - a.dx);
    final mode = modes[index + 1];
    return Stack(
      fit: StackFit.expand,
      children: [
        Positioned(
          left: position.dx - 16,
          top: position.dy - 16,
          child: Transform.rotate(
            angle: mode == TransportMode.ferry ? 0 : angle + (math.pi / 2),
            child: Container(
              width: 32,
              height: 32,
              padding: const EdgeInsets.all(4),
              decoration: BoxDecoration(
                color: Colors.white,
                shape: BoxShape.circle,
                border: Border.all(
                  color: mode == TransportMode.ferry
                      ? _seaRouteColor
                      : LakbayColors.primary,
                  width: 2,
                ),
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
                  color: LakbayColors.primary,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildUnroutedNotice([
    String message =
        'Road route unavailable — dashed lines show stop order only.',
  ]) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.68),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          const Icon(Icons.info_outline_rounded, size: 16, color: Colors.white),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(color: Colors.white, fontSize: 12),
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
                              fontFamily: 'FigGrotesk',
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
                          fontFamily: 'FigGrotesk',
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

/// Draws a road route from decoded road geometry. Callers must only pass
/// provider road geometry (never raw stop coordinates).
class _AnimatedRoutePolylinePainter extends CustomPainter {
  final List<Offset> points;
  final double progress;
  final bool isDark;

  const _AnimatedRoutePolylinePainter({
    required this.points,
    required this.progress,
    required this.isDark,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (points.length < 2) return;

    final fullPath = Path()..moveTo(points.first.dx, points.first.dy);
    for (int i = 1; i < points.length; i++) {
      fullPath.lineTo(points[i].dx, points[i].dy);
    }

    // 1. Subtle ghost track for entire route
    canvas.drawPath(
      fullPath,
      Paint()
        ..color = Colors.white.withValues(alpha: isDark ? 0.24 : 0.6)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 6.0
        ..strokeCap = StrokeCap.round,
    );

    // 2. Progressive line-trim drawing (replicates Mapbox setLineTrimOffset + fade range)
    for (final metric in fullPath.computeMetrics()) {
      final len = metric.length;
      final activeEnd = (len * progress).clamp(0.0, len);
      final trimmed = metric.extractPath(0, activeEnd);

      canvas.drawPath(
        trimmed,
        Paint()
          ..color = Colors.white.withValues(alpha: 0.88)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 6.5
          ..strokeCap = StrokeCap.round,
      );

      canvas.drawPath(
        trimmed,
        Paint()
          ..color = LakbayColors.primary
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3.8
          ..strokeCap = StrokeCap.round,
      );
    }

  }

  @override
  bool shouldRepaint(covariant _AnimatedRoutePolylinePainter oldDelegate) =>
      true;
}

const Color _seaRouteColor = Color(0xFF1E88E5);

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

void _drawDashedPolyline(
  Canvas canvas,
  List<Offset> points,
  Paint paint, {
  double dash = 8,
  double gap = 7,
}) {
  for (int i = 1; i < points.length; i++) {
    final a = points[i - 1];
    final b = points[i];
    final length = (b - a).distance;
    if (length <= 0) continue;
    final dir = (b - a) / length;
    for (double d = 0; d < length; d += dash + gap) {
      canvas.drawLine(a + dir * d, a + dir * math.min(d + dash, length), paint);
    }
  }
}

/// Draws pier-aware routes part by part so a road never appears over water.
class _SegmentedRoutePainter extends CustomPainter {
  final List<(RouteSegmentGeometry, List<Offset>)> segments;
  final bool isDark;

  const _SegmentedRoutePainter({required this.segments, required this.isDark});

  @override
  void paint(Canvas canvas, Size size) {
    for (final (segment, points) in segments) {
      if (points.length < 2) continue;
      if (segment.isSea) {
        _drawDashedPolyline(
          canvas,
          points,
          Paint()
            ..color = Colors.white.withValues(alpha: 0.85)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 6
            ..strokeCap = StrokeCap.round,
          dash: 10,
          gap: 6,
        );
        _drawDashedPolyline(
          canvas,
          points,
          Paint()
            ..color = _seaRouteColor
            ..style = PaintingStyle.stroke
            ..strokeWidth = 3.6
            ..strokeCap = StrokeCap.round,
          dash: 10,
          gap: 6,
        );
      } else if (segment.isEstimated) {
        _drawDashedPolyline(
          canvas,
          points,
          Paint()
            ..color = (isDark ? Colors.white : const Color(0xFF5B6770))
                .withValues(alpha: 0.75)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2.2
            ..strokeCap = StrokeCap.round,
        );
      } else {
        final path = Path()..moveTo(points.first.dx, points.first.dy);
        for (final point in points.skip(1)) {
          path.lineTo(point.dx, point.dy);
        }
        canvas.drawPath(
          path,
          Paint()
            ..color = Colors.white.withValues(alpha: 0.88)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 6.5
            ..strokeCap = StrokeCap.round
            ..strokeJoin = StrokeJoin.round,
        );
        canvas.drawPath(
          path,
          Paint()
            ..color = LakbayColors.primary
            ..style = PaintingStyle.stroke
            ..strokeWidth = 3.8
            ..strokeCap = StrokeCap.round
            ..strokeJoin = StrokeJoin.round,
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant _SegmentedRoutePainter oldDelegate) => true;
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
