import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../models/travel_models.dart';
import '../services/lakbay_api_catalog_service.dart';

/// Travel category for a leg of a [RouteTrail].
enum RouteTrailMode { road, sea, estimated }

/// Metric vertex along a route leg.
class RouteTrailPoint {
  final double lat;
  final double lng;
  final double eastMeters;
  final double northMeters;
  final double cumulativeMeters;

  const RouteTrailPoint({
    required this.lat,
    required this.lng,
    required this.eastMeters,
    required this.northMeters,
    required this.cumulativeMeters,
  });
}

/// One contiguous road, sea, or estimated connector leg of a route.
class RouteTrailLeg {
  final int dayNumber;
  final RouteTrailMode mode;
  final List<RouteTrailPoint> points;
  final double startMeters;
  final double endMeters;
  final List<String> congestionLevels;

  const RouteTrailLeg({
    required this.dayNumber,
    required this.mode,
    required this.points,
    required this.startMeters,
    required this.endMeters,
    this.congestionLevels = const [],
  });

  double get lengthMeters => math.max(0.0, endMeters - startMeters);
  bool get isAnimated => mode != RouteTrailMode.estimated;
}

/// Progressive route-trail model separating animated road/sea legs from static
/// dashed grey estimated legs, using local metric coordinates for bearing,
/// distance lookup, and zoom-aware Douglas-Peucker simplification.
class RouteTrail {
  static const double _earthRadiusMeters = 6371000.0;
  static const Color seaRouteColor = Color(0xFF1E88E5);

  /// Distinct, readable day colors for per-day trail drawing.
  static const List<Color> dayPalette = [
    Color(0xFF00897B), // Day 1: Lakbay teal
    Color(0xFFF4511E), // Day 2: Terracotta coral
    Color(0xFF3949AB), // Day 3: Deep indigo
    Color(0xFF2E7D32), // Day 4: Forest green
    Color(0xFF8E24AA), // Day 5: Plum
    Color(0xFFEF6C00), // Day 6: Warm amber
    Color(0xFFC2185B), // Day 7: Berry
  ];

  final List<RouteTrailLeg> animatedLegs;
  final List<RouteTrailLeg> estimatedLegs;
  final double totalAnimatedMeters;
  final double refLat;
  final double refLng;

  const RouteTrail({
    required this.animatedLegs,
    required this.estimatedLegs,
    required this.totalAnimatedMeters,
    required this.refLat,
    required this.refLng,
  });

  factory RouteTrail.empty() => const RouteTrail(
        animatedLegs: [],
        estimatedLegs: [],
        totalAnimatedMeters: 0,
        refLat: 7.0731,
        refLng: 125.6128,
      );

  double get totalAnimatedKm => totalAnimatedMeters / 1000.0;
  bool get hasAnimatedTrail =>
      animatedLegs.isNotEmpty && totalAnimatedMeters > 0.0;

  static Color colorForDay(
    int dayNumber,
    RouteTrailMode mode, {
    bool isDark = false,
  }) {
    if (mode == RouteTrailMode.sea) return seaRouteColor;
    if (mode == RouteTrailMode.estimated) {
      return isDark
          ? Colors.white.withValues(alpha: 0.75)
          : const Color(0xFF5B6770);
    }
    final index = (dayNumber <= 0 ? 0 : dayNumber - 1) % dayPalette.length;
    return dayPalette[index];
  }

  static Color colorForCongestion(
    String level, {
    required Color fallback,
  }) {
    return switch (level.trim().toLowerCase()) {
      'low' || 'light' => const Color(0xFF2E7D4F),
      'moderate' => const Color(0xFFF59E0B),
      'heavy' => const Color(0xFFE65100),
      'severe' => const Color(0xFFC62828),
      _ => fallback,
    };
  }

  /// Approximate ground resolution (meters per logical pixel) at Web Mercator [zoom].
  static double metersPerPixel(double zoom, double centerLat) {
    final cosLat = math.cos(centerLat * math.pi / 180.0).abs().clamp(0.1, 1.0);
    return 156543.03392 * cosLat / math.pow(2.0, zoom);
  }

  /// Spherical haversine distance in meters.
  static double haversineMeters(
    double lat1,
    double lng1,
    double lat2,
    double lng2,
  ) {
    final dLat = (lat2 - lat1) * math.pi / 180.0;
    final dLng = (lng2 - lng1) * math.pi / 180.0;
    final phi1 = lat1 * math.pi / 180.0;
    final phi2 = lat2 * math.pi / 180.0;
    final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(phi1) *
            math.cos(phi2) *
            math.sin(dLng / 2) *
            math.sin(dLng / 2);
    final c = 2 * math.atan2(math.sqrt(a), math.sqrt(math.max(0.0, 1.0 - a)));
    return _earthRadiusMeters * c;
  }

