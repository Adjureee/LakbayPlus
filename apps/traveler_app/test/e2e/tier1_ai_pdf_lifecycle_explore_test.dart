import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:lakbay_travel/core/plain_words.dart';
import 'package:lakbay_travel/models/travel_models.dart';
import 'package:lakbay_travel/screens/explore_screen.dart';
import 'package:lakbay_travel/screens/home_chat_screen.dart';
import 'package:lakbay_travel/screens/my_trips_screen.dart';
import 'package:lakbay_travel/screens/profile_screen.dart';
import 'package:lakbay_travel/screens/trip_detail_screen.dart';
import 'package:lakbay_travel/services/ai_chat_chip_helper.dart';
import 'package:lakbay_travel/services/timeline_pdf.dart';
import 'package:lakbay_travel/services/trip_pdf.dart';
import 'package:lakbay_travel/widgets/timeline_widgets.dart';

import 'e2e_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    await initOfflineE2eEnv();
  });

  group('Tier 1 — F4 (R4): AI Chat Safe Plan Update & Chips', () {
    testWidgets(
      'F4.1: HomeChatScreen hero chips submit prompt to /ai/chat/guest and render reply',
      (tester) async {
        setTestViewport(tester, phoneViewport390x844);
        final router = E2eMockRouter(
          onPostAiChat: (req) async => http.Response(
            jsonEncode({
              'chat_response': 'Here are top Davao Region spots to explore.',
              'model_id': 'mock-groq',
              'ai_generation_run_id': 11,
              'planning': {
                'input_revision': 1,
                'intent': 'plan_trip',
                'suggested_replies': ['2 days', '3 days'],
                'state_updates': {'interests': ['nature_attractions']},
                'update_status': 'updated',
                'preview': {
                  'state': {'interests': ['nature_attractions']},
                },
                'recommendations': const <dynamic>[],
              },
            }),
            200,
          ),
        );
        await seedTravelerState(signedIn: false);
        final repo = createE2eRepository(router: router);
        await tester.runAsync(() => repo.initialize());

        await tester.pumpWidget(wrapE2eApp(HomeChatScreen(repo: repo)));
        await pumpBounded(tester);

        await tester.tap(find.text('Surprise me'));
        await pumpBounded(tester);

        expect(router.requestsFor('/ai/chat/guest'), isNotEmpty);
        expect(
          find.text('Here are top Davao Region spots to explore.'),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'F4.2: missing-detail structured chips (Easy, Quiet places, This weekend) sync planning_state cleanly',
      (tester) async {
        setTestViewport(tester, phoneViewport390x844);
        var turn = 0;
        final router = E2eMockRouter(
          onPostAiChat: (req) async {
            turn++;
            final askNext = switch (turn) {
              1 => 'activity_level',
              2 => 'prefers_quiet',
              3 => 'travel_start_date',
              _ => null,
            };
            return http.Response(
              jsonEncode({
                'chat_response': 'Got it — noted for your Davao trip.',
                'model_id': 'mock-groq',
                'ai_generation_run_id': 12,
                'planning': {
                  'input_revision': turn,
                  'intent': 'plan_trip',
                  'suggested_replies': const <String>[],
                  'state_updates': const <String, dynamic>{},
                  'update_status': 'updated',
                  'preview': {
                    'state': req.body['planning_state'] ?? <String, dynamic>{},
                  },
                  'recommendations': const <dynamic>[],
                  if (askNext != null)
                    'conversation': {
                      'stage': 'clarify',
                      'missing_details': [askNext],
                      'ask_next': askNext,
                      'optional_details': const <String>[],
                    },
                },
              }),
              200,
              headers: const {
                'content-type': 'application/json; charset=utf-8',
              },
            );
          },
        );
        await seedTravelerState(signedIn: false);
        final repo = createE2eRepository(router: router);
        await tester.runAsync(() => repo.initialize());

        await tester.pumpWidget(wrapE2eApp(HomeChatScreen(repo: repo)));
        await pumpBounded(tester);

        await tester.runAsync(
          () => repo.sendChatMessage('Plan a nature trip to Mount Apo'),
        );
        await pumpBounded(tester);
        expect(find.text('Easy'), findsOneWidget);

        await tester.tap(find.text('Easy'));
        await pumpBounded(tester);
        expect(repo.planningStateView['activity_level'], 'easy');
        expect(find.text('Quiet places'), findsOneWidget);

        await tester.tap(find.text('Quiet places'));
        await pumpBounded(tester);
        expect(repo.planningStateView['prefers_quiet'], isTrue);
        expect(find.text('This weekend'), findsOneWidget);

        await tester.tap(find.text('This weekend'));
        await pumpBounded(tester);
        expect(
          repo.planningStateView['travel_start_date'],
          matches(RegExp(r'^\d{4}-\d{2}-\d{2}$')),
        );
      },
    );

    testWidgets(
      'F4.3: short plan update succeeds without false "I couldn\'t safely update your plan" fallback',
      (tester) async {
        setTestViewport(tester, phoneViewport390x844);
        final router = E2eMockRouter(
          onPostAiChat: (req) async => http.Response(
            jsonEncode({
              'chat_response':
                  'Updated your plan for 2 travelers on a 3-day relaxed Davao nature trip.',
              'model_id': 'mock-groq',
              'ai_generation_run_id': 13,
              'planning': {
                'input_revision': 1,
                'intent': 'plan_trip',
                'suggested_replies': const <String>[],
                'state_updates': {
                  'traveler_count': 2,
                  'day_count': 3,
                  'total_budget': 8000,
                  'destination_ids': [1, 3],
                },
                'update_status': 'updated',
                'preview': {
                  'state': {
                    'traveler_count': 2,
                    'day_count': 3,
                    'total_budget': 8000,
                    'destination_ids': [1, 3],
                  },
                },
                'recommendations': const <dynamic>[],
              },
            }),
            200,
          ),
          onPostPlanningTimeline: (req) async => http.Response(
            jsonEncode({
              'timeline': buildDavaoTimelineData().toJson(),
              'changes': ['Built 2-day Davao timeline.'],
              'unavailable_destination_ids': const <int>[],
            }),
            200,
          ),
        );
        await seedTravelerState(signedIn: false);
        final repo = createE2eRepository(router: router);
        await tester.runAsync(() => repo.initialize());

        await tester.pumpWidget(wrapE2eApp(HomeChatScreen(repo: repo)));
        await pumpBounded(tester);

        await tester.runAsync(
          () => repo.sendChatMessage('Two adults 3 days Davao nature 8000 PHP'),
        );
        await pumpBounded(tester);

        for (final msg in repo.chatMessages) {
          expect(
            AiChatChipHelper.isSafeUpdateFallbackMessage(msg.text),
            isFalse,
          );
        }
        expect(repo.chatMessages.last.timeline, isNotNull);
      },
    );

    testWidgets(
      'F4.4: suggestedReplies render when askNext is null and resolve structured details on tap',
      (tester) async {
        setTestViewport(tester, phoneViewport390x844);
        final router = E2eMockRouter(
          onPostAiChat: (req) async => http.Response(
            jsonEncode({
              'chat_response': 'How many days would you like for Samal Island?',
              'model_id': 'mock-groq',
              'ai_generation_run_id': 14,
              'planning': {
                'input_revision': 1,
                'intent': 'plan_trip',
                'suggested_replies': ['2 days', '3 days'],
                'state_updates': {'interests': ['beaches'], 'traveler_count': 2},
                'update_status': 'updated',
                'preview': {
                  'state': {'interests': ['beaches'], 'traveler_count': 2},
                },
                'recommendations': const <dynamic>[],
              },
            }),
            200,
          ),
        );
        await seedTravelerState(signedIn: false);
        final repo = createE2eRepository(router: router);
        await tester.runAsync(() => repo.initialize());

        await tester.pumpWidget(wrapE2eApp(HomeChatScreen(repo: repo)));
        await pumpBounded(tester);

        await tester.runAsync(() => repo.sendChatMessage('Samal beach trip'));
        await pumpBounded(tester);

        expect(find.text('2 days'), findsOneWidget);
        await tester.tap(find.text('2 days'));
        await pumpBounded(tester);

        expect(repo.planningStateView['day_count'], 2);
      },
    );

    testWidgets(
      'F4.5: isError message exposes "Try again" recovery chip and retries cleanly',
      (tester) async {
        setTestViewport(tester, phoneViewport390x844);
        var chatCalls = 0;
        final router = E2eMockRouter(
          onPostAiChat: (req) async {
            chatCalls++;
            if (chatCalls == 1) {
              return http.Response(
                jsonEncode({'detail': 'Upstream timeout'}),
                503,
              );
            }
            return http.Response(
              jsonEncode({
                'chat_response': 'Recovered! Here is your Davao plan.',
                'model_id': 'mock-groq',
                'ai_generation_run_id': 15,
                'planning': {
                  'input_revision': 1,
                  'intent': 'plan_trip',
                  'suggested_replies': const <String>[],
                  'state_updates': const <String, dynamic>{},
                  'update_status': 'no_changes',
                  'preview': {'state': const <String, dynamic>{}},
                  'recommendations': const <dynamic>[],
                },
              }),
              200,
              headers: const {
                'content-type': 'application/json; charset=utf-8',
              },
            );
          },
        );
        await seedTravelerState(signedIn: false);
        final repo = createE2eRepository(router: router);
        await tester.runAsync(() => repo.initialize());

        await tester.pumpWidget(wrapE2eApp(HomeChatScreen(repo: repo)));
        await pumpBounded(tester);

        await tester.runAsync(() => repo.sendChatMessage('Plan Davao tour'));
        await pumpBounded(tester);

        expect(repo.chatMessages.last.isError, isTrue);
        final retryChip = find.text('Try again');
        expect(retryChip, findsOneWidget);

        await tester.tap(retryChip);
        await pumpBounded(tester);

        expect(chatCalls, 2);
        expect(repo.chatMessages.last.isError, isFalse);
        expect(
          find.text('Recovered! Here is your Davao plan.'),
          findsOneWidget,
        );
      },
    );
  });

  group('Tier 1 — F5 (R5): Flagship PDF Dossier & Theme Tokens', () {
    test(
      'F5.1: TripPdfBuilder emits valid %PDF- with Lakbay+ branding, Page 1 of, and ₱ (not PHP )',
      () async {
        final trip = buildFiveDayDavaoSamalTrip();
        final bytes = await TripPdfBuilder.build(
          trip,
          phpPerUsd: 57.0,
          origin: davaoCityHallOrigin,
          now: DateTime(2026, 12, 1),
          compress: false,
        );

        expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
        final inspected = inspectPdfBytes(bytes);
        expect(inspected.hasType1Fallback, isFalse);
        expect(inspected.unmappedCids, 0);
        expect(inspected.text, contains('Lakbay+'));
        expect(inspected.text, contains('Page 1 of ${inspected.pageCount}'));
        expect(inspected.text, contains('₱'));
        expect(inspected.text, isNot(contains('PHP ')));
      },
    );

    test(
      'F5.2: TripPdfBuilder renders cover KPIs, dates, travelers, budget, and day-by-day Davao timeline',
      () async {
        final trip = buildFiveDayDavaoSamalTrip();
        final bytes = await TripPdfBuilder.build(
          trip,
          phpPerUsd: 57.0,
          origin: davaoCityHallOrigin,
          now: DateTime(2026, 12, 1),
          compress: false,
        );
        final inspected = inspectPdfBytes(bytes);

        expect(inspected.text, contains('5-Day Davao & Samal Grand Loop'));
        expect(inspected.text, contains('5 Days'));
        expect(inspected.text, contains('Travelers: 2'));
        expect(inspected.text, contains('Budget: ₱15,000'));
        expect(inspected.text, contains("People's Park"));
        expect(inspected.text, contains('Samal Island Beach Area'));
      },
    );

    test(
      'F5.3: TimelinePdfBuilder emits %PDF- with Lakbay+ dossier, ₱ currency, trust tags, and Page X of Y',
      () async {
        final timeline = buildDavaoTimelineData();
        final bytes = await TimelinePdfBuilder.build(
          timeline,
          title: 'Davao & Samal Dossier',
          startingFrom: 'Davao City Hall',
          now: DateTime(2026, 12, 1),
          compress: false,
        );

        expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
        final inspected = inspectPdfBytes(bytes);
        expect(inspected.hasType1Fallback, isFalse);
        expect(inspected.unmappedCids, 0);
        expect(inspected.text, contains('Davao & Samal Dossier'));
        expect(inspected.text, contains('Lakbay+'));
        expect(inspected.text, contains('Page 1 of ${inspected.pageCount}'));
        expect(inspected.text, contains('₱50'));
        expect(inspected.text, contains('[Confirmed]'));
        expect(inspected.text, contains('[Estimated]'));
        expect(inspected.text, contains('[Provisional]'));
      },
    );

    testWidgets(
      'F5.4: TripDetailScreen Budget & PDF -> Export PDF invokes PdfShare.override with valid PDF',
      (tester) async {
        setTestViewport(tester, phoneViewport390x844);
        final shares = capturePdfShares();
        final router = E2eMockRouter();
        await seedTravelerState(signedIn: false);
        final repo = createE2eRepository(router: router);
        await tester.runAsync(() => repo.initialize());
        final trip = buildFiveDayDavaoSamalTrip(backendTripId: null);

        await tester.pumpWidget(
          wrapE2eApp(TripDetailScreen(trip: trip, repo: repo)),
        );
        await pumpBounded(tester);

        await tester.tap(find.text('Budget & PDF'));
        await pumpBounded(tester);

        expect(find.text('Export PDF'), findsOneWidget);
        await tester.runAsync(() async {
          await tester.tap(find.text('Export PDF'));
          await Future<void>.delayed(const Duration(milliseconds: 500));
        });
        await tester.pump();

        expect(shares, hasLength(1));
        expect(shares.first.name, 'lakbay-${trip.id}-itinerary.pdf');
        expect(
          String.fromCharCodes(Uint8List.fromList(shares.first.bytes).take(5)),
          '%PDF-',
        );
      },
    );

    testWidgets(
      'F5.5: TimelineCard Export PDF button invokes PdfShare.override with valid PDF',
      (tester) async {
        setTestViewport(tester, const Size(900, 1800));
        final shares = capturePdfShares();
        final router = E2eMockRouter();
        await seedTravelerState(signedIn: false);
        final repo = createE2eRepository(router: router);
        await tester.runAsync(() => repo.initialize());

        await tester.pumpWidget(
          wrapE2eApp(
            Scaffold(
              body: SingleChildScrollView(
                child: TimelineCard(
                  timeline: buildDavaoTimelineData(),
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
        expect(shares.first.name, 'lakbay-itinerary.pdf');
        expect(
          String.fromCharCodes(Uint8List.fromList(shares.first.bytes).take(5)),
          '%PDF-',
        );
      },
    );
  });

  group('Tier 1 — F6 (R6): Trip Completion Lifecycle', () {
    testWidgets(
      'F6.1: TripDetailScreen Mark Trip as Completed + confirmation sends PATCH /trips/{id} status=completed',
      (tester) async {
        setTestViewport(tester, phoneViewport390x844);
        final router = E2eMockRouter();
        final trip = buildFiveDayDavaoSamalTrip(
          backendTripId: 501,
          backendStatus: 'ongoing',
        );
        await seedTravelerState(signedIn: true, savedTrips: [trip]);
        final repo = createE2eRepository(router: router);
        await tester.runAsync(() => repo.initialize());

        await tester.pumpWidget(
          wrapE2eApp(TripDetailScreen(trip: trip, repo: repo)),
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

        final patches = router.requestsFor('/trips/501');
        expect(
          patches.any((r) => r.method == 'PATCH' && r.body['status'] == 'completed'),
          isTrue,
        );
        expect(repo.savedTrips.first.backendStatus, 'completed');
      },
    );

    testWidgets(
      'F6.2: completed trip exposes Reopen Trip undo action and persists status revert',
      (tester) async {
        setTestViewport(tester, phoneViewport390x844);
        final router = E2eMockRouter();
        final trip = buildFiveDayDavaoSamalTrip(
          backendTripId: 502,
          backendStatus: 'completed',
        );
        await seedTravelerState(signedIn: true, savedTrips: [trip]);
        final repo = createE2eRepository(router: router);
        await tester.runAsync(() => repo.initialize());

        await tester.pumpWidget(
          wrapE2eApp(TripDetailScreen(trip: trip, repo: repo)),
        );
        await pumpBounded(tester);

        final reopenBtn = find.text('Reopen Trip');
        expect(reopenBtn, findsOneWidget);
        await tester.ensureVisible(reopenBtn);
        await tester.tap(reopenBtn);
        await pumpBounded(tester);

        final patches = router.requestsFor('/trips/502');
        expect(
          patches.any(
            (r) =>
                r.method == 'PATCH' &&
                (r.body['status'] == 'planned' || r.body['status'] == 'ongoing'),
          ),
          isTrue,
        );
      },
    );

    testWidgets(
      'F6.3: trip with passed endDate shows non-blocking completion prompt while keeping actions active',
      (tester) async {
        setTestViewport(tester, phoneViewport390x844);
        final router = E2eMockRouter();
        final pastTrip = buildFiveDayDavaoSamalTrip(
          backendTripId: 503,
          backendStatus: 'ongoing',
          startDate: DateTime(2025, 1, 10),
          endDate: DateTime(2025, 1, 14),
        );
        await seedTravelerState(signedIn: true, savedTrips: [pastTrip]);
        final repo = createE2eRepository(router: router);
        await tester.runAsync(() => repo.initialize());

        await tester.pumpWidget(
          wrapE2eApp(TripDetailScreen(trip: pastTrip, repo: repo)),
        );
        await pumpBounded(tester);

        expect(find.textContaining('Mark Trip as Completed'), findsWidgets);
        // Non-blocking: Budget & PDF remains directly interactive.
        expect(find.text('Budget & PDF'), findsOneWidget);
      },
    );

    testWidgets(
      'F6.4: MyTripsScreen Past filter displays completed trips with Completed badge',
      (tester) async {
        setTestViewport(tester, phoneViewport390x844);
        final router = E2eMockRouter();
        final completedTrip = buildFiveDayDavaoSamalTrip(
          id: 'trip_completed_1',
          backendTripId: 504,
          backendStatus: 'completed',
        );
        final plannedTrip = buildFiveDayDavaoSamalTrip(
          id: 'trip_planned_2',
          backendTripId: 505,
          backendStatus: 'planned',
        ).copyWith(title: 'Upcoming Mount Apo Climb');
        await seedTravelerState(
          signedIn: true,
          savedTrips: [plannedTrip, completedTrip],
        );
        final repo = createE2eRepository(router: router);
        await tester.runAsync(() => repo.initialize());

        await tester.pumpWidget(wrapE2eApp(MyTripsScreen(repo: repo)));
        await tester.pumpAndSettle();

        final pastChip = find.widgetWithText(ChoiceChip, 'Past');
        expect(pastChip, findsOneWidget);
        await tester.tap(pastChip);
        await tester.pumpAndSettle();

        expect(find.text('5-Day Davao & Samal Grand Loop'), findsOneWidget);
        expect(find.textContaining('Completed'), findsWidgets);
      },
    );

    testWidgets(
      'F6.5: ProfileScreen renders Completed status badge for completed trips (not hardcoded Upcoming)',
      (tester) async {
        setTestViewport(tester, phoneViewport390x844);
        final router = E2eMockRouter();
        final completedTrip = buildFiveDayDavaoSamalTrip(
          id: 'trip_completed_profile',
          backendTripId: 506,
          backendStatus: 'completed',
        );
        await seedTravelerState(signedIn: true, savedTrips: [completedTrip]);
        final repo = createE2eRepository(router: router);
        await tester.runAsync(() => repo.initialize());

        await tester.pumpWidget(wrapE2eApp(ProfileScreen(repo: repo)));
        await tester.pumpAndSettle();

        expect(find.text('5-Day Davao & Samal Grand Loop'), findsOneWidget);
        expect(find.textContaining('Completed'), findsWidgets);
        expect(find.text('✓ Upcoming'), findsNothing);
      },
    );
  });

  group('Tier 1 — F7 (R7): Destination Media & Fallback', () {
    test(
      'F7.1: LakbayApiCatalogService parses Davao destinations with media_url/media_type/image_url safely',
      () async {
        final router = E2eMockRouter(
          destinations: davaoDestinationsCatalogJson(includeMediaFields: true),
        );
        await seedTravelerState(signedIn: false);
        final repo = createE2eRepository(router: router);
        await repo.initialize();

        final items = await repo.apiCatalog.fetchActiveDestinations();
        expect(items, hasLength(6));
        expect(items.first.title, "People's Park");
        expect(
          items.first.thumbnailUrl,
          'https://cdn.lakbay.test/destinations/1/peoples_park.jpg',
        );
        expect(items[3].islandGroup, 'samal');
      },
    );

    testWidgets(
      'F7.2: ExploreScreen renders Davao catalog cards with offline image fallback cleanly',
      (tester) async {
        setTestViewport(tester, phoneViewport390x844);
        final router = E2eMockRouter(
          destinations: davaoDestinationsCatalogJson(includeMediaFields: true),
        );
        await seedTravelerState(signedIn: false);
        final repo = createE2eRepository(router: router);
        await tester.runAsync(() => repo.initialize());
        await tester.runAsync(() => repo.refreshFromApi());

        await tester.pumpWidget(wrapE2eApp(ExploreScreen(repo: repo)));
        await tester.pumpAndSettle();

        expect(find.text('Discover'), findsOneWidget);
        expect(find.text("People's Park"), findsWidgets);
        expect(find.text('Samal Island Beach Area'), findsWidgets);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'F7.3: ExploreScreen respects MediaQueryData(disableAnimations: true) with static poster fallback',
      (tester) async {
        setTestViewport(tester, phoneViewport390x844);
        final router = E2eMockRouter(
          destinations: davaoDestinationsCatalogJson(includeMediaFields: true),
        );
        await seedTravelerState(signedIn: false);
        final repo = createE2eRepository(router: router);
        await tester.runAsync(() => repo.initialize());
        await tester.runAsync(() => repo.refreshFromApi());

        await tester.pumpWidget(
          wrapE2eApp(ExploreScreen(repo: repo), disableAnimations: true),
        );
        await pumpBounded(tester);

        expect(find.text('Discover'), findsOneWidget);
        expect(find.text('Samal Island Beach Area'), findsWidgets);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'F7.4: ExploreScreen Map toggle switches cleanly between Discover list and map view',
      (tester) async {
        setTestViewport(tester, phoneViewport390x844);
        final router = E2eMockRouter();
        await seedTravelerState(signedIn: false);
        final repo = createE2eRepository(router: router);
        await tester.runAsync(() => repo.initialize());
        await tester.runAsync(() => repo.refreshFromApi());

        await tester.pumpWidget(wrapE2eApp(ExploreScreen(repo: repo)));
        await tester.pumpAndSettle();

        await tester.tap(find.text(PlainWords.map));
        await pumpBounded(tester);
        expect(find.text('List View'), findsOneWidget);

        await tester.tap(find.text('List View'));
        await tester.pumpAndSettle();
        expect(find.text(PlainWords.map), findsOneWidget);
      },
    );

    testWidgets(
      'F7.5: tapping Add to trip on Discover card adds place to Trip Builder tray',
      (tester) async {
        setTestViewport(tester, phoneViewport390x844);
        final router = E2eMockRouter();
        await seedTravelerState(signedIn: false);
        final repo = createE2eRepository(router: router);
        await tester.runAsync(() => repo.initialize());
        await tester.runAsync(() => repo.refreshFromApi());

        await tester.pumpWidget(wrapE2eApp(ExploreScreen(repo: repo)));
        await tester.pumpAndSettle();

        final initialCount = repo.tripBuilderStops.length;
        final addBtn = find.text('＋ Add to trip').first;
        await tester.ensureVisible(addBtn);
        await tester.tap(addBtn);
        await tester.pumpAndSettle();

        expect(repo.tripBuilderStops.length, initialCount + 1);
        expect(find.text('✓ In trip'), findsWidgets);
      },
    );
  });

  group('Tier 1 — F8 (R8): Discover Card UX & Duration Clarity', () {
    test(
      'F8.1: normalizeStayDurationType(null) returns null instead of fabricating half_day',
      () {
        final actualNull = asNullableDuration(normalizeStayDurationType(null));
        final actualEmpty = asNullableDuration(normalizeStayDurationType(''));
        expect(actualNull, isNull);
        expect(actualEmpty, isNull);
      },
    );

    test(
      'F8.2: overnightFee presence alone does not coerce normalizeStayDurationType to overnight',
      () {
        final actual = asNullableDuration(
          normalizeStayDurationType(null, overnightFee: '₱3,800/night'),
        );
        expect(actual, isNot('overnight'));
        expect(actual, isNull);
      },
    );

    testWidgets(
      'F8.3: Discover cards show category/location pill instead of bare top-of-card duration overlay',
      (tester) async {
        setTestViewport(tester, phoneViewport390x844);
        final router = E2eMockRouter();
        await seedTravelerState(signedIn: false);
        final repo = createE2eRepository(router: router);
        await tester.runAsync(() => repo.initialize());
        await tester.runAsync(() => repo.refreshFromApi());

        await tester.pumpWidget(wrapE2eApp(ExploreScreen(repo: repo)));
        await tester.pumpAndSettle();

        // Bare top-of-card concatenation like "Wildlife • Half day" or "Beach • Full day" must not appear.
        expect(find.text('Wildlife • Half day'), findsNothing);
        expect(find.text('Nature Resort • Half day'), findsNothing);
        expect(find.text('Beach • Full day'), findsNothing);
      },
    );

    testWidgets(
      'F8.4: Discover card metadata uses explicit "Typical visit:" label for known durations',
      (tester) async {
        setTestViewport(tester, phoneViewport390x844);
        final router = E2eMockRouter();
        await seedTravelerState(signedIn: false);
        final repo = createE2eRepository(router: router);
        await tester.runAsync(() => repo.initialize());
        await tester.runAsync(() => repo.refreshFromApi());

        await tester.pumpWidget(wrapE2eApp(ExploreScreen(repo: repo)));
        await tester.pumpAndSettle();

        expect(find.textContaining('Typical visit:'), findsWidgets);
      },
    );

    testWidgets(
      'F8.5: ExploreScreen copy uses PlainWords ("Davao Region", "Samal Island") without insider jargon',
      (tester) async {
        setTestViewport(tester, phoneViewport390x844);
        final router = E2eMockRouter();
        await seedTravelerState(signedIn: false);
        final repo = createE2eRepository(router: router);
        await tester.runAsync(() => repo.initialize());
        await tester.runAsync(() => repo.refreshFromApi());

        await tester.pumpWidget(wrapE2eApp(ExploreScreen(repo: repo)));
        await tester.pumpAndSettle();

        expect(PlainWords.region, 'Davao Region');
        expect(PlainWords.samal, 'Samal Island');
        expect(find.textContaining('Region XI'), findsNothing);
        expect(find.textContaining('IGaCoS'), findsNothing);
      },
    );
  });
}
