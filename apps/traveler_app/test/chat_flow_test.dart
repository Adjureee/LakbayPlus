import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lakbay_travel/models/travel_models.dart';
import 'package:lakbay_travel/services/lakbay_api_catalog_service.dart';
import 'package:lakbay_travel/services/location_service.dart';
import 'package:lakbay_travel/services/travel_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _facets = {
  'total_places': 41,
  'groups': [
    {
      'key': 'nature_attractions',
      'label': 'Nature attractions',
      'description': 'Waterfalls, mountains and parks.',
      'count': 20,
      'subtypes': [
        {'key': 'waterfalls', 'label': 'Waterfalls', 'count': 4},
        {'key': 'mountains_viewpoints', 'label': 'Mountains & viewpoints', 'count': 5},
      ],
    },
    {
      'key': 'beaches',
      'label': 'Beaches',
      'description': 'Beaches and beach resorts.',
      'count': 7,
      'subtypes': [],
    },
  ],
};

class _Server {
  _Server(this.handler);

  final Map<String, dynamic>? Function(String path, Map<String, dynamic> body)
      handler;
  final requests = <({String path, Map<String, dynamic> body})>[];

  MockClient get client => MockClient((request) async {
        final path = request.url.path.replaceFirst('/api/v1', '');
        final body = request.body.isEmpty
            ? <String, dynamic>{}
            : jsonDecode(request.body) as Map<String, dynamic>;
        requests.add((path: path, body: body));
        if (path == '/destinations/facets') {
          return http.Response(jsonEncode(_facets), 200);
        }
        if (path == '/destinations') return http.Response('[]', 200);
        final reply = handler(path, body);
        if (reply == null) return http.Response('{"error":"down"}', 503);
        return http.Response(jsonEncode(reply), 200);
      });
}

/// The body of the most recent chat request (guests asking for a plan also
/// call the trip-draft endpoint afterwards).
Map<String, dynamic> _lastChat(_Server server) =>
    server.requests.lastWhere((r) => r.path == '/ai/chat/guest').body;

TravelRepository _repo(_Server server) => TravelRepository(
      apiCatalog: LakbayApiCatalogService(
        baseUrlOverride: 'https://api.lakbay.test/api/v1',
        client: server.client,
      ),
      locationService: LocationService(
        customFetcher: () async => const LocationResult(
          granted: false,
          statusMessage: 'Declined',
        ),
      ),
    );

Map<String, dynamic> _planningReply(
  Map<String, dynamic> body, {
  String text = 'Here are some ideas.',
  String intent = 'plan_trip',
  List<Map<String, dynamic>> recommendations = const [],
  List<String> replies = const [],
}) =>
    {
      'chat_response': text,
      'model_id': 'mock',
      'ai_generation_run_id': 1,
      'planning': {
        'input_revision': 1,
        'intent': intent,
        'suggested_replies': replies,
        'state_updates': {},
        'update_status': 'no_changes',
        'preview': {'state': body['planning_state']},
        'recommendations': recommendations,
      },
    };

