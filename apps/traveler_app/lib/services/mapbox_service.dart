import 'dart:math' as math;
import 'dart:ui';
import '../models/travel_models.dart';
import 'env_config.dart';

/// Handles Mapbox Tile URLs, Static Images API URLs (for destination cards & PDF route maps),
/// Davao Region XI coordinate bounds, Web-Mercator projections, and Bezier route animation math.
class MapboxService {
  static const double davaoCenterLat = 7.0731;
  static const double davaoCenterLng = 125.6128;

  // Region XI (Davao Region) bounding box with slight Gulf/Celebes margin
  static const double davaoMinLat = 5.20;
  static const double davaoMaxLat = 8.15;
  static const double davaoMinLng = 124.95;
  static const double davaoMaxLng = 126.85;

  static const String _envToken =
      String.fromEnvironment('MAPBOX_ACCESS_TOKEN', defaultValue: '');

  String _customToken = '';

  String get accessToken {
    if (_customToken.isNotEmpty) return _customToken;
    if (_envToken.isNotEmpty) return _envToken;
    return EnvConfig.mapboxAccessToken;
  }

  bool get hasValidToken =>
      accessToken.trim().isNotEmpty && accessToken.trim().startsWith('pk.');

  void setCustomToken(String token) {
    _customToken = token.trim();
  }

  static bool isInsideDavaoRegion(double lat, double lng) {
    return lat >= davaoMinLat &&
        lat <= davaoMaxLat &&
        lng >= davaoMinLng &&
        lng <= davaoMaxLng;
  }

  static (double lat, double lng) clampToDavaoRegion(double lat, double lng) {
    return (
      lat.clamp(davaoMinLat, davaoMaxLat),
      lng.clamp(davaoMinLng, davaoMaxLng),
    );
  }

  /// Builds a 256px slippy tile URL for the given Mapbox style preset and (z, x, y).
  /// Uses official Mapbox Style Tiles API when a valid `pk.` token is configured,
  /// and falls back to Carto/OSM standard Web-Mercator tiles when no token is set yet.
  String buildTileUrl({
    required MapboxStylePreset style,
    required int z,
    required int x,
    required int y,
  }) {
    if (hasValidToken) {
      return 'https://api.mapbox.com/styles/v1/mapbox/${style.id}/tiles/256/$z/$x/$y@2x?access_token=$accessToken';
    }
    switch (style) {
      case MapboxStylePreset.satelliteStreets:
        return 'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/$z/$y/$x';
      case MapboxStylePreset.navigationNight:
      case MapboxStylePreset.coastalLight:
      case MapboxStylePreset.outdoors:
        return 'https://tile.openstreetmap.org/$z/$x/$y.png';
    }
  }

  /// Builds a Mapbox Static Images API URL for destination cards and PDF route maps,
  /// matching the `MAPBOX_ACCESS_TOKEN` Static Images specification.
  String? buildStaticRouteImageUrl({
    required List<GeoPoint> waypoints,
    required double centerLat,
    required double centerLng,
    double zoom = 8.4,
    int width = 640,
    int height = 320,
    MapboxStylePreset style = MapboxStylePreset.outdoors,
  }) {
    if (!hasValidToken) return null;

    final pins = <String>[];
    for (int i = 0; i < waypoints.length && i < 12; i++) {
      final pt = waypoints[i];
      final color = i == 0 ? 'ff5a36' : '0b3c49';
      final label = (i + 1).toString();
      pins.add(
        'pin-s-$label+$color(${pt.lng.toStringAsFixed(4)},${pt.lat.toStringAsFixed(4)})',
      );
    }

    final overlaySegment = pins.isNotEmpty ? '${pins.join(',')}/' : '';
    final lonStr = centerLng.toStringAsFixed(4);
    final latStr = centerLat.toStringAsFixed(4);
    final zoomStr = zoom.clamp(1.0, 16.0).toStringAsFixed(1);

    return 'https://api.mapbox.com/styles/v1/mapbox/${style.id}/static/'
        '$overlaySegment$lonStr,$latStr,$zoomStr,0/${width}x$height@2x?access_token=$accessToken';
  }

