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

  test('a trip is drafted only by the AI; when it fails nothing is invented', () async {
    final server = _Server((path, body) => null); // every AI call fails
    final repo = _repo(server);
    await repo.initialize();

    final trip = await repo.createTripFromAiPrompt('Plan 2 days in Samal Island');

    expect(trip, isNull);
    expect(repo.savedTrips, isEmpty);
  });

  group('picking and plan details', () {
    final park = <String, dynamic>{
      ..._falls,
      'destination_id': 78,
      'name': 'Hidden Test Park',
      'category': 'Park',
      'lat': 7.2,
      'lng': 126.0,
    };

    Map<String, dynamic> reply(
      Map<String, dynamic> body, {
      Map<String, dynamic> extraState = const {},
      Map<String, dynamic>? conversation,
    }) {
      final base = _planningReply(body, recommendations: [_falls, park]);
      final planning = base['planning'] as Map<String, dynamic>;
      planning['preview'] = {
        'state': {...(body['planning_state'] as Map<String, dynamic>), ...extraState},
      };
      if (conversation != null) planning['conversation'] = conversation;
      return base;
    }

    test('the itinerary is built from exactly the places picked', () async {
      final server = _Server((path, body) {
        if (path == '/ai/itineraries/generate') return {'options': []};
        return reply(body, extraState: {
          'day_count': 2,
          'traveler_count': 2,
          'total_budget': '6000',
        });
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

      await repo.sendChatMessage('I like nature'); // cards: falls + park
      // Pick only the park, not the first card.
      repo.toggleChatPick(repo.resolveExploreTripForRecommendation(
        TopPlaceRecommendation.fromJson(park),
      ));
      expect(repo.chatPickCount, 1);
      await repo.planWithPicks();

      final generate =
          server.requests.lastWhere((r) => r.path == '/ai/itineraries/generate');
      expect(generate.body['destination_ids'], [78]);
      expect((generate.body['planning_state'] as Map)['destination_ids'], [78]);
    });

    test('at most ten places can be picked for one plan', () async {
      final repo = _repo(_Server((_, body) => _planningReply(body)));
      await repo.initialize();
      ExploreTrip place(int id) => repo.resolveExploreTripForRecommendation(
            TopPlaceRecommendation.fromJson({
              ..._falls,
              'destination_id': 200 + id,
              'name': 'Pick Place $id',
            }),
          );

      for (var i = 0; i < TravelRepository.maxChatPicks; i++) {
        expect(repo.toggleChatPick(place(i)), isTrue);
      }
      expect(repo.toggleChatPick(place(99)), isFalse);
      expect(repo.chatPickCount, TravelRepository.maxChatPicks);
      // Removing one frees a slot.
      expect(repo.toggleChatPick(place(0)), isTrue);
      expect(repo.chatPickCount, TravelRepository.maxChatPicks - 1);
    });

    test('a detail question shows answer buttons, and the answer reaches the AI', () async {
      final server = _Server((path, body) => reply(body, conversation: {
            'stage': 'recommend',
            'missing_details': ['activity_level', 'travel_start_date'],
            'ask_next': 'How active do you want to be?',
            'optional_details': [],
          }));
      final repo = _repo(server);
      await repo.initialize();

      await repo.sendChatMessage('I like nature');
      expect(repo.chatMessages.last.askNext, 'activity_level');

      await repo.answerChatDetail('activity_level', 'easy', 'Easy');
      final state = _lastChat(server)['planning_state'] as Map<String, dynamic>;
      expect(state['activity_level'], 'easy');
      expect(_lastChat(server)['message'], 'Easy');
    });

    test('no buttons are offered when nothing button-shaped is missing', () async {
      final server = _Server((path, body) => reply(body, conversation: {
            'stage': 'collect',
            'missing_details': ['traveler_count'],
            'ask_next': 'How many people are going?',
            'optional_details': [],
          }));
      final repo = _repo(server);
      await repo.initialize();

      await repo.sendChatMessage('Hi');
      expect(repo.chatMessages.last.askNext, isNull);
      expect(repo.chatMessages.last.offerPriorities, isFalse);
    });

    test('no model quick replies while the app asks with its own buttons', () async {
      final server = _Server((path, body) {
        final base = _planningReply(
          body,
          replies: ['Tomorrow', 'Next weekend', 'This coming Friday'],
        );
        (base['planning'] as Map<String, dynamic>)['conversation'] = {
          'stage': 'recommend',
          'missing_details': ['travel_start_date'],
          'ask_next': 'When are you travelling?',
          'optional_details': [],
        };
        return base;
      });
      final repo = _repo(server);
      await repo.initialize();

      await repo.sendChatMessage('Easy');

      final last = repo.chatMessages.last;
      expect(last.askNext, 'travel_start_date');
      // The app's own date buttons are the only ones; the AI's would be typed as text.
      expect(last.suggestedReplies, isEmpty);
    });

    test('model quick replies stay when the next question is a free one', () async {
      final server = _Server((path, body) {
        final base = _planningReply(
          body,
          replies: ['Just a day trip', '2 days, 1 night'],
        );
        (base['planning'] as Map<String, dynamic>)['conversation'] = {
          'stage': 'recommend',
          'missing_details': ['day_count'],
          'ask_next': 'How many days do you have?',
          'optional_details': [],
        };
        return base;
      });
      final repo = _repo(server);
      await repo.initialize();

      await repo.sendChatMessage('Just me');

      expect(repo.chatMessages.last.askNext, isNull);
      expect(
        repo.chatMessages.last.suggestedReplies,
        ['Just a day trip', '2 days, 1 night'],
      );
    });

    test('"what matters most" is offered, saved in order, and can be skipped', () async {
      final server = _Server((path, body) => reply(body, conversation: {
            'stage': 'recommend',
            'missing_details': [],
            'ask_next': null,
            'optional_details': ['priority_order'],
          }));
      final repo = _repo(server);
      await repo.initialize();

      await repo.sendChatMessage('I like nature');
      expect(repo.chatMessages.last.offerPriorities, isTrue);

      await repo.answerChatPriorities(
        ['scenery', 'quiet', 'low_cost', 'easy_trail'], 'What matters most',
      );
      final state = _lastChat(server)['planning_state'] as Map<String, dynamic>;
      expect(state['priority_order'], ['scenery', 'quiet', 'low_cost']); // max 3

      await repo.answerChatPriorities(const [], 'Skip');
      await repo.sendChatMessage('Anything else?');
      expect(repo.chatMessages.last.offerPriorities, isFalse);
    });
  });
}
