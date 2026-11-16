import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:lakbay_travel/services/route_optimizer.dart';

double _bruteForceOrderCost(
  List<List<double>> costs, {
  required bool fixedStart,
  required bool roundtrip,
}) {
  final n = costs.length;
  var best = double.infinity;

  void permute(List<int> current, int startIdx) {
    if (startIdx == n) {
      final c = RouteOptimizer.orderCost(costs, current, roundtrip: roundtrip);
      if (c < best) best = c;
      return;
    }
    for (var i = startIdx; i < n; i++) {
      final tmp = current[startIdx];
      current[startIdx] = current[i];
      current[i] = tmp;
      permute(current, startIdx + 1);
      current[i] = current[startIdx];
      current[startIdx] = tmp;
    }
  }

  final initial = List<int>.generate(n, (i) => i);
  permute(initial, (fixedStart || roundtrip) ? 1 : 0);
  return best;
}

double _bruteForceMinMaxDayLoad(
  List<RouteStopInput> stops,
  List<double> legHours,
  int days,
) {
  final s = stops.length;
  var bestMax = double.infinity;

  void partition(int start, int daysLeft, double curMax, int curViolations) {
    if (daysLeft == 1) {
      var viol = curViolations;
      for (var i = start; i < s - 1; i++) {
        if (stops[i].forcesDayEnd) viol++;
      }
      if (viol > 0) return;
      var load = 0.0;
      if (start > 0) load += legHours[start - 1];
      for (var i = start; i < s; i++) {
        load += stops[i].visitHours;
        if (i < s - 1) load += legHours[i];
      }
      final m = math.max(curMax, load);
      if (m < bestMax) bestMax = m;
      return;
    }

    for (var end = start; end <= s - daysLeft; end++) {
      var viol = curViolations;
      for (var i = start; i < end; i++) {
        if (stops[i].forcesDayEnd) viol++;
      }
      if (viol > 0) continue;
      var load = 0.0;
      if (start > 0) load += legHours[start - 1];
      for (var i = start; i <= end; i++) {
        load += stops[i].visitHours;
        if (i < end) load += legHours[i];
      }
      partition(end + 1, daysLeft - 1, math.max(curMax, load), viol);
    }
  }

  partition(0, days, 0.0, 0);
  return bestMax;
}

