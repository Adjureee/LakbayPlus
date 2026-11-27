import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lakbay_admin/screens/destinations_screen.dart';
import 'package:lakbay_admin/services/api_service.dart';
import 'package:lakbay_admin/widgets/admin_widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    adminIsSaving.value = false;
  });

  testWidgets('detail view renders Video badge, attribution, and Open clip button', (
    tester,
  ) async {
    final destination = <String, dynamic>{
      'destination_id': 21,
      'name': 'Mount Apo Trail',
      'district': 'Davao del Sur',
      'category': 'Mountain',
      'lat': 6.9875,
      'lng': 125.2708,
      'is_active': true,
      'image_url': null,
      'image_credit': 'DENR Davao',
      'image_license': 'CC-BY-4.0',
      'image_source_url': 'https://commons.wikimedia.org/wiki/File:MtApo.jpg',
      'media_url':
          'https://res.cloudinary.com/demo/video/upload/v1/lakbay/destinations/21/apo.mp4',
      'media_type': 'video',
      'media_duration_seconds': 11.4,
    };

    final api = ApiService(
      client: MockClient((_) async => http.Response('[]', 200)),
      tokenProvider: () async => 'test-access',
      apiBaseUrl: 'http://lakbay.test/api/v1',
    );
    addTearDown(api.close);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DestinationsScreen(
            api: api,
            initialDestination: destination,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Video (11.4s)'), findsOneWidget);
    expect(find.text('Open clip'), findsOneWidget);
    expect(find.text('Upload GIF / video'), findsOneWidget);
    expect(find.text('DENR Davao'), findsOneWidget);
    expect(find.text('CC-BY-4.0'), findsOneWidget);
    expect(
      find.text('https://commons.wikimedia.org/wiki/File:MtApo.jpg'),
      findsOneWidget,
    );
  });

  testWidgets('map side panel renders GIF badge and Open clip when selected', (
    tester,
  ) async {
    final gifDestination = <String, dynamic>{
      'destination_id': 22,
      'name': 'Samal Reef',
      'district': 'Samal Island',
      'category': 'Beach',
      'lat': 7.08,
      'lng': 125.71,
      'is_active': true,
      'image_url': null,
      'media_url':
          'https://res.cloudinary.com/demo/image/upload/v1/lakbay/destinations/22/reef.gif',
      'media_type': 'gif',
    };

    final api = ApiService(
      client: MockClient((request) async {
        if (request.url.path.endsWith('/destinations/facets')) {
          return http.Response(
            jsonEncode({'total_places': 0, 'groups': [], 'categories': []}),
            200,
          );
        }
        return http.Response(jsonEncode([gifDestination]), 200);
      }),
      tokenProvider: () async => 'test-access',
      apiBaseUrl: 'http://lakbay.test/api/v1',
    );
    addTearDown(api.close);

    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1440, 1400);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: DestinationsScreen(api: api))),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Map'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('destination-pin-22')));
    await tester.pumpAndSettle();

    expect(find.text('GIF'), findsOneWidget);
    expect(find.text('Open clip'), findsOneWidget);
    expect(find.text('Upload GIF / video'), findsOneWidget);
  });
}