  /// Builds a [RouteTrail] from pier-aware [segments] or flat [roadGeometry].
  factory RouteTrail.fromRoute({
    required List<RouteSegmentGeometry> segments,
    List<GeoPoint> roadGeometry = const [],
    List<GeoPoint> waypoints = const [],
    List<String> congestionSegments = const [],
    List<RoadRouteSegment> detailSegments = const [],
  }) {
    final allLatLng = <GeoPoint>[
      for (final s in segments) ...s.points,
      if (segments.isEmpty) ...roadGeometry,
    ];
    if (allLatLng.length < 2) {
      return RouteTrail.empty();
    }

    final refLat = allLatLng.fold<double>(0.0, (s, p) => s + p.lat) /
        allLatLng.length;
    final refLng = allLatLng.fold<double>(0.0, (s, p) => s + p.lng) /
        allLatLng.length;
    final cosRef = math.cos(refLat * math.pi / 180.0).clamp(0.1, 1.0);

    RouteTrailPoint projectGeo(GeoPoint p, double cumulativeMeters) {
      final dLat = (p.lat - refLat) * math.pi / 180.0;
      final dLng = (p.lng - refLng) * math.pi / 180.0;
      return RouteTrailPoint(
        lat: p.lat,
        lng: p.lng,
        eastMeters: _earthRadiusMeters * dLng * cosRef,
        northMeters: _earthRadiusMeters * dLat,
        cumulativeMeters: cumulativeMeters,
      );
    }

    final animatedLegs = <RouteTrailLeg>[];
    final estimatedLegs = <RouteTrailLeg>[];
    var totalAnimatedMeters = 0.0;

    if (segments.isNotEmpty) {
      final totalRoadSegs =
          segments.where((s) => !s.isEstimated && !s.isSea).length;
      var roadSegIdx = 0;
      var wpCursor = 0;
      for (var segIdx = 0; segIdx < segments.length; segIdx++) {
        final seg = segments[segIdx];
        if (seg.points.length < 2) continue;
        // Infer monotonic day number from destination waypoints when available.
        var dayNum = 1;
        if (waypoints.isNotEmpty) {
          final destPt = seg.points.last;
          var bestIdx = wpCursor;
          var bestDist = double.infinity;
          for (var wi = wpCursor; wi < waypoints.length; wi++) {
            final d = haversineMeters(
              destPt.lat,
              destPt.lng,
              waypoints[wi].lat,
              waypoints[wi].lng,
            );
            if (d < bestDist) {
              bestDist = d;
              bestIdx = wi;
            }
          }
          if (bestDist <= 15000.0) {
            wpCursor = bestIdx;
          } else {
            final toLower = seg.toName.trim().toLowerCase();
            if (toLower.isNotEmpty) {
              for (var wi = wpCursor; wi < waypoints.length; wi++) {
                final lbl = (waypoints[wi].label ?? '').trim().toLowerCase();
                if (lbl.isNotEmpty &&
                    (lbl == toLower || lbl.contains(toLower) || toLower.contains(lbl))) {
                  wpCursor = wi;
                  break;
                }
              }
            }
          }
          dayNum = waypoints[wpCursor].dayNumber ??
              _parseDayFromLabel(waypoints[wpCursor].label) ??
              (wpCursor + 1);
        }

        final detailMatch =
            segIdx < detailSegments.length ? detailSegments[segIdx] : null;
        final isUnroutedMode = detailMatch?.mode == 'unrouted';
        final mode = (seg.isEstimated || isUnroutedMode)
            ? RouteTrailMode.estimated
            : (seg.isSea ? RouteTrailMode.sea : RouteTrailMode.road);

        if (mode == RouteTrailMode.estimated) {
          var estCursor = 0.0;
          final pts = <RouteTrailPoint>[projectGeo(seg.points.first, 0.0)];
          for (var i = 1; i < seg.points.length; i++) {
            final prev = seg.points[i - 1];
            final cur = seg.points[i];
            estCursor += haversineMeters(prev.lat, prev.lng, cur.lat, cur.lng);
            pts.add(projectGeo(cur, estCursor));
          }
          estimatedLegs.add(
            RouteTrailLeg(
              dayNumber: dayNum,
              mode: RouteTrailMode.estimated,
              points: pts,
              startMeters: 0.0,
              endMeters: estCursor,
            ),
          );
          continue;
        }

        var legCongestion = const <String>[];
        if (mode == RouteTrailMode.road) {
          if (detailMatch != null && detailMatch.congestionSegments.isNotEmpty) {
            legCongestion = detailMatch.congestionSegments;
          } else if (congestionSegments.isNotEmpty && totalRoadSegs > 0) {
            if (totalRoadSegs == 1) {
              legCongestion = congestionSegments;
            } else {
              final startSlice =
                  (roadSegIdx * congestionSegments.length) ~/ totalRoadSegs;
              final endSlice =
                  ((roadSegIdx + 1) * congestionSegments.length) ~/ totalRoadSegs;
              if (endSlice > startSlice) {
                legCongestion = congestionSegments.sublist(startSlice, endSlice);
              } else if (roadSegIdx < congestionSegments.length) {
                legCongestion = [congestionSegments[roadSegIdx]];
              }
            }
          }
          roadSegIdx++;
        }

        final legStart = totalAnimatedMeters;
        final pts = <RouteTrailPoint>[projectGeo(seg.points.first, legStart)];
        for (var i = 1; i < seg.points.length; i++) {
          final prev = seg.points[i - 1];
          final cur = seg.points[i];
          totalAnimatedMeters +=
              haversineMeters(prev.lat, prev.lng, cur.lat, cur.lng);
          pts.add(projectGeo(cur, totalAnimatedMeters));
        }
        if (totalAnimatedMeters > legStart) {
          animatedLegs.add(
            RouteTrailLeg(
              dayNumber: dayNum,
              mode: mode,
              points: pts,
              startMeters: legStart,
              endMeters: totalAnimatedMeters,
              congestionLevels: legCongestion,
            ),
          );
        }
      }
    } else if (roadGeometry.length >= 2) {
      // Split flat road geometry across day waypoints if multi-day boundaries exist.
      final splitIndices = <({int index, int dayNumber})>[];
      if (waypoints.length >= 2) {
        var searchFrom = 0;
        for (var wi = 0; wi < waypoints.length; wi++) {
          final wp = waypoints[wi];
          final wpDay =
              wp.dayNumber ?? _parseDayFromLabel(wp.label) ?? (wi + 1);
          var bestIdx = searchFrom;
          var bestDist = double.infinity;
          for (var gi = searchFrom; gi < roadGeometry.length; gi++) {
            final d = haversineMeters(
              wp.lat,
              wp.lng,
              roadGeometry[gi].lat,
              roadGeometry[gi].lng,
            );
            if (d < bestDist) {
              bestDist = d;
              bestIdx = gi;
            }
          }
          searchFrom = bestIdx;
          if (wi > 0 && bestIdx > 0) {
            if (splitIndices.isEmpty || splitIndices.last.dayNumber != wpDay) {
              splitIndices.add((index: bestIdx, dayNumber: wpDay));
            }
          }
        }
      }

      if (splitIndices.isEmpty) {
        final pts = <RouteTrailPoint>[projectGeo(roadGeometry.first, 0.0)];
        for (var i = 1; i < roadGeometry.length; i++) {
          final prev = roadGeometry[i - 1];
          final cur = roadGeometry[i];
          totalAnimatedMeters +=
              haversineMeters(prev.lat, prev.lng, cur.lat, cur.lng);
          pts.add(projectGeo(cur, totalAnimatedMeters));
        }
        animatedLegs.add(
          RouteTrailLeg(
            dayNumber: 1,
            mode: RouteTrailMode.road,
            points: pts,
            startMeters: 0.0,
            endMeters: totalAnimatedMeters,
            congestionLevels: congestionSegments,
          ),
        );
      } else {
        var rangeStart = 0;
        for (final split in splitIndices) {
          final rangeEnd =
              split.index.clamp(rangeStart + 1, roadGeometry.length - 1);
          final sub = roadGeometry.sublist(rangeStart, rangeEnd + 1);
          if (sub.length >= 2) {
            final legStart = totalAnimatedMeters;
            final pts = <RouteTrailPoint>[projectGeo(sub.first, legStart)];
            for (var i = 1; i < sub.length; i++) {
              totalAnimatedMeters += haversineMeters(
                sub[i - 1].lat,
                sub[i - 1].lng,
                sub[i].lat,
                sub[i].lng,
              );
              pts.add(projectGeo(sub[i], totalAnimatedMeters));
            }
            animatedLegs.add(
              RouteTrailLeg(
                dayNumber: split.dayNumber,
                mode: RouteTrailMode.road,
                points: pts,
                startMeters: legStart,
                endMeters: totalAnimatedMeters,
              ),
            );
          }
          rangeStart = rangeEnd;
        }
        if (rangeStart < roadGeometry.length - 1) {
          final sub = roadGeometry.sublist(rangeStart);
          final legStart = totalAnimatedMeters;
          final pts = <RouteTrailPoint>[projectGeo(sub.first, legStart)];
          for (var i = 1; i < sub.length; i++) {
            totalAnimatedMeters += haversineMeters(
              sub[i - 1].lat,
              sub[i - 1].lng,
              sub[i].lat,
              sub[i].lng,
            );
            pts.add(projectGeo(sub[i], totalAnimatedMeters));
          }
          final lastDay = waypoints.isNotEmpty
              ? (waypoints.last.dayNumber ??
                  _parseDayFromLabel(waypoints.last.label) ??
                  (animatedLegs.isNotEmpty ? animatedLegs.last.dayNumber : 1))
              : (animatedLegs.isNotEmpty ? animatedLegs.last.dayNumber : 1);
          animatedLegs.add(
            RouteTrailLeg(
              dayNumber: lastDay,
              mode: RouteTrailMode.road,
              points: pts,
              startMeters: legStart,
              endMeters: totalAnimatedMeters,
            ),
          );
        }
      }
    }

    return RouteTrail(
      animatedLegs: List<RouteTrailLeg>.unmodifiable(animatedLegs),
      estimatedLegs: List<RouteTrailLeg>.unmodifiable(estimatedLegs),
      totalAnimatedMeters: totalAnimatedMeters,
      refLat: refLat,
      refLng: refLng,
    );
  }

