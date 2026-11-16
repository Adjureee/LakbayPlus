import 'dart:math' as math;

import '../models/travel_models.dart';

/// A catalog place close to a trip, for "what else is nearby" on the map.
class NearbyPlace {
  final ExploreTrip place;

  /// Straight-line distance to the closest trip stop.
  final double distanceKm;

  /// Name of that closest stop, for "3.2 km from Tagbibinta Falls".
  final String nearestStopName;

  const NearbyPlace({
    required this.place,
    required this.distanceKm,
    required this.nearestStopName,
  });
}

/// Catalog places within [radiusKm] of any stop of [trip], excluding the
/// trip's own destinations, nearest first, at most [limit].
List<NearbyPlace> nearbyPlacesForTrip(
  ItineraryTrip trip,
  Iterable<ExploreTrip> catalog, {
  double radiusKm = 10,
  int limit = 15,
}) {
  final anchors = <({double lat, double lng, String name})>[];
  for (final day in trip.days) {
    final stops = day.stops.where((s) => s.category != 'stay').toList();
    if (stops.isEmpty) {
      if (!day.isContinuationDay) {
        anchors.add((lat: day.lat, lng: day.lng, name: day.cityTitle));
      }
      continue;
    }
    for (final stop in stops) {
      anchors.add((lat: stop.lat, lng: stop.lng, name: stop.title));
    }
  }
  if (anchors.isEmpty) return const [];

  final ownIds = trip.effectiveBackendDestinationIds.toSet();
  final results = <NearbyPlace>[];
  for (final place in catalog) {
    final placeId =
        place.apiDestinationId ??
        (place.id.startsWith('api_')
            ? int.tryParse(place.id.substring(4))
            : null);
    if (placeId != null && ownIds.contains(placeId)) continue;

    var best = double.infinity;
    var bestName = '';
    for (final anchor in anchors) {
      final km = haversineKm(anchor.lat, anchor.lng, place.lat, place.lng);
      if (km < best) {
        best = km;
        bestName = anchor.name;
      }
    }
    // A place at a stop's exact spot is that stop under another id.
    if (best <= radiusKm && best > 0.05) {
      results.add(
        NearbyPlace(place: place, distanceKm: best, nearestStopName: bestName),
      );
    }
  }
  results.sort((a, b) => a.distanceKm.compareTo(b.distanceKm));
  return results.take(limit).toList();
}

double haversineKm(double lat1, double lng1, double lat2, double lng2) {
  double rad(double degrees) => degrees * math.pi / 180;
  final h =
      math.pow(math.sin(rad(lat2 - lat1) / 2), 2) +
      math.cos(rad(lat1)) *
          math.cos(rad(lat2)) *
          math.pow(math.sin(rad(lng2 - lng1) / 2), 2);
  return 2 * 6371 * math.asin(math.sqrt(h));
}

/// Adds [place] to [trip] right after its closest stop, on that stop's day.
/// The new stop carries the destination id, so the next route request
/// includes it. Cached road geometry is dropped because it no longer matches.
ItineraryTrip addPlaceToTrip(ItineraryTrip trip, ExploreTrip place) {
  final placeId =
      place.apiDestinationId ??
      (place.id.startsWith('api_')
          ? int.tryParse(place.id.substring(4))
          : null);
  if (placeId != null &&
      trip.effectiveBackendDestinationIds.contains(placeId)) {
    return trip;
  }
  final newStop = ItineraryStop(
    time: '',
    title: place.title,
    description: place.description ?? place.municipalityLabel,
    category: 'sight',
    lat: place.lat,
    lng: place.lng,
    destinationId: placeId,
    stayDurationType: place.stayDurationType,
    islandGroup: place.islandGroup,
  );

  // Closest stop decides the day and position.
  var bestDay = -1, bestStop = -1;
  var best = double.infinity;
  for (var d = 0; d < trip.days.length; d++) {
    final day = trip.days[d];
    if (day.stops.isEmpty) {
      final km = haversineKm(day.lat, day.lng, place.lat, place.lng);
      if (km < best && !day.isContinuationDay) {
        best = km;
        bestDay = d;
        bestStop = -1;
      }
    }
    for (var s = 0; s < day.stops.length; s++) {
      final stop = day.stops[s];
      final km = haversineKm(stop.lat, stop.lng, place.lat, place.lng);
      if (km < best) {
        best = km;
        bestDay = d;
        bestStop = s;
      }
    }
  }
  if (bestDay < 0) return trip;

  final days = [
    for (var d = 0; d < trip.days.length; d++)
      if (d != bestDay)
        trip.days[d]
      else
        trip.days[d].copyWith(
          stops: [
            ...trip.days[d].stops.take(bestStop + 1),
            newStop,
            ...trip.days[d].stops.skip(bestStop + 1),
          ],
        ),
  ];

  // Keep the route order following the itinerary order.
  final ordered = <int>[];
  void addId(int? id) {
    if (id != null && !ordered.contains(id)) ordered.add(id);
  }

  for (final day in days) {
    addId(day.apiDestinationId);
    for (final stop in day.stops) {
      addId(stop.destinationId);
    }
  }
  for (final id in trip.backendDestinationIds) {
    addId(id);
  }

  return trip.copyWith(
    days: days,
    backendDestinationIds: ordered,
    routeSegments: const [],
  );
}
