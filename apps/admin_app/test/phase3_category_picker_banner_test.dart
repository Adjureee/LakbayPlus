import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lakbay_admin/screens/destination_editor.dart';
import 'package:lakbay_admin/screens/destinations_screen.dart';
import 'package:lakbay_admin/services/api_service.dart';
import 'package:lakbay_admin/widgets/admin_widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

ApiService _api(Future<http.Response> Function(http.Request) handler) =>
    ApiService(
      client: MockClient(handler),
      tokenProvider: () async => 'test-access',
      apiBaseUrl: 'http://lakbay.test/api/v1',
    );

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    adminHasUnsavedChanges.value = false;
    adminIsSaving.value = false;
  });

  testWidgets('DestinationsScreen shows warning banner when categories are ungrouped (Other)',
      (tester) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final api = _api((req) async {
      if (req.url.path.endsWith('/destinations/facets')) {
        return http.Response(
          jsonEncode({
            'total_places': 2,
            'groups': [],
            'categories': [
              {
                'key': 'waterfall',
                'label': 'Waterfall',
                'count': 1,
                'group': 'nature_attractions',
              },
              {
                'key': 'observatory dome',
                'label': 'Observatory Dome',
                'count': 1,
                'group': 'other',
              },
            ],
          }),
          200,
        );
      }
      return http.Response(
        jsonEncode([
          {
            'destination_id': 1,
            'name': 'Aliwagwag Falls',
            'district': 'Davao Oriental',
            'location': 'Cateel',
            'category': 'Waterfall',
            'lat': 7.6,
            'lng': 126.3,
          },
          {
            'destination_id': 2,
            'name': 'Davao Sky Dome',
            'district': 'Davao City',
            'location': 'Davao City',
            'category': 'Observatory Dome',
            'lat': 7.06,
            'lng': 125.55,
          },
        ]),
        200,
      );
    });
    addTearDown(api.close);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: DestinationsScreen(api: api)),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.textContaining('Categories not in any traveler preference group'),
      findsOneWidget,
    );
    expect(find.textContaining('Observatory Dome (1)'), findsOneWidget);
  });

  testWidgets('DestinationEditor shows dropdown of existing categories and Add new option',
      (tester) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final api = _api((req) async {
      if (req.url.path.endsWith('/destinations/facets')) {
        return http.Response(
          jsonEncode({
            'total_places': 2,
            'groups': [],
            'categories': [
              {
                'key': 'waterfall',
                'label': 'Waterfall',
                'count': 1,
                'group': 'nature_attractions',
              },
              {
                'key': 'public plaza',
                'label': 'Public Plaza',
                'count': 1,
                'group': 'parks_recreation',
              },
            ],
          }),
          200,
        );
      }
      return http.Response('{}', 200);
    });
    addTearDown(api.close);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DestinationEditor(
            api: api,
            destination: const {
              'destination_id': 5,
              'name': 'Eden Trail',
              'category': 'Waterfall',
              'lat': 7.01,
              'lng': 125.43,
            },
            onSaved: (_) {},
            onCancel: () {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Waterfall'), findsWidgets);
    await tester.tap(find.byType(DropdownButtonFormField<String>).first);
    await tester.pumpAndSettle();

    expect(find.text('Public Plaza'), findsOneWidget);
    expect(find.text('+ Add new category…'), findsOneWidget);

    await tester.tap(find.text('+ Add new category…').last);
    await tester.pumpAndSettle();

    expect(find.text('New category name'), findsOneWidget);
  });
}
