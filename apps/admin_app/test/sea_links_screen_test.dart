import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lakbay_admin/core/polyline5.dart';
import 'package:lakbay_admin/screens/sea_links_screen.dart';
import 'package:lakbay_admin/services/api_service.dart';
import 'package:lakbay_admin/widgets/admin_widgets.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _sasa = <String, dynamic>{
  'port_id': 1,
  'name': 'Sasa RoRo Wharf (Davao City)',
  'lat': 7.1236,
  'lng': 125.6655,
  'island_group': 'mainland',
  'province': 'Davao City',
  'notes': 'Main RoRo terminal',
  'verified': false,
  'is_active': true,
};

final _babak = <String, dynamic>{
  'port_id': 2,
  'name': 'Babak RoRo Landing (Samal)',
  'lat': 7.1180,
  'lng': 125.6880,
  'island_group': 'samal',
  'province': 'Davao del Norte',
  'verified': true,
  'is_active': true,
};

final _link = <String, dynamic>{
  'link_id': 1,
  'from_port_id': 1,
  'to_port_id': 2,
  'from_port_name': 'Sasa RoRo Wharf (Davao City)',
  'to_port_name': 'Babak RoRo Landing (Samal)',
  'from_lat': 7.1236,
  'from_lng': 125.6655,
  'to_lat': 7.1180,
  'to_lng': 125.6880,
  'bidirectional': true,
  'vessel_type': 'roro_barge',
  'allows_private_vehicle': true,
  'crossing_minutes': 15,
  'typical_wait_minutes': 20,
  'geometry_polyline': null,
  'verified': false,
  'is_active': true,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    adminIsSaving.value = false;
  });

  testWidgets(
    'SeaLinksScreen moves port boarding gate and draws boat crossing track',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1440, 1200);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final portPatches = <Map<String, dynamic>>[];
      final linkPatches = <Map<String, dynamic>>[];
      var currentSasa = Map<String, dynamic>.from(_sasa);
      var currentLink = Map<String, dynamic>.from(_link);

      final api = ApiService(
        tokenProvider: () async => 'admin-token',
        apiBaseUrl: 'http://lakbay.test/api/v1',
        client: MockClient((request) async {
          if (request.url.path == '/api/v1/admin/sea-ports' &&
              request.method == 'GET') {
            return http.Response(jsonEncode([currentSasa, _babak]), 200);
          }
          if (request.url.path == '/api/v1/admin/sea-links' &&
              request.method == 'GET') {
            return http.Response(jsonEncode([currentLink]), 200);
          }
          if (request.url.path == '/api/v1/admin/sea-ports/1' &&
              request.method == 'PATCH') {
            final body = jsonDecode(request.body) as Map<String, dynamic>;
            portPatches.add(body);
            currentSasa = {...currentSasa, ...body};
            return http.Response(jsonEncode(currentSasa), 200);
          }
          if (request.url.path == '/api/v1/admin/sea-links/1' &&
              request.method == 'PATCH') {
            final body = jsonDecode(request.body) as Map<String, dynamic>;
            linkPatches.add(body);
            currentLink = {...currentLink, ...body};
            return http.Response(jsonEncode(currentLink), 200);
          }
          return http.Response('{}', 404);
        }),
      );
      addTearDown(api.close);

      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: SeaLinksScreen(api: api))),
      );
      await tester.pumpAndSettle();

      expect(find.text('Sea Ports & Trails'), findsOneWidget);
      expect(find.text('Sasa RoRo Wharf (Davao City)'), findsOneWidget);

      await tester.tap(find.widgetWithText(OutlinedButton, 'Move gate on map').first);
      await tester.pumpAndSettle();

      final mapRect = tester.getRect(find.byType(FlutterMap).first);
      await tester.tapAt(mapRect.center + const Offset(25, -15));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(FilledButton, 'Save gate'));
      await tester.pumpAndSettle();

      expect(portPatches, hasLength(1));
      expect(portPatches.single['lat'], isA<double>());
      expect(portPatches.single['lng'], isA<double>());

      await tester.tap(find.textContaining('Boat Links'));
      await tester.pumpAndSettle();
      expect(find.text('Draw boat track'), findsOneWidget);

      await tester.tap(find.widgetWithText(OutlinedButton, 'Draw boat track'));
      await tester.pumpAndSettle();
      expect(find.text('Start -> End straight line'), findsOneWidget);

      await tester.tap(find.text('Start -> End straight line'));
      await tester.pumpAndSettle();

      // Append a midpoint inside the trail dialog map so track has 3 waypoints.
      final dialogMap = tester.getRect(find.byType(FlutterMap).last);
      await tester.tapAt(dialogMap.center + const Offset(10, 10));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(FilledButton, 'Use trail'));
      await tester.pumpAndSettle();

      expect(linkPatches, hasLength(1));
      final encoded = linkPatches.single['geometry_polyline']?.toString() ?? '';
      expect(decodePolyline5(encoded).length, equals(3));
      expect(decodePolyline5(encoded).first, isA<LatLng>());
    },
  );
}
