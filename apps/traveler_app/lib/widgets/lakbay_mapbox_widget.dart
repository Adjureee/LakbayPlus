import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../models/travel_models.dart';
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
  final bool isPrimary;
  final bool isOrigin;
  final bool isDestination;

  const LakbayMapMarker({
    required this.id,
    required this.lat,
    required this.lng,
    required this.badgeText,
    required this.title,
    this.subtitle,
    this.isPrimary = false,
    this.isOrigin = false,
    this.isDestination = false,
  });
}

class LakbayMapboxMap extends StatefulWidget {
  final TravelRepository repo;
  final double initialLat;
  final double initialLng;
  final double initialZoom;
  final List<GeoPoint> routePoints;
  final List<GeoPoint> roadGeometry;
  final List<LakbayMapMarker> markers;
  final String? selectedMarkerId;
  final ValueChanged<LakbayMapMarker>? onMarkerTap;
  final bool showControls;
  final bool interactive;
  final bool animateRoute;
  final bool clampToDavao;
  final double borderRadius;

  const LakbayMapboxMap({
    super.key,
    required this.repo,
    required this.initialLat,
    required this.initialLng,
    this.initialZoom = 8.4,
    this.routePoints = const [],
    this.roadGeometry = const [],
    this.markers = const [],
    this.selectedMarkerId,
    this.onMarkerTap,
    this.showControls = true,
    this.interactive = true,
    this.animateRoute = true,
    this.clampToDavao = true,
    this.borderRadius = 20,
  });

  @override
  State<LakbayMapboxMap> createState() => LakbayMapboxMapState();
}

