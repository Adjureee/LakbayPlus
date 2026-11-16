import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lakbay_admin/services/api_service.dart';
import 'package:lakbay_admin/widgets/commute_section.dart';
import 'package:shared_preferences/shared_preferences.dart';

Map<String, dynamic> _route({bool verified = false}) => {
  'commute_route_id': 7,
  'destination_id': 3,
  'start_area': 'Davao City',
  'is_verified': verified,
  'is_active': true,
  'steps': [
    {'vehicle': 'jeepney', 'minutes': 25, 'fare_php': '30.00',
     'charging_unit': 'per_person'},
    {'vehicle': 'tricycle'},
  ],
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('lists routes, drafts steps for review and saves unknowns as null', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1200, 2000);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final posts = <Map<String, dynamic>>[];
    final api = ApiService(
      tokenProvider: () async => 't',
      apiBaseUrl: 'http://lakbay.test/api/v1',
      client: MockClient((request) async {
        final path = request.url.path;
        if (path == '/api/v1/admin/destinations/3/commute' &&
            request.method == 'GET') {
          return http.Response(
            jsonEncode({'destination_id': 3, 'routes': [_route()]}),
            200,
          );
        }
        if (path.endsWith('/commute/draft')) {
          return http.Response(
            jsonEncode({
              'destination_id': 3,
              'source_text': 'x',
              'model_id': 'm',
              'unclear': ['No fares were given.'],
              'routes': [
                {
                  'start_area': null,
                  'is_verified': false,
                  'steps': [
                    {'vehicle': 'van'},
                  ],
                },
              ],
            }),
            200,
          );
        }
        if (path == '/api/v1/admin/destinations/3/commute' &&
            request.method == 'POST') {
          posts.add(jsonDecode(request.body) as Map<String, dynamic>);
          return http.Response(jsonEncode(_route()), 201);
        }
        return http.Response('{}', 404);
      }),
    );
    addTearDown(api.close);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: CommuteSection(api: api, destinationId: '3'),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('Jeepney → Tricycle'), findsOneWidget);
    expect(find.textContaining('Not verified'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('commute-draft')));
    await tester.pump();
    await tester.pump();
    await tester.pump();

    expect(find.text('New commute route'), findsOneWidget);
    expect(find.textContaining('No fares were given.'), findsOneWidget);

    await tester.tap(find.text('Save route'));
    await tester.pump();
    await tester.pump();

    expect(posts, hasLength(1));
    final step = (posts.single['steps'] as List).single as Map<String, dynamic>;
    expect(step['vehicle'], 'van');
    // Nothing was typed, so nothing is invented.
    expect(step['minutes'], isNull);
    expect(step['fare_php'], isNull);
    expect(step['charging_unit'], isNull);
    expect(posts.single['is_verified'], isFalse);
  });
}