  static int? _parseDayFromLabel(String? label) {
    if (label == null) return null;
    final match = RegExp(r'^D(\d+)').firstMatch(label.trim());
    if (match == null) return null;
    return int.tryParse(match.group(1)!);
  }

  /// Active animated leg at [distanceMeters]. Never returns an estimated leg.
  RouteTrailLeg? legAt(double distanceMeters) {
    if (!hasAnimatedTrail) return null;
    final clamped = distanceMeters.clamp(0.0, totalAnimatedMeters);
    for (final leg in animatedLegs) {
      if (clamped <= leg.endMeters + 1e-6) return leg;
    }
    return animatedLegs.last;
  }

  /// Interpolated geographic + metric position at [distanceMeters].
  RouteTrailPoint? pointAt(double distanceMeters) {
    if (!hasAnimatedTrail) return null;
    final clamped = distanceMeters.clamp(0.0, totalAnimatedMeters);
    final leg = legAt(clamped);
    if (leg == null || leg.points.isEmpty) return null;
    if (leg.points.length == 1) return leg.points.first;
    final pts = leg.points;
    for (var i = 1; i < pts.length; i++) {
      final a = pts[i - 1];
      final b = pts[i];
      if (clamped <= b.cumulativeMeters + 1e-6) {
        final span = b.cumulativeMeters - a.cumulativeMeters;
        final t = span <= 1e-6
            ? 0.0
            : ((clamped - a.cumulativeMeters) / span).clamp(0.0, 1.0);
        return RouteTrailPoint(
          lat: a.lat + (b.lat - a.lat) * t,
          lng: a.lng + (b.lng - a.lng) * t,
          eastMeters: a.eastMeters + (b.eastMeters - a.eastMeters) * t,
          northMeters: a.northMeters + (b.northMeters - a.northMeters) * t,
          cumulativeMeters: clamped,
        );
      }
    }
    return pts.last;
  }

