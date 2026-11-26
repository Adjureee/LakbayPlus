import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:lakbay_travel/models/travel_models.dart';
import 'package:lakbay_travel/screens/trip_detail_screen.dart';
import 'package:lakbay_travel/screens/trip_route_map_screen.dart';
import 'package:lakbay_travel/services/lakbay_ai_service.dart';
import 'package:lakbay_travel/services/lakbay_api_catalog_service.dart';
import 'package:lakbay_travel/services/location_service.dart';
import 'package:lakbay_travel/services/mapbox_service.dart';
import 'package:lakbay_travel/services/travel_repository.dart';

TravelRepository _makeTestRepo({http.Client? client}) => TravelRepository(
      apiCatalog: LakbayApiCatalogService(
        baseUrlOverride: 'https://api.lakbay.test/api/v1',
        client: client ?? MockClient((_) async => http.Response('{}', 404)),
      ),
      locationService: LocationService(
        customFetcher: () async =>
            const LocationResult(granted: false, statusMessage: 'Declined'),
      ),
    );

ItineraryTrip _buildMultiDayDavaoSamalTrip() {
  return ItineraryTrip(
    id: 'trip_davao_samal_test',
    title: 'Davao & Samal 2-Day Loop',
    destination: 'Davao City & Samal Island',
    daysCount: 2,
    adults: 2,
    centerLat: 7.084,
    centerLng: 125.67,
    heroAsset: 'assets/png/samal_beach.png',
    vibeTag: 'Nature & Island',
    overviewText:
        'A two-day geographic loop pairing Davao highlands with Samal Island reefs.',
    bestMonths: 'Dec – May',
    avgTemp: '30°C • Sunny',
    expertName: 'Lakbay Planner',
    expertAvatarAsset: 'assets/png/samal_beach.png',
    expertTip: 'Catch the early barge from Sasa Wharf to Babak Pier.',
    backendDestinationIds: const [10, 11, 12],
    flights: const [],
    hotels: const [],
    seaCrossings: const [
      SeaCrossingInfo(
        vesselType: 'barge',
        boardPort: 'Sasa Wharf',
        landPort: 'Babak Wharf',
        boardLat: 7.1145,
        boardLng: 125.6562,
        landLat: 7.1258,
        landLng: 125.6881,
        crossingMinutes: 15,
        typicalWaitMinutes: 20,
        allowsPrivateVehicle: true,
        farePassenger: 35,
        fareVehicle: 320,
        verified: true,
      ),
    ],
    routeSegments: const [
      RouteSegmentGeometry(
        mode: TransportMode.car,
        fromName: 'Davao Crocodile Park',
        toName: 'People\'s Park Davao',
        points: [
          GeoPoint(lat: 7.1014, lng: 125.5968),
          GeoPoint(lat: 7.0715, lng: 125.6095),
        ],
      ),
      RouteSegmentGeometry(
        mode: TransportMode.ferry,
        fromName: 'Sasa Wharf',
        toName: 'Babak Wharf',
        points: [
          GeoPoint(lat: 7.1145, lng: 125.6562),
          GeoPoint(lat: 7.1258, lng: 125.6881),
        ],
      ),
      RouteSegmentGeometry(
        mode: TransportMode.car,
        fromName: 'Babak Wharf',
        toName: 'Hagimit Falls',
        points: [
          GeoPoint(lat: 7.1258, lng: 125.6881),
          GeoPoint(lat: 7.0812, lng: 125.7335),
        ],
      ),
    ],
    days: const [
      ItineraryDay(
        dayNumber: 1,
        cityTitle: 'Day 1 • Davao City Highlights',
        summary: 'Wildlife sanctuary and urban garden in Davao City.',
        lat: 7.1014,
        lng: 125.5968,
        apiDestinationId: 10,
        stops: [
          ItineraryStop(
            time: '09:00 AM',
            title: 'Davao Crocodile Park',
            description: 'Morning wildlife tour by the river.',
            category: 'sight',
            lat: 7.1014,
            lng: 125.5968,
            destinationId: 10,
            islandGroup: 'mainland',
          ),
          ItineraryStop(
            time: '02:00 PM',
            title: 'People\'s Park Davao',
            description: 'Afternoon rainforest walk and Durian Dome.',
            category: 'sight',
            lat: 7.0715,
            lng: 125.6095,
            destinationId: 11,
            islandGroup: 'mainland',
            travelFromPrevMinutes: 22,
            travelFromPrevKm: 5.4,
            travelFromPrevMode: TransportMode.car,
          ),
        ],
      ),
      ItineraryDay(
        dayNumber: 2,
        cityTitle: 'Day 2 • Samal Island Crossing',
        summary: 'Cross Pakiputan Strait by barge to Hagimit Falls.',
        lat: 7.0812,
        lng: 125.7335,
        apiDestinationId: 12,
        stops: [
          ItineraryStop(
            time: '08:30 AM',
            title: 'Hagimit Falls',
            description: 'Cascading travertine pools on Samal Island.',
            category: 'nature',
            lat: 7.0812,
            lng: 125.7335,
            destinationId: 12,
            islandGroup: 'samal',
            travelFromPrevMinutes: 55,
            travelFromPrevKm: 18.2,
            travelFromPrevMode: TransportMode.ferry,
            isSeaCrossingFromPrev: true,
          ),
        ],
      ),
    ],
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    GoogleFonts.config.allowRuntimeFetching = false;
    SharedPreferences.setMockInitialValues({});
  });

  group('AI parsing and coordinate grounding', () {
    test('parseBackendAiOption preserves distinct per-activity coordinates and destinationIds', () async {
      final client = MockClient((req) async {
        final path = req.url.path.replaceFirst('/api/v1', '');
        if (path == '/destinations') {
          return http.Response(
            jsonEncode({'items': [], 'total': 0}),
            200,
          );
        }
        if (path == '/ai/chat/guest') {
          return http.Response(
            jsonEncode({
              'chat_response': 'Generating your 1-day Davao sightseeing loop.',
              'model_id': 'mock-groq',
              'ai_generation_run_id': 77,
              'planning': {
                'input_revision': 1,
                'intent': 'plan_trip',
                'suggested_replies': <String>[],
                'state_updates': {
                  'destination_ids': [101, 102],
                  'day_count': 1,
                  'traveler_count': 2,
                  'total_budget': 4000,
                },
                'update_status': 'updated',
                'preview': {
                  'state': {
                    'destination_ids': [101, 102],
                    'day_count': 1,
                    'traveler_count': 2,
                    'total_budget': 4000,
                  },
                },
                'recommendations': <dynamic>[],
              },
            }),
            200,
            headers: const {'content-type': 'application/json; charset=utf-8'},
          );
        }
        if (path == '/ai/itineraries/generate/guest') {
          return http.Response(
            jsonEncode({
              'selected_generation_run_id': 77,
              'model_runs': <dynamic>[],
              'options': [
                {
                  'option_number': 1,
                  'title': 'Davao River to Park Loop',
                  'summary': 'Two distinct stops on Day 1',
                  'estimated_total_cost': '2800.00',
                  'cost_source': 'ai_draft_estimate',
                  'is_over_budget': false,
                  'destination_ids': [101, 102],
                  'days': [
                    {
                      'day': 1,
                      'title': 'Davao City Tour',
                      'summary': 'Two stops with unique coordinates.',
                      'destination_id': 101,
                      'lat': 7.1014,
                      'lng': 125.5968,
                      'activities': [
                        {
                          'time': '09:00 AM',
                          'title': 'Davao Crocodile Park',
                          'description': 'Start at the park.',
                          'category': 'sight',
                          'destination_id': 101,
                          'lat': 7.1014,
                          'lng': 125.5968,
                          'island_group': 'mainland',
                        },
                        {
                          'time': '01:30 PM',
                          'title': 'Eden Nature Park',
                          'description': 'Head up to Toril ridge.',
                          'category': 'nature',
                          'destination_id': 102,
                          'lat': 7.0322,
                          'lng': 125.4321,
                          'island_group': 'mainland',
                        },
                      ],
                    },
                  ],
                },
              ],
            }),
            200,
            headers: const {'content-type': 'application/json; charset=utf-8'},
          );
        }
        return http.Response('{}', 404);
      });

      final repo = _makeTestRepo(client: client);
      await repo.initialize();

      await repo.sendChatMessage(
        '1 day Davao sights and nature for 2 under 4000 PHP',
      );
      final aiMsg = repo.chatMessages.last;
      expect(
        aiMsg.aiOptions,
        isNotEmpty,
        reason: 'msg="${aiMsg.text}" err=${aiMsg.errorCode}',
      );
      final trip = aiMsg.aiOptions.first.trip;
      final stops = trip.days.first.stops;
      expect(stops.length, 2);
      expect(stops[0].destinationId, 101);
      expect(stops[0].lat, closeTo(7.1014, 0.0001));
      expect(stops[1].destinationId, 102);
      expect(stops[1].lat, closeTo(7.0322, 0.0001));
      expect(stops[1].lng, closeTo(125.4321, 0.0001));
    });

    test('buildTripFromAiResult resolves null-coord stops from catalog and marks Samal crossing', () async {
      final client = MockClient((req) async {
        final path = req.url.path.replaceFirst('/api/v1', '');
        if (path == '/destinations') {
          return http.Response(
            jsonEncode({
              'items': [
                {
                  'id': 201,
                  'name': 'Davao Bamboo Sanctuary',
                  'district': 'Davao City',
                  'municipality_or_city': 'Davao City',
                  'province': 'Davao del Sur',
                  'island_group': 'mainland',
                  'category': 'Park',
                  'lat': 7.0715,
                  'lng': 125.6095,
                  'description': 'Central sanctuary',
                  'estimated_visit_minutes': 90,
                },
                {
                  'id': 202,
                  'name': 'Coral Garden Samal Reef',
                  'district': 'Samal Island',
                  'municipality_or_city': 'IGACOS',
                  'province': 'Davao del Norte',
                  'island_group': 'samal',
                  'category': 'Beach',
                  'lat': 7.0812,
                  'lng': 125.7335,
                  'description': 'Samal reef garden',
                  'estimated_visit_minutes': 120,
                },
              ],
              'total': 2,
            }),
            200,
          );
        }
        return http.Response('{}', 404);
      });

      final repo = _makeTestRepo(client: client);
      await repo.initialize();
      await repo.refreshFromApi();

      const aiDraft = AiPlanResult(
        replyText: 'Here is your 2-day draft.',
        providerUsed: 'groq',
        modelUsed: 'llama-3.3',
        title: 'Davao & Samal Draft',
        destination: 'Davao City & Samal Island',
        daysCount: 2,
        days: [
          AiGeneratedDay(
            day: 1,
            title: 'Davao Sanctuary Day',
            summary: 'Visit Davao Bamboo Sanctuary.',
            activities: [
              AiGeneratedActivity(
                time: '09:00 AM',
                title: 'Davao Bamboo Sanctuary',
                description: 'Stroll the shaded groves.',
              ),
            ],
          ),
          AiGeneratedDay(
            day: 2,
            title: 'Samal Reef Day',
            summary: 'Snorkel at Coral Garden Samal Reef.',
            activities: [
              AiGeneratedActivity(
                time: '10:00 AM',
                title: 'Coral Garden Samal Reef',
                description: 'Crystal shallow reef on Samal.',
              ),
            ],
          ),
        ],
      );

      final trip = repo.buildTripFromAiResult(aiDraft);
      expect(trip.days[0].stops.first.destinationId, 201);
      expect(trip.days[0].stops.first.lat, closeTo(7.0715, 0.0001));
      expect(trip.days[1].stops.first.destinationId, 202);
      expect(trip.days[1].stops.first.lat, closeTo(7.0812, 0.0001));
      expect(trip.days[1].stops.first.isSeaCrossingFromPrev, isTrue);
      expect(trip.backendDestinationIds, containsAll([201, 202]));
    });
  });

  group('MapboxService bounds fitting and tile attribution', () {
    test('computeBoundsCenterAndZoom respects viewportSize and overlay padding', () {
      const pts = [
        GeoPoint(lat: 7.03, lng: 125.43),
        GeoPoint(lat: 7.12, lng: 125.74),
      ];
      final (_, _, unpaddedZoom) = MapboxService.computeBoundsCenterAndZoom(
        pts,
        viewportSize: const Size(800, 600),
      );
      final (_, _, heavilyPaddedZoom) = MapboxService.computeBoundsCenterAndZoom(
        pts,
        viewportSize: const Size(800, 600),
        padding: const EdgeInsets.fromLTRB(220, 140, 60, 220),
      );
      expect(heavilyPaddedZoom, lessThan(unpaddedZoom));
    });

    test('tileAttribution reflects active tile source cleanly', () {
      final mapbox = MapboxService();
      final streetsAttr = mapbox.tileAttribution(MapboxStylePreset.outdoors);
      final satAttr = mapbox.tileAttribution(MapboxStylePreset.satelliteStreets);
      if (mapbox.hasValidToken) {
        expect(streetsAttr, contains('Mapbox'));
      } else {
        expect(streetsAttr, contains('OpenStreetMap'));
        expect(satAttr, contains('Esri'));
      }
    });

    test('decodePolyline5 decodes negative lat/lng deltas without wraparound', () {
      const encoded = r's{nj@ys~}Vv{IxoI{kUjsd@';
      final pts = LakbayApiCatalogService.decodePolyline5(encoded);
      expect(pts.length, 3);
      expect(pts[0].lat, closeTo(7.1265, 0.0001));
      expect(pts[0].lng, closeTo(125.66349, 0.0001));
      expect(pts[1].lat, closeTo(7.0707, 0.0001));
      expect(pts[1].lng, closeTo(125.6096, 0.0001));
      expect(pts[2].lat, closeTo(7.1854, 0.0001));
      expect(pts[2].lng, closeTo(125.4169, 0.0001));
    });
  });

  group('TripRouteMapScreen UX, day filter, sync & viewports', () {
    testWidgets(
      'mobile 390x844: day filter, stop 2 selection preserved, pier sheet opens cleanly',
      (tester) async {
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final repo = _makeTestRepo();
        await tester.runAsync(() => repo.initialize());
        final trip = _buildMultiDayDavaoSamalTrip();

        await tester.pumpWidget(
          MaterialApp(home: TripRouteMapScreen(trip: trip, repo: repo)),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));

        expect(find.byKey(const ValueKey('day-filter-all')), findsOneWidget);
        expect(find.byKey(const ValueKey('day-filter-1')), findsOneWidget);
        expect(find.byKey(const ValueKey('day-filter-2')), findsOneWidget);
        expect(find.byKey(const ValueKey('active-stop-callout')), findsOneWidget);

        // Scroll stop 2 pill into view in Day 1 carousel card -> tap -> active callout stays on Stop 2.
        await tester.ensureVisible(find.text("2. People's Park Davao"));
        await tester.pump();
        await tester.tap(find.text("2. People's Park Davao"));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        final calloutFinder = find.byKey(const ValueKey('active-stop-callout'));
        expect(calloutFinder, findsOneWidget);
        expect(
          find.descendant(
            of: calloutFinder,
            matching: find.text("People's Park Davao"),
          ),
          findsOneWidget,
        );

        // Tap Day 2 filter -> switches to Day 2 stop (Hagimit Falls).
        await tester.tap(find.byKey(const ValueKey('day-filter-2')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        expect(
          find.descendant(
            of: find.byKey(const ValueKey('active-stop-callout')),
            matching: find.text('Hagimit Falls'),
          ),
          findsOneWidget,
        );

        // Tap ferry crossings summary chip -> opens Boat Crossing Details modal sheet.
        await tester.tap(find.byIcon(Icons.directions_boat_rounded).first);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        expect(find.text('Boat Crossing Details'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'desktop 1280x800: split sidebar timeline renders and focuses stops without overflow',
      (tester) async {
        tester.view.physicalSize = const Size(1280, 800);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final repo = _makeTestRepo();
        await tester.runAsync(() => repo.initialize());
        final trip = _buildMultiDayDavaoSamalTrip();

        await tester.pumpWidget(
          MaterialApp(home: TripRouteMapScreen(trip: trip, repo: repo)),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));

        expect(find.text('Route & Stop Timeline'), findsOneWidget);

        // Tap Stop 2 in desktop timeline sidebar -> active stop callout updates to People's Park Davao.
        await tester.tap(find.text("People's Park Davao").first);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        expect(
          find.descendant(
            of: find.byKey(const ValueKey('active-stop-callout')),
            matching: find.text("People's Park Davao"),
          ),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('empty days trip renders empty route state card cleanly', (tester) async {
      final repo = _makeTestRepo();
      await tester.runAsync(() => repo.initialize());
      final emptyTrip = _buildMultiDayDavaoSamalTrip().copyWith(
        days: const [],
        routeSegments: const [],
        seaCrossings: const [],
      );

      await tester.pumpWidget(
        MaterialApp(home: TripRouteMapScreen(trip: emptyTrip, repo: repo)),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.byKey(const ValueKey('empty-route-state')), findsOneWidget);
      expect(find.text('No itinerary stops mapped yet'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('TripDetailScreen overview deduplication, split view & Day navigation', () {
    testWidgets(
      'desktop 1280x800: overviewText renders once, split pane shows map, Day 2 map icon opens Day 2',
      (tester) async {
        tester.view.physicalSize = const Size(1280, 800);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final repo = _makeTestRepo();
        await tester.runAsync(() => repo.initialize());
        final trip = _buildMultiDayDavaoSamalTrip();

        await tester.pumpWidget(
          MaterialApp(home: TripDetailScreen(trip: trip, repo: repo)),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));

        // Desktop split view shows one Full Map button (right split pane only, no redundant Overview preview).
        expect(find.text('Full Map'), findsOneWidget);

        // Scroll down the Overview ListView to inspect overviewText -> must render only once.
        final overviewScrollable = find.byType(Scrollable).first;
        await tester.scrollUntilVisible(
          find.text(trip.overviewText),
          150,
          scrollable: overviewScrollable,
        );
        expect(find.text(trip.overviewText), findsOneWidget);
        await tester.drag(overviewScrollable, const Offset(0, -500));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 200));
        expect(find.text(trip.overviewText), findsNothing);

        // Switch to Day-by-Day tab and tap Day 2's See this day on the map icon.
        await tester.tap(find.text('Day-by-Day'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));

        final inspectIcons = find.byTooltip('See this day on the map');
        expect(inspectIcons, findsNWidgets(2));
        await tester.ensureVisible(inspectIcons.at(1));
        await tester.tap(inspectIcons.at(1));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));

        // Navigated to TripRouteMapScreen pre-focused on Day 2 (Hagimit Falls).
        expect(
          find.descendant(
            of: find.byKey(const ValueKey('active-stop-callout')),
            matching: find.text('Hagimit Falls'),
          ),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      },
    );
  });
}
