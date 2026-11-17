import 'dart:math' as math;

import 'package:latlong2/latlong.dart';

/// Precision-5 encoded polyline helpers compatible with OSRM, Mapbox, and
/// Lakbay+'s `/routes/*` and `/admin/sea-links` APIs.
List<LatLng> decodePolyline5(String encoded) {
  final points = <LatLng>[];
  var index = 0;
  var lat = 0;
  var lng = 0;
  final length = encoded.length;
  while (index < length) {
    final deltas = <int>[];
    for (var axis = 0; axis < 2; axis++) {
      var shift = 0;
      var result = 0;
      while (true) {
        if (index >= length) return points;
        final byte = encoded.codeUnitAt(index) - 63;
        index++;
        result |= (byte & 0x1F) << shift;
        shift += 5;
        if (byte < 0x20) break;
      }
      deltas.add((result & 1) != 0 ? ~(result >> 1) : (result >> 1));
    }
    lat += deltas[0];
    lng += deltas[1];
    points.add(LatLng(lat / 1e5, lng / 1e5));
  }
  return points;
}

String encodePolyline5(List<LatLng> points) {
  final buffer = StringBuffer();
  var prevLat = 0;
  var prevLng = 0;
  for (final pt in points) {
    final curLat = (pt.latitude * 1e5).round();
    final curLng = (pt.longitude * 1e5).round();
    for (final delta in [curLat - prevLat, curLng - prevLng]) {
      var value = delta < 0 ? ~(delta << 1) : (delta << 1);
      while (value >= 0x20) {
        buffer.writeCharCode((0x20 | (value & 0x1F)) + 63);
        value >>= 5;
      }
      buffer.writeCharCode(value + 63);
    }
    prevLat = curLat;
    prevLng = curLng;
  }
  return buffer.toString();
}

double haversineMeters(LatLng a, LatLng b) {
  double rad(double degrees) => degrees * math.pi / 180.0;
  final h =
      math.pow(math.sin(rad(b.latitude - a.latitude) / 2), 2) +
      math.cos(rad(a.latitude)) *
          math.cos(rad(b.latitude)) *
          math.pow(math.sin(rad(b.longitude - a.longitude) / 2), 2);
  return 2 * 6371000 * math.asin(math.sqrt(h));
}

double polylineLengthMeters(List<LatLng> points) {
  if (points.length < 2) return 0;
  var total = 0.0;
  for (var i = 1; i < points.length; i++) {
    total += haversineMeters(points[i - 1], points[i]);
  }
  return total;
}

String formatDistanceMeters(double meters) => meters >= 1000
    ? '${(meters / 1000).toStringAsFixed(2)} km'
    : '${meters.round()} m';
