import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lakbay_travel/models/travel_models.dart';
import 'package:lakbay_travel/screens/explore_screen.dart';
import 'package:lakbay_travel/screens/home_chat_screen.dart';
import 'package:lakbay_travel/services/lakbay_api_catalog_service.dart';
import 'package:lakbay_travel/services/location_service.dart';
import 'package:lakbay_travel/services/travel_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _place = {
  'destination_id': 77,
  'name': 'Hagimit Falls',
  'category': 'waterfall',
  'district': 'Davao del Norte',
  'location': 'Samal Island',
  'lat': 7.071,
  'lng': 125.735,
  'estimated_cost': '250.00',
  'stay_duration_type': 'half_day',
  'family_friendly': true,
  'group_friendly': true,
};

Map<String, dynamic> _planningDraftPayload() => {
      'source': 'catalog_deterministic',
      'source_label': "Built from Lakbay's catalog, without AI",
      'options': [
        {
          'option_number': 1,
          'title': 'Samal Balanced Catalog Route',
          'summary':
              "Built from Lakbay's catalog, without AI. Balanced 2-day pace.",
          'estimated_total_cost': '250.00',
          'cost_source': 'catalog_deterministic',
          'source_label': "Built from Lakbay's catalog, without AI",
          'is_over_budget': false,
          'days': [
            {
              'day': 1,
              'title': 'Day 1: Hagimit Falls',
              'summary': 'Ordered along your route.',
              'activities': [
                {
                  'time': '08:30',
                  'title': 'Visit Hagimit Falls',
                  'description': 'Real catalog waterfall.',
                  'destination_id': 77,
                  'estimated_cost': '250.00',
                  'cost_listed': true,
                  'cost_source': 'catalog_estimate',
                }
              ],
            },
            {
              'day': 2,
              'title': 'Day 2: Hagimit Falls',
              'summary': 'Flex buffer.',
              'activities': [
                {
                  'time': '09:30',
                  'title': 'Explore more around Hagimit Falls',
                  'description': 'Return transit.',
                  'destination_id': 77,
                  'estimated_cost': '0.00',
                  'cost_listed': true,
                  'cost_source': 'catalog_unlisted',
                }
              ],
            },
          ],
        },
        {
          'option_number': 2,
          'title': 'Samal Relaxed Pace Route',
          'summary': "Built from Lakbay's catalog, without AI. Later 09:30 start.",
          'estimated_total_cost': '250.00',
          'cost_source': 'catalog_deterministic',
          'source_label': "Built from Lakbay's catalog, without AI",
          'is_over_budget': false,
          'days': [
            {
              'day': 1,
              'title': 'Day 1: Hagimit Falls',
              'summary': 'Ordered along your route.',
              'activities': [
                {
                  'time': '09:30',
                  'title': 'Visit Hagimit Falls',
                  'description': 'Real catalog waterfall.',
                  'destination_id': 77,
                  'estimated_cost': '250.00',
                  'cost_listed': true,
                  'cost_source': 'catalog_estimate',
                }
              ],
            },
            {
              'day': 2,
              'title': 'Day 2: Hagimit Falls',
              'summary': 'Flex buffer.',
              'activities': [
                {
                  'time': '10:00',
                  'title': 'Explore more around Hagimit Falls',
                  'description': 'Unhurried finish.',
                  'destination_id': 77,
                  'estimated_cost': '0.00',
                  'cost_listed': true,
                  'cost_source': 'catalog_unlisted',
                }
              ],
            },
          ],
        },
      ],
      'planning_preview': {'status': 'choices_available'},
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
      'planWithPicks automatically falls through to /planning/draft when AI fails after retry',
      () async {
    final paths = <String>[];
    final client = MockClient((req) async {
      final path = req.url.path.replaceFirst('/api/v1', '');
      paths.add(path);
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
            'chat_response': 'Ready to plan.',
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
                  'total_budget': '5000.00',
                },
              },
              'recommendations': [_place],
            },
          }),
          200,
        );
      }
      if (path == '/ai/itineraries/generate') {
        return http.Response(
          jsonEncode({
            'error': {
              'code': 'groq_rate_limit_exceeded',
              'message': 'Busy',
              'details': {'retry_after_seconds': 2},
            },
          }),
          429,
        );
      }
      if (path == '/planning/draft') {
        return http.Response(jsonEncode(_planningDraftPayload()), 200);
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
        retryDelayOverride: (_) async {},
      ),
      locationService: LocationService(
        customFetcher: () async => const LocationResult(
          granted: false,
          statusMessage: 'Declined',
        ),
      ),
    );
    await repo.initialize();

    await repo.sendChatMessage('2 travelers, 2 days, 5000 PHP');
    repo.toggleChatPick(
      repo.resolveExploreTripForRecommendation(
        TopPlaceRecommendation.fromJson(_place),
      ),
    );
    await repo.planWithPicks();

    expect(
      paths.where((p) => p == '/ai/itineraries/generate').length,
      2,
    );
    expect(paths, contains('/planning/draft'));
    final last = repo.chatMessages.last;
    expect(last.isError, isFalse);
    expect(last.text, contains("without AI"));
    expect(last.aiOptions.length, 2);
    expect(last.aiOptions.every((o) => o.isCatalogFallback), isTrue);
    expect(last.aiOptions.first.trip.isCatalogFallback, isTrue);
  });

  testWidgets('HomeChatScreen displays no-AI label and Improve with AI button on catalog fallback',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final repo = TravelRepository(
      apiCatalog: LakbayApiCatalogService(baseUrlOverride: ''),
    );
    await tester.runAsync(() async => repo.initialize());

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
                  'total_budget': '5000.00',
                },
              },
              'recommendations': [_place],
            },
          }),
          200,
        );
      }
      if (path == '/ai/itineraries/generate') {
        return http.Response(
          jsonEncode({'error': {'code': 'ai_generation_failed', 'message': 'down'}}),
          502,
        );
      }
      if (path == '/planning/draft') {
        return http.Response(jsonEncode(_planningDraftPayload()), 200);
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
    final liveRepo = TravelRepository(
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
      await liveRepo.initialize();
      await liveRepo.sendChatMessage('2 travelers, 2 days, 5000 PHP');
      liveRepo.toggleChatPick(
        liveRepo.resolveExploreTripForRecommendation(
          TopPlaceRecommendation.fromJson(_place),
        ),
      );
      await liveRepo.planWithPicks();
    });

    await tester.pumpWidget(
      MaterialApp(home: HomeChatScreen(repo: liveRepo)),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    final chatScroll = find.byWidgetPredicate(
      (w) => w is Scrollable && w.axisDirection == AxisDirection.down,
    ).first;
    await tester.scrollUntilVisible(
      find.text("Built from Lakbay's catalog, without AI"),
      300,
      scrollable: chatScroll,
    );
    await tester.pumpAndSettle();

    expect(
      find.text("Built from Lakbay's catalog, without AI"),
      findsOneWidget,
    );
    expect(find.text('Improve with AI'), findsOneWidget);
  });

  testWidgets('Encyclopedia Plan Trip works offline from bundled catalog without AI',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    var aiCalls = 0;
    final downClient = MockClient((req) async {
      if (req.url.path.contains('/ai/')) aiCalls++;
      return http.Response('{"error":"down"}', 503);
    });
    final repo = TravelRepository(
      apiCatalog: LakbayApiCatalogService(
        baseUrlOverride: 'https://api.lakbay.test/api/v1',
        client: downClient,
      ),
      locationService: LocationService(
        customFetcher: () async => const LocationResult(
          granted: false,
          statusMessage: 'Declined',
        ),
      ),
    );
    await tester.runAsync(() async => repo.initialize());

    // Bundled catalog has real places across Davao cities when offline.
    expect(repo.allTrips, isNotEmpty);
    expect(repo.cityDescriptions, isNotEmpty);

    await tester.pumpWidget(
      MaterialApp(home: ExploreScreen(repo: repo)),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    final verticalScroll = find.byWidgetPredicate(
      (w) => w is Scrollable && w.axisDirection == AxisDirection.down,
    ).first;
    await tester.scrollUntilVisible(
      find.text('Davao Region Encyclopedia'),
      350,
      scrollable: verticalScroll,
    );
    await tester.scrollUntilVisible(
      find.text('Plan Trip').first,
      250,
      scrollable: verticalScroll,
    );
    await tester.ensureVisible(find.text('Plan Trip').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Plan Trip').first);
    await tester.pumpAndSettle();

    expect(find.text('Plan Your Route'), findsOneWidget);
    expect(repo.tripBuilderStops, isNotEmpty);
    expect(find.text('Improve with AI'), findsOneWidget);
    expect(aiCalls, 0);
  });
}
