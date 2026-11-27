import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:lakbay_travel/models/travel_models.dart';
import 'package:lakbay_travel/screens/trip_route_map_screen.dart';
import 'package:lakbay_travel/widgets/lakbay_mapbox_widget.dart';

import 'e2e_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    await initOfflineE2eEnv();
  });

  group('Tier 1 — F1 (R1): Live Traffic Accuracy & Status UX', () {
    testWidgets(
      'F1.1: traffic-toggle-chip toggles live traffic and switches Outdoors <-> Navigation Day',
      (tester) async {
        setTestViewport(tester, phoneViewport390x844);
        final router = E2eMockRouter();
        await seedTravelerState(signedIn: false);
        final repo = createE2eRepository(router: router);
        await tester.runAsync(() => repo.initialize());
        final trip = buildFiveDayDavaoSamalTrip();

        await tester.pumpWidget(
          wrapE2eApp(TripRouteMapScreen(trip: trip, repo: repo)),
        );
        await pumpBounded(tester);

        final chipFinder = find.byKey(const ValueKey('traffic-toggle-chip'));
        expect(chipFinder, findsOneWidget);
        expect(repo.showLiveTraffic, isFalse);
        expect(repo.activeMapStyle, MapboxStylePreset.outdoors);

        await tester.tap(chipFinder);
        await pumpBounded(tester);
        expect(repo.showLiveTraffic, isTrue);
        expect(repo.activeMapStyle, MapboxStylePreset.navigationDay);

        await tester.tap(chipFinder);
        await pumpBounded(tester);
        expect(repo.showLiveTraffic, isFalse);
        expect(repo.activeMapStyle, MapboxStylePreset.outdoors);
      },
    );

    testWidgets(
      'F1.2: live traffic response hides unconditional "Live traffic data is limited in this region" banner',
      (tester) async {
        setTestViewport(tester, phoneViewport390x844);
        final router = E2eMockRouter(
          onPostRoutesPreview: (req) async => http.Response(
            jsonEncode(
              buildMockRouteJson(
                destinationIds: const [1, 14, 2, 3, 4, 1],
                useLiveTraffic: true,
                trafficStatus: 'live',
                delaySeconds: 180,
                includeSeaCrossing: true,
              ),
            ),
            200,
          ),
        );
        await seedTravelerState(signedIn: true);
        final repo = createE2eRepository(router: router);
        await tester.runAsync(() => repo.initialize());
        final trip = buildFiveDayDavaoSamalTrip();

        await tester.pumpWidget(
          wrapE2eApp(TripRouteMapScreen(trip: trip, repo: repo)),
        );
        await pumpBounded(tester);

        await tester.tap(find.byKey(const ValueKey('traffic-toggle-chip')));
        await pumpBounded(tester);

        expect(repo.showLiveTraffic, isTrue);
        expect(
          find.text('Live traffic data is limited in this region'),
          findsNothing,
        );
      },
    );

    testWidgets(
      'F1.3: genuine limited_coverage response shows calm contextual status without blocking map canvas',
      (tester) async {
        setTestViewport(tester, phoneViewport390x844);
        final router = E2eMockRouter(
          onPostRoutesPreview: (req) async => http.Response(
            jsonEncode(
              buildMockRouteJson(
                destinationIds: const [1, 14, 2, 3, 4, 1],
                useLiveTraffic: true,
                trafficStatus: 'limited_coverage',
                delaySeconds: null,
              ),
            ),
            200,
          ),
        );
        await seedTravelerState(signedIn: true);
        final repo = createE2eRepository(router: router);
        await tester.runAsync(() => repo.initialize());
        final trip = buildFiveDayDavaoSamalTrip();

        await tester.pumpWidget(
          wrapE2eApp(TripRouteMapScreen(trip: trip, repo: repo)),
        );
        await pumpBounded(tester);

        await tester.tap(find.byKey(const ValueKey('traffic-toggle-chip')));
        await pumpBounded(tester);

        final mapBox = tester.getRect(find.byType(LakbayMapboxMap).first);
        expect(mapBox.height / 844.0, greaterThanOrEqualTo(0.60));
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'F1.4: satellite mode disables traffic-toggle-chip and surfaces unavailability notice',
      (tester) async {
        setTestViewport(tester, phoneViewport390x844);
        final router = E2eMockRouter();
        await seedTravelerState(signedIn: false);
        final repo = createE2eRepository(router: router);
        await tester.runAsync(() => repo.initialize());
        final trip = buildFiveDayDavaoSamalTrip();

        await tester.pumpWidget(
          wrapE2eApp(TripRouteMapScreen(trip: trip, repo: repo)),
        );
        await pumpBounded(tester);

        repo.setMapboxStyle(MapboxStylePreset.satelliteStreets);
        await pumpBounded(tester);

        final chipFinder = find.byKey(const ValueKey('traffic-toggle-chip'));
        final chip = tester.widget<FilterChip>(chipFinder);
        expect(chip.onSelected, isNull);
        expect(repo.showLiveTraffic, isFalse);
        expect(
          find.textContaining('Satellite'),
          findsWidgets,
        );
      },
    );

    testWidgets(
      'F1.5: enabling live traffic sends use_live_traffic=true to route API',
      (tester) async {
        setTestViewport(tester, phoneViewport390x844);
        final router = E2eMockRouter();
        await seedTravelerState(signedIn: true);
        final repo = createE2eRepository(router: router);
        await tester.runAsync(() => repo.initialize());
        final trip = buildFiveDayDavaoSamalTrip();

        await tester.pumpWidget(
          wrapE2eApp(TripRouteMapScreen(trip: trip, repo: repo)),
        );
        await pumpBounded(tester);

        router.requests.clear();
        await tester.tap(find.byKey(const ValueKey('traffic-toggle-chip')));
        await pumpBounded(tester);

        final routeCalls = router.routeRequests;
        expect(routeCalls, isNotEmpty);
        expect(
          routeCalls.any((r) => r.body['use_live_traffic'] == true),
          isTrue,
        );
      },
    );
  });

  group('Tier 1 — F2 (R2): 5-Day Multi-Stop Routing & Retry Recovery', () {
    test(
      'F2.1: 5-day multi-stop trip preserves per-stop destinationIds and non-consecutive hub revisits',
      () async {
        final router = E2eMockRouter();
        await seedTravelerState(signedIn: true);
        final repo = createE2eRepository(router: router);
        await repo.initialize();

        final trip = buildFiveDayDavaoSamalTrip();
        await repo.fetchRoadRouteForTrip(trip);

        final previewReq = router.requestsFor('/routes/preview').first;
        final sentIds = (previewReq.body['destination_ids'] as List<dynamic>)
            .cast<int>();
        expect(sentIds.first, 1);
        expect(sentIds.last, 1);
        expect(sentIds.length, greaterThanOrEqualTo(6));
      },
    );

    testWidgets(
      'F2.2: mixed mainland + Samal Island 5-day trip renders road + ferry segments and sea crossing sheet',
      (tester) async {
        setTestViewport(tester, phoneViewport390x844);
        final router = E2eMockRouter(
          onPostRoutesPreview: (req) async => http.Response(
            jsonEncode(
              buildMockRouteJson(
                destinationIds: const [1, 14, 2, 3, 4, 1],
                includeSeaCrossing: true,
              ),
            ),
            200,
          ),
        );
        await seedTravelerState(signedIn: true);
        final repo = createE2eRepository(router: router);
        await tester.runAsync(() => repo.initialize());
        final trip = buildFiveDayDavaoSamalTrip();

        await tester.pumpWidget(
          wrapE2eApp(TripRouteMapScreen(trip: trip, repo: repo)),
        );
        await pumpBounded(tester);

        final boatIcon = find.byIcon(Icons.directions_boat_rounded);
        expect(boatIcon, findsWidgets);
        await tester.tap(boatIcon.first);
        await pumpBounded(tester);

        expect(find.text('Boat Crossing Details'), findsOneWidget);
        expect(find.textContaining('Sasa Wharf'), findsWidgets);
        expect(find.textContaining('Babak Wharf'), findsWidgets);
      },
    );

    testWidgets(
      'F2.3: transient route failure shows Retry and tapping Retry recovers cleanly',
      (tester) async {
        setTestViewport(tester, phoneViewport390x844);
        var attempt = 0;
        final router = E2eMockRouter(
          onPostRoutesPreview: (req) async {
            attempt++;
            if (attempt <= 2) {
              return http.Response(
                jsonEncode({'detail': 'Temporary routing outage'}),
                503,
              );
            }
            return http.Response(
              jsonEncode(
                buildMockRouteJson(
                  destinationIds: const [1, 14, 2, 3, 4, 1],
                  includeSeaCrossing: true,
                ),
              ),
              200,
            );
          },
          onPostRoutesPlan: (req) async {
            if (attempt <= 2) {
              return http.Response(
                jsonEncode({'detail': 'Temporary routing outage'}),
                503,
              );
            }
            return http.Response(
              jsonEncode({
                'route': buildMockRouteJson(
                  destinationIds: const [1, 14, 2, 3, 4, 1],
                  includeSeaCrossing: true,
                ),
                'suggested_days': 5,
                'days': const <dynamic>[],
              }),
              200,
            );
          },
        );
        await seedTravelerState(signedIn: true);
        final repo = createE2eRepository(router: router);
        await tester.runAsync(() => repo.initialize());
        final trip = buildFiveDayDavaoSamalTrip();

        await tester.pumpWidget(
          wrapE2eApp(TripRouteMapScreen(trip: trip, repo: repo)),
        );
        await pumpBounded(tester);

        final retryFinder = find.text('Retry');
        expect(retryFinder, findsOneWidget);

        await tester.tap(retryFinder);
        await pumpBounded(tester);

        expect(find.text('Retry'), findsNothing);
        expect(find.text('Road directions unavailable'), findsNothing);
      },
    );

    testWidgets(
      'F2.4: guest mode falls back cleanly to POST /routes/plan/guest and renders summary',
      (tester) async {
        setTestViewport(tester, phoneViewport390x844);
        final router = E2eMockRouter(
          onPostRoutesPlan: (req) async => http.Response(
            jsonEncode({
              'route': buildMockRouteJson(
                destinationIds: const [1, 14, 2, 3, 4],
                includeSeaCrossing: true,
              ),
              'suggested_days': 5,
              'days': const <dynamic>[],
            }),
            200,
          ),
        );
        await seedTravelerState(signedIn: false);
        final repo = createE2eRepository(router: router);
        await tester.runAsync(() => repo.initialize());
        final trip = buildFiveDayDavaoSamalTrip();

        await tester.pumpWidget(
          wrapE2eApp(TripRouteMapScreen(trip: trip, repo: repo)),
        );
        await pumpBounded(tester);

        expect(router.requestsFor('/routes/plan/guest'), isNotEmpty);
        expect(find.text('Road directions unavailable'), findsNothing);
        expect(find.textContaining('78 km'), findsWidgets);
      },
    );

    testWidgets(
      'F2.5: partial routing returns road geometry for routable legs alongside warning instead of null',
      (tester) async {
        setTestViewport(tester, phoneViewport390x844);
        final router = E2eMockRouter(
          onPostRoutesPreview: (req) async => http.Response(
            jsonEncode(
              buildMockRouteJson(
                destinationIds: const [1, 14, 2, 3, 4],
                isPartialEstimated: true,
                warnings: const [
                  'Leg 2 uses estimated path; other road legs routed cleanly.',
                ],
              ),
            ),
            200,
          ),
        );
        await seedTravelerState(signedIn: true);
        final repo = createE2eRepository(router: router);
        await tester.runAsync(() => repo.initialize());
        final trip = buildFiveDayDavaoSamalTrip();

        await tester.pumpWidget(
          wrapE2eApp(TripRouteMapScreen(trip: trip, repo: repo)),
        );
        await pumpBounded(tester);

        expect(find.text('Road directions unavailable'), findsNothing);
        final mapWidget = tester.widget<LakbayMapboxMap>(
          find.byType(LakbayMapboxMap).first,
        );
        expect(mapWidget.routeSegments, isNotEmpty);
        expect(mapWidget.routeSegments.any((s) => !s.isEstimated), isTrue);
      },
    );
  });

  group('Tier 1 — F3 (R3): Compressed Map Screen UI/UX Overhaul', () {
    testWidgets(
      'F3.1: 390x844 phone viewport allocates >=60% unobstructed height to LakbayMapboxMap',
      (tester) async {
        setTestViewport(tester, phoneViewport390x844);
        final router = E2eMockRouter();
        await seedTravelerState(signedIn: false);
        final repo = createE2eRepository(router: router);
        await tester.runAsync(() => repo.initialize());
        final trip = buildFiveDayDavaoSamalTrip();

        await tester.pumpWidget(
          wrapE2eApp(TripRouteMapScreen(trip: trip, repo: repo)),
        );
        await pumpBounded(tester);

        final scaffoldBodyRect = tester.getRect(find.byType(Scaffold));
        final mapRect = tester.getRect(find.byType(LakbayMapboxMap).first);
        final visibleMapFraction = mapRect.height / scaffoldBodyRect.height;
        expect(visibleMapFraction, greaterThanOrEqualTo(0.60));
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'F3.2: 360x800 compact phone viewport allocates >=60% map height with zero overflow',
      (tester) async {
        setTestViewport(tester, phoneViewport360x800);
        final router = E2eMockRouter();
        await seedTravelerState(signedIn: false);
        final repo = createE2eRepository(router: router);
        await tester.runAsync(() => repo.initialize());
        final trip = buildFiveDayDavaoSamalTrip();

        await tester.pumpWidget(
          wrapE2eApp(TripRouteMapScreen(trip: trip, repo: repo)),
        );
        await pumpBounded(tester);

        final mapRect = tester.getRect(find.byType(LakbayMapboxMap).first);
        expect(mapRect.height / 800.0, greaterThanOrEqualTo(0.60));
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'F3.3: TripRouteMapScreen uses interactive DraggableScrollableSheet for itinerary stops',
      (tester) async {
        setTestViewport(tester, phoneViewport390x844);
        final router = E2eMockRouter();
        await seedTravelerState(signedIn: false);
        final repo = createE2eRepository(router: router);
        await tester.runAsync(() => repo.initialize());
        final trip = buildFiveDayDavaoSamalTrip();

        await tester.pumpWidget(
          wrapE2eApp(TripRouteMapScreen(trip: trip, repo: repo)),
        );
        await pumpBounded(tester);

        final sheetFinder = find.byType(DraggableScrollableSheet);
        expect(sheetFinder, findsOneWidget);
        final sheetSurface = find.byKey(const ValueKey('route-itinerary-sheet'));
        expect(sheetSurface, findsOneWidget);

        final initialTop = tester.getTopLeft(sheetSurface).dy;
        await tester.drag(sheetSurface, const Offset(0, -220));
        await pumpBounded(tester);
        final expandedTop = tester.getTopLeft(sheetSurface).dy;
        expect(expandedTop, lessThan(initialTop));
      },
    );

    testWidgets(
      'F3.4: floating controls (Zoom In, Zoom Out, Fit Route Stops) meet >=44dp touch targets',
      (tester) async {
        setTestViewport(tester, phoneViewport390x844);
        final router = E2eMockRouter();
        await seedTravelerState(signedIn: false);
        final repo = createE2eRepository(router: router);
        await tester.runAsync(() => repo.initialize());
        final trip = buildFiveDayDavaoSamalTrip();

        await tester.pumpWidget(
          wrapE2eApp(TripRouteMapScreen(trip: trip, repo: repo)),
        );
        await pumpBounded(tester);

        for (final tooltip in const [
          'Zoom In',
          'Zoom Out',
          'Fit Route Stops',
        ]) {
          final btn = find.byTooltip(tooltip);
          expect(btn, findsOneWidget, reason: 'Missing control $tooltip');
          final rect = tester.getRect(btn);
          expect(
            rect.width,
            greaterThanOrEqualTo(44.0),
            reason: '$tooltip width ${rect.width} < 44dp',
          );
          expect(
            rect.height,
            greaterThanOrEqualTo(44.0),
            reason: '$tooltip height ${rect.height} < 44dp',
          );
        }
      },
    );

    testWidgets(
      'F3.5: zero overlap between floating controls & attribution, and day-filter chips switch days',
      (tester) async {
        setTestViewport(tester, phoneViewport390x844);
        final router = E2eMockRouter();
        await seedTravelerState(signedIn: false);
        final repo = createE2eRepository(router: router);
        await tester.runAsync(() => repo.initialize());
        final trip = buildFiveDayDavaoSamalTrip();

        await tester.pumpWidget(
          wrapE2eApp(TripRouteMapScreen(trip: trip, repo: repo)),
        );
        await pumpBounded(tester);

        final zoomInRect = tester.getRect(find.byTooltip('Zoom In'));
        final fitRect = tester.getRect(find.byTooltip('Fit Route Stops'));
        final attributionFinder = find.textContaining('OpenStreetMap');
        if (attributionFinder.evaluate().isNotEmpty) {
          final attrRect = tester.getRect(attributionFinder.first);
          expect(zoomInRect.overlaps(attrRect), isFalse);
          expect(fitRect.overlaps(attrRect), isFalse);
        }

        expect(find.byKey(const ValueKey('day-filter-all')), findsOneWidget);
        expect(find.byKey(const ValueKey('day-filter-1')), findsOneWidget);
        expect(find.byKey(const ValueKey('day-filter-2')), findsOneWidget);

        await tester.tap(find.byKey(const ValueKey('day-filter-2')));
        await pumpBounded(tester);
        expect(
          find.descendant(
            of: find.byKey(const ValueKey('active-stop-callout')),
            matching: find.text('Philippine Eagle Center'),
          ),
          findsOneWidget,
        );
      },
    );
  });
}
