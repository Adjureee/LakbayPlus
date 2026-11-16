import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lakbay_travel/screens/yes_ai_onboarding_flow.dart';
import 'package:lakbay_travel/services/lakbay_api_catalog_service.dart';
import 'package:lakbay_travel/services/location_service.dart';
import 'package:lakbay_travel/services/travel_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

http.Response _jsonRes(Object body, [int statusCode = 200]) => http.Response(
      jsonEncode(body),
      statusCode,
      headers: const {'content-type': 'application/json; charset=utf-8'},
    );

Map<String, dynamic> _placeCard({
  required int id,
  required String name,
  required String district,
  required String category,
  double lat = 7.08,
  double lng = 125.71,
}) =>
    {
      'destination_id': id,
      'name': name,
      'district': district,
      'category': category,
      'score': 92.0,
      'reasons': ['Matches $category', 'Good match for your trip'],
      'route_verified': true,
      'travel_mode': 'driving',
      'travel_minutes': 40,
      'lat': lat,
      'lng': lng,
    };

Map<String, dynamic> _itineraryOptionJson({
  required int destId,
  required String title,
  String cost = '4500.00',
}) =>
    {
      'option_number': 1,
      'title': title,
      'summary': 'Grounded Region XI route.',
      'estimated_total_cost': cost,
      'cost_source': 'ai_draft_estimate',
      'is_over_budget': false,
      'days': [
        {
          'day': 1,
          'title': 'Day 1 • $title',
          'summary': 'Explore $title.',
          'activities': [
            {
              'time': '09:00',
              'title': 'Arrive at pick',
              'description': 'Morning arrival and orientation.',
              'destination_id': destId,
              'estimated_cost': '500.00',
              'cost_source': 'ai_draft_estimate',
            },
          ],
        },
      ],
    };

