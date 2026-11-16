import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lakbay_travel/models/travel_models.dart';
import 'package:lakbay_travel/services/lakbay_api_catalog_service.dart';
import 'package:lakbay_travel/services/location_service.dart';
import 'package:lakbay_travel/services/travel_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _place = {
  'destination_id': 78,
  'name': 'Hidden Test Park',
  'category': 'park',
  'district': 'Davao City',
  'location': 'Toril, Davao City',
  'lat': 7.12,
  'lng': 125.55,
  'estimated_cost': '500.00',
  'stay_duration_type': 'half_day',
  'family_friendly': true,
  'group_friendly': true,
};

Map<String, dynamic> _validGeneratedResponse() => {
      'selected_generation_run_id': 91,
      'options': [
        {
          'option_number': 1,
          'title': 'Relaxed Park Escape',
          'summary': 'Unrushed park visit.',
          'estimated_total_cost': '1000.00',
          'is_over_budget': false,
          'days': [
            {
              'day': 1,
              'title': 'Day 1',
              'summary': 'Park morning.',
              'activities': [
                {
                  'time': '09:00',
                  'title': 'Visit Hidden Test Park',
                  'description': 'Morning walk under tall trees.',
                  'destination_id': 78,
                  'estimated_cost': '500.00',
                }
              ],
            },
            {
              'day': 2,
              'title': 'Day 2',
              'summary': 'Relaxed afternoon.',
              'activities': [
                {
                  'time': '10:00',
                  'title': 'Scenic Picnic',
                  'description': 'Picnic and easy trails.',
                  'destination_id': 78,
                  'estimated_cost': '500.00',
                }
              ],
            },
          ],
        },
        {
          'option_number': 2,
          'title': 'Active Trail Morning',
          'summary': 'Earlier start on the park trails.',
          'estimated_total_cost': '1000.00',
          'is_over_budget': false,
          'days': [
            {
              'day': 1,
              'title': 'Day 1',
              'summary': 'Early trail.',
              'activities': [
                {
                  'time': '07:30',
                  'title': 'Trail Hike',
                  'description': 'Morning hike across the ridge.',
                  'destination_id': 78,
                  'estimated_cost': '500.00',
                }
              ],
            },
            {
              'day': 2,
              'title': 'Day 2',
              'summary': 'Garden loop.',
              'activities': [
                {
                  'time': '09:00',
                  'title': 'Garden Loop',
                  'description': 'Explore the shaded gardens.',
                  'destination_id': 78,
                  'estimated_cost': '500.00',
                }
              ],
            },
          ],
        },
      ],
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('computeWholeTripBudgetPhp scales per-person budgets cleanly', () {
    expect(
      TravelRepository.computeWholeTripBudgetPhp({
        'total_budget': '3000',
        'budget_scope': 'per_person',
        'traveler_count': 2,
      }),
      6000.0,
    );
    expect(
      TravelRepository.computeWholeTripBudgetPhp({
        'total_budget': '8500.50',
        'budget_scope': 'whole_trip',
        'traveler_count': 4,
      }),
      8500.50,
    );
    expect(
      TravelRepository.computeWholeTripBudgetPhp({
        'total_budget': '3000',
        'budget_scope': 'per_person',
      }),
      isNull,
    );
  });

  test(
      'AI language defaults to auto, rejects unsupported values, persists, and sends on AI requests',
      () async {
    final recorded = <({String path, Map<String, dynamic> body})>[];
    final client = MockClient((req) async {
      final path = req.url.path.replaceFirst('/api/v1', '');
      final body = req.body.isEmpty
          ? <String, dynamic>{}
          : jsonDecode(req.body) as Map<String, dynamic>;
      recorded.add((path: path, body: body));
      if (path == '/destinations/facets') {
        return http.Response(jsonEncode({'groups': []}), 200);
      }
      if (path == '/destinations') {
        return http.Response('[]', 200);
      }
      if (path == '/ai/chat' || path == '/ai/chat/guest') {
        return http.Response(
          jsonEncode({
            'chat_response': 'Maayong adlaw!',
            'model_id': 'mock',
            'ai_generation_run_id': 1,
            'planning': {
              'input_revision': 1,
              'intent': 'brainstorm',
              'suggested_replies': [],
              'state_updates': {},
              'update_status': 'no_changes',
              'preview': {'state': body['planning_state']},
              'recommendations': [],
            },
          }),
          200,
        );
      }
      if (path == '/ai/trip-draft') {
        return http.Response(
          jsonEncode({
            'draft': {'reply': 'Maayong adlaw!', 'days': []},
            'model_id': 'mock',
            'provider': 'groq',
          }),
          200,
        );
      }
      return http.Response('{}', 200);
    });

    SharedPreferences.setMockInitialValues({});
    final api = LakbayApiCatalogService(
      baseUrlOverride: 'https://api.lakbay.test/api/v1',
      client: client,
    );
    final repo = TravelRepository(
      apiCatalog: api,
      locationService: LocationService(
        customFetcher: () async => const LocationResult(
          granted: false,
          statusMessage: 'Declined',
        ),
      ),
    );
    await repo.initialize();

    expect(repo.aiLanguage, 'auto');
    expect(repo.aiLanguageDisplayName, 'Auto');

    repo.setAiLanguage('spanish');
    expect(repo.aiLanguage, 'auto');

    repo.setAiLanguage('bisaya');
    expect(repo.aiLanguage, 'bisaya');
    expect(repo.aiLanguageDisplayName, 'Bisaya / Cebuano');

    await repo.sendChatMessage('Asa nindot mag suroy?');
    final chatCall = recorded.lastWhere((r) => r.path.contains('/ai/chat'));
    expect(chatCall.body['language'], 'bisaya');

    await api.aiTripDraft(message: 'Samal', language: repo.aiLanguage);
    final draftCall = recorded.lastWhere((r) => r.path == '/ai/trip-draft');
    expect(draftCall.body['language'], 'bisaya');

    // Persisted reload
    final reloaded = TravelRepository(
      apiCatalog: api,
      locationService: LocationService(
        customFetcher: () async => const LocationResult(
          granted: false,
          statusMessage: 'Declined',
        ),
      ),
    );
    await reloaded.initialize();
    expect(reloaded.aiLanguage, 'bisaya');
  });

  test('planWithPicks skips /ai/chat when details are complete and sends whole-trip budget',
      () async {
    final recorded = <({String path, Map<String, dynamic> body})>[];
    final client = MockClient((req) async {
      final path = req.url.path.replaceFirst('/api/v1', '');
      final body = req.body.isEmpty
          ? <String, dynamic>{}
          : jsonDecode(req.body) as Map<String, dynamic>;
      recorded.add((path: path, body: body));
      if (path == '/destinations/facets') {
        return http.Response(jsonEncode({'groups': []}), 200);
      }
      if (path == '/destinations') {
        return http.Response('[]', 200);
      }
      if (path == '/ai/chat') {
        return http.Response(
          jsonEncode({
            'chat_response': 'Picked up details.',
            'model_id': 'mock',
            'ai_generation_run_id': 1,
            'planning': {
              'input_revision': 1,
              'intent': 'show_places',
              'suggested_replies': [],
              'state_updates': {},
              'update_status': 'applied',
              'preview': {
                'state': {
                  ...(body['planning_state'] as Map<String, dynamic>),
                  'day_count': 2,
                  'traveler_count': 3,
                  'total_budget': '2500.00',
                  'budget_scope': 'per_person',
                },
              },
              'recommendations': [_place],
            },
          }),
          200,
        );
      }
      if (path == '/ai/itineraries/generate') {
        return http.Response(jsonEncode(_validGeneratedResponse()), 200);
      }
      return http.Response('{}', 200);
    });

    SharedPreferences.setMockInitialValues({
      'lakbay_traveler_state_v1': jsonEncode({
        'hasCompletedOnboarding': true,
        'aiLanguage': 'filipino',
        'authSession': const LakbayAuthSession(
          accessToken: 'token',
          refreshToken: 'refresh',
          userId: 1,
          fullName: 'Test Traveler',
          email: 't@example.com',
          role: 'traveler',
        ).toJson(),
      }),
    });
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
    await repo.initialize();

    await repo.sendChatMessage('3 travelers, 2 days, 2500 each');
    repo.toggleChatPick(
      repo.resolveExploreTripForRecommendation(
        TopPlaceRecommendation.fromJson(_place),
      ),
    );

    final chatsBeforePlan =
        recorded.where((r) => r.path == '/ai/chat').length;
    await repo.planWithPicks();
    final chatsAfterPlan = recorded.where((r) => r.path == '/ai/chat').length;

    expect(chatsAfterPlan, chatsBeforePlan);
    final generateCall =
        recorded.lastWhere((r) => r.path == '/ai/itineraries/generate');
    expect(generateCall.body['total_budget'], '7500.00');
    expect(generateCall.body['language'], 'filipino');
    expect(repo.chatMessages.last.aiOptions.length, 2);
  });

  test('generateAiItineraries auto-retries once on rate limit and maps typed errors',
      () async {
    var generateAttempt = 0;
    final observedWaits = <int>[];

    final client = MockClient((req) async {
      final path = req.url.path.replaceFirst('/api/v1', '');
      if (path == '/ai/itineraries/generate') {
        generateAttempt++;
        if (generateAttempt == 1) {
          return http.Response(
            jsonEncode({
              'error': {
                'code': 'groq_rate_limit_exceeded',
                'message': 'Groq rate limit reached.',
                'details': {'retry_after_seconds': 2},
              },
            }),
            429,
            headers: {'retry-after': '2'},
          );
        }
        return http.Response(jsonEncode(_validGeneratedResponse()), 200);
      }
      return http.Response('{}', 200);
    });

    final api = LakbayApiCatalogService(
      baseUrlOverride: 'https://api.lakbay.test/api/v1',
      client: client,
      retryDelayOverride: (_) async {},
    );

    final result = await api.generateAiItineraries(
      'token',
      totalBudgetPhp: 5000,
      travelerCount: 2,
      dayCount: 2,
      destinationIds: [78],
      onRateLimitRetry: observedWaits.add,
    );

    expect(generateAttempt, 2);
    expect(observedWaits, [2]);
    expect(result, isA<AiItinerarySuccess>());
    expect((result as AiItinerarySuccess).options.length, 2);

    const overBudget = AiItineraryFailure(
      code: 'planning_over_budget',
      message: 'Over budget',
      statusCode: 409,
    );
    expect(
      overBudget.userFacingMessage(),
      'Your picks cost more than your budget. Raise the budget or remove a place.',
    );

    const rateLimitFail = AiItineraryFailure(
      code: 'groq_rate_limit_exceeded',
      message: 'Busy',
      statusCode: 429,
      retryAfterSeconds: 9,
    );
    expect(
      rateLimitFail.userFacingMessage(),
      'The AI is busy right now. Try again in 9s.',
    );

    const genericFail = AiItineraryFailure(
      code: 'ai_generation_failed',
      message: 'Bad gateway',
      statusCode: 502,
    );
    expect(
      genericFail.userFacingMessage(),
      "I couldn't draft that one. Try again.",
    );
  });

  test('planning_over_budget surfaces actionable message and raisePlanningBudgetAndRetry recovers',
      () async {
    final client = MockClient((req) async {
      final path = req.url.path.replaceFirst('/api/v1', '');
      final body = req.body.isEmpty
          ? <String, dynamic>{}
          : jsonDecode(req.body) as Map<String, dynamic>;
      if (path == '/destinations/facets') {
        return http.Response(jsonEncode({'groups': []}), 200);
      }
      if (path == '/destinations') return http.Response('[]', 200);
      if (path == '/ai/chat') {
        return http.Response(
          jsonEncode({
            'chat_response': 'Noted.',
            'model_id': 'mock',
            'ai_generation_run_id': 1,
            'planning': {
              'input_revision': 1,
              'intent': 'show_places',
              'suggested_replies': [],
              'state_updates': {},
              'update_status': 'applied',
              'preview': {
                'state': {
                  ...(body['planning_state'] as Map<String, dynamic>),
                  'day_count': 2,
                  'traveler_count': 2,
                  'total_budget': '1000.00',
                  'budget_scope': 'whole_trip',
                },
              },
              'recommendations': [_place],
            },
          }),
          200,
        );
      }
      if (path == '/ai/itineraries/generate') {
        final budget = double.tryParse(body['total_budget'].toString()) ?? 0;
        if (budget < 4000) {
          return http.Response(
            jsonEncode({
              'error': {
                'code': 'planning_over_budget',
                'message': 'Selected plan exceeds budget.',
              },
            }),
            409,
          );
        }
        return http.Response(jsonEncode(_validGeneratedResponse()), 200);
      }
      return http.Response('{}', 200);
    });

    SharedPreferences.setMockInitialValues({
      'lakbay_traveler_state_v1': jsonEncode({
        'hasCompletedOnboarding': true,
        'authSession': const LakbayAuthSession(
          accessToken: 'token',
          refreshToken: 'refresh',
          userId: 1,
          fullName: 'Test Traveler',
          email: 't@example.com',
          role: 'traveler',
        ).toJson(),
      }),
    });
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
    await repo.initialize();
    await repo.sendChatMessage('2 travelers, 2 days, 1000 PHP');
    repo.toggleChatPick(
      repo.resolveExploreTripForRecommendation(
        TopPlaceRecommendation.fromJson(_place),
      ),
    );

    await repo.planWithPicks();
    expect(repo.chatMessages.last.isError, isTrue);
    expect(repo.chatMessages.last.errorCode, 'planning_over_budget');
    expect(
      repo.chatMessages.last.text,
      'Your picks cost more than your budget. Raise the budget or remove a place.',
    );

    await repo.raisePlanningBudgetAndRetry(5000);
    expect(repo.chatMessages.last.isError, isFalse);
    expect(repo.chatMessages.last.aiOptions.length, 2);
  });
}
