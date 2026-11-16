import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lakbay_admin/screens/destinations_screen.dart';
import 'package:lakbay_admin/services/api_service.dart';
import 'package:lakbay_admin/widgets/admin_widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _destinations = [
  {
    'destination_id': 8,
    'name': 'Tagbibinta Falls',
    'lat': 7.3163971,
    'lng': 126.171868,
    'is_active': true,
  },
  {
    'destination_id': 26,
    'name': 'Pyalitan Falls',
    'lat': 7.29919,
    'lng': 126.1707,
    'is_active': true,
  },
];

const _osmMatch = {
  'osm_type': 'node',
  'osm_id': 123456,
  'osm_url': 'https://www.openstreetmap.org/node/123456',
  'name': 'Tagbibinta Viewpoint',
  'lat': 7.3171,
  'lng': 126.1702,
  'category': 'viewpoint',
  'source_tag': 'tourism=viewpoint',
};

typedef _Log = List<http.Request>;

ApiService _api(_Log log, {List<Map<String, dynamic>> nearby = const []}) =>
    ApiService(
      client: MockClient((request) async {
        log.add(request);
        final path = request.url.path;
        if (path.endsWith('/osm/search')) {
          return http.Response(jsonEncode([_osmMatch]), 200);
        }
        if (path.endsWith('/nearby')) {
          return http.Response(
            jsonEncode({
              'lat': 7.3,
              'lng': 126.1,
              'radius_m': 500,
              'places': nearby,
            }),
            200,
          );
        }
        if (request.method == 'POST') {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          return http.Response(
            jsonEncode({
              'candidate_id': 77,
              ...body,
              'review_status': 'staged',
            }),
            201,
          );
        }
        return http.Response(jsonEncode(_destinations), 200);
      }),
      tokenProvider: () async => 'test-access',
      apiBaseUrl: 'http://lakbay.test/api/v1',
    );

Future<void> _openMap(WidgetTester tester, ApiService api) async {
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

  testWidgets('an OpenStreetMap result can be added to the review queue', (
    tester,
  ) async {
    final log = <http.Request>[];
    final api = _api(log);
    addTearDown(api.close);
    await _openMap(tester, api);

    await tester.enterText(
      find.widgetWithText(TextField, 'Find a place to add (OpenStreetMap)'),
      'Tagbibinta',
    );
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();

    final search = log.lastWhere((r) => r.url.path.endsWith('/osm/search'));
    expect(search.url.queryParameters['name'], 'Tagbibinta');
    expect(search.url.queryParameters['radius_m'], '30000');

    await tester.tap(find.text('Tagbibinta Viewpoint'));
    await tester.pumpAndSettle();
    expect(find.text('New place'), findsOneWidget);
    expect(find.textContaining('From OpenStreetMap'), findsOneWidget);
    expect(find.byKey(const ValueKey('new-place-pin')), findsOneWidget);

    await tester.tap(find.text('Add to review queue'));
    await tester.pumpAndSettle();

    final post = log.lastWhere((r) => r.method == 'POST');
    expect(post.url.path, '/api/v1/admin/destination-candidates');
    final body = jsonDecode(post.body) as Map<String, dynamic>;
    expect(body['osm_id'], 123456);
    expect(body['osm_url'], 'https://www.openstreetmap.org/node/123456');
    expect(body['name'], 'Tagbibinta Viewpoint');
    expect(body['source_tag'], 'tourism=viewpoint');
    expect(body['suggested_category'], 'viewpoint');
    expect(
      find.text('Tagbibinta Viewpoint added to the review queue.'),
      findsOneWidget,
    );
    expect(find.text('New place'), findsNothing);
  });

  testWidgets('a dropped pin needs a name and warns about nearby places', (
    tester,
  ) async {
    final log = <http.Request>[];
    final api = _api(
      log,
      nearby: [
        {
          'kind': 'destination',
          'id': 26,
          'name': 'Pyalitan Falls',
          'distance_m': 90.4,
        },
      ],
    );
    addTearDown(api.close);
    await _openMap(tester, api);

    await tester.tap(find.widgetWithText(OutlinedButton, 'Add a place'));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('Click the map where the new place is'),
      findsOneWidget,
    );

    final map = tester.getRect(find.byType(FlutterMap));
    await tester.tapAt(map.center + const Offset(60, 120));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(find.textContaining('Pin dropped on the map'), findsOneWidget);
    expect(
      find.textContaining('Pyalitan Falls (destination, 90 m)'),
      findsOneWidget,
    );

    // Name is required.
    await tester.tap(find.text('Add to review queue'));
    await tester.pumpAndSettle();
    expect(find.text('Enter the place name.'), findsOneWidget);
    expect(log.where((r) => r.method == 'POST'), isEmpty);

    await tester.enterText(
      find.widgetWithText(TextField, 'Place name *'),
      'Coronobe Hot Spring',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Category'),
      'Hot Spring',
    );
    await tester.tap(find.text('Add to review queue'));
    await tester.pumpAndSettle();

    final post = log.lastWhere((r) => r.method == 'POST');
    expect(post.url.path, '/api/v1/admin/destination-candidates/manual');
    final body = jsonDecode(post.body) as Map<String, dynamic>;
    expect(body['name'], 'Coronobe Hot Spring');
    expect(body['suggested_category'], 'Hot Spring');
    expect(body['lat'], isA<double>());
    expect(body.containsKey('osm_id'), isFalse);
  });
}
