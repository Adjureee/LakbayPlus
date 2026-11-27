import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lakbay_travel/models/travel_models.dart';
import 'package:lakbay_travel/screens/trip_detail_screen.dart';
import 'package:lakbay_travel/screens/trip_route_map_screen.dart';
import 'package:lakbay_travel/services/lakbay_api_catalog_service.dart';
import 'package:lakbay_travel/services/location_service.dart';
import 'package:lakbay_travel/services/route_summary.dart';
import 'package:lakbay_travel/services/travel_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _davao = GeoPoint(lat: 7.0731, lng: 125.6128, label: 'Davao City');
const _samal = GeoPoint(lat: 7.0744, lng: 125.7087, label: 'Samal');
const _mati = GeoPoint(lat: 6.9551, lng: 126.2185, label: 'Mati');

BackendRouteResult _route({
  double km = 82.7,
  int minutes = 94,
  bool estimated = false,
  String? provider,
}) =>
    BackendRouteResult(
      routeProvider: provider ?? (estimated ? 'haversine' : 'mapbox'),
      isEstimated: estimated,
      totalDistanceKm: km,
      totalDurationMinutes: minutes,
      geometryPoints: const [],
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('the route summary says what kind of number it is', () {
    test('a road route shows its distance, time, mode and that it is a road route', () {
      final mapboxDriving = RouteSummaryText.line(
        route: _route(),
        stops: const [_samal],
        mode: 'driving',
      );
      expect(mapboxDriving, '83 km • 1 h 34 min • Private car • with current traffic');

      final osrmDriving = RouteSummaryText.line(
        route: _route(provider: 'osrm'),
        stops: const [_samal],
        mode: 'driving',
      );
      expect(osrmDriving, '83 km • 1 h 34 min • Private car • road route');
    });

    test('an estimated route is labelled an estimate', () {
      final line = RouteSummaryText.line(
        route: _route(km: 8.2, minutes: 45, estimated: true),
        stops: const [_samal],
        mode: 'public_transport',
      );
      expect(line, '8.2 km • 45 min • Public transit • estimate');
    });

    test('with no route, the straight line from the traveler is shown and says so', () {
      final line = RouteSummaryText.line(
        stops: const [_samal],
        origin: _davao,
        mode: 'walking',
      );
      expect(line, startsWith('≈ '));
      expect(line, endsWith('km from your location (straight line)'));
    });

    test('one stop and no starting point has no distance, not 0 km', () {
      expect(RouteSummaryText.line(stops: const [_samal]), isNull);
      expect(RouteSummaryText.chip(stops: const [_samal]), isNull);
    });

    test('with several stops and no start, the straight line between stops is labelled', () {
      final line = RouteSummaryText.line(stops: const [_samal, _mati]);
      expect(line, endsWith('km between stops (straight line)'));
    });

    test('a single place is never "0 km" once the traveler has a starting point', () {
      final chip = RouteSummaryText.chip(stops: const [_samal], origin: _davao);
      expect(chip, isNotNull);
      expect(chip!.value, isNot(contains('0 km')));
      expect(chip.qualifier, 'from you, straight line');
    });

    test('durations read naturally', () {
      expect(RouteSummaryText.durationText(0), '');
      expect(RouteSummaryText.durationText(45), '45 min');
      expect(RouteSummaryText.durationText(120), '2 h');
      expect(RouteSummaryText.durationText(94), '1 h 34 min');
    });
  });

  group('a new trip is built only from real catalog places', () {
    test('every stop is a catalog place with its real coordinates, and nothing is invented', () async {
      final repo = TravelRepository();
      await repo.initialize();
      final catalog = {for (final t in repo.allTrips) t.title: t};

      final trip = repo.generateCustomTrip(
        destination: 'Samal Island',
        daysCount: 3,
        vibe: 'Beach',
      );

      final stops = trip.days.expand((d) => d.stops).toList();
      expect(stops, isNotEmpty);
      for (final stop in stops) {
        final place = catalog[stop.title];
        expect(place, isNotNull, reason: '${stop.title} is not a catalog place');
        expect(stop.lat, place!.lat);
        expect(stop.lng, place.lng);
        expect(stop.time, isEmpty); // no invented schedule
        expect(stop.costEstimateUsd, 0); // no invented cost
      }
      // The typed-in meal and viewpoint stops, flights and hotels are gone.
      final text = jsonEncode(trip.toJson());
      for (final invented in ['Morning Highlight', 'Culinary Stop', 'Golden Hour', 'Cebu Pacific', 'Sasa Wharf']) {
        expect(text.contains(invented), isFalse, reason: 'found "$invented"');
      }
      expect(trip.flights, isEmpty);
      expect(trip.hotels, isEmpty);
      expect(trip.days.every((d) => d.transportDuration == null), isTrue);
    });

    test('a destination the catalog does not know gets empty days, not made-up ones', () async {
      final repo = TravelRepository();
      await repo.initialize();

      final trip = repo.generateCustomTrip(
        destination: 'Atlantis',
        daysCount: 2,
        vibe: 'Beach',
      );

      expect(trip.days, hasLength(2));
      expect(trip.days.expand((d) => d.stops), isEmpty);
      expect(trip.days.first.summary, 'No places added to this day yet.');
    });

    test('a trip with no known costs says "cost not listed" instead of assuming a daily rate', () async {
      final repo = TravelRepository();
      await repo.initialize();
      final trip = repo.generateCustomTrip(destination: 'Atlantis', daysCount: 4, vibe: 'x');

      expect(trip.totalEstimatedCostUsd, 0);
      expect(trip.hasCostEstimate, isFalse);
    });

    testWidgets('the trip screen shows "Cost not listed" and no distance of 0', (tester) async {
      final repo = TravelRepository(apiCatalog: LakbayApiCatalogService(baseUrlOverride: ''));
      await tester.runAsync(() => repo.initialize());
      final trip = repo.generateCustomTrip(destination: 'Atlantis', daysCount: 2, vibe: 'x');

      await tester.pumpWidget(MaterialApp(home: TripDetailScreen(trip: trip, repo: repo)));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('Cost not listed'), findsWidgets);
      expect(find.textContaining('Region XI Route'), findsNothing);
      expect(find.textContaining(' 0 km'), findsNothing);
    });
  });

  group('access trails', () {
    test('a place keeps the trail the admin drew, and one without has none', () async {
      // Google's documented example polyline: it only has to decode here.
      const trail = '_p~iF~ps|U_ulLnnqC_mqNvxq`@';
      final client = MockClient((request) async {
        if (request.url.path.endsWith('/destinations')) {
          return http.Response(
            jsonEncode({
              'items': [
                {
                  'destination_id': 1, 'name': 'Trail Falls', 'lat': 7.3, 'lng': 126.1,
                  'category': 'waterfall', 'access_trail_polyline': trail,
                },
                {'destination_id': 2, 'name': 'No Trail Beach', 'lat': 7.0, 'lng': 125.7, 'category': 'beach'},
              ],
              'total': 2,
            }),
            200,
          );
        }
        return http.Response('{}', 404);
      });
      final catalog = LakbayApiCatalogService(
        baseUrlOverride: 'https://api.lakbay.test/api/v1',
        client: client,
      );

      final places = await catalog.fetchAllActiveDestinations();

      final withTrail = places.firstWhere((p) => p.title == 'Trail Falls');
      final without = places.firstWhere((p) => p.title == 'No Trail Beach');
      expect(withTrail.accessTrailPolyline, trail);
      expect(without.accessTrailPolyline, isNull);
      expect(LakbayApiCatalogService.decodePolyline5(trail), hasLength(3));
      // Saved and loaded again, it is still there.
      expect(ExploreTrip.fromJson(withTrail.toJson()).accessTrailPolyline, trail);
    });
  });

  group('the map', () {
    testWidgets('offers car, public transit and walking, and each loads its own route', (tester) async {
      final modes = <String>[];
      final client = MockClient((request) async {
        final path = request.url.path.replaceFirst('/api/v1', '');
        if (path.startsWith('/routes/')) {
          final body = request.body.isEmpty
              ? <String, dynamic>{}
              : jsonDecode(request.body) as Map<String, dynamic>;
          modes.add('${body['travel_mode']}');
        }
        return http.Response('{}', 404);
      });
      final repo = TravelRepository(
        apiCatalog: LakbayApiCatalogService(
          baseUrlOverride: 'https://api.lakbay.test/api/v1',
          client: client,
        ),
        locationService: LocationService(
          customFetcher: () async => const LocationResult(granted: false, statusMessage: 'Declined'),
        ),
      );
      await tester.runAsync(() => repo.initialize());
      final trip = repo
          .generateCustomTrip(destination: 'Samal Island', daysCount: 2, vibe: 'Beach')
          .copyWith(backendDestinationIds: [1, 2]);

      await tester.pumpWidget(MaterialApp(home: TripRouteMapScreen(trip: trip, repo: repo)));
      await tester.pump();
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('Private car'), findsOneWidget);
      expect(find.text('Public transit'), findsOneWidget);
      expect(find.text('Walking'), findsOneWidget);
      expect(modes, isNotEmpty);
      expect(modes.toSet(), {'driving'}); // the default mode

      modes.clear();
      await tester.tap(find.text('Public transit'));
      await tester.pump();
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump(const Duration(milliseconds: 300));
      expect(modes.toSet(), {'public_transport'});
      expect(repo.preferredTravelMode, 'public_transport');

      modes.clear();
      await tester.tap(find.text('Walking'));
      await tester.pump();
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump(const Duration(milliseconds: 300));
      expect(modes.toSet(), {'walking'});
      expect(repo.preferredTravelMode, 'walking');
    });
  });
}
