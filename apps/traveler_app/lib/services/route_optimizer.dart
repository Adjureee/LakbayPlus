import 'dart:math' as math;

const double earthRadiusKm = 6371.0;
const double roadDetourFactor = 1.35;
const double planningRoadSpeedKmh = 40.0;
const int exactOrderMaxStops = 11;
const double crossingOrderPenaltyMinutes = 30.0;
const double passengerOnlyPenaltyMinutes = 60.0;
const double unreachableRouteCost = 1e9;
const double routeCostTieTolerance = 1e-6;

enum TripPace {
  relaxed('relaxed', 'Relaxed', 6.0),
  balanced('balanced', 'Balanced', 8.0),
  packed('packed', 'Packed', 10.0);

  const TripPace(this.key, this.label, this.hoursPerDay);

  final String key;
  final String label;
  final double hoursPerDay;

  static TripPace fromKey(String? raw) {
    final cleaned = (raw ?? '').trim().toLowerCase();
    for (final value in TripPace.values) {
      if (value.key == cleaned) return value;
    }
    return TripPace.balanced;
  }
}

/// Normalizes a raw stay duration string into one of the five canonical keys:
/// `short`, `half_day`, `full_day`, `overnight`, `multi_day`.
String normalizeStayDurationKey(String? raw) {
  final cleaned = (raw ?? '')
      .trim()
      .toLowerCase()
      .replaceAll('-', '_')
      .replaceAll(' ', '_');
  if (cleaned.isEmpty) return 'half_day';
  if (cleaned.contains('multi')) return 'multi_day';
  if (cleaned.contains('overnight')) return 'overnight';
  if (cleaned == 'full' || cleaned.contains('full_day') || cleaned == 'fullday') {
    return 'full_day';
  }
  if (cleaned == 'half' || cleaned.contains('half_day') || cleaned == 'halfday') {
    return 'half_day';
  }
  if (cleaned.startsWith('short') || cleaned.contains('1_2_hour')) {
    return 'short';
  }
  return 'half_day';
}

double stayHoursForType(String? stayDurationType) {
  switch (normalizeStayDurationKey(stayDurationType)) {
    case 'short':
      return 1.5;
    case 'half_day':
      return 4.0;
    case 'full_day':
      return 7.0;
    case 'overnight':
    case 'multi_day':
      return 8.0;
    default:
      return 4.0;
  }
}

bool stayForcesDayEnd(String? stayDurationType) {
  final key = normalizeStayDurationKey(stayDurationType);
  return key == 'overnight' || key == 'multi_day';
}

/// Normalizes null/empty/mainland values to `'mainland'`.
String normalizeIslandGroup(String? islandGroup) {
  final cleaned = (islandGroup ?? '').trim().toLowerCase();
  if (cleaned.isEmpty || cleaned == 'davao_mainland') return 'mainland';
  return cleaned;
}

double haversineKm(double lat1, double lng1, double lat2, double lng2) {
  final lat1Rad = lat1 * math.pi / 180.0;
  final lat2Rad = lat2 * math.pi / 180.0;
  final dLat = (lat2 - lat1) * math.pi / 180.0;
  final dLng = (lng2 - lng1) * math.pi / 180.0;
  final a =
      math.sin(dLat / 2) * math.sin(dLat / 2) +
      math.cos(lat1Rad) *
          math.cos(lat2Rad) *
          math.sin(dLng / 2) *
          math.sin(dLng / 2);
  final c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
  return earthRadiusKm * c;
}

double roadDistanceKm(double lat1, double lng1, double lat2, double lng2) {
  return haversineKm(lat1, lng1, lat2, lng2) * roadDetourFactor;
}

double roadMinutes(double lat1, double lng1, double lat2, double lng2) {
  return roadDistanceKm(lat1, lng1, lat2, lng2) /
      planningRoadSpeedKmh *
      60.0;
}

class GeoCoord {
  const GeoCoord({
    required this.lat,
    required this.lng,
    this.islandGroup,
    this.label = '',
  });

  final double lat;
  final double lng;
  final String? islandGroup;
  final String label;

  String get normalizedIsland => normalizeIslandGroup(islandGroup);
}

class SeaPortNode {
  const SeaPortNode({
    required this.portId,
    required this.name,
    required this.lat,
    required this.lng,
    required this.islandGroup,
  });

  final int portId;
  final String name;
  final double lat;
  final double lng;
  final String islandGroup;

  String get normalizedIsland => normalizeIslandGroup(islandGroup);
}

class SeaLinkEdge {
  const SeaLinkEdge({
    required this.linkId,
    required this.fromPortId,
    required this.toPortId,
    required this.vesselType,
    required this.allowsPrivateVehicle,
    required this.crossingMinutes,
    required this.typicalWaitMinutes,
    this.bidirectional = true,
  });

  final int linkId;
  final int fromPortId;
  final int toPortId;
  final String vesselType;
  final bool allowsPrivateVehicle;
  final int crossingMinutes;
  final int typicalWaitMinutes;
  final bool bidirectional;

  double costMinutes({required bool driving}) {
    final base = (crossingMinutes + typicalWaitMinutes).toDouble();
    if (driving && !allowsPrivateVehicle) {
      return base + passengerOnlyPenaltyMinutes;
    }
    return base;
  }
}

class SeaHop {
  const SeaHop({
    required this.link,
    required this.boardPort,
    required this.landPort,
    required this.reversedGeometry,
    required this.distanceKm,
  });

  final SeaLinkEdge link;
  final SeaPortNode boardPort;
  final SeaPortNode landPort;
  final bool reversedGeometry;
  final double distanceKm;

  int get effectiveMinutes => link.crossingMinutes + link.typicalWaitMinutes;
}

class SeaPath {
  const SeaPath({
    required this.hops,
    required this.roadMinutes,
    required this.seaMinutes,
    required this.roadDistanceKm,
    required this.seaDistanceKm,
  });

  final List<SeaHop> hops;
  final double roadMinutes;
  final double seaMinutes;
  final double roadDistanceKm;
  final double seaDistanceKm;

  double get totalMinutes => roadMinutes + seaMinutes;
  double get totalDistanceKm => roadDistanceKm + seaDistanceKm;
}

class _EdgeStep {
  const _EdgeStep({
    required this.fromNode,
    required this.toNode,
    required this.weight,
    this.hop,
  });

  final int fromNode;
  final int toNode;
  final double weight;
  final SeaHop? hop;
}

/// Shortest-path sea and pier router for Region XI islands.
class SeaNetwork {
  SeaNetwork({
    required List<SeaPortNode> ports,
    required List<SeaLinkEdge> links,
  }) : ports = List<SeaPortNode>.unmodifiable(ports),
       links = List<SeaLinkEdge>.unmodifiable(links);

  final List<SeaPortNode> ports;
  final List<SeaLinkEdge> links;

  /// Exact starter graph matching the database migration seeds.
  factory SeaNetwork.davaoStarter() => SeaNetwork(
    ports: const [
      SeaPortNode(
        portId: 1,
        name: 'Sasa RoRo Wharf (Davao City)',
        lat: 7.1236,
        lng: 125.6655,
        islandGroup: 'mainland',
      ),
      SeaPortNode(
        portId: 2,
        name: 'Babak RoRo Landing (Samal)',
        lat: 7.1180,
        lng: 125.6880,
        islandGroup: 'samal',
      ),
      SeaPortNode(
        portId: 3,
        name: 'Sta. Ana Wharf (Davao City)',
        lat: 7.0760,
        lng: 125.6260,
        islandGroup: 'mainland',
      ),
      SeaPortNode(
        portId: 4,
        name: 'Talikud Island Pier (Santa Cruz)',
        lat: 6.9530,
        lng: 125.6990,
        islandGroup: 'talikud',
      ),
    ],
    links: const [
      SeaLinkEdge(
        linkId: 1,
        fromPortId: 1,
        toPortId: 2,
        vesselType: 'roro_barge',
        allowsPrivateVehicle: true,
        crossingMinutes: 15,
        typicalWaitMinutes: 20,
      ),
      SeaLinkEdge(
        linkId: 2,
        fromPortId: 3,
        toPortId: 4,
        vesselType: 'passenger_ferry',
        allowsPrivateVehicle: false,
        crossingMinutes: 60,
        typicalWaitMinutes: 45,
      ),
    ],
  );