  /// Forward travel bearing in radians clockwise from true North (`0` = North,
  /// `pi / 2` = East, `pi` = South, `-pi / 2` = West) at [distanceMeters].
  double bearingAt(double distanceMeters) {
    if (!hasAnimatedTrail) return 0.0;
    final clamped = distanceMeters.clamp(0.0, totalAnimatedMeters);
    final leg = legAt(clamped);
    if (leg == null || leg.points.length < 2) return 0.0;
    final pts = leg.points;
    for (var i = 1; i < pts.length; i++) {
      final a = pts[i - 1];
      final b = pts[i];
      if (clamped <= b.cumulativeMeters + 1e-6 || i == pts.length - 1) {
        final dx = b.eastMeters - a.eastMeters;
        final dyNorth = b.northMeters - a.northMeters;
        if (dx.abs() > 1e-6 || dyNorth.abs() > 1e-6) {
          return math.atan2(dx, dyNorth);
        }
      }
    }
    return 0.0;
  }

  /// Douglas-Peucker polyline simplification preserving start, end, and vertices
  /// deviating more than [tolerance] units.
  static List<T> douglasPeucker<T>(
    List<T> points,
    double tolerance,
    Offset Function(T) toXY,
  ) {
    if (points.length <= 2 || tolerance <= 0) {
      return List<T>.from(points);
    }
    final keep = List<bool>.filled(points.length, false);
    keep[0] = true;
    keep[points.length - 1] = true;

    final stack = <(int, int)>[(0, points.length - 1)];
    while (stack.isNotEmpty) {
      final (start, end) = stack.removeLast();
      if (end - start <= 1) continue;
      final a = toXY(points[start]);
      final b = toXY(points[end]);
      var maxDist = -1.0;
      var maxIdx = -1;
      for (var i = start + 1; i < end; i++) {
        final d = _perpDistance(toXY(points[i]), a, b);
        if (d > maxDist) {
          maxDist = d;
          maxIdx = i;
        }
      }
      if (maxDist > tolerance && maxIdx >= 0) {
        keep[maxIdx] = true;
        stack.add((start, maxIdx));
        stack.add((maxIdx, end));
      }
    }

    return [
      for (var i = 0; i < points.length; i++)
        if (keep[i]) points[i],
    ];
  }

  static double _perpDistance(Offset p, Offset a, Offset b) {
    final dx = b.dx - a.dx;
    final dy = b.dy - a.dy;
    final lenSq = dx * dx + dy * dy;
    if (lenSq <= 1e-9) return (p - a).distance;
    final num = ((p.dx - a.dx) * dy - (p.dy - a.dy) * dx).abs();
    return num / math.sqrt(lenSq);
  }

  /// Simplifies projected screen vertices within ~[tolerancePx] pixels while
  /// preserving sharp turns and endpoints.
  static List<Offset> simplifyScreenPolyline(
    List<Offset> points, {
    double tolerancePx = 1.0,
  }) {
    if (points.length <= 4) return points;
    return douglasPeucker<Offset>(points, tolerancePx, (o) => o);
  }

