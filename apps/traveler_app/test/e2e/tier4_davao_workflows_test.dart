import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:lakbay_travel/core/plain_words.dart';
import 'package:lakbay_travel/screens/explore_screen.dart';
import 'package:lakbay_travel/screens/home_chat_screen.dart';
import 'package:lakbay_travel/screens/my_trips_screen.dart';
import 'package:lakbay_travel/screens/trip_detail_screen.dart';
import 'package:lakbay_travel/screens/trip_route_map_screen.dart';
import 'package:lakbay_travel/widgets/lakbay_mapbox_widget.dart';
import 'package:lakbay_travel/widgets/timeline_widgets.dart';

import 'e2e_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    await initOfflineE2eEnv();
  });

  group('Tier 4 — Real-World Davao Region Traveler Workflows', () {
    testWidgets(
      'Workflow 1 (F1+F2+F3+F5): 5-Day Davao City + Samal Island multimodal map, traffic, sea crossing & PDF dossier',
      (tester) async {
        setTestViewport(tester, phoneViewport390x844);
        final shares = capturePdfShares();
        final router = E2eMockRouter(
          onPostRoutesPreview: (req) async => http.Response(
            jsonEncode(
              buildMockRouteJson(
                destinationIds: const [1, 14, 2, 3, 4, 1],
                useLiveTraffic: req.body['use_live_traffic'] == true,
                trafficStatus: 'live',
                includeSeaCrossing: true,
              ),
            ),
            200,
          ),
        );
        final trip = buildFiveDayDavaoSamalTrip(backendTripId: 801);
        await seedTravelerState(signedIn: true, savedTrips: [trip]);
        final repo = createE2eRepository(router: router);
        await tester.runAsync(() => repo.initialize());

        // 1. Route Map: verify >=60% viewport, DraggableScrollableSheet, live traffic
        await tester.pumpWidget(
          wrapE2eApp(TripRouteMapScreen(trip: trip, repo: repo)),
        );
        await pumpBounded(tester);

        expect(
          tester.getRect(find.byType(LakbayMapboxMap).first).height / 844.0,
          greaterThanOrEqualTo(0.60),
        );
        expect(find.byType(DraggableScrollableSheet), findsOneWidget);

        await tester.tap(find.byKey(const ValueKey('traffic-toggle-chip')));
        await pumpBounded(tester);
        expect(repo.showLiveTraffic, isTrue);
        expect(
          find.text('Live traffic data is limited in this region'),
          findsNothing,
        );

        // 2. Inspect Sasa -> Babak sea crossing details
        await tester.tap(find.byIcon(Icons.directions_boat_rounded).first);
        await pumpBounded(tester);
        expect(find.text('Boat Crossing Details'), findsOneWidget);
        expect(find.textContaining('Sasa Wharf'), findsWidgets);
        Navigator.of(tester.element(find.text('Boat Crossing Details'))).pop();
        await pumpBounded(tester);

        // 3. Filter to Day 4 (Samal Island)
        final day4Filter = find.byKey(const ValueKey('day-filter-4'));
        await tester.ensureVisible(day4Filter);
        await tester.tap(day4Filter);
        await pumpBounded(tester);
        expect(
          find.descendant(
            of: find.byKey(const ValueKey('active-stop-callout')),
            matching: find.text('Samal Island Beach Area'),
          ),
          findsOneWidget,
        );

        // 4. Open TripDetailScreen -> Budget & PDF -> Export PDF dossier
        await tester.pumpWidget(
          wrapE2eApp(TripDetailScreen(trip: trip, repo: repo)),
        );
        await pumpBounded(tester);
        await tester.tap(find.text('Budget & PDF'));
        await pumpBounded(tester);
        await tester.runAsync(() async {
          await tester.tap(find.text('Export PDF'));
          await Future<void>.delayed(const Duration(milliseconds: 500));
        });
        await tester.pump();

        expect(shares, hasLength(1));
        final inspected = inspectPdfBytes(
          Uint8List.fromList(shares.first.bytes),
        );
        expect(inspected.unmappedCids, 0);
        expect(inspected.text, contains('Lakbay+'));
        expect(inspected.text, contains('₱'));
        expect(inspected.text, contains('Page 1 of ${inspected.pageCount}'));
      },
    );

    testWidgets(
      'Workflow 2 (F4+F5+F6): Mount Apo & Eden AI chat chips -> timeline PDF -> Mark Trip as Completed -> MyTrips Past',
      (tester) async {
        setTestViewport(tester, phoneViewport390x844);
        final shares = capturePdfShares();
        var turn = 0;
        final router = E2eMockRouter(
          onPostAiChat: (req) async {
            turn++;
            if (turn == 1) {
              return http.Response(
                jsonEncode({
                  'chat_response': 'Great Mount Apo & Eden picks! How intense should hikes be?',
                  'model_id': 'mock-groq',
                  'ai_generation_run_id': 802,
                  'planning': {
                    'input_revision': 1,
                    'intent': 'plan_trip',
                    'suggested_replies': const <String>[],
                    'state_updates': {
                      'destination_ids': [3, 5],
                      'day_count': 2,
                      'traveler_count': 2,
                      'total_budget': 7000,
                    },
                    'update_status': 'updated',
                    'preview': {
                      'state': {
                        'destination_ids': [3, 5],
                        'day_count': 2,
                        'traveler_count': 2,
                        'total_budget': 7000,
                      },
                    },
                    'recommendations': const <dynamic>[],
                    'conversation': {
                      'stage': 'clarify',
                      'missing_details': ['activity_level'],
                      'ask_next': 'activity_level',
                      'optional_details': const <String>[],
                    },
                  },
                }),
                200,
              );
            }
            if (turn == 2) {
              return http.Response(
                jsonEncode({
                  'chat_response': 'Do you prefer quieter spots or popular highlights?',
                  'model_id': 'mock-groq',
                  'ai_generation_run_id': 802,
                  'planning': {
                    'input_revision': 2,
                    'intent': 'plan_trip',
                    'suggested_replies': const <String>[],
                    'state_updates': {'activity_level': 'easy'},
                    'update_status': 'updated',
                    'preview': {
                      'state': {
                        'destination_ids': [3, 5],
                        'day_count': 2,
                        'traveler_count': 2,
                        'total_budget': 7000,
                        'activity_level': 'easy',
                      },
                    },
                    'recommendations': const <dynamic>[],
                    'conversation': {
                      'stage': 'clarify',
                      'missing_details': ['prefers_quiet'],
                      'ask_next': 'prefers_quiet',
                      'optional_details': const <String>[],
                    },
                  },
                }),
                200,
              );
            }
            return http.Response(
              jsonEncode({
                'chat_response': 'Built your Mount Apo & Eden 2-day plan!',
                'model_id': 'mock-groq',
                'ai_generation_run_id': 802,
                'planning': {
                  'input_revision': 3,
                  'intent': 'plan_trip',
                  'suggested_replies': const <String>[],
                  'state_updates': {'prefers_quiet': true},
                  'update_status': 'updated',
                  'preview': {
                    'state': {
                      'destination_ids': [3, 5],
                      'day_count': 2,
                      'traveler_count': 2,
                      'total_budget': 7000,
                      'activity_level': 'easy',
                      'prefers_quiet': true,
                    },
                  },
                  'recommendations': const <dynamic>[],
                },
              }),
              200,
            );
          },
          onPostPlanningTimeline: (req) async => http.Response(
            jsonEncode({
              'timeline': buildDavaoTimelineData().toJson(),
              'changes': ['Planned Mount Apo & Eden itinerary.'],
              'unavailable_destination_ids': const <int>[],
            }),
            200,
          ),
        );
        final savedTrip = buildFiveDayDavaoSamalTrip(
          id: 'apo_eden_trip',
          backendTripId: 802,
          backendStatus: 'ongoing',
        ).copyWith(title: 'Mount Apo & Eden Escape');

        await seedTravelerState(signedIn: true, savedTrips: [savedTrip]);
        final repo = createE2eRepository(router: router);
        await tester.runAsync(() => repo.initialize());

        // 1. AI Chat flow with structured chips
        await tester.pumpWidget(wrapE2eApp(HomeChatScreen(repo: repo)));
        await pumpBounded(tester);

        await tester.runAsync(
          () => repo.sendChatMessage('Plan Mount Apo and Eden for 2 days'),
        );
        await pumpBounded(tester);

        await tester.tap(find.text('Easy'));
        await pumpBounded(tester);
        await tester.tap(find.text('Quiet places'));
        await pumpBounded(tester);

        expect(repo.chatMessages.last.timeline, isNotNull);

        // 2. Export Timeline PDF via TimelineCard
        await tester.pumpWidget(
          wrapE2eApp(
            Scaffold(
              body: SingleChildScrollView(
                child: TimelineCard(
                  timeline: repo.chatMessages.last.timeline!,
                  repo: repo,
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.runAsync(() async {
          await tester.tap(find.byKey(const ValueKey('timeline-export-pdf')));
          await Future<void>.delayed(const Duration(milliseconds: 500));
        });
        await tester.pump();
        expect(shares, hasLength(1));

        // 3. Mark Trip as Completed -> verify in MyTrips Past filter
        await tester.pumpWidget(
          wrapE2eApp(TripDetailScreen(trip: savedTrip, repo: repo)),
        );
        await pumpBounded(tester);
        final completeBtn = find.text('Mark Trip as Completed');
        expect(completeBtn, findsOneWidget);
        await tester.ensureVisible(completeBtn);
        await tester.tap(completeBtn);
        await pumpBounded(tester);
        final confirmBtn = find.text('Mark as Completed').last;
        if (confirmBtn.evaluate().isNotEmpty) {
          await tester.tap(confirmBtn);
          await pumpBounded(tester);
        }

        expect(repo.savedTrips.first.backendStatus, 'completed');

        await tester.pumpWidget(wrapE2eApp(MyTripsScreen(repo: repo)));
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(ChoiceChip, 'Past'));
        await tester.pumpAndSettle();
        expect(find.text('Mount Apo & Eden Escape'), findsOneWidget);
      },
    );

    testWidgets(
      'Workflow 3 (F2+F7+F8): Davao Region Discover -> duration clarity -> Map toggle -> Add stops -> Route Map',
      (tester) async {
        setTestViewport(tester, phoneViewport390x844);
        final router = E2eMockRouter(
          destinations: davaoDestinationsCatalogJson(includeMediaFields: true),
        );
        await seedTravelerState(signedIn: false);
        final repo = createE2eRepository(router: router);
        await tester.runAsync(() => repo.initialize());
        await tester.runAsync(() => repo.refreshFromApi());

        // 1. ExploreScreen Discover cards + duration clarity + PlainWords
        await tester.pumpWidget(wrapE2eApp(ExploreScreen(repo: repo)));
        await tester.pumpAndSettle();

        expect(find.text('Discover'), findsOneWidget);
        expect(find.textContaining('Typical visit:'), findsWidgets);
        expect(find.textContaining('Region XI'), findsNothing);
        expect(find.text('Wildlife • Half day'), findsNothing);

        // 2. Toggle Map / List View
        await tester.tap(find.text(PlainWords.map));
        await pumpBounded(tester);
        expect(find.text('List View'), findsOneWidget);
        await tester.tap(find.text('List View'));
        await tester.pumpAndSettle();

        // 3. Add stops to Trip Tray and verify TripRouteMapScreen
        final addBtn = find.text('＋ Add to trip').first;
        await tester.ensureVisible(addBtn);
        await tester.tap(addBtn);
        await tester.pumpAndSettle();
        expect(repo.tripBuilderStops, isNotEmpty);

        final builtTrip = buildFiveDayDavaoSamalTrip(backendTripId: null);
        await tester.pumpWidget(
          wrapE2eApp(TripRouteMapScreen(trip: builtTrip, repo: repo)),
        );
        await pumpBounded(tester);

        expect(find.text('Road directions unavailable'), findsNothing);
        expect(find.byKey(const ValueKey('day-filter-all')), findsOneWidget);
      },
    );

    testWidgets(
      'Workflow 4 (F1+F2+F3): 14-day / 25-stop Davao Grand Loop with hub revisits & Retry recovery',
      (tester) async {
        setTestViewport(tester, phoneViewport390x844);
        var routeAttempts = 0;
        final router = E2eMockRouter(
          onPostRoutesPreview: (req) async {
            routeAttempts++;
            if (routeAttempts <= 2) {
              return http.Response(
                jsonEncode({'detail': 'Gateway timeout'}),
                504,
              );
            }
            return http.Response(
              jsonEncode(
                buildMockRouteJson(
                  destinationIds: (req.body['destination_ids'] as List<dynamic>)
                      .cast<int>(),
                  useLiveTraffic: req.body['use_live_traffic'] == true,
                  trafficStatus: 'limited_coverage',
                  includeSeaCrossing: true,
                ),
              ),
              200,
            );
          },
          onPostRoutesPlan: (req) async {
            if (routeAttempts <= 2) {
              return http.Response(
                jsonEncode({'detail': 'Gateway timeout'}),
                504,
              );
            }
            return http.Response(
              jsonEncode({
                'route': buildMockRouteJson(
                  destinationIds: (req.body['destination_ids'] as List<dynamic>)
                      .cast<int>(),
                  useLiveTraffic: req.body['use_live_traffic'] == true,
                  trafficStatus: 'limited_coverage',
                  includeSeaCrossing: true,
                ),
                'suggested_days': 14,
                'days': const <dynamic>[],
              }),
              200,
            );
          },
        );
        final grandTrip = buildFourteenDayDavaoGrandLoopTrip();
        await seedTravelerState(signedIn: true, savedTrips: [grandTrip]);
        final repo = createE2eRepository(router: router);
        await tester.runAsync(() => repo.initialize());

        await tester.pumpWidget(
          wrapE2eApp(TripRouteMapScreen(trip: grandTrip, repo: repo)),
        );
        await pumpBounded(tester);

        // Initial 504 -> Retry pill shown -> tap Retry -> recovers cleanly
        final retryBtn = find.text('Retry');
        expect(retryBtn, findsOneWidget);
        await tester.tap(retryBtn);
        await pumpBounded(tester);

        expect(find.text('Retry'), findsNothing);
        expect(find.text('Road directions unavailable'), findsNothing);

        // Enable traffic on limited_coverage response without blocking map
        await tester.tap(find.byKey(const ValueKey('traffic-toggle-chip')));
        await pumpBounded(tester);

        final mapRect = tester.getRect(find.byType(LakbayMapboxMap).first);
        expect(mapRect.height / 844.0, greaterThanOrEqualTo(0.60));
        expect(find.byKey(const ValueKey('day-filter-1')), findsOneWidget);
        expect(find.byKey(const ValueKey('day-filter-6')), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  });
}