  /// Built-in Region XI offline graph adding Kaputian <-> Talikud and
  /// Sarangani Strait / Mainland <-> Balut Island links.
  factory SeaNetwork.regionXI({
    List<SeaPortNode> extraPorts = const [],
    List<SeaLinkEdge> extraLinks = const [],
  }) {
    final starter = SeaNetwork.davaoStarter();
    return SeaNetwork(
      ports: [
        ...starter.ports,
        const SeaPortNode(
          portId: 5,
          name: 'Kaputian Wharf (Samal)',
          lat: 6.9556,
          lng: 125.7281,
          islandGroup: 'samal',
        ),
        const SeaPortNode(
          portId: 6,
          name: 'Sarangani Strait Jump-off (Mainland)',
          lat: 5.6640,
          lng: 125.4900,
          islandGroup: 'mainland',
        ),
        const SeaPortNode(
          portId: 7,
          name: 'Balut Island Pier (Mabila)',
          lat: 5.4020,
          lng: 125.3790,
          islandGroup: 'balut',
        ),
        ...extraPorts,
      ],
      links: [
        ...starter.links,
        const SeaLinkEdge(
          linkId: 3,
          fromPortId: 5,
          toPortId: 4,
          vesselType: 'passenger_ferry',
          allowsPrivateVehicle: false,
          crossingMinutes: 20,
          typicalWaitMinutes: 25,
        ),
        const SeaLinkEdge(
          linkId: 4,
          fromPortId: 6,
          toPortId: 7,
          vesselType: 'passenger_ferry',
          allowsPrivateVehicle: false,
          crossingMinutes: 120,
          typicalWaitMinutes: 60,
        ),
        ...extraLinks,
      ],
    );
  }

  /// Finds the minimum-time path between [origin] and [destination].
  /// Returns `null` when one endpoint sits on an unconnected island.
  SeaPath? findPath(
    GeoCoord origin,
    GeoCoord destination, {
    bool driving = true,
  }) {
    final originGroup = origin.normalizedIsland;
    final destGroup = destination.normalizedIsland;
    if (originGroup == destGroup) {
      final km = roadDistanceKm(
        origin.lat,
        origin.lng,
        destination.lat,
        destination.lng,
      );
      return SeaPath(
        hops: const [],
        roadMinutes: roadMinutes(
          origin.lat,
          origin.lng,
          destination.lat,
          destination.lng,
        ),
        seaMinutes: 0.0,
        roadDistanceKm: km,
        seaDistanceKm: 0.0,
      );
    }

    if (ports.isEmpty || links.isEmpty) return null;

    // Node indices: 0 = origin, 1..P = ports, P + 1 = destination.
    final pCount = ports.length;
    final destNode = pCount + 1;
    final portIndexById = <int, int>{};
    for (var i = 0; i < pCount; i++) {
      portIndexById[ports[i].portId] = i + 1;
    }

    final adjacency = List<List<_EdgeStep>>.generate(
      pCount + 2,
      (_) => <_EdgeStep>[],
    );

    for (var i = 0; i < pCount; i++) {
      final port = ports[i];
      final nodeIdx = i + 1;
      if (port.normalizedIsland == originGroup) {
        adjacency[0].add(
          _EdgeStep(
            fromNode: 0,
            toNode: nodeIdx,
            weight: roadMinutes(origin.lat, origin.lng, port.lat, port.lng),
          ),
        );
      }
      if (port.normalizedIsland == destGroup) {
        adjacency[nodeIdx].add(
          _EdgeStep(
            fromNode: nodeIdx,
            toNode: destNode,
            weight: roadMinutes(
              port.lat,
              port.lng,
              destination.lat,
              destination.lng,
            ),
          ),
        );
      }
      for (var j = i + 1; j < pCount; j++) {
        final other = ports[j];
        if (port.normalizedIsland == other.normalizedIsland) {
          final transferMin = roadMinutes(
            port.lat,
            port.lng,
            other.lat,
            other.lng,
          );
          adjacency[nodeIdx].add(
            _EdgeStep(fromNode: nodeIdx, toNode: j + 1, weight: transferMin),
          );
          adjacency[j + 1].add(
            _EdgeStep(fromNode: j + 1, toNode: nodeIdx, weight: transferMin),
          );
        }
      }
    }

    for (final link in links) {
      final u = portIndexById[link.fromPortId];
      final v = portIndexById[link.toPortId];
      if (u == null || v == null) continue;
      final portU = ports[u - 1];
      final portV = ports[v - 1];
      final seaKm = haversineKm(portU.lat, portU.lng, portV.lat, portV.lng);
      final cost = link.costMinutes(driving: driving);
      adjacency[u].add(
        _EdgeStep(
          fromNode: u,
          toNode: v,
          weight: cost,
          hop: SeaHop(
            link: link,
            boardPort: portU,
            landPort: portV,
            reversedGeometry: false,
            distanceKm: seaKm,
          ),
        ),
      );
      if (link.bidirectional) {
        adjacency[v].add(
          _EdgeStep(
            fromNode: v,
            toNode: u,
            weight: cost,
            hop: SeaHop(
              link: link,
              boardPort: portV,
              landPort: portU,
              reversedGeometry: true,
              distanceKm: seaKm,
            ),
          ),
        );
      }
    }

    final dist = List<double>.filled(pCount + 2, double.infinity);
    final visited = List<bool>.filled(pCount + 2, false);
    final prevStep = List<_EdgeStep?>.filled(pCount + 2, null);
    dist[0] = 0.0;

    for (var iter = 0; iter < pCount + 2; iter++) {
      var u = -1;
      var best = double.infinity;
      for (var n = 0; n < pCount + 2; n++) {
        if (!visited[n] && dist[n] < best) {
          best = dist[n];
          u = n;
        }
      }
      if (u == -1 || best.isInfinite) break;
      visited[u] = true;
      if (u == destNode) break;
      for (final edge in adjacency[u]) {
        final cand = dist[u] + edge.weight;
        if (cand < dist[edge.toNode] - routeCostTieTolerance) {
          dist[edge.toNode] = cand;
          prevStep[edge.toNode] = edge;
        }
      }
    }

    if (dist[destNode].isInfinite) return null;

    final pathEdges = <_EdgeStep>[];
    var cursor = destNode;
    while (cursor != 0) {
      final step = prevStep[cursor];
      if (step == null) return null;
      pathEdges.add(step);
      cursor = step.fromNode;
    }

    final hops = <SeaHop>[];
    var totalRoadMin = 0.0;
    var totalSeaMin = 0.0;
    var totalRoadKm = 0.0;
    var totalSeaKm = 0.0;

    for (final edge in pathEdges.reversed) {
      final hop = edge.hop;
      if (hop != null) {
        hops.add(hop);
        totalSeaMin += hop.effectiveMinutes;
        totalSeaKm += hop.distanceKm;
      } else {
        final pFrom = edge.fromNode == 0 ? origin : _portAsCoord(edge.fromNode);
        final pTo =
            edge.toNode == destNode ? destination : _portAsCoord(edge.toNode);
        totalRoadMin += edge.weight;
        totalRoadKm += roadDistanceKm(pFrom.lat, pFrom.lng, pTo.lat, pTo.lng);
      }
    }

    return SeaPath(
      hops: hops,
      roadMinutes: totalRoadMin,
      seaMinutes: totalSeaMin,
      roadDistanceKm: totalRoadKm,
      seaDistanceKm: totalSeaKm,
    );
  }