  /// Extracts a trimmed sub-path of [fullPath] for [progress] in `0.0..1.0`
  /// using Flutter's [ui.PathMetrics].
  static Path trimmedPath(Path fullPath, double progress) {
    final clamped = progress.clamp(0.0, 1.0);
    if (clamped <= 0.0) return Path();
    final metrics = fullPath.computeMetrics().toList();
    if (metrics.isEmpty) return Path();
    final totalLength = metrics.fold<double>(0.0, (s, m) => s + m.length);
    if (totalLength <= 0.0) return Path();

    var remaining = totalLength * clamped;
    final out = Path();
    for (final metric in metrics) {
      if (remaining <= 0.0) break;
      final take = math.min(metric.length, remaining);
      out.addPath(metric.extractPath(0.0, take), Offset.zero);
      remaining -= take;
    }
    return out;
  }
}

/// Controls sequential per-day playback of a [RouteTrail] (~1.2s per 10km,
/// clamped 2..12s, easeInOut travel + ~300ms pause at day boundaries), honoring
/// reduced-motion accessibility and settling at completion until replayed.
class RouteTrailController extends ChangeNotifier {
  final TickerProvider vsync;
  final VoidCallback? onSettled;

  late RouteTrail _trail;
  late AnimationController _animController;
  Animatable<double>? _timeline;
  List<({int dayNumber, double endDistFraction, double timelineEnd})>
      _dayTargets = const [];
  bool _disableAnimations = false;
  bool _disposed = false;

  RouteTrailController({
    required this.vsync,
    required RouteTrail trail,
    bool disableAnimations = false,
    bool autoPlay = true,
    this.onSettled,
  }) {
    _trail = trail;
    _disableAnimations = disableAnimations;
    _animController = AnimationController(vsync: vsync)
      ..addListener(_onTick)
      ..addStatusListener(_onStatus);
    _rebuildTimeline();
    if (_trail.hasAnimatedTrail) {
      if (_disableAnimations) {
        _animController.value = 1.0;
      } else if (autoPlay) {
        play();
      }
    } else {
      _animController.value = 1.0;
    }
  }

  RouteTrail get trail => _trail;
  bool get hasAnimatedTrail => _trail.hasAnimatedTrail;
  bool get disableAnimations => _disableAnimations;

  /// Linear distance fraction `0.0..1.0` along animated legs only.
  double get progress {
    if (!_trail.hasAnimatedTrail || _disableAnimations) return 1.0;
    if (_timeline == null) return _animController.value.clamp(0.0, 1.0);
    return _timeline!.transform(_animController.value).clamp(0.0, 1.0);
  }

  double get currentDistanceMeters => _trail.totalAnimatedMeters * progress;

  RouteTrailLeg? get currentLeg =>
      _trail.hasAnimatedTrail ? _trail.legAt(currentDistanceMeters) : null;

  RouteTrailPoint? get currentPoint =>
      _trail.hasAnimatedTrail ? _trail.pointAt(currentDistanceMeters) : null;

  double get currentBearingRadians =>
      _trail.hasAnimatedTrail ? _trail.bearingAt(currentDistanceMeters) : 0.0;

  int get activeDayNumber => currentLeg?.dayNumber ?? 1;

  bool get isPlaying => _animController.isAnimating;

  bool get isSettled =>
      !_trail.hasAnimatedTrail ||
      _disableAnimations ||
      _animController.status == AnimationStatus.completed ||
      progress >= 0.9999;

  void _rebuildTimeline() {
    if (!_trail.hasAnimatedTrail) {
      _timeline = null;
      _dayTargets = const [];
      _animController.duration = const Duration(milliseconds: 2000);
      return;
    }

    // Group animated legs sequentially by day.
    final dayGroups = <({int dayNumber, double startMeters, double endMeters})>[];
    for (final leg in _trail.animatedLegs) {
      if (dayGroups.isNotEmpty && dayGroups.last.dayNumber == leg.dayNumber) {
        final prev = dayGroups.removeLast();
        dayGroups.add((
          dayNumber: prev.dayNumber,
          startMeters: prev.startMeters,
          endMeters: leg.endMeters,
        ));
      } else {
        dayGroups.add((
          dayNumber: leg.dayNumber,
          startMeters: leg.startMeters,
          endMeters: leg.endMeters,
        ));
      }
    }

    final travelMs =
        (_trail.totalAnimatedKm / 10.0 * 1200.0).round().clamp(2000, 12000);
    const pauseMs = 300;
    final totalPauses = math.max(0, dayGroups.length - 1);
    final totalMs = travelMs + totalPauses * pauseMs;
    _animController.duration = Duration(milliseconds: totalMs);

    final totalMeters = _trail.totalAnimatedMeters;
    final seqItems = <TweenSequenceItem<double>>[];
    final targets =
        <({int dayNumber, double endDistFraction, double timelineEnd})>[];
    var timelineCursor = 0.0;

    for (var i = 0; i < dayGroups.length; i++) {
      final group = dayGroups[i];
      final f0 = (group.startMeters / totalMeters).clamp(0.0, 1.0);
      final f1 = (group.endMeters / totalMeters).clamp(0.0, 1.0);
      final double segWeight =
          math.max(1.0, travelMs * math.max(0.001, f1 - f0)).toDouble();
      seqItems.add(
        TweenSequenceItem<double>(
          tween: Tween<double>(begin: f0, end: f1)
              .chain(CurveTween(curve: Curves.easeInOut)),
          weight: segWeight,
        ),
      );
      timelineCursor += segWeight / totalMs;
      targets.add((
        dayNumber: group.dayNumber,
        endDistFraction: f1,
        timelineEnd: timelineCursor.clamp(0.0, 1.0),
      ));

      if (i < dayGroups.length - 1) {
        seqItems.add(
          TweenSequenceItem<double>(
            tween: ConstantTween<double>(f1),
            weight: pauseMs.toDouble(),
          ),
        );
        timelineCursor += pauseMs / totalMs;
      }
    }

    _timeline = seqItems.isEmpty ? null : TweenSequence<double>(seqItems);
    _dayTargets = targets;
  }

