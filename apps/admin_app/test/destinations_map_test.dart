import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lakbay_admin/core/polyline5.dart';
import 'package:lakbay_admin/screens/destinations_screen.dart';
import 'package:lakbay_admin/services/api_service.dart';
import 'package:lakbay_admin/widgets/admin_widgets.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _eden = <String, dynamic>{
  'destination_id': 3,
  'name': 'Eden Nature Park',
  'district': 'Davao City',
  'category': 'Nature Resort',
  'lat': 7.0282403,
  'lng': 125.401755,
  'arrival_lat': 7.0304604,
  'arrival_lng': 125.3979848,
  'route_ready': true,
  'is_active': true,
};

final _dahican = <String, dynamic>{
  'destination_id': 6,
  'name': 'Dahican Beach',
  'district': 'Mati City',
  'category': 'Beach',
  'lat': 6.9243488,
  'lng': 126.2808986,
  'is_active': true,
};

Future<void> _mount(WidgetTester tester, ApiService api) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(1440, 1400);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(body: DestinationsScreen(api: api)),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.text('Map'));
  await tester.pumpAndSettle();
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    adminIsSaving.value = false;
  });

  testWidgets('map view shows a pin per destination and the side panel', (
    tester,
  ) async {
    final api = ApiService(
      client: MockClient(
        (_) async => http.Response(jsonEncode([_eden, _dahican]), 200),
      ),
      tokenProvider: () async => 'test-access',
      apiBaseUrl: 'http://lakbay.test/api/v1',
    );
    addTearDown(api.close);
    await _mount(tester, api);

    expect(find.byType(FlutterMap), findsOneWidget);
    expect(find.byKey(const ValueKey('destination-pin-3')), findsOneWidget);
    expect(find.byKey(const ValueKey('destination-pin-6')), findsOneWidget);
    expect(find.textContaining('Click a pin'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('destination-pin-3')));
    await tester.pumpAndSettle();
    expect(find.text('Eden Nature Park'), findsOneWidget);
    expect(find.textContaining('Route-ready endpoint'), findsOneWidget);
    expect(find.widgetWithText(OutlinedButton, 'Move pin'), findsOneWidget);
  });

  testWidgets('Move pin saves only the new coordinates', (tester) async {
    final patches = <http.Request>[];
    final api = ApiService(
      client: MockClient((request) async {
        if (request.method == 'PATCH') {
          patches.add(request);
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          return http.Response(jsonEncode({..._dahican, ...body}), 200);
        }
        return http.Response(jsonEncode([_eden, _dahican]), 200);
      }),
      tokenProvider: () async => 'test-access',
      apiBaseUrl: 'http://lakbay.test/api/v1',
    );
    addTearDown(api.close);
    await _mount(tester, api);

    await tester.tap(find.byKey(const ValueKey('destination-pin-6')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(OutlinedButton, 'Move pin'));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('Click the map where Dahican Beach'),
      findsOneWidget,
    );
    // Save stays disabled until a new spot is chosen.
    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, 'Save new pin'),
          )
          .onPressed,
      isNull,
    );

    final map = tester.getRect(find.byType(FlutterMap));
    await tester.tapAt(map.center + const Offset(40, 30));
    // flutter_map reports a single tap after the double-tap window.
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('New pin for Dahican Beach placed'),
      findsOneWidget,
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Save new pin'));
    await tester.pumpAndSettle();

    expect(patches, hasLength(1));
    expect(patches.single.url.path, '/api/v1/destinations/6');
    final body = jsonDecode(patches.single.body) as Map<String, dynamic>;
    expect(body.keys.toSet(), {'lat', 'lng'});
    expect(body['lat'], isA<double>());
    expect(find.text('Moved the pin for Dahican Beach.'), findsOneWidget);
  });

  testWidgets(
    'Set endpoint and Preview trail work directly from map view',
    (tester) async {
      final patches = <http.Request>[];
      final previews = <http.Request>[];
      final sampleRoad = encodePolyline5([
        const LatLng(7.299, 125.674),
        const LatLng(7.1236, 125.6655),
      ]);
      final api = ApiService(
        client: MockClient((request) async {
          if (request.method == 'PATCH') {
            patches.add(request);
            final body = jsonDecode(request.body) as Map<String, dynamic>;
            return http.Response(
              jsonEncode({..._eden, 'arrival_source_url': 'https://osm.org/node/1', ...body}),
              200,
            );
          }
          if (request.url.path == '/api/v1/routes/preview') {
            previews.add(request);
            return http.Response(
              jsonEncode({
                'route_provider': 'osrm+sea_links',
                'is_estimated': false,
                'total_distance_km': 42.5,
                'total_duration_minutes': 68,
                'polyline': sampleRoad,
                'warnings': ['Board RoRo at Sasa Wharf'],
                'segments': [
                  {
                    'order': 1,
                    'mode': 'road',
                    'from_name': 'Panabo',
                    'to_name': 'Eden Nature Park',
                    'polyline': sampleRoad,
                    'is_estimated': false,
                  },
                ],
              }),
              200,
            );
          }
          return http.Response(
            jsonEncode([
              {..._eden, 'arrival_source_url': 'https://osm.org/node/1'},
              _dahican,
            ]),
            200,
          );
        }),
        tokenProvider: () async => 'test-access',
        apiBaseUrl: 'http://lakbay.test/api/v1',
      );
      addTearDown(api.close);
      await _mount(tester, api);

      await tester.tap(find.byKey(const ValueKey('destination-pin-3')));
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(OutlinedButton, 'Set endpoint'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('road endpoint / gate for Eden Nature Park'),
        findsOneWidget,
      );

      final map = tester.getRect(find.byType(FlutterMap));
      await tester.tapAt(map.center + const Offset(20, 20));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(FilledButton, 'Save endpoint'));
      await tester.pumpAndSettle();

      expect(patches, hasLength(1));
      final patchBody = jsonDecode(patches.single.body) as Map<String, dynamic>;
      expect(patchBody['arrival_lat'], isA<double>());
      expect(patchBody['arrival_lng'], isA<double>());
      expect(patchBody['arrival_source_url'], 'https://osm.org/node/1');
      expect(patchBody['arrival_verified_at'], isNotEmpty);

      await tester.tap(find.text('Preview trail'));
      await tester.pumpAndSettle();
      expect(previews, hasLength(1));
      expect(
        find.textContaining('42.5 km · 68 min · osrm+sea_links'),
        findsOneWidget,
      );
      expect(find.textContaining('Board RoRo at Sasa Wharf'), findsOneWidget);
    },
  );
}