const _falls = {
  'destination_id': 77,
  'name': 'Hidden Test Falls',  // not in the bundled catalog
  'district': 'Maragusan',
  'category': 'Waterfall',
  'score': 88.5,
  'reasons': ['Matches Nature attractions.'],
  'route_verified': false,
  'travel_mode': 'driving',
  'lat': 7.3164,
  'lng': 126.1719,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('a new traveler starts with an empty chat and nothing pre-filled', () async {
    final repo = _repo(_Server((_, _) => null));
    await repo.initialize();

    expect(repo.chatSessions, hasLength(1));
    expect(repo.chatSessions.single.messages, isEmpty);
    expect(repo.chatSessions.single.title, 'New Trip');
    expect(repo.savedTrips, isEmpty);
    expect(repo.selectedVibes, isEmpty);
    expect(repo.bucketListTripIds, isEmpty);
  });

  test('sample chats saved by older versions are dropped on restore', () async {
    final sample = ChatSession(
      id: 'chat_today_samal',
      title: '3-Day Samal and Davao City Escape',
      groupLabel: 'Today',
      isTrip: true,
      createdAt: DateTime(2026, 11, 1),
      messages: [
        ChatMessage(
          id: 'welcome_1',
          isUser: false,
          text: 'Maayong adlaw! I am your planner.',
          timestamp: DateTime(2026, 11, 1),
        ),
      ],
    );
    final real = ChatSession(
      id: 'chat_real',
      title: 'Falls near Digos',
      groupLabel: 'Today',
      isTrip: false,
      createdAt: DateTime(2026, 11, 2),
      messages: [
        ChatMessage(
          id: 'u1', isUser: true, text: 'waterfalls near Digos',
          timestamp: DateTime(2026, 11, 2),
        ),
      ],
    );
    SharedPreferences.setMockInitialValues({
      'lakbay_traveler_state_v1': jsonEncode({
        'hasCompletedOnboarding': true,
        'chatSessions': [sample.toJson(), real.toJson()],
        'activeChatId': 'chat_today_samal',
      }),
    });
    final repo = _repo(_Server((_, _) => null));
    await repo.initialize();

    expect(repo.chatSessions.map((s) => s.id), ['chat_real']);
    expect(repo.activeChatId, 'chat_real');
  });

  test('when Lakbay AI cannot be reached the traveler sees an error, not an invented trip', () async {
    final server = _Server((_, _) => null);
    final repo = _repo(server);
    await repo.initialize();

    await repo.sendChatMessage('Plan 3 days of waterfalls for 4 people');

    final last = repo.chatMessages.last;
    expect(last.isError, isTrue);
    expect(last.retryText, 'Plan 3 days of waterfalls for 4 people');
    expect(last.attachedTrip, isNull);
    expect(last.aiOptions, isEmpty);
    expect(last.recommendedPlaces, isEmpty);
    expect(last.suggestedReplies, isEmpty);
    expect(last.text, isNot(contains('mapped out')));
    expect(repo.isAiTyping, isFalse);
    // The server was asked once; no other AI path produced a fake answer.
    expect(
      server.requests.where((r) => r.path.startsWith('/ai/')).map((r) => r.path),
      ['/ai/chat/guest'],
    );
  });

  test('with no server configured the app says so instead of answering', () async {
    final repo = TravelRepository(
      apiCatalog: LakbayApiCatalogService(baseUrlOverride: ''),
    );
    await repo.initialize();

    await repo.sendChatMessage('Plan a trip');

    expect(repo.chatMessages.last.isError, isTrue);
    expect(repo.chatMessages.last.attachedTrip, isNull);
  });

  test('suggested replies are only the ones the AI gave', () async {
    final repo = _repo(_Server((path, body) => _planningReply(
          body, intent: 'question', text: 'Mornings are best.', replies: [],
        )));
    await repo.initialize();

    await repo.sendChatMessage('When is the best time?');

    expect(repo.chatMessages.last.text, 'Mornings are best.');
    expect(repo.chatMessages.last.suggestedReplies, isEmpty);
  });

  test('cards come with any planning reply, but never with a plain answer', () async {
    final intents = <String>['plan_trip', 'question'];
    final server = _Server((path, body) => path == '/ai/chat/guest'
        ? _planningReply(
            body, intent: intents.removeAt(0), recommendations: [_falls],
          )
        : null);
    final repo = _repo(server);
    await repo.initialize();

    await repo.sendChatMessage('I like waterfalls');
    expect(repo.chatMessages.last.recommendedPlaces.map((p) => p.name),
        ['Hidden Test Falls']);
    expect(repo.chatMessages.last.recommendedPlaces.single.lat, 7.3164);

    await repo.sendChatMessage('How do I get there?');
    expect(repo.chatMessages.last.recommendedPlaces, isEmpty);
  });

  test("a card's + Add tells the AI planner, so it plans the traveler's picks", () async {
    final server = _Server((path, body) =>
        path == '/ai/chat/guest' ? _planningReply(body) : null);
    final repo = _repo(server);
    await repo.initialize();

    final falls = TopPlaceRecommendation.fromJson(_falls);
    final place = repo.resolveExploreTripForRecommendation(falls);
    // The card's own pin is used when the catalog has not synced the place.
    expect(place.lat, 7.3164);
    expect(place.lng, 126.1719);
    expect(place.apiDestinationId, 77);

    repo.toggleChatPick(place);
    expect(repo.isInTripBuilder(place.id), isTrue);

    await repo.sendChatMessage('Build my itinerary');
    final sent = _lastChat(server)['planning_state'] as Map<String, dynamic>;
    expect(sent['destination_ids'], [77]);

    repo.toggleChatPick(place);
    await repo.sendChatMessage('Actually, none of those');
    final cleared = _lastChat(server)['planning_state'] as Map<String, dynamic>;
    expect(cleared['destination_ids'], isEmpty);
  });

  test('nothing is assumed about the party, days or budget in the planning state', () async {
    final server = _Server((path, body) => _planningReply(body));
    final repo = _repo(server);
    await repo.initialize();

    await repo.sendChatMessage('Show me waterfalls');

    final state = _lastChat(server)['planning_state'] as Map<String, dynamic>;
    expect(state.keys.toSet(), {'destination_ids'});
    expect(state['destination_ids'], isEmpty);
  });

  test('preference groups come from the server and reach the AI as interests', () async {
    final server = _Server((path, body) => _planningReply(body));
    final repo = _repo(server);
    await repo.initialize();
    await repo.refreshPreferenceGroups();

    expect(repo.preferenceGroups.map((g) => g.key), ['nature_attractions', 'beaches']);
    expect(repo.preferenceGroups.first.subtypes.map((s) => s.label),
        ['Waterfalls', 'Mountains & viewpoints']);
    expect(repo.selectedVibes, isEmpty); // nothing pre-selected

    repo.toggleVibe('nature_attractions');
    repo.toggleVibe('waterfalls');
    await repo.sendChatMessage('Where should I go?');
    final state = _lastChat(server)['planning_state'] as Map<String, dynamic>;
    expect(state['interests'], ['nature_attractions', 'waterfalls']);

    // Changing a preference mid-chat updates what the AI is told next.
    repo.toggleVibe('nature_attractions'); // also clears its sub-types
    expect(repo.selectedVibes, isEmpty);
    await repo.sendChatMessage('Anything else?');
    final later = _lastChat(server)['planning_state'] as Map<String, dynamic>;
    expect(later['interests'], isEmpty);
  });

  test('preferences the catalog no longer offers are forgotten', () async {
    SharedPreferences.setMockInitialValues({
      'lakbay_traveler_state_v1': jsonEncode({
        'hasCompletedOnboarding': true,
        'selectedVibes': ['beaches', 'foodie'],
      }),
    });
    final repo = _repo(_Server((_, _) => null));
    await repo.initialize();
    await repo.refreshPreferenceGroups();

    expect(repo.selectedVibes, {'beaches'});
  });

  test('itineraries are built only from picks and details the traveler gave', () async {
    final server = _Server((path, body) {
      if (path == '/ai/itineraries/generate') return {'options': []};
      return _planningReply(body, recommendations: [_falls]);
    });
    SharedPreferences.setMockInitialValues({
      'lakbay_traveler_state_v1': jsonEncode({
        'hasCompletedOnboarding': true,
        'authSession': const LakbayAuthSession(
          accessToken: 'token', refreshToken: 'refresh', userId: 1,
          fullName: 'Test Traveler', email: 't@example.com', role: 'traveler',
        ).toJson(),
      }),
    });
    final repo = _repo(server);
    await repo.initialize();
    expect(repo.isSignedIn, isTrue);

    // No picks: cards are offered, and nothing is generated from search results.
    await repo.sendChatMessage('Plan my trip');
    expect(server.requests.where((r) => r.path == '/ai/itineraries/generate'), isEmpty);
    expect(repo.chatMessages.last.recommendedPlaces, isNotEmpty);

    // A pick, but no days, party or budget yet: the AI asks, the app does not guess.
    repo.toggleChatPick(repo.resolveExploreTripForRecommendation(
      TopPlaceRecommendation.fromJson(_falls),
    ));
    await repo.sendChatMessage('Plan my trip');
    expect(server.requests.where((r) => r.path == '/ai/itineraries/generate'), isEmpty);
    expect(repo.chatMessages.last.attachedTrip, isNull);
  });
}