  void updateTrail(
    RouteTrail newTrail, {
    bool? disableAnimations,
    bool autoPlay = true,
  }) {
    final nextDisable = disableAnimations ?? _disableAnimations;
    final sameMeters =
        (newTrail.totalAnimatedMeters - _trail.totalAnimatedMeters).abs() < 1.0 &&
            newTrail.animatedLegs.length == _trail.animatedLegs.length &&
            newTrail.estimatedLegs.length == _trail.estimatedLegs.length;
    if (sameMeters && nextDisable == _disableAnimations) return;

    _trail = newTrail;
    _disableAnimations = nextDisable;
    _rebuildTimeline();
    if (!_trail.hasAnimatedTrail || _disableAnimations) {
      _animController.stop();
      _animController.value = 1.0;
    } else if (autoPlay) {
      _animController.forward(from: 0.0);
    } else {
      _animController.value = 1.0;
    }
    notifyListeners();
  }

  void play() {
    if (!_trail.hasAnimatedTrail || _disableAnimations) {
      _animController.value = 1.0;
      notifyListeners();
      return;
    }
    if (isSettled) {
      _animController.forward(from: 0.0);
    } else {
      _animController.forward();
    }
    notifyListeners();
  }

  void pause() {
    if (_animController.isAnimating) {
      _animController.stop();
      notifyListeners();
    }
  }

  void replay() {
    if (!_trail.hasAnimatedTrail || _disableAnimations) {
      _animController.value = 1.0;
      notifyListeners();
      return;
    }
    _animController.forward(from: 0.0);
    notifyListeners();
  }

  /// Jumps directly to the end of [dayNumber]'s trail leg and pauses there.
  void seekToDay(int dayNumber) {
    if (!_trail.hasAnimatedTrail) return;
    _animController.stop();
    for (final target in _dayTargets) {
      if (target.dayNumber == dayNumber) {
        _animController.value = target.timelineEnd;
        notifyListeners();
        return;
      }
    }
    if (_dayTargets.isNotEmpty) {
      _animController.value = _dayTargets.last.timelineEnd;
      notifyListeners();
    }
  }

  void _onTick() {
    if (_disposed) return;
    notifyListeners();
  }

  void _onStatus(AnimationStatus status) {
    if (_disposed) return;
    if (status == AnimationStatus.completed) {
      notifyListeners();
      onSettled?.call();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _animController.removeListener(_onTick);
    _animController.removeStatusListener(_onStatus);
    _animController.dispose();
    super.dispose();
  }
}

/// CustomPainter rendering per-day road trails, dashed ocean-blue sea crossings,
/// ~15% faded drawing tails via linear gradient shader, and static dashed grey
/// estimated connectors (never animated, never hosting a vehicle sprite).
class RouteTrailPainter extends CustomPainter {
  final RouteTrail trail;
  final List<(RouteTrailLeg, List<Offset>)> animatedProjectedLegs;
  final List<(RouteTrailLeg, List<Offset>)> estimatedProjectedLegs;
  final double currentDistanceMeters;
  final bool isSettled;
  final bool isDark;
  final int? highlightedDayNumber;
  final bool showTrafficColors;

  const RouteTrailPainter({
    required this.trail,
    required this.animatedProjectedLegs,
    required this.estimatedProjectedLegs,
    required this.currentDistanceMeters,
    required this.isSettled,
    required this.isDark,
    this.highlightedDayNumber,
    this.showTrafficColors = false,
  });

