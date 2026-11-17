import 'dart:math' as math;

import '../models/travel_models.dart';

/// Where a GPS fix sits relative to a route polyline.
class RouteProjection {
  /// Shortest distance from the fix to the route line, in meters.
  final double distanceMeters;

  /// Index of the route segment (points[i] -> points[i + 1]) nearest the fix.
  final int segmentIndex;

  /// Route distance still ahead of the projected point, in meters.
  final double remainingMeters;

  const RouteProjection({
    required this.distanceMeters,
    required this.segmentIndex,
    required this.remainingMeters,
  });
}

const double _earthRadiusMeters = 6371000;

double haversineMeters(double lat1, double lng1, double lat2, double lng2) {
  final dLat = (lat2 - lat1) * math.pi / 180;
  final dLng = (lng2 - lng1) * math.pi / 180;
  final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
      math.cos(lat1 * math.pi / 180) *
          math.cos(lat2 * math.pi / 180) *
          math.sin(dLng / 2) *
          math.sin(dLng / 2);
  return 2 * _earthRadiusMeters * math.atan2(math.sqrt(a), math.sqrt(1 - a));
}

/// Projects [lat]/[lng] onto [route]. Uses a local flat projection, which is
/// accurate to well under a meter at city scale. Returns null for routes with
/// fewer than two points.
RouteProjection? projectOntoRoute(double lat, double lng, List<GeoPoint> route) {
  if (route.length < 2) return null;
  final cosLat = math.cos(lat * math.pi / 180);
  const metersPerDegree = _earthRadiusMeters * math.pi / 180;
  double x(double pointLng) => (pointLng - lng) * metersPerDegree * cosLat;
  double y(double pointLat) => (pointLat - lat) * metersPerDegree;

  final segmentLengths = <double>[];
  for (int i = 0; i < route.length - 1; i++) {
    segmentLengths.add(haversineMeters(
        route[i].lat, route[i].lng, route[i + 1].lat, route[i + 1].lng));
  }

  var bestDistance = double.infinity;
  var bestIndex = 0;
  var bestFraction = 0.0;
  for (int i = 0; i < route.length - 1; i++) {
    final ax = x(route[i].lng), ay = y(route[i].lat);
    final bx = x(route[i + 1].lng), by = y(route[i + 1].lat);
    final dx = bx - ax, dy = by - ay;
    final lengthSquared = dx * dx + dy * dy;
    // The fix is the origin (0, 0) in this projection.
    final t = lengthSquared == 0
        ? 0.0
        : ((-ax * dx - ay * dy) / lengthSquared).clamp(0.0, 1.0);
    final px = ax + t * dx, py = ay + t * dy;
    final distance = math.sqrt(px * px + py * py);
    if (distance < bestDistance) {
      bestDistance = distance;
      bestIndex = i;
      bestFraction = t;
    }
  }

  var remaining = segmentLengths[bestIndex] * (1 - bestFraction);
  for (int i = bestIndex + 1; i < segmentLengths.length; i++) {
    remaining += segmentLengths[i];
  }
  return RouteProjection(
    distanceMeters: bestDistance,
    segmentIndex: bestIndex,
    remainingMeters: remaining,
  );
}

/// Decides when the traveler has left the route and a reroute is worth it.
///
/// A reroute fires after [requiredFixes] consecutive accurate fixes farther
/// than [thresholdMeters] from the route, and at most once per [cooldown], so
/// one noisy GPS reading never triggers a new route request.
class OffRouteDetector {
  OffRouteDetector({
    this.thresholdMeters = 50,
    this.requiredFixes = 3,
    this.maxUsableAccuracyMeters = 100,
    this.cooldown = const Duration(seconds: 30),
  });

  final double thresholdMeters;
  final int requiredFixes;
  final double maxUsableAccuracyMeters;
  final Duration cooldown;

  int _consecutiveOff = 0;
  DateTime? _lastReroute;

  /// Returns true when the caller should request a new route now.
  bool update({
    required double lat,
    required double lng,
    required double accuracyMeters,
    required List<GeoPoint> route,
    required DateTime now,
  }) {
    if (accuracyMeters > maxUsableAccuracyMeters) return false;
    final projection = projectOntoRoute(lat, lng, route);
    if (projection == null) return false;
    // A fix whose accuracy circle still touches the route is not off it.
    final effectiveThreshold = math.max(thresholdMeters, accuracyMeters);
    if (projection.distanceMeters <= effectiveThreshold) {
      _consecutiveOff = 0;
      return false;
    }
    _consecutiveOff++;
    if (_consecutiveOff < requiredFixes) return false;
    final last = _lastReroute;
    if (last != null && now.difference(last) < cooldown) return false;
    _lastReroute = now;
    _consecutiveOff = 0;
    return true;
  }

  void reset() => _consecutiveOff = 0;
}

/// Index of the first not-yet-reached stop within [radiusMeters] of the fix,
/// or null. Stops at or before [reachedCount] are already reached.
int? detectArrival({
  required double lat,
  required double lng,
  required List<GeoPoint> stops,
  required int reachedCount,
  double radiusMeters = 120,
}) {
  for (int i = reachedCount; i < stops.length; i++) {
    if (haversineMeters(lat, lng, stops[i].lat, stops[i].lng) <= radiusMeters) {
      return i;
    }
  }
  return null;
}

/// "2.4 km" / "350 m".
String formatDistanceMeters(double meters) {
  if (meters >= 1000) return '${(meters / 1000).toStringAsFixed(1)} km';
  return '${(meters / 10).round() * 10} m';
}
