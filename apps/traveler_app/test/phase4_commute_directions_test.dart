import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lakbay_travel/models/commute.dart';
import 'package:lakbay_travel/screens/commute_directions_screen.dart';
import 'package:lakbay_travel/services/lakbay_api_catalog_service.dart';
import 'package:lakbay_travel/services/travel_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

Map<String, dynamic> _routeJson({
  bool complete = true,
  List<Map<String, dynamic>>? steps,
}) => {
  'commute_route_id': 1,
  'start_area': 'Davao City',
  'is_verified': true,
  'total_minutes': 40,
  'minutes_complete': complete,
  'total_fare_per_person_php': '130.00',
  'fare_complete': complete,
  'transfers': 1,
  'steps': steps ??
      [
        {
          'vehicle': 'jeepney', 'from_place': 'Davao City', 'to_place': 'Toril',
          'get_off_at': 'Toril Terminal', 'minutes': 25, 'fare_php': '30.00',
          'charging_unit': 'per_person',
        },
        {
          'vehicle': 'tricycle', 'to_place': 'the park', 'minutes': 15,
          'fare_php': '100.00', 'charging_unit': 'per_person',
        },
        {'vehicle': 'fee', 'notes': 'Pay the local community fee'},
      ],
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('commute model', () {
    test('labels are exact when complete and say "at least" or "+" when not', () {
      final full = CommuteRoute.fromJson(_routeJson());
      expect(full.timeLabel, '≈40 min');
      expect(full.fareLabel, '₱130 per person');
      expect(full.summary, 'Jeepney → Tricycle');

      final partial = CommuteRoute.fromJson(_routeJson(complete: false));
      expect(partial.timeLabel, 'at least 40 min');
      expect(partial.fareLabel, '₱130+ per person');
    });

    test('unknown time and fare stay unknown', () {
      final route = CommuteRoute.fromJson({
        'commute_route_id': 2,
        'total_minutes': 0,
        'total_fare_per_person_php': '0.00',
        'steps': [
          {'vehicle': 'van'},
        ],
      });
      expect(route.timeLabel, isNull);
      expect(route.fareLabel, isNull);
      expect(route.steps.single.fareLabel, isNull);
    });

    test('directions read as plain sentences', () {
      final route = CommuteRoute.fromJson(_routeJson());
      expect(route.steps[0].instruction, 'Ride a jeepney from Davao City to Toril');
      expect(route.steps[2].instruction, 'Pay the local community fee');
      expect(route.toPlainText('Eden'), contains('1. Ride a jeepney'));
    });
  });

  testWidgets('shows drive and verified commute directions, and Start gives a checklist', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(900, 2200);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final repo = TravelRepository(
      apiCatalog: LakbayApiCatalogService(
        baseUrlOverride: 'https://api.lakbay.test/api/v1',
        client: MockClient((request) async {
          if (request.url.path.endsWith('/destinations/5/commute')) {
            return http.Response(
              jsonEncode({'destination_id': 5, 'routes': [_routeJson()]}),
              200,
            );
          }
          return http.Response('{}', 404);
        }),
      ),
    );
    await tester.runAsync(() => repo.initialize());
    final trip = repo.generateCustomTrip(
      destination: 'Atlantis', daysCount: 1, vibe: 'x',
    );

    await tester.pumpWidget(
      MaterialApp(
        home: CommuteDirectionsScreen(
          repo: repo,
          trip: trip,
          stops: const [CommuteStopRef(5, 'Eden Nature Park')],
        ),
      ),
    );
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();
    await tester.pump();

    expect(find.text('Getting to Eden Nature Park'), findsOneWidget);
    expect(find.text('Drive'), findsOneWidget);
    expect(find.text('≈40 min'), findsOneWidget);
    expect(find.text('₱130 per person'), findsOneWidget);
    expect(find.text('Ride a jeepney from Davao City to Toril'), findsOneWidget);
    expect(find.text('Pay the local community fee'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('commute-start')));
    await tester.pump();
    expect(find.byType(Checkbox), findsNWidgets(3));
  });

  testWidgets('with no verified route it says so and invents none', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(900, 1600);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final repo = TravelRepository(
      apiCatalog: LakbayApiCatalogService(
        baseUrlOverride: 'https://api.lakbay.test/api/v1',
        client: MockClient(
          (_) async => http.Response(
            jsonEncode({'destination_id': 5, 'routes': []}), 200),
        ),
      ),
    );
    await tester.runAsync(() => repo.initialize());
    final trip = repo.generateCustomTrip(
      destination: 'Atlantis', daysCount: 1, vibe: 'x',
    );

    await tester.pumpWidget(
      MaterialApp(
        home: CommuteDirectionsScreen(
          repo: repo, trip: trip, stops: const [CommuteStopRef(5, 'Eden')],
        ),
      ),
    );
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();
    await tester.pump();

    expect(find.textContaining('No verified public-transport directions'), findsOneWidget);
    expect(find.text('Commute'), findsNothing);
    expect(find.byKey(const ValueKey('commute-start')), findsNothing);
  });
}