  GeoCoord _portAsCoord(int nodeIdx) {
    final p = ports[nodeIdx - 1];
    return GeoCoord(
      lat: p.lat,
      lng: p.lng,
      islandGroup: p.islandGroup,
      label: p.name,
    );
  }
}

class RouteStopInput {
  const RouteStopInput({
    required this.id,
    required this.name,
    required this.lat,
    required this.lng,
    this.islandGroup,
    this.stayDurationType = 'half_day',
    this.mustVisit = true,
  });

  final String id;
  final String name;
  final double lat;
  final double lng;
  final String? islandGroup;
  final String stayDurationType;
  final bool mustVisit;

  GeoCoord toGeoCoord() => GeoCoord(
    lat: lat,
    lng: lng,
    islandGroup: islandGroup,
    label: name,
  );

  double get visitHours => stayHoursForType(stayDurationType);
  bool get forcesDayEnd => stayForcesDayEnd(stayDurationType);
  String get normalizedIsland => normalizeIslandGroup(islandGroup);
  String get normalizedStayType => normalizeStayDurationKey(stayDurationType);
}

class CostMatrixResult {
  const CostMatrixResult({
    required this.orderingCosts,
    required this.transitMinutes,
    required this.distanceKm,
    required this.seaPaths,
    required this.unconnectedIslandGroups,
    required this.costSource,
  });

  final List<List<double>> orderingCosts;
  final List<List<double>> transitMinutes;
  final List<List<double>> distanceKm;
  final List<List<SeaPath?>> seaPaths;
  final List<String> unconnectedIslandGroups;
  final String costSource;
}

class PlannedLeg {
  const PlannedLeg({
    required this.fromLabel,
    required this.toLabel,
    required this.distanceKm,
    required this.transitMinutes,
    required this.seaHops,
    required this.isEstimated,
  });

  final String fromLabel;
  final String toLabel;
  final double distanceKm;
  final double transitMinutes;
  final List<SeaHop> seaHops;
  final bool isEstimated;
}

class PlannedDay {
  const PlannedDay({
    required this.dayNumber,
    required this.stops,
    required this.visitHours,
    required this.transitHours,
    required this.totalHours,
    required this.legs,
    this.isContinuationDay = false,
    this.continuationOfStop,
    this.isOverloaded = false,
    this.overloadWarning,
  });

  final int dayNumber;
  final List<RouteStopInput> stops;
  final double visitHours;
  final double transitHours;
  final double totalHours;
  final List<PlannedLeg> legs;
  final bool isContinuationDay;
  final RouteStopInput? continuationOfStop;
  final bool isOverloaded;
  final String? overloadWarning;
}

class RouteSavings {
  const RouteSavings({
    required this.baselineDistanceKm,
    required this.optimizedDistanceKm,
    required this.distanceSavedKm,
    required this.distanceSavedPercent,
    required this.baselineTransitMinutes,
    required this.optimizedTransitMinutes,
    required this.minutesSaved,
  });

  final double baselineDistanceKm;
  final double optimizedDistanceKm;
  final double distanceSavedKm;
  final double distanceSavedPercent;
  final double baselineTransitMinutes;
  final double optimizedTransitMinutes;
  final double minutesSaved;
}

class RoutePlanResult {
  const RoutePlanResult({
    required this.orderedStops,
    required this.days,
    required this.suggestedDays,
    required this.orderMethod,
    required this.costSource,
    required this.savingsVsInput,
    required this.warnings,
    required this.roundtrip,
    required this.pace,
    required this.totalDistanceKm,
    required this.totalTransitMinutes,
    required this.seaPathsUsed,
    this.skippedOptionalStops = const [],
  });

  final List<RouteStopInput> orderedStops;
  final List<PlannedDay> days;
  final int suggestedDays;
  final String orderMethod;
  final String costSource;
  final RouteSavings savingsVsInput;
  final List<String> warnings;
  final bool roundtrip;
  final TripPace pace;
  final double totalDistanceKm;
  final double totalTransitMinutes;
  final List<SeaPath> seaPathsUsed;
  final List<RouteStopInput> skippedOptionalStops;
}

/// Pure-Dart adaptive route optimizer and linear-partition day planner.
class RouteOptimizer {
  RouteOptimizer({SeaNetwork? seaNetwork})
    : seaNetwork = seaNetwork ?? SeaNetwork.regionXI();

  final SeaNetwork seaNetwork;

  /// Computes asymmetric pairwise ordering costs, realistic transit times, and
  /// road/sea distances for [points].
  CostMatrixResult buildCostMatrix(
    List<GeoCoord> points, {
    bool driving = true,
    List<List<double>>? overrideTransitMinutes,
    List<List<double>>? overrideDistanceKm,
    String costSource = 'haversine',
  }) {
    final n = points.length;
    final ordering = List<List<double>>.generate(
      n,
      (_) => List<double>.filled(n, 0.0),
    );
    final transit = List<List<double>>.generate(
      n,
      (_) => List<double>.filled(n, 0.0),
    );
    final distances = List<List<double>>.generate(
      n,
      (_) => List<double>.filled(n, 0.0),
    );
    final paths = List<List<SeaPath?>>.generate(
      n,
      (_) => List<SeaPath?>.filled(n, null),
    );
    final unconnected = <String>{};
    var usedOverride = false;

    for (var i = 0; i < n; i++) {
      for (var j = 0; j < n; j++) {
        if (i == j) continue;
        final a = points[i];
        final b = points[j];
        final sameIsland = a.normalizedIsland == b.normalizedIsland;

        if (sameIsland) {
          final hasOverrideMin =
              overrideTransitMinutes != null &&
              i < overrideTransitMinutes.length &&
              j < overrideTransitMinutes[i].length &&
              overrideTransitMinutes[i][j].isFinite &&
              overrideTransitMinutes[i][j] > 0;
          final mins = hasOverrideMin
              ? overrideTransitMinutes[i][j]
              : roadMinutes(a.lat, a.lng, b.lat, b.lng);
          if (hasOverrideMin) usedOverride = true;

          final hasOverrideKm =
              overrideDistanceKm != null &&
              i < overrideDistanceKm.length &&
              j < overrideDistanceKm[i].length &&
              overrideDistanceKm[i][j].isFinite &&
              overrideDistanceKm[i][j] >= 0;
          final km = hasOverrideKm
              ? overrideDistanceKm[i][j]
              : roadDistanceKm(a.lat, a.lng, b.lat, b.lng);

          ordering[i][j] = mins;
          transit[i][j] = mins;
          distances[i][j] = km;
          continue;
        }

        final path = seaNetwork.findPath(a, b, driving: driving);
        paths[i][j] = path;
        if (path == null) {
          if (a.normalizedIsland != 'mainland') {
            unconnected.add(a.normalizedIsland);
          }
          if (b.normalizedIsland != 'mainland') {
            unconnected.add(b.normalizedIsland);
          }
          ordering[i][j] = unreachableRouteCost;
          transit[i][j] =
              roadMinutes(a.lat, a.lng, b.lat, b.lng) +
              crossingOrderPenaltyMinutes;
          distances[i][j] = roadDistanceKm(a.lat, a.lng, b.lat, b.lng);
        } else {
          ordering[i][j] = path.totalMinutes + crossingOrderPenaltyMinutes;
          transit[i][j] = path.totalMinutes;
          distances[i][j] = path.totalDistanceKm;
        }
      }
    }

    return CostMatrixResult(
      orderingCosts: ordering,
      transitMinutes: transit,
      distanceKm: distances,
      seaPaths: paths,
      unconnectedIslandGroups: unconnected.toList()..sort(),
      costSource: usedOverride ? costSource : 'haversine',
    );
  }