  @override
  void paint(Canvas canvas, Size size) {
    // 1. Estimated (unrouted) legs are ALWAYS drawn statically dashed grey.
    final baseEstColor = RouteTrail.colorForDay(
      1,
      RouteTrailMode.estimated,
      isDark: isDark,
    );
    for (final (leg, pts) in estimatedProjectedLegs) {
      final safePts = _sanitizeScreenPoints(pts);
      if (safePts.length < 2) continue;
      final dimmed = highlightedDayNumber != null &&
          leg.dayNumber != highlightedDayNumber;
      final estPaint = Paint()
        ..color = dimmed ? baseEstColor.withValues(alpha: 0.24) : baseEstColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = dimmed ? 1.8 : 2.4
        ..strokeCap = StrokeCap.round;
      _drawDashedScreenPolyline(canvas, safePts, estPaint, dash: 8.0, gap: 7.0);
    }

    if (animatedProjectedLegs.isEmpty) return;

    // 2. Subtle ghost track while actively animating so user sees full corridor.
    if (!isSettled) {
      final ghostPaint = Paint()
        ..color = Colors.white.withValues(alpha: isDark ? 0.22 : 0.55)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 6.0
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round;
      for (final (_, rawPts) in animatedProjectedLegs) {
        final safeRaw = _sanitizeScreenPoints(rawPts);
        final pts = RouteTrail.simplifyScreenPolyline(safeRaw, tolerancePx: 1.0);
        if (pts.length < 2) continue;
        canvas.drawPath(_buildPath(pts), ghostPaint);
      }
    }

    // 3. Draw each animated road or sea leg up to currentDistanceMeters,
    // drawing non-highlighted days underneath when a day filter is active.
    final effectiveMeters =
        isSettled ? trail.totalAnimatedMeters : currentDistanceMeters;
    final orderedLegs = highlightedDayNumber == null
        ? animatedProjectedLegs
        : [
            for (final entry in animatedProjectedLegs)
              if (entry.$1.dayNumber != highlightedDayNumber) entry,
            for (final entry in animatedProjectedLegs)
              if (entry.$1.dayNumber == highlightedDayNumber) entry,
          ];

    for (final (leg, rawPts) in orderedLegs) {
      final safeRaw = _sanitizeScreenPoints(rawPts);
      final pts = RouteTrail.simplifyScreenPolyline(safeRaw, tolerancePx: 1.0);
      if (pts.length < 2) continue;
      final legLen = leg.lengthMeters;
      if (legLen <= 0.0 || effectiveMeters < leg.startMeters) continue;

      final legProgress = effectiveMeters >= leg.endMeters
          ? 1.0
          : ((effectiveMeters - leg.startMeters) / legLen).clamp(0.0, 1.0);
      if (legProgress <= 0.0) continue;

      final fullPath = _buildPath(pts);
      final revealedPath = legProgress >= 0.9999
          ? fullPath
          : RouteTrail.trimmedPath(fullPath, legProgress);
      final isDimmed = highlightedDayNumber != null &&
          leg.dayNumber != highlightedDayNumber;
      final rawColor =
          RouteTrail.colorForDay(leg.dayNumber, leg.mode, isDark: isDark);
      final legColor =
          isDimmed ? rawColor.withValues(alpha: 0.24) : rawColor;

      if (leg.mode == RouteTrailMode.sea) {
        final casingPaint = Paint()
          ..color = Colors.white.withValues(alpha: isDimmed ? 0.30 : 0.88)
          ..style = PaintingStyle.stroke
          ..strokeWidth = isDimmed ? 4.2 : 6.2
          ..strokeCap = StrokeCap.round;
        final seaPaint = Paint()
          ..color = legColor
          ..style = PaintingStyle.stroke
          ..strokeWidth = isDimmed ? 2.6 : 3.8
          ..strokeCap = StrokeCap.round;
        _drawDashedPath(canvas, revealedPath, casingPaint, dash: 10.0, gap: 6.0);
        _drawDashedPath(canvas, revealedPath, seaPaint, dash: 10.0, gap: 6.0);
        continue;
      }

      // White outer casing for legible contrast over any tile style.
      canvas.drawPath(
        revealedPath,
        Paint()
          ..color = Colors.white.withValues(alpha: isDimmed ? 0.35 : 0.90)
          ..style = PaintingStyle.stroke
          ..strokeWidth = isDimmed ? 4.4 : 6.8
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round,
      );

      final hasTrafficColors = showTrafficColors &&
          !isDimmed &&
          leg.congestionLevels.any((c) => c != 'unknown' && c.isNotEmpty);

      if (isSettled || legProgress >= 0.9999 || isDimmed) {
        if (hasTrafficColors) {
          _drawCongestionSpans(
            canvas,
            revealedPath,
            levels: leg.congestionLevels,
            fallbackColor: legColor,
            strokeWidth: 4.2,
          );
        } else {
          canvas.drawPath(
            revealedPath,
            Paint()
              ..color = legColor
              ..style = PaintingStyle.stroke
              ..strokeWidth = isDimmed ? 2.6 : 4.2
              ..strokeCap = StrokeCap.round
              ..strokeJoin = StrokeJoin.round,
          );
        }
      } else {
        // Active drawing head: solid settled core + ~15% faded leading tail.
        final metrics = revealedPath.computeMetrics().toList();
        final revealedLen = metrics.fold<double>(0.0, (s, m) => s + m.length);
        final tailSpan = revealedLen * 0.15;
        final solidEnd = math.max(0.0, revealedLen - tailSpan);

        if (solidEnd > 0.5) {
          final corePath = _extractSpan(metrics, 0.0, solidEnd);
          canvas.drawPath(
            corePath,
            Paint()
              ..color = legColor
              ..style = PaintingStyle.stroke
              ..strokeWidth = 4.2
              ..strokeCap = StrokeCap.round
              ..strokeJoin = StrokeJoin.round,
          );
        }

        if (tailSpan > 1.0 && metrics.isNotEmpty) {
          final tailPath = _extractSpan(metrics, solidEnd, revealedLen);
          final startTangent = _tangentAt(metrics, solidEnd);
          final endTangent = _tangentAt(metrics, revealedLen);
          final pA = startTangent ?? pts.first;
          final pB = endTangent ?? pts.last;
          final shader = (pB - pA).distance > 1.0
              ? ui.Gradient.linear(
                  pA,
                  pB,
                  [
                    legColor.withValues(alpha: 0.45),
                    legColor.withValues(alpha: 1.0),
                  ],
                )
              : null;
          canvas.drawPath(
            tailPath,
            Paint()
              ..color = legColor
              ..shader = shader
              ..style = PaintingStyle.stroke
              ..strokeWidth = 4.6
              ..strokeCap = StrokeCap.round
              ..strokeJoin = StrokeJoin.round,
          );
        }
      }
    }
  }