  /// Converts latitude/longitude to fractional Web-Mercator tile coordinates at zoom [zoom].
  static (double x, double y) latLngToTileXY(
      double lat, double lng, double zoom) {
    final n = math.pow(2.0, zoom);
    final clampedLat = lat.clamp(-85.0511, 85.0511);
    final latRad = clampedLat * math.pi / 180.0;
    final x = ((lng + 180.0) / 360.0) * n;
    final y =
        (1.0 - math.log(math.tan(latRad) + 1.0 / math.cos(latRad)) / math.pi) /
            2.0 *
            n;
    return (x, y);
  }

  /// Converts fractional Web-Mercator tile coordinates back to (lat, lng).
  static (double lat, double lng) tileXYToLatLng(
      double x, double y, double zoom) {
    final n = math.pow(2.0, zoom);
    final lng = (x / n) * 360.0 - 180.0;
    final latRad = math.atan(_sinh(math.pi * (1.0 - 2.0 * y / n)));
    final lat = (latRad * 180.0 / math.pi).clamp(-85.0511, 85.0511);
    return (lat, lng);
  }

  static double _sinh(double x) => (math.exp(x) - math.exp(-x)) / 2.0;

  /// Evaluates a point along a quadratic Bezier curve from [p0] to [p2] with control [p1] at [t].
  static Offset evaluateQuadraticBezier(
      Offset p0, Offset p1, Offset p2, double t) {
    final u = 1.0 - t;
    return Offset(
      u * u * p0.dx + 2 * u * t * p1.dx + t * t * p2.dx,
      u * u * p0.dy + 2 * u * t * p1.dy + t * t * p2.dy,
    );
  }

  /// Evaluates the tangent angle (radians) along a quadratic Bezier curve at [t].
  static double evaluateQuadraticBezierAngle(
      Offset p0, Offset p1, Offset p2, double t) {
    final dx = 2 * (1 - t) * (p1.dx - p0.dx) + 2 * t * (p2.dx - p1.dx);
    final dy = 2 * (1 - t) * (p1.dy - p0.dy) + 2 * t * (p2.dy - p1.dy);
    return math.atan2(dy, dx);
  }

  /// Calculates total great-circle route distance in kilometers across ordered waypoints.
  static double calculateRouteDistanceKm(List<GeoPoint> points) {
    if (points.length < 2) return 0;
    double totalKm = 0;
    for (int i = 1; i < points.length; i++) {
      totalKm += haversineKm(
        points[i - 1].lat,
        points[i - 1].lng,
        points[i].lat,
        points[i].lng,
      );
    }
    return totalKm;
  }

  static double haversineKm(
      double lat1, double lon1, double lat2, double lon2) {
    const r = 6371.0;
    final dLat = (lat2 - lat1) * math.pi / 180.0;
    final dLon = (lon2 - lon1) * math.pi / 180.0;
    final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(lat1 * math.pi / 180.0) *
            math.cos(lat2 * math.pi / 180.0) *
            math.sin(dLon / 2) *
            math.sin(dLon / 2);
    final c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
    return r * c;
  }

  /// Computes an ideal camera center (lat, lng) and zoom level to fit [points].
  static (double centerLat, double centerLng, double zoom)
      computeBoundsCenterAndZoom(List<GeoPoint> points) {
    if (points.isEmpty) return (davaoCenterLat, davaoCenterLng, 8.5);
    if (points.length == 1) return (points.first.lat, points.first.lng, 10.2);

    double minLat = points.first.lat;
    double maxLat = points.first.lat;
    double minLng = points.first.lng;
    double maxLng = points.first.lng;

    for (final p in points) {
      if (p.lat < minLat) minLat = p.lat;
      if (p.lat > maxLat) maxLat = p.lat;
      if (p.lng < minLng) minLng = p.lng;
      if (p.lng > maxLng) maxLng = p.lng;
    }

    final centerLat = (minLat + maxLat) / 2.0;
    final centerLng = (minLng + maxLng) / 2.0;
    final span = math.max((maxLat - minLat).abs(), (maxLng - minLng).abs());

    double zoom = 9.0;
    if (span > 2.2) {
      zoom = 7.6;
    } else if (span > 1.2) {
      zoom = 8.4;
    } else if (span > 0.6) {
      zoom = 9.3;
    } else if (span > 0.25) {
      zoom = 10.2;
    } else {
      zoom = 11.2;
    }

    return (centerLat, centerLng, zoom);
  }
}