  /// Total cost of visiting [order] in sequence, adding the return leg if
  /// [roundtrip] is true.
  static double orderCost(
    List<List<double>> costs,
    List<int> order, {
    required bool roundtrip,
  }) {
    if (order.length <= 1) return 0.0;
    var total = 0.0;
    for (var i = 0; i < order.length - 1; i++) {
      total += costs[order[i]][order[i + 1]];
    }
    if (roundtrip) {
      total += costs[order.last][order.first];
    }
    return total;
  }

  /// Finds the optimal visiting order using Held-Karp exact DP for `n <= 11`,
  /// or multi-start Nearest-Neighbor + 2-opt + Or-opt for larger sets.
  List<int> optimizeStopOrder(
    List<List<double>> costs, {
    bool fixedStart = false,
    bool roundtrip = false,
    int? fixedSecondIndex,
  }) {
    final n = costs.length;
    if (n <= 1) return List<int>.generate(n, (i) => i);
    if (n <= exactOrderMaxStops) {
      return exactOrder(
        costs,
        fixedStart: fixedStart,
        roundtrip: roundtrip,
        fixedSecondIndex: fixedSecondIndex,
      );
    }
    return nearestNeighborTwoOptOrOpt(
      costs,
      fixedStart: fixedStart,
      roundtrip: roundtrip,
      fixedSecondIndex: fixedSecondIndex,
    );
  }

  /// Held-Karp bitmask dynamic programming solver (`n <= 11`).
  List<int> exactOrder(
    List<List<double>> costs, {
    bool fixedStart = false,
    bool roundtrip = false,
    int? fixedSecondIndex,
  }) {
    final n = costs.length;
    if (n > exactOrderMaxStops) {
      throw ArgumentError(
        'exactOrder supports at most $exactOrderMaxStops stops; got $n',
      );
    }
    if (n <= 1) return List<int>.generate(n, (i) => i);

    final mustStartAtZero = fixedStart || roundtrip;
    final states = 1 << n;
    final dp = List<double>.filled(states * n, double.infinity);
    final parent = List<int>.filled(states * n, -1);

    if (mustStartAtZero) {
      dp[(1 << 0) * n + 0] = 0.0;
    } else {
      for (var i = 0; i < n; i++) {
        dp[(1 << i) * n + i] = 0.0;
      }
    }

    for (var mask = 1; mask < states; mask++) {
      if (mustStartAtZero && (mask & 1) == 0) continue;
      for (var last = 0; last < n; last++) {
        if ((mask & (1 << last)) == 0) continue;
        final currentCost = dp[mask * n + last];
        if (currentCost.isInfinite) continue;

        for (var next = 0; next < n; next++) {
          if ((mask & (1 << next)) != 0) continue;
          if (fixedSecondIndex != null && mask == 1 && next != fixedSecondIndex) {
            continue;
          }
          final nextMask = mask | (1 << next);
          final slot = nextMask * n + next;
          final candidateCost = currentCost + costs[last][next];
          final existingCost = dp[slot];

          if (candidateCost < existingCost - routeCostTieTolerance) {
            dp[slot] = candidateCost;
            parent[slot] = last;
          } else if ((candidateCost - existingCost).abs() <=
              routeCostTieTolerance) {
            final candPath = _reconstructWithHead(parent, mask, last, n, next);
            final oldPath = _reconstructPath(parent, nextMask, next, n);
            if (_lexLess(candPath, oldPath)) {
              dp[slot] = candidateCost;
              parent[slot] = last;
            }
          }
        }
      }
    }

    final fullMask = states - 1;
    var bestCost = double.infinity;
    List<int>? bestOrder;

    for (var last = 0; last < n; last++) {
      final slot = fullMask * n + last;
      final base = dp[slot];
      if (base.isInfinite) continue;
      final total = roundtrip ? base + costs[last][0] : base;
      final path = _reconstructPath(parent, fullMask, last, n);

      if (bestOrder == null || total < bestCost - routeCostTieTolerance) {
        bestCost = total;
        bestOrder = path;
      } else if ((total - bestCost).abs() <= routeCostTieTolerance &&
          _lexLess(path, bestOrder)) {
        bestOrder = path;
      }
    }

    return bestOrder ?? List<int>.generate(n, (i) => i);
  }

  List<int> _reconstructPath(List<int> parent, int mask, int last, int n) {
    final reversed = <int>[];
    var curMask = mask;
    var cur = last;
    while (cur != -1) {
      reversed.add(cur);
      final prev = parent[curMask * n + cur];
      curMask ^= 1 << cur;
      cur = prev;
    }
    return reversed.reversed.toList();
  }

  List<int> _reconstructWithHead(
    List<int> parent,
    int prevMask,
    int prevLast,
    int n,
    int next,
  ) {
    final prefix = _reconstructPath(parent, prevMask, prevLast, n);
    prefix.add(next);
    return prefix;
  }

  /// Multi-start Nearest Neighbor followed by 2-opt and Or-opt (runs 1..3).
  List<int> nearestNeighborTwoOptOrOpt(
    List<List<double>> costs, {
    bool fixedStart = false,
    bool roundtrip = false,
    int? fixedSecondIndex,
  }) {
    final n = costs.length;
    if (n <= 1) return List<int>.generate(n, (i) => i);

    final mustStartAtZero = fixedStart || roundtrip;
    final prefixLocked = mustStartAtZero
        ? (fixedSecondIndex != null ? 2 : 1)
        : 0;

    final seeds = <List<int>>[];
    // Candidate 1: requested input order (possibly placing fixedSecondIndex at 1).
    if (fixedSecondIndex != null && n > 1 && fixedSecondIndex != 1) {
      final req = <int>[0, fixedSecondIndex];
      for (var i = 1; i < n; i++) {
        if (i != fixedSecondIndex) req.add(i);
      }
      seeds.add(req);
    } else {
      seeds.add(List<int>.generate(n, (i) => i));
    }

    final starts = mustStartAtZero
        ? const [0]
        : List<int>.generate(n, (i) => i);
    for (final s in starts) {
      seeds.add(
        _nearestNeighbor(
          costs,
          s,
          fixedSecondIndex: mustStartAtZero ? fixedSecondIndex : null,
        ),
      );
    }

    var bestOrder = _localSearch(
      costs,
      seeds.first,
      prefixLocked: prefixLocked,
      roundtrip: roundtrip,
    );
    var bestCost = orderCost(costs, bestOrder, roundtrip: roundtrip);

    for (var i = 1; i < seeds.length; i++) {
      final candidate = _localSearch(
        costs,
        seeds[i],
        prefixLocked: prefixLocked,
        roundtrip: roundtrip,
      );
      final cost = orderCost(costs, candidate, roundtrip: roundtrip);
      if (cost < bestCost - routeCostTieTolerance) {
        bestCost = cost;
        bestOrder = candidate;
      } else if ((cost - bestCost).abs() <= routeCostTieTolerance &&
          _lexLess(candidate, bestOrder)) {
        bestOrder = candidate;
      }
    }
    return bestOrder;
  }

