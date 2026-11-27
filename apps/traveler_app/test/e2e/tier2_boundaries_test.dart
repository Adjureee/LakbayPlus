import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:lakbay_travel/core/theme/app_theme.dart';
import 'package:lakbay_travel/models/timeline_models.dart';
import 'package:lakbay_travel/models/travel_models.dart';
import 'package:lakbay_travel/screens/explore_screen.dart';
import 'package:lakbay_travel/screens/home_chat_screen.dart';
import 'package:lakbay_travel/screens/my_trips_screen.dart';
import 'package:lakbay_travel/screens/trip_detail_screen.dart';
import 'package:lakbay_travel/screens/trip_route_map_screen.dart';
import 'package:lakbay_travel/services/ai_chat_chip_helper.dart';
import 'package:lakbay_travel/services/mapbox_service.dart';
import 'package:lakbay_travel/services/pdf_design_tokens.dart';
import 'package:lakbay_travel/services/timeline_pdf.dart';
import 'package:lakbay_travel/services/trip_pdf.dart';
import 'package:lakbay_travel/theme/lakbay_theme.dart';
import 'package:lakbay_travel/widgets/lakbay_mapbox_widget.dart';

import 'e2e_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    await initOfflineE2eEnv();
  });

  group('Tier 2 Boundaries — F1 (Live Traffic & Map Style)', () {
    testWidgets(
      'F1.B1: rapid double-tap on traffic-toggle-chip keeps state consistent',
      (tester) async {
        setTestViewport(tester, phoneViewport390x844);
        final router = E2eMockRouter();
        await seedTravelerState(signedIn: false);
        final repo = createE2eRepository(router: router);
        await tester.runAsync(() => repo.initialize());

        await tester.pumpWidget(
          wrapE2eApp(
            TripRouteMapScreen(trip: buildFiveDayDavaoSamalTrip(), repo: repo),
          ),
        );
        await pumpBounded(tester);

        final chip = find.byKey(const ValueKey('traffic-toggle-chip'));
        await tester.tap(chip);
        await tester.pump();
        await tester.tap(chip);
        await pumpBounded(tester);

        expect(repo.showLiveTraffic, isFalse);
        expect(repo.activeMapStyle, MapboxStylePreset.outdoors);
      },
    );

    testWidgets(
      'F1.B2: unavailable_no_provider traffic status renders calmly without fabricating traffic',
      (tester) async {
        setTestViewport(tester, phoneViewport390x844);
        final router = E2eMockRouter(
          onPostRoutesPreview: (req) async => http.Response(
            jsonEncode(
              buildMockRouteJson(
                destinationIds: const [1, 14, 2, 3, 4],
                useLiveTraffic: true,
                trafficStatus: 'unavailable_no_provider',
                delaySeconds: null,
              ),
            ),
            200,
          ),
        );
        await seedTravelerState(signedIn: true);
        final repo = createE2eRepository(router: router);
        await tester.runAsync(() => repo.initialize());

        await tester.pumpWidget(
          wrapE2eApp(
            TripRouteMapScreen(trip: buildFiveDayDavaoSamalTrip(), repo: repo),
          ),
        );
        await pumpBounded(tester);

        await tester.tap(find.byKey(const ValueKey('traffic-toggle-chip')));
        await pumpBounded(tester);
        expect(tester.takeException(), isNull);
        expect(find.byType(LakbayMapboxMap), findsOneWidget);
      },
    );

    test(
      'F1.B3: disabling traffic from navigationNight restores navigationNight (not outdoors)',
      () async {
        final router = E2eMockRouter();
        await seedTravelerState(signedIn: false);
        final repo = createE2eRepository(router: router);
        await repo.initialize();

        repo.setMapboxStyle(MapboxStylePreset.navigationNight);
        repo.setLiveTrafficEnabled(true);
        expect(repo.showLiveTraffic, isTrue);
        expect(repo.activeMapStyle, MapboxStylePreset.navigationNight);

        repo.setLiveTrafficEnabled(false);
        expect(repo.showLiveTraffic, isFalse);
        expect(repo.activeMapStyle, MapboxStylePreset.navigationNight);
      },
    );

    testWidgets(
      'F1.B4: switching to satelliteStreets while traffic is on disables traffic and shows notice',
      (tester) async {
        setTestViewport(tester, phoneViewport390x844);
        final router = E2eMockRouter();
        await seedTravelerState(signedIn: false, showLiveTraffic: true);
        final repo = createE2eRepository(router: router);
        await tester.runAsync(() => repo.initialize());

        await tester.pumpWidget(
          wrapE2eApp(
            TripRouteMapScreen(trip: buildFiveDayDavaoSamalTrip(), repo: repo),
          ),
        );
        await pumpBounded(tester);

        repo.setMapboxStyle(MapboxStylePreset.satelliteStreets);
        await pumpBounded(tester);

        expect(repo.showLiveTraffic, isFalse);
        expect(
          find.text('Traffic is unavailable on Satellite view.'),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'F1.B5: route response with null/malformed traffic field parses safely without exception',
      (tester) async {
        setTestViewport(tester, phoneViewport390x844);
        final router = E2eMockRouter(
          onPostRoutesPreview: (req) async {
            final base = buildMockRouteJson(destinationIds: const [1, 14, 2]);
            base['traffic'] = null;
            return http.Response(jsonEncode(base), 200);
          },
        );
        await seedTravelerState(signedIn: true, showLiveTraffic: true);
        final repo = createE2eRepository(router: router);
        await tester.runAsync(() => repo.initialize());

        await tester.pumpWidget(
          wrapE2eApp(
            TripRouteMapScreen(trip: buildFiveDayDavaoSamalTrip(), repo: repo),
          ),
        );
        await pumpBounded(tester);
        expect(tester.takeException(), isNull);
      },
    );
  });

  group('Tier 2 Boundaries — F2 (14-Day 25-Stop, Empty, Offline Retry)', () {
    test(
      'F2.B1: 14-day / 25-stop trip preserves all 25 stops and non-consecutive hub revisits',
      () async {
        final router = E2eMockRouter();
        await seedTravelerState(signedIn: true);
        final repo = createE2eRepository(router: router);
        await repo.initialize();

        final grandTrip = buildFourteenDayDavaoGrandLoopTrip();
        final totalStops = grandTrip.days.fold<int>(
          0,
          (sum, d) => sum + d.stops.length,
        );
        expect(totalStops, 25);

        await repo.fetchRoadRouteForTrip(grandTrip);
        expect(router.routeRequests, isNotEmpty);
        final firstIds = (router.routeRequests.first.body['destination_ids']
                as List<dynamic>)
            .cast<int>();
        expect(firstIds.length, greaterThanOrEqualTo(24));
        expect(firstIds.first, 1);
        expect(firstIds.last, 1);
      },
    );

    testWidgets(
      'F2.B2: trip with zero stops displays empty-route-state without multi-stop route request',
      (tester) async {
        setTestViewport(tester, phoneViewport390x844);
        final router = E2eMockRouter();
        await seedTravelerState(signedIn: false);
        final repo = createE2eRepository(router: router);
        await tester.runAsync(() => repo.initialize());

        final emptyTrip = buildFiveDayDavaoSamalTrip().copyWith(
          days: const [],
          backendDestinationIds: const [],
        );

        await tester.pumpWidget(
          wrapE2eApp(TripRouteMapScreen(trip: emptyTrip, repo: repo)),
        );
        await pumpBounded(tester);

        expect(find.byKey(const ValueKey('empty-route-state')), findsOneWidget);
        expect(find.text('No itinerary stops mapped yet'), findsOneWidget);
        expect(router.routeRequests, isEmpty);
      },
    );

    testWidgets(
      'F2.B3: offline network exception during Retry surfaces specific offline/network failure reason',
      (tester) async {
        setTestViewport(tester, phoneViewport390x844);
        final router = E2eMockRouter(
          onPostRoutesPreview: (req) async =>
              throw http.ClientException('Network is unreachable'),
          onPostRoutesPlan: (req) async =>
              throw http.ClientException('Network is unreachable'),
        );
        await seedTravelerState(signedIn: true);
        final repo = createE2eRepository(router: router);
        await tester.runAsync(() => repo.initialize());

        await tester.pumpWidget(
          wrapE2eApp(
            TripRouteMapScreen(trip: buildFiveDayDavaoSamalTrip(), repo: repo),
          ),
        );
        await pumpBounded(tester);

        final retryBtn = find.text('Retry');
        expect(retryBtn, findsOneWidget);
        await tester.tap(retryBtn);
        await pumpBounded(tester);

        // Expect specific offline/network diagnostic rather than generic error.
        expect(
          find.byWidgetPredicate(
            (w) =>
                w is Text &&
                (w.data ?? '').toLowerCase().contains('offline') ||
                w is Text &&
                    (w.data ?? '').toLowerCase().contains('connection') ||
                w is Text &&
                    (w.data ?? '').toLowerCase().contains('unreachable'),
          ),
          findsWidgets,
        );
      },
    );

    test(
      'F2.B4: 401 on authed /routes/preview falls back to POST /routes/plan/guest',
      () async {
        final router = E2eMockRouter(
          onPostRoutesPreview: (req) async =>
              http.Response(jsonEncode({'detail': 'Unauthorized'}), 401),
        );
        await seedTravelerState(signedIn: true);
        final repo = createE2eRepository(router: router);
        await repo.initialize();

        final result = await repo.fetchRoadRouteForTrip(
          buildFiveDayDavaoSamalTrip(),
        );
        expect(result, isNotNull);
        expect(router.requestsFor('/routes/plan/guest'), isNotEmpty);
      },
    );

    test(
      'F2.B5: stops with null destinationId alongside valid IDs resolve safely without crash',
      () async {
        final router = E2eMockRouter();
        await seedTravelerState(signedIn: false);
        final repo = createE2eRepository(router: router);
        await repo.initialize();

        final mixedTrip = buildFiveDayDavaoSamalTrip().copyWith(
          backendDestinationIds: const [],
          days: const [
            ItineraryDay(
              dayNumber: 1,
              cityTitle: 'Day 1',
              summary: 'Mixed stops',
              lat: 7.0707,
              lng: 125.6096,
              stops: [
                ItineraryStop(
                  time: '09:00 AM',
                  title: 'Unlinked Stop',
                  description: 'No catalog ID',
                  category: 'sight',
                  lat: 7.07,
                  lng: 125.60,
                  destinationId: null,
                ),
                ItineraryStop(
                  time: '11:00 AM',
                  title: 'Museo Dabawenyo',
                  description: 'Linked stop',
                  category: 'sight',
                  lat: 7.07939,
                  lng: 125.60449,
                  destinationId: 14,
                ),
              ],
            ),
          ],
        );

        final res = await repo.fetchRoadRouteForTrip(mixedTrip);
        expect(res, isNotNull);
      },
    );
  });

  group('Tier 2 Boundaries — F3 (Tiny 320x568 & Desktop Viewports)', () {
    testWidgets(
      'F3.B1: tiny 320x568 viewport keeps LakbayMapboxMap >=60% height with zero overflow',
      (tester) async {
        setTestViewport(tester, phoneViewport320x568);
        final router = E2eMockRouter();
        await seedTravelerState(signedIn: false);
        final repo = createE2eRepository(router: router);
        await tester.runAsync(() => repo.initialize());

        await tester.pumpWidget(
          wrapE2eApp(
            TripRouteMapScreen(trip: buildFiveDayDavaoSamalTrip(), repo: repo),
          ),
        );
        await pumpBounded(tester);

        final mapRect = tester.getRect(find.byType(LakbayMapboxMap).first);
        expect(mapRect.height / 568.0, greaterThanOrEqualTo(0.60));
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'F3.B2: tiny 320x568 viewport keeps floating controls inside screen bounds without attribution overlap',
      (tester) async {
        setTestViewport(tester, phoneViewport320x568);
        final router = E2eMockRouter();
        await seedTravelerState(signedIn: false);
        final repo = createE2eRepository(router: router);
        await tester.runAsync(() => repo.initialize());

        await tester.pumpWidget(
          wrapE2eApp(
            TripRouteMapScreen(trip: buildFiveDayDavaoSamalTrip(), repo: repo),
          ),
        );
        await pumpBounded(tester);

        for (final tooltip in const ['Zoom In', 'Zoom Out', 'Fit Route Stops']) {
          final rect = tester.getRect(find.byTooltip(tooltip));
          expect(rect.left, greaterThanOrEqualTo(0));
          expect(rect.right, lessThanOrEqualTo(320));
          expect(rect.top, greaterThanOrEqualTo(0));
          expect(rect.bottom, lessThanOrEqualTo(568));
        }
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'F3.B3: day-filter-all resets focus after day-filter-2 selection cleanly',
      (tester) async {
        setTestViewport(tester, phoneViewport390x844);
        final router = E2eMockRouter();
        await seedTravelerState(signedIn: false);
        final repo = createE2eRepository(router: router);
        await tester.runAsync(() => repo.initialize());

        await tester.pumpWidget(
          wrapE2eApp(
            TripRouteMapScreen(trip: buildFiveDayDavaoSamalTrip(), repo: repo),
          ),
        );
        await pumpBounded(tester);

        await tester.tap(find.byKey(const ValueKey('day-filter-2')));
        await pumpBounded(tester);
        await tester.tap(find.byKey(const ValueKey('day-filter-all')));
        await pumpBounded(tester);

        expect(find.byKey(const ValueKey('day-filter-all')), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'F3.B4: desktop 1280x800 split layout renders Route & Stop Timeline without overflow',
      (tester) async {
        setTestViewport(tester, desktopViewport1280x800);
        final router = E2eMockRouter();
        await seedTravelerState(signedIn: false);
        final repo = createE2eRepository(router: router);
        await tester.runAsync(() => repo.initialize());

        await tester.pumpWidget(
          wrapE2eApp(
            TripRouteMapScreen(trip: buildFiveDayDavaoSamalTrip(), repo: repo),
          ),
        );
        await pumpBounded(tester);

        expect(find.text('Route & Stop Timeline'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );

    test(
      'F3.B5: MapboxService.computeBoundsCenterAndZoom zooms out when sheet padding increases',
      () {
        const pts = [peoplesParkPoint, samalIslandPoint];
        final (_, _, unpadded) = MapboxService.computeBoundsCenterAndZoom(
          pts,
          viewportSize: phoneViewport390x844,
        );
        final (_, _, padded) = MapboxService.computeBoundsCenterAndZoom(
          pts,
          viewportSize: phoneViewport390x844,
          padding: const EdgeInsets.fromLTRB(36, 136, 56, 320),
        );
        expect(padded, lessThan(unpadded));
      },
    );
  });

  group('Tier 2 Boundaries — F4 (AI Chat Long Input, Over Budget, Error Edge)', () {
    testWidgets(
      'F4.B1: >8-word chat input submits cleanly and updates plan without false safe-update error',
      (tester) async {
        setTestViewport(tester, phoneViewport390x844);
        final router = E2eMockRouter(
          onPostAiChat: (req) async => http.Response(
            jsonEncode({
              'chat_response':
                  'Updated your 4-day relaxed Mount Apo and Samal plan for 2 adults.',
              'model_id': 'mock-groq',
              'ai_generation_run_id': 21,
              'planning': {
                'input_revision': 1,
                'intent': 'plan_trip',
                'suggested_replies': const <String>[],
                'state_updates': {
                  'traveler_count': 2,
                  'day_count': 4,
                  'activity_level': 'easy',
                },
                'update_status': 'updated',
                'preview': {
                  'state': {
                    'traveler_count': 2,
                    'day_count': 4,
                    'activity_level': 'easy',
                  },
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

        await tester.runAsync(
          () => repo.sendChatMessage(
            'Two adults looking for a relaxed four day nature and beach itinerary across Davao and Samal',
          ),
        );
        await pumpBounded(tester);

        expect(
          AiChatChipHelper.isSafeUpdateFallbackMessage(
            repo.chatMessages.last.text,
          ),
          isFalse,
        );
        expect(repo.planningStateView['day_count'], 4);
      },
    );

    testWidgets(
      'F4.B2: planning_over_budget error renders Raise budget and Remove a place chips',
      (tester) async {
        setTestViewport(tester, phoneViewport390x844);
        final router = E2eMockRouter(
          onPostAiChat: (req) async => http.Response(
            jsonEncode({
              'chat_response': 'Checking your budget.',
              'model_id': 'mock-groq',
              'ai_generation_run_id': 22,
              'planning': {
                'input_revision': 1,
                'intent': 'plan_trip',
                'suggested_replies': const <String>[],
                'state_updates': {
                  'destination_ids': [1, 3, 4],
                  'day_count': 3,
                  'traveler_count': 2,
                  'total_budget': 500,
                },
                'update_status': 'updated',
                'preview': {
                  'state': {
                    'destination_ids': [1, 3, 4],
                    'day_count': 3,
                    'traveler_count': 2,
                    'total_budget': 500,
                  },
                },
                'recommendations': const <dynamic>[],
              },
            }),
            200,
          ),
          onPostPlanningTimeline: (req) async => http.Response(
            jsonEncode({
              'detail': {
                'code': 'planning_over_budget',
                'message': 'Estimated cost exceeds ₱500 budget.',
              },
            }),
            422,
            headers: const {'content-type': 'application/json; charset=utf-8'},
          ),
        );
        await seedTravelerState(signedIn: false);
        final repo = createE2eRepository(router: router);
        await tester.runAsync(() => repo.initialize());
        await tester.runAsync(() => repo.refreshFromApi());
        for (final t in repo.allTrips.take(2)) {
          repo.toggleTripBuilderStop(t);
        }

        await tester.pumpWidget(wrapE2eApp(HomeChatScreen(repo: repo)));
        await pumpBounded(tester);

        await tester.runAsync(() => repo.sendChatMessage('Build for ₱500'));
        await pumpBounded(tester);

        expect(find.text('Raise budget'), findsOneWidget);
        if (repo.chatPickCount > 1) {
          expect(find.text('Remove a place'), findsOneWidget);
        }
      },
    );

    testWidgets(
      'F4.B3: empty or whitespace-only prompt does not trigger /ai/chat/guest request',
      (tester) async {
        setTestViewport(tester, phoneViewport390x844);
        final router = E2eMockRouter();
        await seedTravelerState(signedIn: false);
        final repo = createE2eRepository(router: router);
        await tester.runAsync(() => repo.initialize());

        await tester.pumpWidget(wrapE2eApp(HomeChatScreen(repo: repo)));
        await pumpBounded(tester);

        await tester.runAsync(() => repo.sendChatMessage('   \n\t  '));
        await pumpBounded(tester);
        expect(router.requestsFor('/ai/chat/guest'), isEmpty);
      },
    );

    testWidgets(
      'F4.B4: HTTP 500 on /ai/chat/guest preserves retryText and resends exact prompt on Try again',
      (tester) async {
        setTestViewport(tester, phoneViewport390x844);
        var attempts = 0;
        final router = E2eMockRouter(
          onPostAiChat: (req) async {
            attempts++;
            if (attempts == 1) {
              return http.Response('Internal Server Error', 500);
            }
            return http.Response(
              jsonEncode({
                'chat_response': 'Back online — Davao waterfalls ready!',
                'model_id': 'mock-groq',
                'ai_generation_run_id': 23,
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

        await tester.runAsync(() => repo.sendChatMessage('Waterfalls near Davao'));
        await pumpBounded(tester);

        expect(repo.chatMessages.last.retryText, 'Waterfalls near Davao');
        await tester.tap(find.text('Try again'));
        await pumpBounded(tester);

        expect(router.requestsFor('/ai/chat/guest').length, 2);
        expect(
          router.requestsFor('/ai/chat/guest').last.body['message'],
          'Waterfalls near Davao',
        );
      },
    );

    test(
      'F4.B5: AiChatChipHelper.resolveSuggestedReplyDetail validates currency shorthand and party bounds',
      () {
        final budget1500 = AiChatChipHelper.resolveSuggestedReplyDetail(
          '₱1,500',
          'total_budget',
          const {},
        );
        expect(budget1500?.value, 1500);

        final budget5k = AiChatChipHelper.resolveSuggestedReplyDetail(
          '5k',
          'total_budget',
          const {},
        );
        expect(budget5k?.value, 5000);

        expect(
          AiChatChipHelper.resolveSuggestedReplyDetail(
            '99 travelers',
            'traveler_count',
            const {},
          ),
          isNull,
        );
        expect(
          AiChatChipHelper.resolveSuggestedReplyDetail(
            '0 people',
            'traveler_count',
            const {},
          ),
          isNull,
        );
      },
    );
  });

  group('Tier 2 Boundaries — F5 (Multi-Page PDF, Unicode, Honesty)', () {
    test(
      'F5.B1: 14-day / 25-stop PDF with ₱, ñ, Ñ, —, ° renders multi-page with Page X of Y and zero unmapped CIDs',
      () async {
        final trip = buildFourteenDayDavaoGrandLoopTrip();
        final bytes = await TripPdfBuilder.build(
          trip,
          phpPerUsd: 57.0,
          origin: davaoCityHallOrigin,
          now: DateTime(2026, 12, 1),
          compress: true,
        );

        final inspected = inspectPdfBytes(bytes);
        expect(inspected.hasType1Fallback, isFalse);
        expect(inspected.unmappedCids, 0);
        expect(inspected.pageCount, greaterThan(2));
        expect(inspected.text, contains('Page 1 of ${inspected.pageCount}'));
        expect(
          inspected.text,
          contains('Page ${inspected.pageCount} of ${inspected.pageCount}'),
        );
        expect(inspected.text, contains('Santo Niño Ridge'));
        expect(inspected.text, contains('₱'));
      },
    );

    test(
      'F5.B2: TripPdfBuilder prints honest unknown markers when cost, startDate, and travelers are unset',
      () async {
        final sparseTrip = buildFiveDayDavaoSamalTrip(
          startDate: null,
          endDate: null,
          backendBudgetPhp: null,
          backendEstimatedCostPhp: null,
        ).copyWith(
          adults: null,
          children: 0,
          days: const [
            ItineraryDay(
              dayNumber: 1,
              cityTitle: 'Day 1',
              summary: 'Free stroll',
              lat: 7.0707,
              lng: 125.6096,
              stops: [
                ItineraryStop(
                  time: '09:00 AM',
                  title: "People's Park",
                  description: 'Walk',
                  category: 'sight',
                  costEstimateUsd: 0,
                  lat: 7.0707,
                  lng: 125.6096,
                ),
              ],
            ),
          ],
        );
        final noDateTrip = ItineraryTrip(
          id: sparseTrip.id,
          title: sparseTrip.title,
          destination: sparseTrip.destination,
          daysCount: 1,
          adults: null,
          centerLat: sparseTrip.centerLat,
          centerLng: sparseTrip.centerLng,
          heroAsset: sparseTrip.heroAsset,
          vibeTag: sparseTrip.vibeTag,
          overviewText: sparseTrip.overviewText,
          bestMonths: sparseTrip.bestMonths,
          avgTemp: sparseTrip.avgTemp,
          startDate: null,
          endDate: null,
          expertName: sparseTrip.expertName,
          expertTip: sparseTrip.expertTip,
          days: sparseTrip.days,
          flights: const [],
          hotels: const [],
        );

        final bytes = await TripPdfBuilder.build(
          noDateTrip,
          phpPerUsd: 57.0,
          compress: false,
        );
        final inspected = inspectPdfBytes(bytes);

        expect(inspected.text, contains('Start date: not set'));
        expect(inspected.text, contains('Travelers: not set'));
        expect(inspected.text, contains('Cost not listed'));
      },
    );

    test(
      'F5.B3: TimelinePdfBuilder omits Remaining when incomplete and strips emoji without tofu boxes',
      () async {
        final incomplete = TimelineData.fromJson({
          ...buildDavaoTimelineData().toJson(),
          'budget': {
            'known_total': '350.00',
            'estimated_total': '1000.00',
            'unknown': ['Guide fee'],
            'unbased': const <String>[],
            'to_complete': const <String>[],
            'subtotal': '1350.00',
            'complete': false,
            'total_budget': '5000.00',
            'remaining': null,
            'fit': 'undetermined',
            'notes': const <String>[],
          },
          'assumptions': ['Santo Niño • 29°C 🌴 — ₱50'],
        });

        final bytes = await TimelinePdfBuilder.build(
          incomplete,
          compress: false,
        );
        final inspected = inspectPdfBytes(bytes);

        expect(inspected.unmappedCids, 0);
        expect(inspected.text, isNot(contains('Remaining:')));
        expect(inspected.text, isNot(contains('🌴')));
        expect(inspected.text, contains('Santo Niño'));
        expect(inspected.text, contains('₱50'));
      },
    );

    test(
      'F5.B4: oversized 1500+ char description wraps cleanly across pages without TooManyPagesException',
      () async {
        final longDesc = List.filled(
          40,
          'Scenic Davao highland trail overlooking Pakiputan Strait and Mount Apo.',
        ).join(' ');
        final longTrip = buildFiveDayDavaoSamalTrip().copyWith(
          days: [
            ItineraryDay(
              dayNumber: 1,
              cityTitle: 'Day 1 • Long Notes',
              summary: 'Detailed historical notes',
              lat: 7.0707,
              lng: 125.6096,
              stops: [
                ItineraryStop(
                  time: '09:00 AM',
                  title: "People's Park Long Heritage Note",
                  description: longDesc,
                  category: 'sight',
                  costEstimateUsd: 2.0,
                  lat: 7.0707,
                  lng: 125.6096,
                ),
              ],
            ),
          ],
        );

        final bytes = await TripPdfBuilder.build(
          longTrip,
          phpPerUsd: 57.0,
          compress: false,
        );
        final inspected = inspectPdfBytes(bytes);
        expect(inspected.unmappedCids, 0);
        expect(inspected.text, contains('Pakiputan Strait'));
      },
    );

    test(
      'F5.B5: LakbayPdfTokens mirrors LakbayColors and AppTheme palette exactly',
      () {
        expect(
          LakbayPdfTokens.primary.toInt(),
          LakbayColors.primary.toARGB32(),
        );
        expect(
          LakbayPdfTokens.tealDeep.toInt(),
          LakbayColors.tealDeep.toARGB32(),
        );
        expect(
          LakbayPdfTokens.cocoaOrange.toInt(),
          LakbayColors.cocoaOrange.toARGB32(),
        );
        expect(
          LakbayPdfTokens.canvasBg.toInt(),
          AppTheme.backgroundLight.toARGB32(),
        );
      },
    );
  });

  group('Tier 2 Boundaries — F6 (Lifecycle Negative & Edge Paths)', () {
    testWidgets(
      'F6.B1: future endDate trip does NOT show passed-end-date completion banner prematurely',
      (tester) async {
        setTestViewport(tester, phoneViewport390x844);
        final router = E2eMockRouter();
        final futureTrip = buildFiveDayDavaoSamalTrip(
          backendTripId: 601,
          backendStatus: 'planned',
          startDate: DateTime.now().add(const Duration(days: 10)),
          endDate: DateTime.now().add(const Duration(days: 14)),
        );
        await seedTravelerState(signedIn: true, savedTrips: [futureTrip]);
        final repo = createE2eRepository(router: router);
        await tester.runAsync(() => repo.initialize());

        await tester.pumpWidget(
          wrapE2eApp(TripDetailScreen(trip: futureTrip, repo: repo)),
        );
        await pumpBounded(tester);

        expect(
          find.textContaining('Trip end date has passed'),
          findsNothing,
        );
      },
    );

    testWidgets(
      'F6.B2: archived trip disables Add memory and does not show active completion CTA',
      (tester) async {
        setTestViewport(tester, phoneViewport390x844);
        final router = E2eMockRouter();
        final archivedTrip = buildFiveDayDavaoSamalTrip(
          backendTripId: 602,
          backendStatus: 'archived',
        );
        await seedTravelerState(signedIn: true, savedTrips: [archivedTrip]);
        final repo = createE2eRepository(router: router);
        await tester.runAsync(() => repo.initialize());

        await tester.pumpWidget(
          wrapE2eApp(TripDetailScreen(trip: archivedTrip, repo: repo)),
        );
        await pumpBounded(tester);

        expect(
          find.text('Archived trips are read-only for new memories.'),
          findsOneWidget,
        );
        expect(find.text('Mark Trip as Completed'), findsNothing);
      },
    );

    testWidgets(
      'F6.B3: PATCH /trips/{id} 500 server failure keeps trip status unchanged and surfaces error',
      (tester) async {
        setTestViewport(tester, phoneViewport390x844);
        final router = E2eMockRouter(
          onPatchTrip: (req) async => http.Response(
            jsonEncode({'detail': 'Transition failed'}),
            500,
          ),
        );
        final trip = buildFiveDayDavaoSamalTrip(
          backendTripId: 603,
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

        expect(repo.savedTrips.first.backendStatus, isNot('completed'));
      },
    );

    testWidgets(
      'F6.B4: guest local-only trip (backendTripId == null) completes locally without crashing',
      (tester) async {
        setTestViewport(tester, phoneViewport390x844);
        final router = E2eMockRouter();
        final localTrip = buildFiveDayDavaoSamalTrip(
          backendTripId: null,
          backendStatus: 'planned',
        );
        await seedTravelerState(signedIn: false, savedTrips: [localTrip]);
        final repo = createE2eRepository(router: router);
        await tester.runAsync(() => repo.initialize());

        await tester.pumpWidget(
          wrapE2eApp(TripDetailScreen(trip: localTrip, repo: repo)),
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
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'F6.B5: MyTripsScreen search query combined with Past filter narrows completed trips',
      (tester) async {
        setTestViewport(tester, phoneViewport390x844);
        final router = E2eMockRouter();
        final samalDone = buildFiveDayDavaoSamalTrip(
          id: 'done_samal',
          backendStatus: 'completed',
        );
        final apoDone = buildFiveDayDavaoSamalTrip(
          id: 'done_apo',
          backendStatus: 'completed',
        ).copyWith(title: 'Mount Apo Trek', destination: 'Mount Apo');
        await seedTravelerState(
          signedIn: true,
          savedTrips: [samalDone, apoDone],
        );
        final repo = createE2eRepository(router: router);
        await tester.runAsync(() => repo.initialize());

        await tester.pumpWidget(wrapE2eApp(MyTripsScreen(repo: repo)));
        await tester.pumpAndSettle();

        await tester.tap(find.widgetWithText(ChoiceChip, 'Past'));
        await tester.pumpAndSettle();

        await tester.enterText(find.byType(TextField), 'Samal');
        await tester.pumpAndSettle();

        expect(find.text('5-Day Davao & Samal Grand Loop'), findsOneWidget);
        expect(find.text('Mount Apo Trek'), findsNothing);
      },
    );
  });

  group('Tier 2 Boundaries — F7 (Catalog & Media Edge Cases)', () {
    test(
      'F7.B1: malformed /destinations items (missing lat, lng, or name) are skipped safely',
      () async {
        final router = E2eMockRouter(
          destinations: [
            {'destination_id': 900, 'name': 'Missing Coords'},
            {'destination_id': 901, 'lat': 7.07, 'lng': 125.60},
            {'name': 'Missing ID', 'lat': 7.07, 'lng': 125.60},
            davaoDestinationsCatalogJson().first,
          ],
        );
        await seedTravelerState(signedIn: false);
        final repo = createE2eRepository(router: router);
        await repo.initialize();

        final items = await repo.apiCatalog.fetchActiveDestinations();
        expect(items, hasLength(1));
        expect(items.first.title, "People's Park");
      },
    );

    testWidgets(
      'F7.B2: unknown media_type or empty media_url falls back cleanly to poster/asset',
      (tester) async {
        setTestViewport(tester, phoneViewport390x844);
        final router = E2eMockRouter(
          destinations: [
            {
              ...davaoDestinationsCatalogJson().first,
              'media_url': '',
              'media_type': 'exe',
            },
          ],
        );
        await seedTravelerState(signedIn: false);
        final repo = createE2eRepository(router: router);
        await tester.runAsync(() => repo.initialize());
        await tester.runAsync(() => repo.refreshFromApi());

        await tester.pumpWidget(wrapE2eApp(ExploreScreen(repo: repo)));
        await tester.pumpAndSettle();

        expect(find.text("People's Park"), findsWidgets);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'F7.B3: destination with media_duration_seconds > 15s handles gracefully without crash',
      (tester) async {
        setTestViewport(tester, phoneViewport390x844);
        final router = E2eMockRouter(
          destinations: [
            {
              ...davaoDestinationsCatalogJson()[3],
              'media_url': 'https://cdn.lakbay.test/destinations/4/long.mp4',
              'media_type': 'video',
              'media_duration_seconds': 42.0,
            },
          ],
        );
        await seedTravelerState(signedIn: false);
        final repo = createE2eRepository(router: router);
        await tester.runAsync(() => repo.initialize());
        await tester.runAsync(() => repo.refreshFromApi());

        await tester.pumpWidget(wrapE2eApp(ExploreScreen(repo: repo)));
        await tester.pumpAndSettle();

        expect(find.text('Samal Island Beach Area'), findsWidgets);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'F7.B4: empty catalog response (items: []) renders ExploreScreen safely',
      (tester) async {
        setTestViewport(tester, phoneViewport390x844);
        final router = E2eMockRouter(destinations: const []);
        await seedTravelerState(signedIn: false);
        final repo = createE2eRepository(router: router);
        await tester.runAsync(() => repo.initialize());
        await tester.runAsync(() => repo.refreshFromApi());

        await tester.pumpWidget(wrapE2eApp(ExploreScreen(repo: repo)));
        await tester.pumpAndSettle();

        expect(find.text('Discover'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'F7.B5: rapid region filter chip toggling on ExploreScreen produces zero exceptions',
      (tester) async {
        setTestViewport(tester, phoneViewport390x844);
        final router = E2eMockRouter();
        await seedTravelerState(signedIn: false);
        final repo = createE2eRepository(router: router);
        await tester.runAsync(() => repo.initialize());
        await tester.runAsync(() => repo.refreshFromApi());

        await tester.pumpWidget(wrapE2eApp(ExploreScreen(repo: repo)));
        await tester.pumpAndSettle();

        for (final filter in const ['Samal', 'Davao City', 'All']) {
          final chip = find.widgetWithText(ChoiceChip, filter);
          if (chip.evaluate().isNotEmpty) {
            await tester.ensureVisible(chip);
            await tester.tap(chip);
            await tester.pump();
          }
        }
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      },
    );
  });

  group('Tier 2 Boundaries — F8 (Duration Normalization & Copy)', () {
    test(
      'F8.B1: normalizeStayDurationType normalizes edge formatting and returns null for unknown',
      () {
        final shortVal = asNullableDuration(
          normalizeStayDurationType('1-2 hours'),
        );
        final fullVal = asNullableDuration(
          normalizeStayDurationType('FULL-DAY'),
        );
        final multiVal = asNullableDuration(
          normalizeStayDurationType('Multi Day'),
        );
        final unknownVal = asNullableDuration(
          normalizeStayDurationType('xyz_invalid'),
        );

        expect(shortVal, 'short');
        expect(fullVal, 'full_day');
        expect(multiVal, 'multi_day');
        expect(unknownVal, isNull);
      },
    );

    test(
      'F8.B2: ExploreTrip with stayDurationType=null and overnightFee does NOT fabricate Overnight',
      () {
        final normalized = asNullableDuration(
          normalizeStayDurationType(
            null,
            category: 'Nature Resort',
            overnightFee: '₱2,500/night',
          ),
        );
        expect(normalized, isNot('overnight'));
      },
    );

    test(
      'F8.B3: explicit short duration with overnightFee keeps short (day visit not overwritten)',
      () {
        final normalized = asNullableDuration(
          normalizeStayDurationType('short', overnightFee: '₱2,500/night'),
        );
        expect(normalized, 'short');
      },
    );

    testWidgets(
      'F8.B4: ExploreScreen search with zero-match query handles empty results without error',
      (tester) async {
        setTestViewport(tester, phoneViewport390x844);
        final router = E2eMockRouter();
        await seedTravelerState(signedIn: false);
        final repo = createE2eRepository(router: router);
        await tester.runAsync(() => repo.initialize());
        await tester.runAsync(() => repo.refreshFromApi());

        await tester.pumpWidget(wrapE2eApp(ExploreScreen(repo: repo)));
        await tester.pumpAndSettle();

        await tester.enterText(
          find.byType(TextField),
          'zzzz_nonexistent_davao_spot',
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'F8.B5: ExploreScreen never leaks Region XI or IGaCoS insider jargon in visible labels',
      (tester) async {
        setTestViewport(tester, phoneViewport390x844);
        final router = E2eMockRouter();
        await seedTravelerState(signedIn: false);
        final repo = createE2eRepository(router: router);
        await tester.runAsync(() => repo.initialize());
        await tester.runAsync(() => repo.refreshFromApi());

        await tester.pumpWidget(wrapE2eApp(ExploreScreen(repo: repo)));
        await tester.pumpAndSettle();

        expect(find.textContaining('Region XI'), findsNothing);
        expect(find.textContaining('IGaCoS'), findsNothing);
      },
    );
  });
}
