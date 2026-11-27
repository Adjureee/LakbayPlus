import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:lakbay_travel/screens/explore_screen.dart';
import 'package:lakbay_travel/screens/home_chat_screen.dart';
import 'package:lakbay_travel/screens/my_trips_screen.dart';
import 'package:lakbay_travel/screens/profile_screen.dart';
import 'package:lakbay_travel/screens/trip_detail_screen.dart';
import 'package:lakbay_travel/screens/trip_route_map_screen.dart';
import 'package:lakbay_travel/widgets/lakbay_mapbox_widget.dart';

import 'e2e_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    await initOfflineE2eEnv();
  });

  group('Tier 3 — Pairwise Cross-Feature Combinatorial Tests', () {
    testWidgets(
      'P1 (F1+F2+F3): 5-day multimodal Davao+Samal trip + live traffic + compressed 390x844 map UI',
      (tester) async {
        setTestViewport(tester, phoneViewport390x844);
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

        expect(
          router.routeRequests.any((r) => r.body['use_live_traffic'] == true),
          isTrue,
        );
        expect(
          find.text('Live traffic data is limited in this region'),
          findsNothing,
        );
        final mapRect = tester.getRect(find.byType(LakbayMapboxMap).first);
        expect(mapRect.height / 844.0, greaterThanOrEqualTo(0.60));
        expect(find.byType(DraggableScrollableSheet), findsOneWidget);
        expect(find.byIcon(Icons.directions_boat_rounded), findsWidgets);
      },
    );

    testWidgets(
      'P2 (F5+F6): completed trip exports flagship PDF dossier with Completed status, ₱, and Page X of Y',
      (tester) async {
        setTestViewport(tester, phoneViewport390x844);
        final shares = capturePdfShares();
        final router = E2eMockRouter();
        final completed = buildFiveDayDavaoSamalTrip(
          backendTripId: 702,
          backendStatus: 'completed',
        );
        await seedTravelerState(signedIn: true, savedTrips: [completed]);
        final repo = createE2eRepository(router: router);
        await tester.runAsync(() => repo.initialize());

        await tester.pumpWidget(
          wrapE2eApp(TripDetailScreen(trip: completed, repo: repo)),
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
        expect(inspected.text, contains('Completed'));
        expect(inspected.text, contains('Lakbay+'));
        expect(inspected.text, contains('₱'));
        expect(inspected.text, contains('Page 1 of ${inspected.pageCount}'));
      },
    );

    testWidgets(
      'P3 (F7+F8): destination media + missing duration + overnightFee renders cleanly under reduced motion',
      (tester) async {
        setTestViewport(tester, phoneViewport390x844);
        final catalog = [
          {
            ...davaoDestinationsCatalogJson(includeMediaFields: true)[2],
            'stay_duration_type': null,
            'overnight_fee': '₱3,800/night',
          },
          {
            ...davaoDestinationsCatalogJson(includeMediaFields: true)[3],
            'stay_duration_type': null,
            'overnight_fee': '₱2,500/night',
          },
        ];
        final router = E2eMockRouter(destinations: catalog);
        await seedTravelerState(signedIn: false);
        final repo = createE2eRepository(router: router);
        await tester.runAsync(() => repo.initialize());
        await tester.runAsync(() => repo.refreshFromApi());

        await tester.pumpWidget(
          wrapE2eApp(ExploreScreen(repo: repo), disableAnimations: true),
        );
        await pumpBounded(tester);

        expect(find.text('Eden Nature Park'), findsWidgets);
        expect(find.text('Samal Island Beach Area'), findsWidgets);
        // Should not fabricate bare top-of-card Overnight overlays.
        expect(find.text('Nature Resort • Overnight'), findsNothing);
        expect(find.text('Beach • Overnight'), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'P4 (F2+F4): AI chat structured chips generate plan -> TripRouteMapScreen fetches guest route',
      (tester) async {
        setTestViewport(tester, phoneViewport390x844);
        final router = E2eMockRouter(
          onPostAiChat: (req) async => http.Response(
            jsonEncode({
              'chat_response': 'Planned your 2-day Davao & Samal loop.',
              'model_id': 'mock-groq',
              'ai_generation_run_id': 704,
              'planning': {
                'input_revision': 1,
                'intent': 'plan_trip',
                'suggested_replies': const <String>[],
                'state_updates': {
                  'destination_ids': [1, 4],
                  'day_count': 2,
                  'traveler_count': 2,
                  'total_budget': 5000,
                },
                'update_status': 'updated',
                'preview': {
                  'state': {
                    'destination_ids': [1, 4],
                    'day_count': 2,
                    'traveler_count': 2,
                    'total_budget': 5000,
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
              'changes': ['Planned 2 days.'],
              'unavailable_destination_ids': const <int>[],
            }),
            200,
          ),
          onPostRoutesPlan: (req) async => http.Response(
            jsonEncode({
              'route': buildMockRouteJson(
                destinationIds: const [1, 4],
                includeSeaCrossing: true,
              ),
              'suggested_days': 2,
              'days': const <dynamic>[],
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
          () => repo.sendChatMessage("People's Park and Samal for 2 days"),
        );
        await pumpBounded(tester);
        expect(repo.chatMessages.last.timeline, isNotNull);

        // Open route map for a Davao+Samal trip using the same offline repo.
        final trip = buildFiveDayDavaoSamalTrip(backendTripId: null);
        await tester.pumpWidget(
          wrapE2eApp(TripRouteMapScreen(trip: trip, repo: repo)),
        );
        await pumpBounded(tester);

        expect(router.requestsFor('/routes/plan/guest'), isNotEmpty);
        expect(find.text('Road directions unavailable'), findsNothing);
      },
    );

    testWidgets(
      'P5 (F6): completed trip in MyTrips Past filter -> Reopen Trip -> ProfileScreen reflects reopened status',
      (tester) async {
        setTestViewport(tester, phoneViewport390x844);
        final router = E2eMockRouter();
        final completed = buildFiveDayDavaoSamalTrip(
          id: 'p5_trip',
          backendTripId: 705,
          backendStatus: 'completed',
        );
        await seedTravelerState(signedIn: true, savedTrips: [completed]);
        final repo = createE2eRepository(router: router);
        await tester.runAsync(() => repo.initialize());

        await tester.pumpWidget(wrapE2eApp(MyTripsScreen(repo: repo)));
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(ChoiceChip, 'Past'));
        await tester.pumpAndSettle();
        expect(find.text('5-Day Davao & Samal Grand Loop'), findsOneWidget);

        await tester.pumpWidget(
          wrapE2eApp(TripDetailScreen(trip: completed, repo: repo)),
        );
        await pumpBounded(tester);
        final reopenBtn = find.text('Reopen Trip');
        expect(reopenBtn, findsOneWidget);
        await tester.ensureVisible(reopenBtn);
        await tester.tap(reopenBtn);
        await pumpBounded(tester);

        expect(repo.savedTrips.first.backendStatus, isNot('completed'));

        await tester.pumpWidget(wrapE2eApp(ProfileScreen(repo: repo)));
        await tester.pumpAndSettle();
        expect(find.text('5-Day Davao & Samal Grand Loop'), findsOneWidget);
        expect(find.text('Completed'), findsNothing);
      },
    );

    testWidgets(
      'P6 (F2+F7+F8): ExploreScreen Discover -> Add to trip -> TripRouteMapScreen multimodal route',
      (tester) async {
        setTestViewport(tester, phoneViewport390x844);
        final router = E2eMockRouter(
          onPostRoutesPlan: (req) async => http.Response(
            jsonEncode({
              'route': buildMockRouteJson(
                destinationIds: const [1, 4],
                includeSeaCrossing: true,
              ),
              'suggested_days': 2,
              'days': const <dynamic>[],
            }),
            200,
          ),
        );
        await seedTravelerState(signedIn: false);
        final repo = createE2eRepository(router: router);
        await tester.runAsync(() => repo.initialize());
        await tester.runAsync(() => repo.refreshFromApi());

        await tester.pumpWidget(wrapE2eApp(ExploreScreen(repo: repo)));
        await tester.pumpAndSettle();

        final addBtn = find.text('＋ Add to trip').first;
        await tester.ensureVisible(addBtn);
        await tester.tap(addBtn);
        await tester.pumpAndSettle();
        expect(repo.tripBuilderStops, isNotEmpty);

        final trip = buildFiveDayDavaoSamalTrip(backendTripId: null);
        await tester.pumpWidget(
          wrapE2eApp(TripRouteMapScreen(trip: trip, repo: repo)),
        );
        await pumpBounded(tester);

        expect(find.byKey(const ValueKey('day-filter-1')), findsOneWidget);
        expect(find.byIcon(Icons.directions_boat_rounded), findsWidgets);
      },
    );
  });
}