  List<int> _nearestNeighbor(
    List<List<double>> costs,
    int start, {
    int? fixedSecondIndex,
  }) {
    final n = costs.length;
    final visited = List<bool>.filled(n, false);
    final order = <int>[start];
    visited[start] = true;

    if (fixedSecondIndex != null &&
        fixedSecondIndex != start &&
        fixedSecondIndex >= 0 &&
        fixedSecondIndex < n) {
      order.add(fixedSecondIndex);
      visited[fixedSecondIndex] = true;
    }

    while (order.length < n) {
      final current = order.last;
      var bestNext = -1;
      var bestWeight = double.infinity;
      for (var cand = 0; cand < n; cand++) {
        if (visited[cand]) continue;
        final w = costs[current][cand];
        if (w < bestWeight - routeCostTieTolerance) {
          bestWeight = w;
          bestNext = cand;
        }
      }
      if (bestNext == -1) break;
      visited[bestNext] = true;
      order.add(bestNext);
    }
    return order;
  }

  List<int> _localSearch(
    List<List<double>> costs,
    List<int> initial, {
    required int prefixLocked,
    required bool roundtrip,
  }) {
    var order = List<int>.from(initial);
    var currentCost = orderCost(costs, order, roundtrip: roundtrip);
    var improved = true;

    while (improved) {
      improved = false;

      // 2-opt: reverse a contiguous subsegment [left..right].
      for (var left = prefixLocked; left < order.length - 1; left++) {
        for (var right = left + 1; right < order.length; right++) {
          final cand = <int>[
            ...order.sublist(0, left),
            ...order.sublist(left, right + 1).reversed,
            ...order.sublist(right + 1),
          ];
          final cost = orderCost(costs, cand, roundtrip: roundtrip);
          if (cost < currentCost - routeCostTieTolerance) {
            order = cand;
            currentCost = cost;
            improved = true;
          }
        }
      }

      // Or-opt: relocate contiguous segments of length 1, 2, or 3.
      for (var segLen = 3; segLen >= 1; segLen--) {
        if (order.length - prefixLocked <= segLen) continue;
        var segMoved = true;
        while (segMoved) {
          segMoved = false;
          for (var start = prefixLocked;
              start <= order.length - segLen;
              start++) {
            final segment = order.sublist(start, start + segLen);
            final remainder = <int>[
              ...order.sublist(0, start),
              ...order.sublist(start + segLen),
            ];
            for (var insertAt = prefixLocked;
                insertAt <= remainder.length;
                insertAt++) {
              if (insertAt == start) continue;
              final cand = <int>[
                ...remainder.sublist(0, insertAt),
                ...segment,
                ...remainder.sublist(insertAt),
              ];
              final cost = orderCost(costs, cand, roundtrip: roundtrip);
              if (cost < currentCost - routeCostTieTolerance) {
                order = cand;
                currentCost = cost;
                improved = true;
                segMoved = true;
                break;
              }
            }
            if (segMoved) break;
          }
        }
      }
    }
    return order;
  }

  /// Full optimization and day-planning pipeline from stops and trip preferences.
  RoutePlanResult planRoute({
    required List<RouteStopInput> stops,
    required int days,
    TripPace pace = TripPace.balanced,
    GeoCoord? origin,
    bool roundtrip = false,
    String? lockedFirstId,
    bool driving = true,
    bool pruneOptionalToFit = false,
    List<List<double>>? overrideTransitMinutes,
    List<List<double>>? overrideDistanceKm,
    String costSource = 'haversine',
  }) {
    if (stops.isEmpty) {
      return RoutePlanResult(
        orderedStops: const [],
        days: const [],
        suggestedDays: 1,
        orderMethod: 'requested',
        costSource: costSource,
        savingsVsInput: const RouteSavings(
          baselineDistanceKm: 0,
          optimizedDistanceKm: 0,
          distanceSavedKm: 0,
          distanceSavedPercent: 0,
          baselineTransitMinutes: 0,
          optimizedTransitMinutes: 0,
          minutesSaved: 0,
        ),
        warnings: const [],
        roundtrip: roundtrip,
        pace: pace,
        totalDistanceKm: 0,
        totalTransitMinutes: 0,
        seaPathsUsed: const [],
      );
    }

    var activeStops = List<RouteStopInput>.from(stops);
    final skippedOptional = <RouteStopInput>[];
    var result = _planForStops(
      activeStops: activeStops,
      baselineReferenceStops: stops,
      days: days,
      pace: pace,
      origin: origin,
      roundtrip: roundtrip,
      lockedFirstId: lockedFirstId,
      driving: driving,
      overrideTransitMinutes: overrideTransitMinutes,
      overrideDistanceKm: overrideDistanceKm,
      costSource: costSource,
    );

    if (pruneOptionalToFit) {
      final totalBudget = days.clamp(1, 14) * pace.hoursPerDay + 0.5;
      while (activeStops.length > 1) {
        final hasOverload =
            result.days.any((d) => d.isOverloaded) ||
            result.days.fold<double>(0.0, (sum, d) => sum + d.totalHours) >
                totalBudget;
        if (!hasOverload) break;

        final candidates = <int>[
          for (var i = 0; i < activeStops.length; i++)
            if (!activeStops[i].mustVisit && activeStops[i].id != lockedFirstId)
              i,
        ];
        if (candidates.isEmpty) break;

        // Drop the optional stop farthest from the centroid of remaining stops.
        var worstIdx = candidates.first;
        var worstScore = -double.infinity;
        final avgLat =
            activeStops.fold<double>(0.0, (s, e) => s + e.lat) /
            activeStops.length;
        final avgLng =
            activeStops.fold<double>(0.0, (s, e) => s + e.lng) /
            activeStops.length;
        for (final idx in candidates) {
          final s = activeStops[idx];
          final distScore =
              roadMinutes(avgLat, avgLng, s.lat, s.lng) + s.visitHours * 15.0;
          if (distScore > worstScore) {
            worstScore = distScore;
            worstIdx = idx;
          }
        }
        skippedOptional.add(activeStops.removeAt(worstIdx));
        result = _planForStops(
          activeStops: activeStops,
          baselineReferenceStops: activeStops,
          days: days,
          pace: pace,
          origin: origin,
          roundtrip: roundtrip,
          lockedFirstId: lockedFirstId,
          driving: driving,
          costSource: costSource,
        );
      }
      if (skippedOptional.isNotEmpty) {
        final droppedNames = skippedOptional.map((s) => s.name).join(', ');
        return RoutePlanResult(
          orderedStops: result.orderedStops,
          days: result.days,
          suggestedDays: result.suggestedDays,
          orderMethod: result.orderMethod,
          costSource: result.costSource,
          savingsVsInput: result.savingsVsInput,
          warnings: [
            ...result.warnings,
            'Skipped optional stops to fit ${days.clamp(1, 14)} days: $droppedNames.',
          ],
          roundtrip: result.roundtrip,
          pace: result.pace,
          totalDistanceKm: result.totalDistanceKm,
          totalTransitMinutes: result.totalTransitMinutes,
          seaPathsUsed: result.seaPathsUsed,
          skippedOptionalStops: skippedOptional,
        );
      }
    }
    return result;
  }