void main() {
  setUp(() {
    GoogleFonts.config.allowRuntimeFetching = false;
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets(
    'Persona 1 (vague explorer with Panabo GPS) & Persona 2 (island hopper) use onboarding AI + guest itinerary endpoint',
    (tester) async {
      final recorded = <({String path, Map<String, dynamic> body})>[];
      final client = MockClient((req) async {
        final path = req.url.path.replaceFirst('/api/v1', '');
        final body = req.body.isEmpty
            ? <String, dynamic>{}
            : jsonDecode(req.body) as Map<String, dynamic>;
        recorded.add((path: path, body: body));
        if (path == '/destinations/facets') {
          return http.Response(
            jsonEncode({
              'groups': [],
              'categories': [
                {'key': 'park', 'label': 'Parks', 'count': 3, 'examples': ['People\'s Park']},
              ],
            }),
            200,
          );
        }
        if (path == '/destinations/browse') {
          return http.Response(
            jsonEncode([
              _placeCard(
                id: 91,
                name: 'Eden Nature Park',
                district: 'Davao City',
                category: 'Park',
              ),
            ]),
            200,
          );
        }
        if (path == '/destinations') {
          return http.Response(jsonEncode({'items': [], 'total': 0}), 200);
        }
        if (path == '/ai/chat/guest') {
          final msg = (body['message'] ?? '').toString().toLowerCase();
          final state = Map<String, dynamic>.from(
            body['planning_state'] as Map<String, dynamic>? ?? const {},
          );
          if (msg.contains('inspire me')) {
            return http.Response(
              jsonEncode({
                'chat_response': 'Leaving from Panabo City, try coral beaches on Samal or cool ridges in Marilog!',
                'model_id': 'mock-groq',
                'ai_generation_run_id': 11,
                'planning': {
                  'input_revision': 0,
                  'intent': 'show_places',
                  'suggested_replies': ['Plan 2-day Samal trip'],
                  'state_updates': {'interests': ['beaches']},
                  'update_status': 'updated',
                  'preview': {'state': state},
                  'recommendations': [
                    _placeCard(
                      id: 12,
                      name: 'Hagimit Falls & Reef',
                      district: 'Samal',
                      category: 'Beach & Falls',
                    ),
                  ],
                },
              }),
              200,
            );
          }
          // Persona 2: full island brief triggers plan_trip -> /ai/itineraries/generate/guest
          final nextState = {
            ...state,
            'destination_ids': [12],
            'day_count': 3,
            'traveler_count': 2,
            'total_budget': '8000.00',
            'budget_scope': 'whole_trip',
          };
          return http.Response(
            jsonEncode({
              'chat_response': 'Building your 3-day Samal beach escape from Panabo!',
              'model_id': 'mock-groq',
              'ai_generation_run_id': 12,
              'planning': {
                'input_revision': 1,
                'intent': 'plan_trip',
                'suggested_replies': ['Swap stops'],
                'state_updates': {'destination_ids': [12]},
                'update_status': 'updated',
                'preview': {'state': nextState},
                'recommendations': [],
              },
            }),
            200,
          );
        }
        if (path == '/ai/itineraries/generate/guest') {
          return _jsonRes({
            'options': [_itineraryOptionJson(destId: 12, title: 'Samal Island 3D2N Escape')],
            'model_runs': [],
          });
        }
        return http.Response('{}', 200);
      });

      final repo = TravelRepository(
        apiCatalog: LakbayApiCatalogService(
          baseUrlOverride: 'https://api.lakbay.test/api/v1',
          client: client,
        ),
          locationService: LocationService(
          customFetcher: () async => const LocationResult(
            granted: true,
            resolvedLabel: 'Panabo City',
            lat: 7.3081,
            lng: 125.6842,
            statusMessage: 'OK',
          ),
        ),
      );
      await tester.runAsync(() => repo.initialize());
      await tester.runAsync(() => repo.requestAndSaveCurrentLocation());

      await tester.pumpWidget(
        MaterialApp(
          home: YesAiOnboardingFlow(repo: repo, onBackToDecision: () {}),
        ),
      );
      await tester.pumpAndSettle();

      // Shows live origin from Phase 4 and zero hardcoded fake Dec 14/29°/₱5,400 cards.
      expect(find.text('From Panabo City'), findsOneWidget);
      expect(find.text('Dec 14'), findsNothing);
      expect(find.text('₱5,400'), findsNothing);

      // Persona 1: Inspire me!
      await tester.tap(find.text('Inspire me!'));
      await tester.pumpAndSettle();
      expect(find.text('Hagimit Falls & Reef'), findsOneWidget);

      final inspireCall = recorded.lastWhere((r) => r.path == '/ai/chat/guest');
      expect(inspireCall.body['is_onboarding'], isTrue);
      expect(inspireCall.body['planning_state']['origin']['label'], 'Panabo City');

      // Persona 2: full prompt triggers guest itinerary generation automatically
      await tester.enterText(
        find.byType(TextField),
        '3-day Samal beach getaway for 2 on 8000 PHP',
      );
      await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
      await tester.pumpAndSettle();

      expect(recorded.any((r) => r.path == '/ai/itineraries/generate/guest'), isTrue);
      await tester.scrollUntilVisible(
        find.text('Samal Island 3D2N Escape'),
        150,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('Samal Island 3D2N Escape'), findsOneWidget);

      await tester.ensureVisible(find.text('Use plan ✨'));
      await tester.tap(find.text('Use plan ✨'));
      await tester.pumpAndSettle();
      expect(find.text('Good so far?'), findsOneWidget);

      await tester.tap(find.text('Rate Lakbay+✦'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.text('First plan, done.'), findsOneWidget);
      expect(find.text('Sign in or create account to save trip'), findsOneWidget);
    },
  );

  testWidgets(
    'Persona 3 (hiker ask_next), Persona 4 (budget Phase 2 fallback), Persona 5 (browse category + raise budget)',
    (tester) async {
      final client = MockClient((req) async {
        final path = req.url.path.replaceFirst('/api/v1', '');
        final body = req.body.isEmpty
            ? <String, dynamic>{}
            : jsonDecode(req.body) as Map<String, dynamic>;
        if (path == '/destinations/facets') {
          return http.Response(
            jsonEncode({
              'groups': [],
              'categories': [
                {'key': 'park', 'label': 'Parks', 'count': 2, 'examples': ['Eden Nature Park']},
              ],
            }),
            200,
          );
        }
        if (path == '/destinations/browse') {
          return http.Response(
            jsonEncode([
              _placeCard(
                id: 91,
                name: 'Eden Nature Park',
                district: 'Davao City',
                category: 'Park',
              ),
            ]),
            200,
          );
        }
        if (path == '/destinations') {
          return http.Response(
            jsonEncode({
              'items': [
                {
                  'destination_id': 91,
                  'name': 'Eden Nature Park',
                  'district': 'Davao City',
                  'category': 'park',
                  'estimated_cost': '500.00',
                  'lat': 7.03,
                  'lng': 125.43,
                },
              ],
              'total': 1,
            }),
            200,
          );
        }
        if (path == '/ai/chat/guest') {
          final state = Map<String, dynamic>.from(
            body['planning_state'] as Map<String, dynamic>? ?? const {},
          );
          final msg = (body['message'] ?? '').toString().toLowerCase();
          if (msg.contains('hike')) {
            return http.Response(
              jsonEncode({
                'chat_response': 'Nice pick! How active should the trail day be?',
                'model_id': 'mock-groq',
                'ai_generation_run_id': 21,
                'planning': {
                  'input_revision': 0,
                  'intent': 'recommend',
                  'suggested_replies': [],
                  'conversation': {
                    'stage': 'recommend',
                    'missing_details': ['activity_level'],
                    'ask_next': 'How active do you want to be?',
                  },
                  'state_updates': {'interests': ['nature_attractions']},
                  'update_status': 'updated',
                  'preview': {'state': state},
                  'recommendations': [
                    _placeCard(
                      id: 88,
                      name: 'Mt. Loay Highland Trail',
                      district: 'Sta. Cruz',
                      category: 'Mountain',
                    ),
                  ],
                },
              }),
              200,
            );
          }
          if (msg.contains('easy pace')) {
            return http.Response(
              jsonEncode({
                'chat_response': 'Easy pace locked in — add the trail or generate anytime.',
                'model_id': 'mock-groq',
                'ai_generation_run_id': 22,
                'planning': {
                  'input_revision': 1,
                  'intent': 'recommend',
                  'suggested_replies': [],
                  'state_updates': {'day_count': 1, 'traveler_count': 2, 'total_budget': '1500.00'},
                  'update_status': 'updated',
                  'preview': {
                    'state': {
                      ...state,
                      'day_count': 1,
                      'traveler_count': 2,
                      'total_budget': '1500.00',
                      'budget_scope': 'whole_trip',
                    },
                  },
                  'recommendations': [],
                },
              }),
              200,
            );
          }
          final preservedBudget = state['total_budget']?.toString() ?? '1500.00';
          return http.Response(
            jsonEncode({
              'chat_response': 'Building fallback budget trip!',
              'model_id': 'mock-groq',
              'ai_generation_run_id': 23,
              'planning': {
                'input_revision': 2,
                'intent': 'plan_trip',
                'suggested_replies': [],
                'state_updates': {},
                'update_status': 'no_changes',
                'preview': {
                  'state': {
                    ...state,
                    'destination_ids': [91],
                    'day_count': 1,
                    'traveler_count': 2,
                    'total_budget': preservedBudget,
                    'budget_scope': 'whole_trip',
                  },
                },
                'recommendations': [],
              },
            }),
            200,
          );
        }
        if (path == '/ai/itineraries/generate/guest') {
          final budget = double.tryParse((body['total_budget'] ?? '0').toString()) ?? 0;
          if (budget < 3000) {
            return _jsonRes({
              'error': {
                'code': 'planning_over_budget',
                'message': 'Selected plan exceeds ₱1,500 budget.',
              },
            }, 409);
          }
          // On retry with raised budget, simulate AI outage so Phase 2 /planning/draft runs
          return _jsonRes(
            {'error': {'code': 'ai_generation_failed', 'message': 'Model down'}},
            502,
          );
        }
        if (path == '/planning/draft') {
          return _jsonRes({
            'options': [_itineraryOptionJson(destId: 91, title: 'Eden Catalog Escape')],
            'source': 'catalog',
          });
        }
        return http.Response('{}', 200);
      });

      final repo = TravelRepository(
        apiCatalog: LakbayApiCatalogService(
          baseUrlOverride: 'https://api.lakbay.test/api/v1',
          client: client,
        ),
        locationService: LocationService(
          customFetcher: () async =>
              const LocationResult(granted: false, statusMessage: 'Declined'),
        ),
      );
      await tester.runAsync(() => repo.initialize());
      await tester.runAsync(() => repo.refreshPreferenceGroups());

      await tester.pumpWidget(
        MaterialApp(
          home: YesAiOnboardingFlow(repo: repo, onBackToDecision: () {}),
        ),
      );
      await tester.pumpAndSettle();

      // Persona 5: Browse DB category without spending an AI call
      await tester.ensureVisible(find.text('Parks (2)'));
      await tester.tap(find.text('Parks (2)'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('Eden Nature Park'),
        150,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('Eden Nature Park'), findsOneWidget);

      // Persona 3: Mountain hike -> receives ask_next Easy pace pill -> answers it
      await tester.enterText(find.byType(TextField), 'Mountain hike in Marilog');
      await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('Easy pace'),
        150,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('Easy pace'), findsOneWidget);

      await tester.tap(find.text('Easy pace'));
      await tester.pumpAndSettle();
      expect(repo.planningStateView['activity_level'], 'easy');

      // Add Eden Nature Park card & trigger plan_trip -> hits 409 planning_over_budget -> Raise budget -> Phase 2 fallback!
      await tester.scrollUntilVisible(
        find.text('+ Add').first,
        -150,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('+ Add').first);
      await tester.pumpAndSettle();
      expect(find.text('Plan with 1 pick'), findsOneWidget);

      await tester.tap(find.text('Plan with 1 pick'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('Raise budget'),
        150,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('Raise budget'), findsOneWidget);

      await tester.tap(find.text('Raise budget'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Update & retry'));
      await tester.pumpAndSettle();

      await tester.scrollUntilVisible(
        find.text('Eden Catalog Escape'),
        150,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text("Built from Lakbay's catalog, without AI"), findsOneWidget);
      expect(find.text('Eden Catalog Escape'), findsOneWidget);
    },
  );
}
