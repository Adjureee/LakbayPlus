import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lakbay_travel/screens/home_chat_screen.dart';
import 'package:lakbay_travel/services/lakbay_api_catalog_service.dart';
import 'package:lakbay_travel/services/location_service.dart';
import 'package:lakbay_travel/services/travel_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _liveFacetsPayload = {
  'total_places': 6,
  'groups': [
    {
      'key': 'parks_recreation',
      'label': 'Parks & recreation',
      'description': 'Parks and plazas.',
      'count': 2,
      'subtypes': [],
    },
  ],
  'categories': [
    {
      'key': 'public plaza',
      'label': 'Public Plaza',
      'count': 2,
      'group': 'parks_recreation',
      'groups': ['parks_recreation'],
      'examples': ["People's Park", 'Rizal Park'],
    },
    {
      'key': 'observatory dome',
      'label': 'Observatory Dome',
      'count': 1,
      'group': 'other',
      'groups': ['other'],
      'examples': ['Davao Dome'],
    },
  ],
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
      'Browse by category chips come from live facets and show ranked cards with zero AI calls',
      (tester) async {
    var aiCalls = 0;
    final browseRequests = <Uri>[];

    final client = MockClient((req) async {
      final path = req.url.path.replaceFirst('/api/v1', '');
      if (path.startsWith('/ai/')) {
        aiCalls++;
      }
      if (path == '/destinations/facets') {
        return http.Response(jsonEncode(_liveFacetsPayload), 200);
      }
      if (path == '/destinations') {
        return http.Response('[]', 200);
      }
      if (path == '/destinations/browse') {
        browseRequests.add(req.url);
        return http.Response(
          jsonEncode([
            {
              'rank': 1,
              'destination_id': 99,
              'name': "People's Park Plaza",
              'district': 'Davao City',
              'category': 'Park / Public Plaza',
              'score': 82.0,
              'reasons': ['Matches Public Plaza'],
              'route_verified': false,
              'travel_mode': 'driving',
              'lat': 7.071,
              'lng': 125.609,
            },
          ]),
          200,
        );
      }
      return http.Response('{}', 200);
    });

    SharedPreferences.setMockInitialValues({});
    final repo = TravelRepository(
      apiCatalog: LakbayApiCatalogService(
        baseUrlOverride: 'https://api.lakbay.test/api/v1',
        client: client,
      ),
      locationService: LocationService(
        customFetcher: () async => const LocationResult(
          granted: false,
          statusMessage: 'Declined',
        ),
      ),
    );
    await tester.runAsync(() async {
      await repo.initialize();
      await repo.refreshPreferenceGroups();
    });

    expect(repo.categoryFacets.map((c) => c.key), ['public plaza', 'observatory dome']);

    await tester.pumpWidget(MaterialApp(home: HomeChatScreen(repo: repo)));
    await tester.pump();

    expect(find.text('Browse by category'), findsOneWidget);
    expect(find.text('Public Plaza (2)'), findsOneWidget);
    expect(find.text('Observatory Dome (1)'), findsOneWidget);

    await tester.tap(find.text('Public Plaza (2)'));
    await tester.pumpAndSettle();

    expect(aiCalls, 0);
    expect(browseRequests.single.queryParameters['category'], 'public plaza');
    expect(repo.chatMessages.last.recommendedPlaces.first.name, "People's Park Plaza");
  });
}