  RoutePlanResult _planForStops({
    required List<RouteStopInput> activeStops,
    required List<RouteStopInput> baselineReferenceStops,
    required int days,
    required TripPace pace,
    required GeoCoord? origin,
    required bool roundtrip,
    required String? lockedFirstId,
    required bool driving,
    List<List<double>>? overrideTransitMinutes,
    List<List<double>>? overrideDistanceKm,
    required String costSource,
  }) {
    final stops = activeStops;
    final clampedDays = days.clamp(1, 14);
    final hasOrigin = origin != null;
    final lockedIdx = lockedFirstId == null
        ? -1
        : stops.indexWhere((s) => s.id == lockedFirstId);
    final hasLockedFirst = lockedIdx >= 0;

    // Build point list: if origin provided, index 0 is origin and stops are 1..S.
    // Otherwise index 0..S-1 are stops, moving lockedFirstId to 0 when set.
    final workingStops = List<RouteStopInput>.from(stops);
    if (!hasOrigin && hasLockedFirst && lockedIdx != 0) {
      final locked = workingStops.removeAt(lockedIdx);
      workingStops.insert(0, locked);
    }

    final points = <GeoCoord>[
      if (hasOrigin) origin,
      ...workingStops.map((s) => s.toGeoCoord()),
    ];

    final matrix = buildCostMatrix(
      points,
      driving: driving,
      overrideTransitMinutes: overrideTransitMinutes,
      overrideDistanceKm: overrideDistanceKm,
      costSource: costSource,
    );

    final fixedSecond = hasOrigin && hasLockedFirst
        ? workingStops.indexWhere((s) => s.id == lockedFirstId) + 1
        : null;

    final fixedStart = hasOrigin || hasLockedFirst;
    final optimizedIndices = optimizeStopOrder(
      matrix.orderingCosts,
      fixedStart: fixedStart,
      roundtrip: roundtrip,
      fixedSecondIndex: fixedSecond,
    );

    final stopPositionOrder = hasOrigin
        ? optimizedIndices.where((idx) => idx != 0).toList()
        : optimizedIndices;

    final orderedStops = [
      for (final idx in stopPositionOrder)
        workingStops[hasOrigin ? idx - 1 : idx],
    ];

    // Map each ordered stop back into `points` indices for matrix lookup.
    final orderedPointIndices = stopPositionOrder;
    final inputPointIndices = [
      for (var i = 0; i < baselineReferenceStops.length; i++)
        hasOrigin
            ? _workingIndexForOriginal(baselineReferenceStops, workingStops, i) + 1
            : _workingIndexForOriginal(baselineReferenceStops, workingStops, i),
    ];

    final baselineTotals = _measureSequence(
      matrix: matrix,
      pointIndices: inputPointIndices,
      hasOrigin: hasOrigin,
      roundtrip: roundtrip,
    );
    final optimizedTotals = _measureSequence(
      matrix: matrix,
      pointIndices: orderedPointIndices,
      hasOrigin: hasOrigin,
      roundtrip: roundtrip,
    );

    final legHours = <double>[];
    final legDistances = <double>[];
    final legMinutes = <double>[];
    final legSeaHops = <List<SeaHop>>[];
    final seaPathsUsed = <SeaPath>[];

    for (var i = 0; i < orderedPointIndices.length - 1; i++) {
      final u = orderedPointIndices[i];
      final v = orderedPointIndices[i + 1];
      final mins = matrix.transitMinutes[u][v];
      final km = matrix.distanceKm[u][v];
      final path = matrix.seaPaths[u][v];
      if (path != null) seaPathsUsed.add(path);
      legHours.add(mins / 60.0);
      legMinutes.add(mins);
      legDistances.add(km);
      legSeaHops.add(path?.hops ?? const []);
    }

    final originMinutes = hasOrigin
        ? matrix.transitMinutes[0][orderedPointIndices.first]
        : 0.0;
    final originDistanceKm = hasOrigin
        ? matrix.distanceKm[0][orderedPointIndices.first]
        : 0.0;
    final originSeaPath = hasOrigin
        ? matrix.seaPaths[0][orderedPointIndices.first]
        : null;
    if (originSeaPath != null) seaPathsUsed.add(originSeaPath);

    var returnMinutes = 0.0;
    var returnDistanceKm = 0.0;
    SeaPath? returnSeaPath;
    if (roundtrip) {
      final anchor = hasOrigin ? 0 : orderedPointIndices.first;
      final last = orderedPointIndices.last;
      if (last != anchor) {
        returnMinutes = matrix.transitMinutes[last][anchor];
        returnDistanceKm = matrix.distanceKm[last][anchor];
        returnSeaPath = matrix.seaPaths[last][anchor];
        if (returnSeaPath != null) seaPathsUsed.add(returnSeaPath);
      }
    }

    final suggested = computeSuggestedDays(
      orderedStops: orderedStops,
      legTransitHours: legHours,
      pace: pace,
      originTransitHours: originMinutes / 60.0,
      returnTransitHours: returnMinutes / 60.0,
    );

    final dayPlan = planDays(
      orderedStops: orderedStops,
      days: clampedDays,
      pace: pace,
      legTransitHours: legHours,
      originTransitHours: originMinutes / 60.0,
      returnTransitHours: returnMinutes / 60.0,
      originLabel: origin?.label.isNotEmpty == true ? origin!.label : 'Start',
      legDistancesKm: legDistances,
      legSeaHops: legSeaHops,
      originDistanceKm: originDistanceKm,
      originSeaHops: originSeaPath?.hops ?? const [],
      returnDistanceKm: returnDistanceKm,
      returnSeaHops: returnSeaPath?.hops ?? const [],
      unconnectedIslands: matrix.unconnectedIslandGroups.toSet(),
    );

    final warnings = <String>[
      for (final island in matrix.unconnectedIslandGroups)
        'No ferry or pier link is mapped yet for $island; sea travel is estimated.',
      ...dayPlan.warnings,
    ];

    final usesSea = seaPathsUsed.any((p) => p.hops.isNotEmpty);
    final orderMethod = points.length <= 2
        ? 'requested'
        : usesSea
            ? 'island_aware'
            : points.length <= exactOrderMaxStops
                ? 'exact'
                : 'nearest_neighbor_2opt';

    final savedKm = math.max(
      0.0,
      baselineTotals.distanceKm - optimizedTotals.distanceKm,
    );
    final savedMin = math.max(
      0.0,
      baselineTotals.transitMinutes - optimizedTotals.transitMinutes,
    );
    final savedPct = baselineTotals.distanceKm > 1e-6
        ? (savedKm / baselineTotals.distanceKm) * 100.0
        : 0.0;

    return RoutePlanResult(
      orderedStops: orderedStops,
      days: dayPlan.days,
      suggestedDays: suggested,
      orderMethod: orderMethod,
      costSource: matrix.costSource,
      savingsVsInput: RouteSavings(
        baselineDistanceKm: baselineTotals.distanceKm,
        optimizedDistanceKm: optimizedTotals.distanceKm,
        distanceSavedKm: savedKm,
        distanceSavedPercent: savedPct,
        baselineTransitMinutes: baselineTotals.transitMinutes,
        optimizedTransitMinutes: optimizedTotals.transitMinutes,
        minutesSaved: savedMin,
      ),
      warnings: warnings,
      roundtrip: roundtrip,
      pace: pace,
      totalDistanceKm: optimizedTotals.distanceKm,
      totalTransitMinutes: optimizedTotals.transitMinutes,
      seaPathsUsed: seaPathsUsed,
    );
  }

  int _workingIndexForOriginal(
    List<RouteStopInput> original,
    List<RouteStopInput> working,
    int origIdx,
  ) {
    final targetId = original[origIdx].id;
    final found = working.indexWhere((s) => s.id == targetId);
    return found >= 0 ? found : origIdx;
  }

  ({double distanceKm, double transitMinutes}) _measureSequence({
    required CostMatrixResult matrix,
    required List<int> pointIndices,
    required bool hasOrigin,
    required bool roundtrip,
  }) {
    if (pointIndices.isEmpty) {
      return (distanceKm: 0.0, transitMinutes: 0.0);
    }
    var km = 0.0;
    var min = 0.0;
    if (hasOrigin) {
      km += matrix.distanceKm[0][pointIndices.first];
      min += matrix.transitMinutes[0][pointIndices.first];
    }
    for (var i = 0; i < pointIndices.length - 1; i++) {
      km += matrix.distanceKm[pointIndices[i]][pointIndices[i + 1]];
      min += matrix.transitMinutes[pointIndices[i]][pointIndices[i + 1]];
    }
    if (roundtrip) {
      final anchor = hasOrigin ? 0 : pointIndices.first;
      final last = pointIndices.last;
      if (last != anchor) {
        km += matrix.distanceKm[last][anchor];
        min += matrix.transitMinutes[last][anchor];
      }
    }
    return (distanceKm: km, transitMinutes: min);
  }