  static Path _buildPath(List<Offset> pts) {
    final p = Path()..moveTo(pts.first.dx, pts.first.dy);
    for (var i = 1; i < pts.length; i++) {
      p.lineTo(pts[i].dx, pts[i].dy);
    }
    return p;
  }

  static Path _extractSpan(
    List<ui.PathMetric> metrics,
    double start,
    double end,
  ) {
    final out = Path();
    var cursor = 0.0;
    for (final m in metrics) {
      final len = m.length;
      final segStart = math.max(0.0, start - cursor);
      final segEnd = math.min(len, end - cursor);
      if (segEnd > segStart) {
        out.addPath(m.extractPath(segStart, segEnd), Offset.zero);
      }
      cursor += len;
    }
    return out;
  }

  static Offset? _tangentAt(List<ui.PathMetric> metrics, double distance) {
    var remaining = distance;
    for (final m in metrics) {
      if (remaining <= m.length + 1e-6) {
        return m
            .getTangentForOffset(remaining.clamp(0.0, m.length))
            ?.position;
      }
      remaining -= m.length;
    }
    return metrics.isEmpty
        ? null
        : metrics.last.getTangentForOffset(metrics.last.length)?.position;
  }

  static void _drawDashedScreenPolyline(
    Canvas canvas,
    List<Offset> points,
    Paint paint, {
    double dash = 8.0,
    double gap = 6.0,
  }) {
    for (var i = 1; i < points.length; i++) {
      final a = points[i - 1];
      final b = points[i];
      final length = (b - a).distance;
      if (length <= 0) continue;
      final dir = (b - a) / length;
      for (var d = 0.0; d < length; d += dash + gap) {
        final end = math.min(d + dash, length);
        canvas.drawLine(a + dir * d, a + dir * end, paint);
      }
    }
  }

  static List<Offset> _sanitizeScreenPoints(List<Offset> pts) {
    return [
      for (final p in pts)
        if (p.dx.isFinite &&
            p.dy.isFinite &&
            p.dx.abs() < 1e6 &&
            p.dy.abs() < 1e6)
          p,
    ];
  }

  static void _drawDashedPath(
    Canvas canvas,
    Path path,
    Paint paint, {
    double dash = 10.0,
    double gap = 6.0,
  }) {
    for (final metric in path.computeMetrics()) {
      final len = metric.length;
      if (!len.isFinite || len <= 0.0) continue;
      final step = math.max(dash + gap, len / 400.0);
      final effectiveDash = math.min(dash, step * 0.65);
      for (var d = 0.0; d < len; d += step) {
        final end = math.min(d + effectiveDash, len);
        if (end > d) {
          canvas.drawPath(metric.extractPath(d, end), paint);
        }
      }
    }
  }

  static void _drawCongestionSpans(
    Canvas canvas,
    Path path, {
    required List<String> levels,
    required Color fallbackColor,
    required double strokeWidth,
  }) {
    if (levels.isEmpty) return;
    final metrics = path.computeMetrics().toList();
    final totalLen = metrics.fold<double>(0.0, (sum, m) => sum + m.length);
    if (!totalLen.isFinite || totalLen <= 0.5) return;

    final n = levels.length;
    var i = 0;
    while (i < n) {
      final level = levels[i];
      var j = i + 1;
      while (j < n && levels[j] == level) {
        j++;
      }
      final startDist = (i / n) * totalLen;
      final endDist = (j / n) * totalLen;
      final spanPath = _extractSpan(metrics, startDist, endDist);
      canvas.drawPath(
        spanPath,
        Paint()
          ..color = RouteTrail.colorForCongestion(level, fallback: fallbackColor)
          ..style = PaintingStyle.stroke
          ..strokeWidth = strokeWidth
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round,
      );
      i = j;
    }
  }

  @override
  bool shouldRepaint(covariant RouteTrailPainter oldDelegate) =>
      oldDelegate.currentDistanceMeters != currentDistanceMeters ||
      oldDelegate.isSettled != isSettled ||
      oldDelegate.isDark != isDark ||
      oldDelegate.highlightedDayNumber != highlightedDayNumber ||
      oldDelegate.showTrafficColors != showTrafficColors ||
      oldDelegate.trail != trail ||
      oldDelegate.animatedProjectedLegs != animatedProjectedLegs ||
      oldDelegate.estimatedProjectedLegs != estimatedProjectedLegs;
}
