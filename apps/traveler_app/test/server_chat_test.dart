import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lakbay_travel/services/lakbay_api_catalog_service.dart';
import 'package:lakbay_travel/services/location_service.dart';
import 'package:lakbay_travel/services/travel_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
      'server chat sends lat/lng and the latest turns, and uses the model '
      'intent and suggested replies', () async {
    SharedPreferences.setMockInitialValues({});
    final chatBodies = <Map<String, dynamic>>[];
    var itineraryCalls = 0;
    var reply = 0;

    final mockClient = MockClient((request) async {
      final path = request.url.path;
      if (path == '/api/v1/auth/login') {
        return http.Response(
          jsonEncode({
            'tokens': {'access_token': 'jwt', 'refresh_token': 'r'},
            'user': {
              'user_id': 1,
              'full_name': 'Test Traveler',
              'email': 'traveler@example.test',
              'role': 'traveler',
            },
          }),
          200,
        );
      }
      if (path == '/api/v1/ai/chat') {
        chatBodies.add(jsonDecode(request.body) as Map<String, dynamic>);
        reply++;
        return http.Response(
          jsonEncode({
            'chat_response': 'Reply $reply: take the RoRo barge from Sasa Wharf.',
            'model_id': 'test-model',
            'retrieved_context': [
              {'source': 'destination', 'source_id': 4},
            ],
            'planning': {
              'input_revision': reply,
              'intent': 'logistics',
              'suggested_replies': ['How much is the barge?', 'Best time to cross?'],
              'preview': {
                'state': {
                  'origin': {'label': 'Davao City', 'lat': 7.07, 'lng': 125.61},
                  'destination_ids': [4],
                },
              },
            },
          }),
          200,
        );
      }
      if (path.contains('/ai/itineraries')) itineraryCalls++;
      return http.Response('[]', 200);
    });

    final repo = TravelRepository(
      apiCatalog: LakbayApiCatalogService(
        client: mockClient,
        baseUrlOverride: 'https://api.test/api/v1',
      ),
      locationService: LocationService(
        customFetcher: () async => const LocationResult(
          granted: true,
          lat: 7.07,
          lng: 125.61,
          resolvedLabel: 'Davao City',
          statusMessage: 'ok',
        ),
      ),
    );
    await repo.initialize();
    await repo.requestAndSaveCurrentLocation();
    await repo.signInWithBackend(
        email: 'traveler@example.test', password: 'Password123!');

    for (var i = 1; i <= 9; i++) {
      await repo.sendChatMessage('Question $i about Samal trip');
    }

    final first = chatBodies.first;
    final origin = first['planning_state']['origin'] as Map<String, dynamic>;
    expect(origin.keys, containsAll(<String>['lat', 'lng']));
    expect(origin.containsKey('latitude'), isFalse);

    final last = chatBodies.last;
    final history = (last['history'] as List).cast<Map<String, dynamic>>();
    expect(history.length, lessThanOrEqualTo(12));
    // The latest earlier turn is included; the very first is not.
    expect(history.last['content'], startsWith('Reply 8'));
    expect(history.any((m) => m['content'] == 'Question 1 about Samal trip'),
        isFalse);
    expect(history.any((m) => (m['content'] as String).contains('Powered by')),
        isFalse);

    // "trip" is in every message, but the model said logistics: no itinerary run.
    expect(itineraryCalls, 0);
    final aiMessage = repo.chatMessages.last;
    expect(aiMessage.text, 'Reply 9: take the RoRo barge from Sasa Wharf.');
    expect(aiMessage.suggestedReplies,
        ['How much is the barge?', 'Best time to cross?']);
  });

  test('guests chat through the backend guest endpoint without a token',
      () async {
    SharedPreferences.setMockInitialValues({});
    final paths = <String>[];
    final auth = <String?>[];
    final mockClient = MockClient((request) async {
      paths.add(request.url.path);
      auth.add(request.headers['Authorization']);
      if (request.url.path == '/api/v1/ai/chat/guest') {
        return http.Response(
          jsonEncode({
            'chat_response': 'Maayong buntag! Samal is a short barge ride away.',
            'model_id': 'test-model',
            'retrieved_context': [],
            'planning': {'input_revision': 1, 'intent': 'question'},
          }),
          200,
        );
      }
      return http.Response('[]', 200);
    });
    final repo = TravelRepository(
      apiCatalog: LakbayApiCatalogService(
        client: mockClient,
        baseUrlOverride: 'https://api.test/api/v1',
      ),
    );
    await repo.initialize();
    expect(repo.isSignedIn, isFalse);

    await repo.sendChatMessage('Is Samal far?');

    expect(paths, contains('/api/v1/ai/chat/guest'));
    expect(paths, isNot(contains('/api/v1/ai/chat')));
    expect(auth[paths.indexOf('/api/v1/ai/chat/guest')], isNull);
    expect(repo.chatMessages.last.text,
        'Maayong buntag! Samal is a short barge ride away.');
  });
}