  /// Suggests a comfortable number of days (`1..14`) for [orderedStops] under [pace].
  int computeSuggestedDays({
    required List<RouteStopInput> orderedStops,
    required List<double> legTransitHours,
    TripPace pace = TripPace.balanced,
    double originTransitHours = 0.0,
    double returnTransitHours = 0.0,
  }) {
    final s = orderedStops.length;
    if (s == 0) return 1;

    final forcedBoundaries = <int>[
      for (var i = 0; i < s - 1; i++)
        if (orderedStops[i].forcesDayEnd) i,
    ];
    final minForOvernights = math.min(14, forcedBoundaries.length + 1);
    final extraMultiDays = orderedStops
        .where((stop) => stop.normalizedStayType == 'multi_day')
        .length;
    final budget = pace.hoursPerDay;

    var chosen = math.min(14, s);
    for (var d = minForOvernights; d <= math.min(14, s); d++) {
      final candidate = planDays(
        orderedStops: orderedStops,
        days: d,
        pace: pace,
        legTransitHours: legTransitHours,
        originTransitHours: originTransitHours,
        returnTransitHours: returnTransitHours,
      );
      final multiStopOverloaded = candidate.days.any(
        (day) => day.stops.length > 1 && day.totalHours > budget + 0.75,
      );
      if (!multiStopOverloaded) {
        chosen = d;
        break;
      }
    }

    return math.min(14, math.max(1, chosen + extraMultiDays));
  }

  /// Partitions [orderedStops] across [days] (`1..14`) using Linear-Partition DP
  /// when `days <= stops`, or spreading rest/continuation days when `days > stops`.
  /// Every stop appears exactly once in the resulting itinerary.
  ({List<PlannedDay> days, List<String> warnings}) planDays({
    required List<RouteStopInput> orderedStops,
    required int days,
    TripPace pace = TripPace.balanced,
    required List<double> legTransitHours,
    double originTransitHours = 0.0,
    double returnTransitHours = 0.0,
    String originLabel = 'Start',
    List<double>? legDistancesKm,
    List<List<SeaHop>>? legSeaHops,
    double originDistanceKm = 0.0,
    List<SeaHop> originSeaHops = const [],
    double returnDistanceKm = 0.0,
    List<SeaHop> returnSeaHops = const [],
    Set<String> unconnectedIslands = const {},
  }) {
    final s = orderedStops.length;
    final targetDays = days.clamp(1, 14);
    if (s == 0) return (days: const [], warnings: const []);

    final ranges = targetDays >= s
        ? <({int start, int end})>[
            for (var i = 0; i < s; i++) (start: i, end: i),
          ]
        : _linearPartition(
            orderedStops: orderedStops,
            days: targetDays,
            legTransitHours: legTransitHours,
            originTransitHours: originTransitHours,
            returnTransitHours: returnTransitHours,
          );

    final extraDaysPerStop = targetDays > s
        ? _allocateExtraDays(orderedStops, targetDays - s)
        : List<int>.filled(s, 0);

    final warnings = <String>[];
    final plannedDays = <PlannedDay>[];
    final budget = pace.hoursPerDay;
    var dayNumber = 1;

    // Warn when user chose fewer days than required overnight splits.
    if (targetDays < s) {
      var violations = 0;
      for (final range in ranges) {
        for (var i = range.start; i < range.end; i++) {
          if (orderedStops[i].forcesDayEnd) violations++;
        }
      }
      if (violations > 0) {
        warnings.add(
          'Too few days ($targetDays) to end each day after every overnight stop; add $violations more day${violations == 1 ? '' : 's'} if you plan to stay overnight at each.',
        );
      }
    }

    for (var rIdx = 0; rIdx < ranges.length; rIdx++) {
      final range = ranges[rIdx];
      final blockStops = orderedStops.sublist(range.start, range.end + 1);
      final isFinalStopRange = rIdx == ranges.length - 1;
      final extraAfterThis = isFinalStopRange && targetDays > s
          ? extraDaysPerStop[range.end]
          : 0;
      final includeReturnNow =
          returnDistanceKm > 0 || returnTransitHours > 0
              ? (isFinalStopRange && extraAfterThis == 0)
              : false;

      final legs = <PlannedLeg>[];
      var transitH = 0.0;

      if (range.start == 0) {
        if (originTransitHours > 0 || originDistanceKm > 0) {
          transitH += originTransitHours;
          legs.add(
            PlannedLeg(
              fromLabel: originLabel,
              toLabel: blockStops.first.name,
              distanceKm: originDistanceKm,
              transitMinutes: originTransitHours * 60.0,
              seaHops: originSeaHops,
              isEstimated: unconnectedIslands.contains(
                blockStops.first.normalizedIsland,
              ),
            ),
          );
        }
      } else {
        final prevStop = orderedStops[range.start - 1];
        final curStop = orderedStops[range.start];
        final h = _safeAt(legTransitHours, range.start - 1);
        final km = _safeAt(legDistancesKm, range.start - 1);
        final hops = _safeHops(legSeaHops, range.start - 1);
        transitH += h;
        legs.add(
          PlannedLeg(
            fromLabel: prevStop.name,
            toLabel: curStop.name,
            distanceKm: km,
            transitMinutes: h * 60.0,
            seaHops: hops,
            isEstimated:
                unconnectedIslands.contains(prevStop.normalizedIsland) ||
                unconnectedIslands.contains(curStop.normalizedIsland),
          ),
        );
      }

      for (var i = range.start; i < range.end; i++) {
        final a = orderedStops[i];
        final b = orderedStops[i + 1];
        final h = _safeAt(legTransitHours, i);
        final km = _safeAt(legDistancesKm, i);
        final hops = _safeHops(legSeaHops, i);
        transitH += h;
        legs.add(
          PlannedLeg(
            fromLabel: a.name,
            toLabel: b.name,
            distanceKm: km,
            transitMinutes: h * 60.0,
            seaHops: hops,
            isEstimated:
                unconnectedIslands.contains(a.normalizedIsland) ||
                unconnectedIslands.contains(b.normalizedIsland),
          ),
        );
      }

      if (includeReturnNow) {
        transitH += returnTransitHours;
        legs.add(
          PlannedLeg(
            fromLabel: blockStops.last.name,
            toLabel: originLabel,
            distanceKm: returnDistanceKm,
            transitMinutes: returnTransitHours * 60.0,
            seaHops: returnSeaHops,
            isEstimated: unconnectedIslands.contains(
              blockStops.last.normalizedIsland,
            ),
          ),
        );
      }

      final visitH = blockStops.fold<double>(
        0.0,
        (sum, stop) => sum + stop.visitHours,
      );
      final totalH = visitH + transitH;
      final isOverloaded = totalH > budget + 0.5 &&
          (blockStops.length > 1 || totalH > budget + 1.0);
      String? overloadMsg;
      if (isOverloaded) {
        overloadMsg =
            'Day $dayNumber is ${totalH.toStringAsFixed(1)} h (${pace.label.toLowerCase()} pace is ${budget.toStringAsFixed(0)} h). Add a day?';
        warnings.add(overloadMsg);
      }

      plannedDays.add(
        PlannedDay(
          dayNumber: dayNumber++,
          stops: blockStops,
          visitHours: visitH,
          transitHours: transitH,
          totalHours: totalH,
          legs: legs,
          isOverloaded: isOverloaded,
          overloadWarning: overloadMsg,
        ),
      );

      // Append any rest/continuation days allocated when targetDays > stops.
      final extra = targetDays > s ? extraDaysPerStop[range.end] : 0;
      for (var e = 0; e < extra; e++) {
        final isVeryLast = isFinalStopRange && e == extra - 1;
        final contLegs = <PlannedLeg>[];
        var contTransit = 0.0;
        if (isVeryLast && (returnDistanceKm > 0 || returnTransitHours > 0)) {
          contTransit = returnTransitHours;
          contLegs.add(
            PlannedLeg(
              fromLabel: blockStops.last.name,
              toLabel: originLabel,
              distanceKm: returnDistanceKm,
              transitMinutes: returnTransitHours * 60.0,
              seaHops: returnSeaHops,
              isEstimated: unconnectedIslands.contains(
                blockStops.last.normalizedIsland,
              ),
            ),
          );
        }
        plannedDays.add(
          PlannedDay(
            dayNumber: dayNumber++,
            stops: const [],
            visitHours: 0.0,
            transitHours: contTransit,
            totalHours: contTransit,
            legs: contLegs,
            isContinuationDay: true,
            continuationOfStop: blockStops.last,
          ),
        );
      }
    }

    return (days: plannedDays, warnings: warnings);
  }

