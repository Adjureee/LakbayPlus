import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:lakbay_travel/models/travel_models.dart';
import 'package:lakbay_travel/screens/trip_detail_screen.dart';
import 'package:lakbay_travel/screens/trip_route_map_screen.dart';
import 'package:lakbay_travel/services/lakbay_api_catalog_service.dart';
import 'package:lakbay_travel/services/location_service.dart';
import 'package:lakbay_travel/services/mapbox_service.dart';
import 'package:lakbay_travel/services/route_summary.dart';
import 'package:lakbay_travel/services/travel_repository.dart';

const _samal = GeoPoint(lat: 7.0794, lng: 125.7024, label: 'Samal');

BackendRouteResult _route({
  String provider = 'mapbox',
  bool estimated = false,
  double km = 24.0,
  int minutes = 42,
}) =>
    BackendRouteResult(
      routeProvider: provider,
      isEstimated: estimated,
      totalDistanceKm: km,
      totalDurationMinutes: minutes,
      geometryPoints: const [_samal],
    );

TravelRepository _makeRepo({http.Client? client}) => TravelRepository(
      apiCatalog: LakbayApiCatalogService(
        baseUrlOverride: 'https://api.lakbay.test/api/v1',
        client: client ?? MockClient((_) async => http.Response('{}', 404)),
      ),
      locationService: LocationService(
        customFetcher: () async =>
            const LocationResult(granted: false, statusMessage: 'Declined'),
      ),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('RouteSummaryText cycling and Mapbox traffic qualifier', () {
    test('modeLabel supports cycling', () {
      expect(RouteSummaryText.modeLabel('cycling'), 'Cycling');
    });

    test('shows "with current traffic" only for non-estimated Mapbox driving', () {
      final mapboxDrivingLine = RouteSummaryText.line(
        route: _route(provider: 'mapbox', estimated: false),
        stops: const [_samal],
        mode: 'driving',
      );
      expect(mapboxDrivingLine, '24 km • 42 min • Private car • with current traffic');

      final mapboxDrivingChip = RouteSummaryText.chip(
        route: _route(provider: 'mapbox', estimated: false),
        stops: const [_samal],
        mode: 'driving',
      );
      expect(mapboxDrivingChip?.qualifier, 'with current traffic');

      // OSRM driving must NOT say "with current traffic"
      final osrmDrivingLine = RouteSummaryText.line(
        route: _route(provider: 'osrm', estimated: false),
        stops: const [_samal],
        mode: 'driving',
      );
      expect(osrmDrivingLine, '24 km • 42 min • Private car • road route');

      // Mapbox cycling must NOT say "with current traffic"
      final mapboxCyclingLine = RouteSummaryText.line(
        route: _route(provider: 'mapbox', estimated: false),
        stops: const [_samal],
        mode: 'cycling',
      );
      expect(mapboxCyclingLine, '24 km • 42 min • Cycling • road route');

      // Mapbox walking must NOT say "with current traffic"
      final mapboxWalkingChip = RouteSummaryText.chip(
        route: _route(provider: 'mapbox', estimated: false),
        stops: const [_samal],
        mode: 'walking',
      );
      expect(mapboxWalkingChip?.qualifier, 'road route');

      // Estimated route must always say "estimate"
      final estCyclingLine = RouteSummaryText.line(
        route: _route(provider: 'haversine', estimated: true),
        stops: const [_samal],
        mode: 'cycling',
      );
      expect(estCyclingLine, '24 km • 42 min • Cycling • estimate');
    });
  });

  group('MapboxStylePreset.navigationDay and tile URLs', () {
    test('navigationDay preset has id navigation-day-v1 and title Traffic', () {
      expect(MapboxStylePreset.navigationDay.id, 'navigation-day-v1');
      expect(MapboxStylePreset.navigationDay.title, 'Traffic');

      final svc = MapboxService()..setCustomToken('pk.test_token_123');
      expect(
        svc.buildTileUrl(style: MapboxStylePreset.navigationDay, z: 10, x: 1, y: 2),
        contains('/styles/v1/mapbox/navigation-day-v1/tiles/256/10/1/2@2x'),
      );
      expect(
        svc.buildTileUrl(style: MapboxStylePreset.navigationNight, z: 10, x: 1, y: 2),
        contains('/styles/v1/mapbox/navigation-night-v1/tiles/256/10/1/2@2x'),
      );
    });
  });

  group('TravelRepository persistence for cycling and live traffic', () {
    test('remembers preferredTravelMode cycling across restart', () async {
      final repo1 = _makeRepo();
      await repo1.initialize();
      repo1.setPreferredTravelMode('cycling');
      await Future<void>.delayed(const Duration(milliseconds: 250));

      final repo2 = _makeRepo();
      await repo2.initialize();
      expect(repo2.preferredTravelMode, 'cycling');
    });

    test('traffic toggle uses navigationDay/navigationNight, restores style, remembers state, and blocks Satellite', () async {
      final repo1 = _makeRepo();
      await repo1.initialize();

      // Off by default on Outdoors
      expect(repo1.showLiveTraffic, isFalse);
      expect(repo1.activeMapStyle, MapboxStylePreset.outdoors);

      // Turn on -> navigationDay
      repo1.setLiveTrafficEnabled(true);
      expect(repo1.showLiveTraffic, isTrue);
      expect(repo1.activeMapStyle, MapboxStylePreset.navigationDay);

      // Persists across restart
      await Future<void>.delayed(const Duration(milliseconds: 250));
      final repo2 = _makeRepo();
      await repo2.initialize();
      expect(repo2.showLiveTraffic, isTrue);
      expect(repo2.activeMapStyle, MapboxStylePreset.navigationDay);

      // Turning off restores Outdoors
      repo2.setLiveTrafficEnabled(false);
      expect(repo2.showLiveTraffic, isFalse);
      expect(repo2.activeMapStyle, MapboxStylePreset.outdoors);

      // Night Nav stays navigationNight when traffic is toggled on and restores Night Nav on off
      repo2.setMapboxStyle(MapboxStylePreset.navigationNight);
      repo2.setLiveTrafficEnabled(true);
      expect(repo2.showLiveTraffic, isTrue);
      expect(repo2.activeMapStyle, MapboxStylePreset.navigationNight);
      repo2.setLiveTrafficEnabled(false);
      expect(repo2.showLiveTraffic, isFalse);
      expect(repo2.activeMapStyle, MapboxStylePreset.navigationNight);

      // Satellite disables traffic toggle
      repo2.setMapboxStyle(MapboxStylePreset.satelliteStreets);
      expect(repo2.canToggleLiveTraffic, isFalse);
      repo2.setLiveTrafficEnabled(true);
      expect(repo2.showLiveTraffic, isFalse);
      expect(repo2.activeMapStyle, MapboxStylePreset.satelliteStreets);
    });
  });

  group('UI controls on TripRouteMapScreen and TripDetailScreen', () {
    testWidgets('TripRouteMapScreen has Cycling chip and Traffic toggle with Satellite guard and regional note', (tester) async {
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
      final repo = _makeRepo(client: client);
      await tester.runAsync(() => repo.initialize());
      final trip = repo
          .generateCustomTrip(destination: 'Samal Island', daysCount: 2, vibe: 'Beach')
          .copyWith(backendDestinationIds: [1, 2]);

      await tester.pumpWidget(MaterialApp(home: TripRouteMapScreen(trip: trip, repo: repo)));
      await tester.pump();
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump(const Duration(milliseconds: 300));

      // Cycling chip exists and re-fetches with cycling
      expect(find.text('Cycling'), findsOneWidget);
      modes.clear();
      await tester.tap(find.text('Cycling'));
      await tester.pump();
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump(const Duration(milliseconds: 300));
      expect(modes.toSet(), {'cycling'});
      expect(repo.preferredTravelMode, 'cycling');

      // Traffic toggle starts off, no note yet
      final trafficFinder = find.byKey(const ValueKey('traffic-toggle-chip'));
      expect(trafficFinder, findsOneWidget);
      expect(repo.showLiveTraffic, isFalse);
      expect(find.text('Live traffic data is limited in this region'), findsNothing);

      // Tap Traffic -> switches to navigationDay and shows note
      await tester.tap(trafficFinder);
      await tester.pump();
      expect(repo.showLiveTraffic, isTrue);
      expect(repo.activeMapStyle, MapboxStylePreset.navigationDay);
      expect(find.text('Live traffic data is limited in this region'), findsOneWidget);

      // Tap Traffic again -> restores outdoors and hides note
      await tester.tap(trafficFinder);
      await tester.pump();
      expect(repo.showLiveTraffic, isFalse);
      expect(repo.activeMapStyle, MapboxStylePreset.outdoors);
      expect(find.text('Live traffic data is limited in this region'), findsNothing);

      // Switch to Satellite -> Traffic toggle disabled with one-line reason
      repo.setMapboxStyle(MapboxStylePreset.satelliteStreets);
      await tester.pump();
      final chip = tester.widget<FilterChip>(trafficFinder);
      expect(chip.onSelected, isNull);
      expect(find.text('Traffic is unavailable on Satellite view.'), findsOneWidget);
    });

    testWidgets('TripDetailScreen has Cycling ChoiceChip beside other modes', (tester) async {
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
      final repo = _makeRepo(client: client);
      await tester.runAsync(() => repo.initialize());
      final trip = repo
          .generateCustomTrip(destination: 'Samal Island', daysCount: 2, vibe: 'Beach')
          .copyWith(backendDestinationIds: [1, 2]);

      await tester.pumpWidget(MaterialApp(home: TripDetailScreen(trip: trip, repo: repo)));
      await tester.pump();
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump(const Duration(milliseconds: 300));

      final cyclingChip = find.widgetWithText(ChoiceChip, 'Cycling');
      await tester.ensureVisible(cyclingChip);
      expect(cyclingChip, findsOneWidget);

      modes.clear();
      await tester.tap(cyclingChip);
      await tester.pump();
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump(const Duration(milliseconds: 300));
      expect(modes.toSet(), {'cycling'});
      expect(repo.preferredTravelMode, 'cycling');
    });
  });
}
