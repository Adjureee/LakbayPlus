import '../models/travel_models.dart';
import 'lakbay_api_catalog_service.dart';
import 'mapbox_service.dart';

/// One honest line about a route, shared by the trip screen and the map.
///
/// A distance and time from the route service are shown as such (labelled a
/// road route or an estimate). With no route yet, a straight-line distance is
/// shown and says so: from the traveler's position when it is known, otherwise
/// between the stops. A single stop with no starting point has no distance.
class RouteSummaryText {
  RouteSummaryText._();

  static String durationText(int minutes) {
    if (minutes <= 0) return '';
    if (minutes < 60) return '$minutes min';
    final hours = minutes ~/ 60;
    final rest = minutes % 60;
    return rest == 0 ? '$hours h' : '$hours h $rest min';
  }

  static String modeLabel(String mode) => switch (mode) {
        'public_transport' => 'Public transit',
        'walking' => 'Walking',
        'cycling' => 'Cycling',
        _ => 'Private car',
      };

  static String _qualifier(BackendRouteResult route, String? mode) {
    if (route.isEstimated) return 'estimate';
    if (route is RoadRouteResult) {
      if (mode == 'driving' && route.traffic.isLive) {
        return 'with current traffic';
      }
      return 'road route';
    }
    if (mode == 'driving' && route.routeProvider == 'mapbox') {
      return 'with current traffic';
    }
    return 'road route';
  }

  /// Straight-line length through [origin] (when given) and then every stop.
  static double straightLineKm(List<GeoPoint> stops, {GeoPoint? origin}) =>
      MapboxService.calculateRouteDistanceKm([?origin, ...stops]);

  /// A short value for a small chip ("82.7 km • 1 h 34 min") with what kind of
  /// number it is ("road route", "with current traffic", "estimate", "straight line"), or null.
  static ({String value, String qualifier})? chip({
    BackendRouteResult? route,
    required List<GeoPoint> stops,
    GeoPoint? origin,
    String? mode,
  }) {
    if (route != null && route.totalDistanceKm > 0) {
      final km = route.totalDistanceKm;
      final time = durationText(route.totalDurationMinutes);
      return (
        value: [
          '${km >= 10 ? km.toStringAsFixed(0) : km.toStringAsFixed(1)} km',
          if (time.isNotEmpty) time,
        ].join(' • '),
        qualifier: _qualifier(route, mode),
      );
    }
    final km = straightLineKm(stops, origin: origin);
    if (km <= 0) return null;
    return (
      value: '≈ ${km >= 10 ? km.toStringAsFixed(0) : km.toStringAsFixed(1)} km',
      qualifier: origin != null ? 'from you, straight line' : 'straight line',
    );
  }

  /// The summary line, or null when there is nothing honest to say.
  static String? line({
    BackendRouteResult? route,
    required List<GeoPoint> stops,
    GeoPoint? origin,
    String? mode,
  }) {
    if (route != null && route.totalDistanceKm > 0) {
      final km = route.totalDistanceKm;
      final time = durationText(route.totalDurationMinutes);
      return [
        '${km >= 10 ? km.toStringAsFixed(0) : km.toStringAsFixed(1)} km',
        if (time.isNotEmpty) time,
        if (mode != null) modeLabel(mode),
        _qualifier(route, mode),
      ].join(' • ');
    }
    final km = straightLineKm(stops, origin: origin);
    if (km <= 0) return null;
    final rounded = km >= 10 ? km.toStringAsFixed(0) : km.toStringAsFixed(1);
    return origin != null
        ? '≈ $rounded km from your location (straight line)'
        : '≈ $rounded km between stops (straight line)';
  }
}