  List<({int start, int end})> _linearPartition({
    required List<RouteStopInput> orderedStops,
    required int days,
    required List<double> legTransitHours,
    required double originTransitHours,
    required double returnTransitHours,
  }) {
    final s = orderedStops.length;
    if (days >= s) {
      return [for (var i = 0; i < s; i++) (start: i, end: i)];
    }
    if (days <= 1) {
      return [(start: 0, end: s - 1)];
    }

    final prefixVisit = List<double>.filled(s + 1, 0.0);
    final prefixLeg = List<double>.filled(s + 1, 0.0);
    for (var i = 0; i < s; i++) {
      prefixVisit[i + 1] = prefixVisit[i] + orderedStops[i].visitHours;
      if (i > 0) {
        prefixLeg[i + 1] = prefixLeg[i] + _safeAt(legTransitHours, i - 1);
      }
    }

    double blockLoad(int start, int end) {
      var load = prefixVisit[end + 1] - prefixVisit[start];
      if (start == 0) {
        load += originTransitHours;
      } else {
        load += _safeAt(legTransitHours, start - 1);
      }
      load += prefixLeg[end + 1] - prefixLeg[start + 1];
      if (end == s - 1) {
        load += returnTransitHours;
      }
      return load;
    }

    int blockViolations(int start, int end) {
      var count = 0;
      for (var i = start; i < end; i++) {
        if (orderedStops[i].forcesDayEnd) count++;
      }
      return count;
    }

    final totalAllLoad =
        prefixVisit[s] + prefixLeg[s] + originTransitHours + returnTransitHours;
    final meanLoad = totalAllLoad / days;

    // Pass 1: find exact global minimum (violations, maxDayLoad).
    const big = 1 << 20;
    final dpViol = List<List<int>>.generate(
      days + 1,
      (_) => List<int>.filled(s + 1, big),
    );
    final dpMax = List<List<double>>.generate(
      days + 1,
      (_) => List<double>.filled(s + 1, double.infinity),
    );
    dpViol[0][0] = 0;
    dpMax[0][0] = 0.0;

    for (var k = 1; k <= days; k++) {
      for (var p = k; p <= s; p++) {
        for (var cut = k - 1; cut < p; cut++) {
          if (dpViol[k - 1][cut] >= big) continue;
          final viol = dpViol[k - 1][cut] + blockViolations(cut, p - 1);
          final load = blockLoad(cut, p - 1);
          final maxLoad = math.max(dpMax[k - 1][cut], load);

          if (viol < dpViol[k][p] ||
              (viol == dpViol[k][p] &&
                  maxLoad < dpMax[k][p] - routeCostTieTolerance)) {
            dpViol[k][p] = viol;
            dpMax[k][p] = maxLoad;
          }
        }
      }
    }

    final targetViol = dpViol[days][s];
    final targetMax = dpMax[days][s] + routeCostTieTolerance;

    // Pass 2: minimize additive squared deviation under (targetViol, targetMax).
    final dpSqViol = List<List<int>>.generate(
      days + 1,
      (_) => List<int>.filled(s + 1, big),
    );
    final dpSq = List<List<double>>.generate(
      days + 1,
      (_) => List<double>.filled(s + 1, double.infinity),
    );
    final parentCut = List<List<int>>.generate(
      days + 1,
      (_) => List<int>.filled(s + 1, -1),
    );
    dpSqViol[0][0] = 0;
    dpSq[0][0] = 0.0;

    for (var k = 1; k <= days; k++) {
      for (var p = k; p <= s; p++) {
        for (var cut = k - 1; cut < p; cut++) {
          if (dpSqViol[k - 1][cut] >= big) continue;
          final load = blockLoad(cut, p - 1);
          if (load > targetMax) continue;
          final viol = dpSqViol[k - 1][cut] + blockViolations(cut, p - 1);
          if (viol > targetViol) continue;
          final diff = load - meanLoad;
          final sq = dpSq[k - 1][cut] + diff * diff;

          if (viol < dpSqViol[k][p] ||
              (viol == dpSqViol[k][p] &&
                  sq < dpSq[k][p] - routeCostTieTolerance)) {
            dpSqViol[k][p] = viol;
            dpSq[k][p] = sq;
            parentCut[k][p] = cut;
          }
        }
      }
    }

    final reversed = <({int start, int end})>[];
    var curP = s;
    for (var k = days; k >= 1; k--) {
      final cut = parentCut[k][curP];
      if (cut < 0) {
        // Defensive fallback if Pass 2 tolerance edge missed.
        return [for (var i = 0; i < days - 1; i++) (start: i, end: i), (start: days - 1, end: s - 1)];
      }
      reversed.add((start: cut, end: curP - 1));
      curP = cut;
    }
    return reversed.reversed.toList();
  }

  List<int> _allocateExtraDays(List<RouteStopInput> stops, int extraCount) {
    final s = stops.length;
    final extra = List<int>.filled(s, 0);
    double priority(int i) {
      final key = stops[i].normalizedStayType;
      var score = switch (key) {
        'multi_day' => 6.0,
        'overnight' => 4.0,
        'full_day' => 2.0,
        'half_day' => 1.0,
        _ => 0.5,
      };
      if (i == s - 1) score += 0.2;
      return score;
    }

    for (var step = 0; step < extraCount; step++) {
      var bestIdx = 0;
      var bestScore = -double.infinity;
      for (var i = 0; i < s; i++) {
        final cand = priority(i) - extra[i] * 2.0;
        if (cand > bestScore + routeCostTieTolerance) {
          bestScore = cand;
          bestIdx = i;
        }
      }
      extra[bestIdx]++;
    }
    return extra;
  }

  double _safeAt(List<double>? values, int idx) {
    if (values == null || idx < 0 || idx >= values.length) return 0.0;
    return values[idx];
  }

  List<SeaHop> _safeHops(List<List<SeaHop>>? values, int idx) {
    if (values == null || idx < 0 || idx >= values.length) return const [];
    return values[idx];
  }

  static bool _lexLess(List<int> a, List<int> b) {
    final len = math.min(a.length, b.length);
    for (var i = 0; i < len; i++) {
      if (a[i] != b[i]) return a[i] < b[i];
    }
    return a.length < b.length;
  }
}