void main() {
  group('RouteOptimizer Held-Karp exact & heuristic orderings', () {
    test('Held-Karp matches brute-force minimum for n <= 8 across modes', () {
      final optimizer = RouteOptimizer();
      final points = const [
        GeoCoord(lat: 7.0707, lng: 125.6096),
        GeoCoord(lat: 7.1854, lng: 125.4169),
        GeoCoord(lat: 7.0088, lng: 125.3992),
        GeoCoord(lat: 7.3476, lng: 126.1514),
        GeoCoord(lat: 6.9487, lng: 126.2542),
        GeoCoord(lat: 6.7755, lng: 125.3439),
        GeoCoord(lat: 7.4411, lng: 125.7999),
      ];
      final costs = optimizer.buildCostMatrix(points).orderingCosts;

      for (final fixedStart in [false, true]) {
        for (final roundtrip in [false, true]) {
          final order = optimizer.exactOrder(
            costs,
            fixedStart: fixedStart,
            roundtrip: roundtrip,
          );
          expect(List<int>.from(order)..sort(), List<int>.generate(points.length, (i) => i));
          if (fixedStart || roundtrip) {
            expect(order.first, 0);
          }
          final exactCost = RouteOptimizer.orderCost(
            costs,
            order,
            roundtrip: roundtrip,
          );
          final bruteCost = _bruteForceOrderCost(
            costs,
            fixedStart: fixedStart,
            roundtrip: roundtrip,
          );
          expect(exactCost, closeTo(bruteCost, 1e-6));
        }
      }
    });

    test('exactOrder handles asymmetric one-way costs and preserves tiebreak order', () {
      final optimizer = RouteOptimizer();
      final asymmetric = [
        [0.0, 9.0, 9.0, 1.0],
        [1.0, 0.0, 9.0, 9.0],
        [9.0, 1.0, 0.0, 9.0],
        [9.0, 9.0, 1.0, 0.0],
      ];
      expect(
        optimizer.exactOrder(asymmetric, fixedStart: true, roundtrip: true),
        [0, 3, 2, 1],
      );

      final uniform = List<List<double>>.generate(
        5,
        (i) => List<double>.generate(5, (j) => i == j ? 0.0 : 1.0),
      );
      expect(
        optimizer.exactOrder(uniform, fixedStart: false, roundtrip: false),
        [0, 1, 2, 3, 4],
      );
    });

    test('Multi-start NN + 2-opt + Or-opt is within 5% of exact on n = 11', () {
      final optimizer = RouteOptimizer();
      final points = const [
        GeoCoord(lat: 7.0707, lng: 125.6096),
        GeoCoord(lat: 7.1854, lng: 125.4169),
        GeoCoord(lat: 7.0088, lng: 125.3992),
        GeoCoord(lat: 6.9487, lng: 126.2542),
        GeoCoord(lat: 7.3476, lng: 126.1514),
        GeoCoord(lat: 7.3636, lng: 125.9494),
        GeoCoord(lat: 6.5361, lng: 125.4693),
        GeoCoord(lat: 6.9051, lng: 125.3465),
        GeoCoord(lat: 7.4411, lng: 125.7999),
        GeoCoord(lat: 7.2699, lng: 125.6805),
        GeoCoord(lat: 6.2693, lng: 126.1930),
      ];
      final costs = optimizer.buildCostMatrix(points).orderingCosts;

      final exact = optimizer.exactOrder(
        costs,
        fixedStart: true,
        roundtrip: true,
      );
      final heuristic = optimizer.nearestNeighborTwoOptOrOpt(
        costs,
        fixedStart: true,
        roundtrip: true,
      );

      expect(heuristic.first, 0);
      expect(List<int>.from(heuristic)..sort(), List<int>.generate(11, (i) => i));

      final exactCost = RouteOptimizer.orderCost(costs, exact, roundtrip: true);
      final heuristicCost = RouteOptimizer.orderCost(
        costs,
        heuristic,
        roundtrip: true,
      );
      expect(heuristicCost, lessThanOrEqualTo(exactCost * 1.05));
    });
  });

  group('RouteOptimizer linear-partition day planner & constraints', () {
    test('Every picked stop appears once across D < stops, D == stops, and D > stops', () {
      final optimizer = RouteOptimizer();
      final stops = const [
        RouteStopInput(
          id: 's1',
          name: 'Stop 1',
          lat: 7.0707,
          lng: 125.6096,
          stayDurationType: 'short',
        ),
        RouteStopInput(
          id: 's2',
          name: 'Stop 2',
          lat: 7.1854,
          lng: 125.4169,
          stayDurationType: 'half_day',
        ),
        RouteStopInput(
          id: 's3',
          name: 'Stop 3',
          lat: 7.0088,
          lng: 125.3992,
          stayDurationType: 'full_day',
        ),
        RouteStopInput(
          id: 's4',
          name: 'Stop 4',
          lat: 6.9487,
          lng: 126.2542,
          stayDurationType: 'overnight',
        ),
        RouteStopInput(
          id: 's5',
          name: 'Stop 5',
          lat: 6.9875,
          lng: 125.2708,
          stayDurationType: 'multi_day',
        ),
      ];

      for (final d in [2, 3, 5, 8]) {
        final plan = optimizer.planRoute(stops: stops, days: d);
        expect(plan.days.length, d);
        final flattenedIds = [
          for (final day in plan.days)
            for (final stop in day.stops) stop.id,
        ];
        expect(flattenedIds.length, stops.length);
        expect(flattenedIds.toSet(), {'s1', 's2', 's3', 's4', 's5'});

        if (d > stops.length) {
          final restDays = plan.days.where((day) => day.isContinuationDay).toList();
          expect(restDays.length, d - stops.length);
          expect(
            restDays.any(
              (day) => day.continuationOfStop?.id == 's5',
            ),
            isTrue,
          );
        }
      }
    });

    test('Linear-Partition DP achieves brute-force minimal max day load & respects overnight end', () {
      final optimizer = RouteOptimizer();
      final stops = const [
        RouteStopInput(
          id: 'a',
          name: 'Park',
          lat: 7.07,
          lng: 125.61,
          stayDurationType: 'short',
        ),
        RouteStopInput(
          id: 'b',
          name: 'Eagle',
          lat: 7.18,
          lng: 125.42,
          stayDurationType: 'half_day',
        ),
        RouteStopInput(
          id: 'c',
          name: 'Beach',
          lat: 7.07,
          lng: 125.71,
          stayDurationType: 'overnight',
        ),
        RouteStopInput(
          id: 'd',
          name: 'Museum',
          lat: 7.08,
          lng: 125.60,
          stayDurationType: 'short',
        ),
        RouteStopInput(
          id: 'e',
          name: 'Waterpark',
          lat: 7.09,
          lng: 125.67,
          stayDurationType: 'full_day',
        ),
      ];
      final legHours = [0.5, 1.0, 1.0, 0.4];
      final result = optimizer.planDays(
        orderedStops: stops,
        days: 3,
        pace: TripPace.balanced,
        legTransitHours: legHours,
      );

      final dpMaxLoad = result.days
          .map((day) => day.totalHours)
          .reduce(math.max);
      final bruteMaxLoad = _bruteForceMinMaxDayLoad(stops, legHours, 3);
      expect(dpMaxLoad, closeTo(bruteMaxLoad, 1e-6));

      // The overnight stop ('c') MUST end its day instead of chaining into 'd'.
      final overnightDay = result.days.firstWhere(
        (day) => day.stops.any((s) => s.id == 'c'),
      );
      expect(overnightDay.stops.last.id, 'c');
    });

    test('Impossible overnight packing emits helpful warning', () {
      final optimizer = RouteOptimizer();
      final stops = const [
        RouteStopInput(
          id: 'o1',
          name: 'Overnight 1',
          lat: 7.0,
          lng: 125.6,
          stayDurationType: 'overnight',
        ),
        RouteStopInput(
          id: 'o2',
          name: 'Overnight 2',
          lat: 7.1,
          lng: 125.7,
          stayDurationType: 'overnight',
        ),
        RouteStopInput(
          id: 'o3',
          name: 'Overnight 3',
          lat: 7.2,
          lng: 125.8,
          stayDurationType: 'overnight',
        ),
      ];
      final plan = optimizer.planRoute(stops: stops, days: 2);
      expect(plan.warnings.any((w) => w.contains('overnight stop')), isTrue);
    });
  });

  group('SeaNetwork crossings, locks, and parity fixture', () {
    test('Mainland + Samal + Talikud stops group by island and Balut Island connects via mainland jump-off', () {
      final optimizer = RouteOptimizer();
      final stops = const [
        RouteStopInput(
          id: 'city',
          name: 'People\'s Park',
          lat: 7.0707,
          lng: 125.6096,
        ),
        RouteStopInput(
          id: 'samal_1',
          name: 'Samal Island Beach Area',
          lat: 7.0744,
          lng: 125.7087,
          islandGroup: 'samal',
          stayDurationType: 'full_day',
        ),
        RouteStopInput(
          id: 'talikud',
          name: 'Isla Reta Beach Resort',
          lat: 6.935867,
          lng: 125.720346,
          islandGroup: 'talikud',
          stayDurationType: 'full_day',
        ),
        RouteStopInput(
          id: 'eagle',
          name: 'Philippine Eagle Center',
          lat: 7.1854,
          lng: 125.4169,
          stayDurationType: 'half_day',
        ),
        RouteStopInput(
          id: 'samal_2',
          name: 'Monfort Bat Sanctuary',
          lat: 7.165537,
          lng: 125.692742,
          islandGroup: 'samal',
          stayDurationType: 'half_day',
        ),
      ];

      final plan = optimizer.planRoute(
        stops: stops,
        days: 3,
        lockedFirstId: 'city',
      );
      expect(plan.orderMethod, 'island_aware');
      expect(plan.orderedStops.first.id, 'city');

      // Both Samal stops must sit contiguously instead of oscillating across piers.
      final samalIdx = <int>[];
      for (var i = 0; i < plan.orderedStops.length; i++) {
        if (plan.orderedStops[i].normalizedIsland == 'samal') samalIdx.add(i);
      }
      expect(samalIdx[1] - samalIdx[0], 1);
      expect(
        plan.seaPathsUsed.any(
          (p) => p.hops.any((h) => h.landPort.normalizedIsland == 'talikud'),
        ),
        isTrue,
      );

      // Balut Island must find a sea path instead of 1e9 unreachable.
      final balutPath = optimizer.seaNetwork.findPath(
        const GeoCoord(lat: 5.9622, lng: 125.6777),
        const GeoCoord(lat: 5.4047, lng: 125.3765, islandGroup: 'balut'),
      );
      expect(balutPath, isNotNull);
      expect(balutPath!.hops.single.landPort.normalizedIsland, 'balut');
    });

    test('Locked first works with origin and mustVisit optional prunes when requested', () {
      final optimizer = RouteOptimizer();
      final stops = const [
        RouteStopInput(
          id: 'near',
          name: 'Museo Dabawenyo',
          lat: 7.07939,
          lng: 125.60449,
          stayDurationType: 'short',
        ),
        RouteStopInput(
          id: 'must_first',
          name: 'Eden Nature Park',
          lat: 7.0088,
          lng: 125.3992,
          stayDurationType: 'half_day',
        ),
        RouteStopInput(
          id: 'optional_far',
          name: 'Aliwagwag Falls',
          lat: 7.7431,
          lng: 126.4218,
          stayDurationType: 'overnight',
          mustVisit: false,
        ),
      ];

      final plan = optimizer.planRoute(
        stops: stops,
        days: 1,
        pace: TripPace.relaxed,
        origin: const GeoCoord(
          lat: 7.0707,
          lng: 125.6096,
          label: 'Downtown',
        ),
        lockedFirstId: 'must_first',
        pruneOptionalToFit: true,
      );

      expect(plan.orderedStops.first.id, 'must_first');
      expect(plan.skippedOptionalStops.map((s) => s.id), ['optional_far']);
      expect(plan.orderedStops.map((s) => s.id), ['must_first', 'near']);
    });

    test('Deterministic parity fixture produces repeatable savings and balanced days', () {
      final file = File('test/fixtures/route_parity_case.json');
      final raw = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      final originMap = raw['origin'] as Map<String, dynamic>;
      final origin = GeoCoord(
        lat: (originMap['lat'] as num).toDouble(),
        lng: (originMap['lng'] as num).toDouble(),
        islandGroup: originMap['island_group'] as String?,
        label: originMap['label'] as String,
      );
      final stops = [
        for (final item in raw['stops'] as List)
          RouteStopInput(
            id: item['id'] as String,
            name: item['name'] as String,
            lat: (item['lat'] as num).toDouble(),
            lng: (item['lng'] as num).toDouble(),
            islandGroup: item['island_group'] as String?,
            stayDurationType: item['stay_duration_type'] as String,
          ),
      ];

      final optimizer = RouteOptimizer(seaNetwork: SeaNetwork.davaoStarter());
      final result = optimizer.planRoute(
        stops: stops,
        days: raw['days'] as int,
        pace: TripPace.fromKey(raw['pace'] as String?),
        origin: origin,
        roundtrip: raw['roundtrip'] as bool,
        driving: raw['driving'] as bool,
      );

      // Scrambled input crosses to Samal twice; optimal order visits mainland
      // west stops and Samal stops contiguously, saving substantial distance.
      expect(result.costSource, 'haversine');
      expect(result.orderMethod, 'island_aware');
      // Day 1 visits West Davao mainland stops; Day 2 visits both Samal stops
      // (both Babak loop directions tie at identical km/min; Dart keeps input order);
      // Day 3 finishes at overnight Dahican.
      expect(result.days[0].stops.map((s) => s.id), ['api_3', 'api_2']);
      expect(result.days[1].stops.map((s) => s.id), ['api_4', 'api_34']);
      expect(result.days[2].stops.map((s) => s.id), ['api_6']);
      expect(result.savingsVsInput.baselineDistanceKm, closeTo(304.93, 0.05));
      expect(result.savingsVsInput.optimizedDistanceKm, closeTo(222.47, 0.05));
      expect(result.savingsVsInput.distanceSavedKm, closeTo(82.46, 0.05));
      expect(result.savingsVsInput.distanceSavedPercent, closeTo(27.0, 0.2));
      expect(result.savingsVsInput.minutesSaved, closeTo(186.0, 0.5));
      expect([for (final d in result.days) d.stops.length], [2, 2, 1]);
      expect(result.days.length, 3);
      expect(result.orderedStops.last.id, 'api_6'); // overnight Dahican at end
      final allIds = [
        for (final d in result.days)
          for (final s in d.stops) s.id,
      ];
      expect(allIds.length, 5);
      expect(allIds.toSet().length, 5);
    });
  });
}