class LakbayMapboxMapState extends State<LakbayMapboxMap>
    with TickerProviderStateMixin {
  late double _centerLat;
  late double _centerLng;
  late double _zoom;

  late AnimationController _cameraAnimController;
  late AnimationController _routeAnimController;
  late AnimationController _pulseController;

  double _startLat = 0;
  double _startLng = 0;
  double _startZoom = 8.4;
  double _targetLat = 0;
  double _targetLng = 0;
  double _targetZoom = 8.4;

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
    if (widget.animateRoute && widget.routePoints.length >= 2) {
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
    if (widget.animateRoute &&
        widget.routePoints.length >= 2 &&
        !_routeAnimController.isAnimating) {
      _routeAnimController.repeat();
    }
  }

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
    _targetZoom = (zoom ?? _zoom).clamp(6.8, 15.0);
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

  void _handlePanUpdate(DragUpdateDetails details) {
    if (!widget.interactive) return;
    final int tileZ = _zoom.floor().clamp(1, 16);
    final double scale = math.pow(2.0, _zoom - tileZ).toDouble();
    final double tileSize = 256.0 * scale;

    final (centerTileX, centerTileY) =
        MapboxService.latLngToTileXY(_centerLat, _centerLng, tileZ.toDouble());

    final newTileX = centerTileX - (details.delta.dx / tileSize);
    final newTileY = centerTileY - (details.delta.dy / tileSize);

    final (newLat, newLng) =
        MapboxService.tileXYToLatLng(newTileX, newTileY, tileZ.toDouble());

    setState(() {
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
          final hasDetailedRoad = widget.roadGeometry.length >= 2;
          final effectiveRoute =
              hasDetailedRoad ? widget.roadGeometry : widget.routePoints;
          final projectedRoute = effectiveRoute
              .map((p) => _latLngToViewportOffset(p.lat, p.lng, size))
              .toList();

          return GestureDetector(
            onPanUpdate: widget.interactive ? _handlePanUpdate : null,
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

                // 3. Animated Mapbox Route Line-Trim (lineTrimOffset + lineTrimFadeRange) & Moving Sprite
                if (projectedRoute.length >= 2)
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
                      final mid = Offset((p0.dx + p2.dx) / 2, (p0.dy + p2.dy) / 2);
                      final dx = p2.dx - p0.dx;
                      final dy = p2.dy - p0.dy;
                      final p1 = hasDetailedRoad
                          ? mid
                          : Offset(mid.dx - dy * 0.16, mid.dy + dx * 0.16);

                      final spritePos = hasDetailedRoad
                          ? Offset.lerp(p0, p2, segT) ?? p0
                          : MapboxService.evaluateQuadraticBezier(
                              p0, p1, p2, segT);
                      final spriteAngle = hasDetailedRoad
                          ? math.atan2(dy, dx)
                          : MapboxService.evaluateQuadraticBezierAngle(
                              p0, p1, p2, segT);
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
                              isExactRoadPath: hasDetailedRoad,
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
                  final offset =
                      _latLngToViewportOffset(marker.lat, marker.lng, size);
                  if (offset.dx < -60 ||
                      offset.dx > size.width + 60 ||
                      offset.dy < -60 ||
                      offset.dy > size.height + 60) {
                    return const SizedBox.shrink();
                  }
                  final isSelected = widget.selectedMarkerId == marker.id;
                  return Positioned(
                    left: offset.dx - 55,
                    top: offset.dy - 46,
                    width: 110,
                    child: Align(
                      alignment: Alignment.bottomCenter,
                      child: GestureDetector(
                        onTap: () {
                          flyTo(marker.lat, marker.lng,
                              zoom: math.max(_zoom, 9.6));
                          widget.onMarkerTap?.call(marker);
                        },
                        child: _buildMarkerWidget(marker, isSelected),
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
                      children: [
                        PopupMenuButton<MapboxStylePreset>(
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
                                              color: LakbayColors.textSecondary,
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
                                  color: Colors.white.withValues(alpha: 0.25)),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(Icons.layers_rounded,
                                    color: LakbayColors.primary, size: 15),
                                const SizedBox(width: 6),
                                Text(
                                  'Mapbox: ${style.title}',
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                const SizedBox(width: 4),
                                const Icon(Icons.keyboard_arrow_down_rounded,
                                    color: Colors.white70, size: 16),
                              ],
                            ),
                          ),
                        ),
                        const Spacer(),
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

                // 6. Right-Side Zoom & Fit-Route Controls
                if (widget.showControls)
                  Positioned(
                    right: 12,
                    bottom: 36,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
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
                          tooltip: 'Fit Davao Route',
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
                      '© Mapbox • Region XI (${_centerLat.toStringAsFixed(2)}°N, ${_centerLng.toStringAsFixed(2)}°E)',
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
          );
        },
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

  Widget _buildMarkerWidget(LakbayMapMarker marker, bool isSelected) {
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

class _AnimatedRoutePolylinePainter extends CustomPainter {
  final List<Offset> points;
  final double progress;
  final bool isDark;
  final bool isExactRoadPath;

  const _AnimatedRoutePolylinePainter({
    required this.points,
    required this.progress,
    required this.isDark,
    this.isExactRoadPath = false,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (points.length < 2) return;

    final fullPath = Path()..moveTo(points.first.dx, points.first.dy);
    if (isExactRoadPath) {
      for (int i = 1; i < points.length; i++) {
        fullPath.lineTo(points[i].dx, points[i].dy);
      }
    } else {
      for (int i = 1; i < points.length; i++) {
        final prev = points[i - 1];
        final curr = points[i];
        final mid = Offset((prev.dx + curr.dx) / 2, (prev.dy + curr.dy) / 2);
        final dx = curr.dx - prev.dx;
        final dy = curr.dy - prev.dy;
        final control = Offset(mid.dx - dy * 0.16, mid.dy + dx * 0.16);
        fullPath.quadraticBezierTo(control.dx, control.dy, curr.dx, curr.dy);
      }
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

    for (final pt in points) {
      canvas.drawCircle(pt, 4.5, Paint()..color = Colors.white);
      canvas.drawCircle(pt, 2.8, Paint()..color = LakbayColors.tealDeep);
    }
  }

  @override
  bool shouldRepaint(covariant _AnimatedRoutePolylinePainter oldDelegate) =>
      true;
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
