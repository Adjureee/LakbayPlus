import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lakbay_travel/models/travel_models.dart';
import 'package:lakbay_travel/screens/explore_screen.dart';
import 'package:lakbay_travel/screens/trip_detail_screen.dart';
import 'package:lakbay_travel/services/lakbay_api_catalog_service.dart';
import 'package:lakbay_travel/services/route_optimizer.dart';
import 'package:lakbay_travel/services/travel_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

List<ExploreTrip> _samplePlaces() => const [
      ExploreTrip(
        locale: 'en',
        id: 'api_1',
        apiDestinationId: 1,
        title: 'Eden Nature Park',
        days: 1,
        lat: 7.0247,
        lng: 125.4375,
        thumbnailUrl: '',
        tag: 'Nature',
        district: 'Toril, Davao City',
        islandGroup: 'mainland',
        stayDurationType: 'half_day',
      ),
      ExploreTrip(
        locale: 'en',
        id: 'api_2',
        apiDestinationId: 2,
        title: 'Philippine Eagle Center',
        days: 1,
        lat: 7.1856,
        lng: 125.4158,
        thumbnailUrl: '',
        tag: 'Wildlife',
        district: 'Calinan, Davao City',
        islandGroup: 'mainland',
        stayDurationType: 'half_day',
      ),
      ExploreTrip(
        locale: 'en',
        id: 'api_4',
        apiDestinationId: 4,
        title: 'Samal Island Beach Area',
        days: 1,
        lat: 7.0715,
        lng: 125.7069,
        thumbnailUrl: '',
        tag: 'Beach',
        district: 'IGACOS, Davao del Norte',
        islandGroup: 'samal',
        stayDurationType: 'full_day',
      ),
      ExploreTrip(
        locale: 'en',
        id: 'api_3',
        apiDestinationId: 3,
        title: 'Dahican Beach',
        days: 1,
        lat: 6.9567,
        lng: 126.2789,
        thumbnailUrl: '',
        tag: 'Beach',
        district: 'Mati City, Davao Oriental',
        islandGroup: 'mainland',
        stayDurationType: 'full_day',
      ),
      ExploreTrip(
        locale: 'en',
        id: 'api_15',
        apiDestinationId: 15,
        title: 'Mount Apo (Kapatagan Trailhead)',
        days: 1,
        lat: 6.9322,
        lng: 125.3036,
        thumbnailUrl: '',
        tag: 'Adventure',
        district: 'Digos / Santa Cruz',
        islandGroup: 'mainland',
        stayDurationType: 'half_day',
      ),
    ];

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('buildMultiStopExploreTrip keeps all 5 places in 3 days without drops', () async {
    final repo = TravelRepository(
      apiCatalog: LakbayApiCatalogService(baseUrlOverride: ''),
    );
    final places = _samplePlaces();
    for (final p in places) {
      repo.toggleTripBuilderStop(p);
    }

    final trip = await repo.buildMultiStopExploreTrip(
      daysCount: 3,
      refineWithBackend: false,
    );

    expect(trip.days.length, 3);
    expect(trip.daysCount, 3);
    final stopTitles = trip.days.expand((d) => d.stops).map((s) => s.title).toList();
    expect(stopTitles.length, 5);
    expect(stopTitles.toSet().length, 5);
    for (final p in places) {
      expect(stopTitles, contains(p.title));
    }
    expect(trip.routeWaypoints.length, 5);
    expect(trip.optimizationSummary, isNotNull);
    expect(trip.effectiveBackendDestinationIds.toSet(), {1, 2, 3, 4, 15});
  });

  test('buildMultiStopExploreTrip spreads 2 places across 5 days without repeats', () async {
    final repo = TravelRepository(
      apiCatalog: LakbayApiCatalogService(baseUrlOverride: ''),
    );
    final places = _samplePlaces().take(2).toList();
    for (final p in places) {
      repo.toggleTripBuilderStop(p);
    }

    final trip = await repo.buildMultiStopExploreTrip(
      daysCount: 5,
      refineWithBackend: false,
    );

    expect(trip.days.length, 5);
    final activeDays = trip.days.where((d) => !d.isContinuationDay).toList();
    final contDays = trip.days.where((d) => d.isContinuationDay).toList();
    expect(activeDays.length, 2);
    expect(contDays.length, 3);
    // Waypoints on the map must only cover the 2 real stops (no zero-length dupes).
    expect(trip.routeWaypoints.length, 2);
  });

  test('buildMultiStopExploreTrip refines guest route via /routes/plan/guest and persists', () async {
    Uri? capturedUri;
    Map<String, dynamic>? capturedBody;

    final mockClient = MockClient((request) async {
      capturedUri = request.url;
      capturedBody = jsonDecode(request.body) as Map<String, dynamic>;
      return http.Response(
        jsonEncode({
          'order_method': 'exact_held_karp',
          'cost_source': 'osrm',
          'suggested_days': 3,
          'pace': 'balanced',
          'savings_vs_input': {
            'baseline_distance_km': 304.93,
            'optimized_distance_km': 222.47,
            'distance_saved_km': 82.46,
            'distance_saved_percent': 27.0,
            'baseline_transit_minutes': 457.0,
            'optimized_transit_minutes': 271.0,
            'minutes_saved': 186.0,
          },
          'warnings': <String>[],
          'skipped_destination_ids': <int>[],
          'days': [
            {
              'day_number': 1,
              'stops': [
                {
                  'destination_id': 1,
                  'name': 'Eden Nature Park',
                  'lat': 7.0247,
                  'lng': 125.4375,
                  'island_group': 'mainland',
                  'stay_duration_type': 'half_day',
                  'visit_hours': 4.0,
                },
                {
                  'destination_id': 2,
                  'name': 'Philippine Eagle Center',
                  'lat': 7.1856,
                  'lng': 125.4158,
                  'island_group': 'mainland',
                  'stay_duration_type': 'half_day',
                  'visit_hours': 4.0,
                },
              ],
              'visit_hours': 8.0,
              'transit_hours': 0.55,
              'total_hours': 8.55,
              'is_continuation_day': false,
              'is_overloaded': false,
            },
            {
              'day_number': 2,
              'stops': [
                {
                  'destination_id': 4,
                  'name': 'Samal Island Beach Area',
                  'lat': 7.0715,
                  'lng': 125.7069,
                  'island_group': 'samal',
                  'stay_duration_type': 'full_day',
                  'visit_hours': 7.0,
                },
              ],
              'visit_hours': 7.0,
              'transit_hours': 1.25,
              'total_hours': 8.25,
              'is_continuation_day': false,
              'is_overloaded': false,
            },
            {
              'day_number': 3,
              'stops': [
                {
                  'destination_id': 3,
                  'name': 'Dahican Beach',
                  'lat': 6.9567,
                  'lng': 126.2789,
                  'island_group': 'mainland',
                  'stay_duration_type': 'full_day',
                  'visit_hours': 7.0,
                },
              ],
              'visit_hours': 7.0,
              'transit_hours': 2.75,
              'total_hours': 9.75,
              'is_continuation_day': false,
              'is_overloaded': false,
            },
          ],
          'route': {
            'travel_mode': 'driving',
            'route_provider': 'osrm',
            'is_estimated': false,
            'order_method': 'exact_held_karp',
            'total_distance_km': 222.47,
            'total_duration_minutes': 271,
            'stops': [
              {'destination_id': 1},
              {'destination_id': 2},
              {'destination_id': 4},
              {'destination_id': 3},
            ],
            'legs': <dynamic>[],
            'warnings': <String>[],
            'sea_crossings': [
              {
                'vessel_type': 'roro_barge',
                'board_port': 'Sasa RoRo Wharf (Davao City)',
                'land_port': 'Babak RoRo Landing (Samal)',
                'board_lat': 7.1236,
                'board_lng': 125.6578,
                'land_lat': 7.1279,
                'land_lng': 125.7064,
                'crossing_minutes': 15,
                'typical_wait_minutes': 20,
                'allows_private_vehicle': true,
                'verified': true,
              },
            ],
            'segments': [
              {
                'order': 1,
                'mode': 'road',
                'from_name': 'Eden Nature Park',
                'to_name': 'Sasa RoRo Wharf',
                'polyline': '_ibE_seK_ibE_seK',
                'is_estimated': false,
              },
              {
                'order': 2,
                'mode': 'sea',
                'from_name': 'Sasa RoRo Wharf',
                'to_name': 'Babak RoRo Landing',
                'polyline': '_ibE_seK_ibE_seK',
                'is_estimated': false,
              },
            ],
          },
        }),
        200,
      );
    });

    final repo = TravelRepository(
      apiCatalog: LakbayApiCatalogService(
        client: mockClient,
        baseUrlOverride: 'https://api.lakbay.test/api/v1',
      ),
    );
    for (final p in _samplePlaces().take(4)) {
      repo.toggleTripBuilderStop(p);
    }
    repo.toggleLockedFirstStop('api_1');

    final trip = await repo.buildMultiStopExploreTrip(daysCount: 3);

    expect(capturedUri?.path, '/api/v1/routes/plan/guest');
    expect(capturedBody?['locked_first_destination_id'], 1);
    expect(trip.optimizationSummary?.costSource, 'osrm');
    expect(trip.optimizationSummary?.orderMethod, 'exact_held_karp');
    expect(trip.optimizationSummary?.distanceSavedPercent, 27.0);
    expect(trip.seaCrossings.length, 1);
    expect(trip.routeSegments.length, 2);
    expect(trip.routeWaypoints.length, 4);

    // JSON round-trip preserves summary, segments, and multi-stop waypoints.
    final roundTripped = ItineraryTrip.fromJson(trip.toJson());
    expect(roundTripped.optimizationSummary?.costSource, 'osrm');
    expect(roundTripped.routeSegments.length, 2);
    expect(roundTripped.seaCrossings.length, 1);
    expect(roundTripped.routeWaypoints.length, 4);
  });

  test('replanTripWithSettings clears 1-day overload when expanded to 2 days', () async {
    final repo = TravelRepository(
      apiCatalog: LakbayApiCatalogService(baseUrlOverride: ''),
    );
    for (final p in _samplePlaces().take(3)) {
      repo.toggleTripBuilderStop(p);
    }

    final crammed = await repo.buildMultiStopExploreTrip(
      daysCount: 1,
      pace: TripPace.balanced,
      refineWithBackend: false,
    );
    expect(crammed.days.single.overloadWarning, isNotNull);

    final expanded = await repo.replanTripWithSettings(
      crammed,
      daysCount: 3,
    );
    expect(expanded.days.length, 3);
    expect(expanded.days.every((d) => d.overloadWarning == null), isTrue);
  });

  testWidgets('Explore Plan Sheet supports lock-first, must-visit, pace, and live recalc', (tester) async {
    final repo = TravelRepository(
      apiCatalog: LakbayApiCatalogService(baseUrlOverride: ''),
    );
    await tester.runAsync(() async {
      await repo.initialize();
    });
    for (final p in _samplePlaces().take(4)) {
      repo.toggleTripBuilderStop(p);
    }

    await tester.pumpWidget(
      MaterialApp(
        home: ExploreScreen(repo: repo),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('4 places selected · Plan trip'), findsOneWidget);
    await tester.tap(find.text('Plan trip'));
    await tester.pumpAndSettle();

    expect(find.text('Plan Your Route'), findsOneWidget);
    // The two ways to get a trip are named by what they do.
    expect(find.text('Build my 4-day trip (no AI)', skipOffstage: false),
        findsOneWidget);
    expect(find.text('Plan it with Lakbay AI instead', skipOffstage: false),
        findsOneWidget);
    expect(find.text('Eden Nature Park'), findsOneWidget);
    expect(find.textContaining('Suggested:'), findsWidgets);
    expect(find.text('My location'), findsOneWidget);
    expect(find.text('Hotel'), findsOneWidget);
    expect(find.text('First place'), findsOneWidget);
    expect(find.text('Relaxed (~6h)'), findsOneWidget);
    expect(find.text('Balanced (~8h)'), findsOneWidget);
    expect(find.text('Packed (~10h)'), findsOneWidget);

    // Toggle lock-first on first pin button while visible near top.
    await tester.tap(find.byTooltip('Lock as first stop').first);
    await tester.pump(const Duration(milliseconds: 450));
    expect(repo.builderLockedFirstStopId, isNotNull);

    // Scroll inside sheet and toggle pace; verify debounce timer settles cleanly.
    await tester.ensureVisible(find.text('Packed (~10h)'));
    await tester.pump();
    await tester.tap(find.text('Packed (~10h)'));
    await tester.pump(const Duration(milliseconds: 450));
    expect(repo.builderPace, TripPace.packed);
  });

  testWidgets('TripDetailScreen Day-by-Day displays multi-stop card and Add a day action', (tester) async {
    // A tall screen: the forecast note above the day list pushes content down.
    tester.view.physicalSize = const Size(900, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final repo = TravelRepository(
      apiCatalog: LakbayApiCatalogService(baseUrlOverride: ''),
    );
    for (final p in _samplePlaces().take(3)) {
      repo.toggleTripBuilderStop(p);
    }
    final trip = await repo.buildMultiStopExploreTrip(
      daysCount: 1,
      pace: TripPace.balanced,
      refineWithBackend: false,
    );
    repo.saveTripToMyTrips(trip);

    await tester.pumpWidget(
      MaterialApp(
        home: TripDetailScreen(trip: trip, repo: repo),
      ),
    );
    // LakbayMapboxMap runs repeating controllers; pump bounded frames instead of pumpAndSettle.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // Overview shows savings summary card.
    expect(find.textContaining('Route'), findsWidgets);

    // Switch to Day-by-Day tab.
    await tester.tap(find.text('Day-by-Day'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));

    expect(find.text('Eden Nature Park'), findsOneWidget);
    expect(find.text('Samal Island Beach Area'), findsOneWidget);
    expect(find.text('Add a day'), findsOneWidget);

    await tester.ensureVisible(find.text('Add a day'));
    await tester.tap(find.text('Add a day'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    // Re-plan creates Day 2; verify via updated repository trip and scroll into view.
    expect(repo.savedTrips.last.days.length, 2);
    await tester.scrollUntilVisible(
      find.text('DAY 2'),
      250,
      scrollable: find.descendant(
        of: find.byType(ListView),
        matching: find.byType(Scrollable),
      ),
    );
    expect(find.text('DAY 2'), findsOneWidget);
  });
}
