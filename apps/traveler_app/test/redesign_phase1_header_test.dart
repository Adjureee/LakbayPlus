import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lakbay_travel/screens/home_chat_screen.dart';
import 'package:lakbay_travel/services/lakbay_api_catalog_service.dart';
import 'package:lakbay_travel/services/travel_repository.dart';
import 'package:lakbay_travel/widgets/notifications_sheet.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<TravelRepository> _repo(
  WidgetTester tester, {
  int unread = 0,
}) async {
  SharedPreferences.setMockInitialValues({
    'lakbay_traveler_state_v1': jsonEncode({
      'hasCompletedOnboarding': true,
      'authSession': {
        'accessToken': 'tok',
        'refreshToken': 'ref',
        'userId': 1,
        'email': 'a@b.ph',
        'fullName': 'A B',
      },
    }),
  });
  final repo = TravelRepository(
    apiCatalog: LakbayApiCatalogService(
      baseUrlOverride: 'https://api.lakbay.test/api/v1',
      client: MockClient((request) async {
        if (request.url.path == '/api/v1/notifications/unread-count') {
          return http.Response(jsonEncode({'unread_count': unread}), 200);
        }
        return http.Response('[]', 200);
      }),
    ),
  );
  await tester.runAsync(() => repo.initialize());
  await tester.runAsync(() => repo.refreshNotifications());
  return repo;
}

void main() {
  setUp(() {
    GoogleFonts.config.allowRuntimeFetching = false;
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('the bell is a plain icon: no circle, no shadow, a 48 dp tap area', (
    tester,
  ) async {
    final repo = await _repo(tester);
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: NotificationBellButton(repo: repo))),
    );
    await tester.pump();

    expect(find.byTooltip('Notifications'), findsOneWidget);
    expect(find.byType(Material).evaluate().where((e) {
      final m = e.widget as Material;
      return m.shape is CircleBorder && m.elevation > 0;
    }), isEmpty);
    final size = tester.getSize(find.byType(SizedBox).first);
    expect(size.width, greaterThanOrEqualTo(48));
    expect(size.height, greaterThanOrEqualTo(48));
    expect(find.byKey(const ValueKey('unread-badge')), findsNothing);
  });

  testWidgets('unread shows a small dot, and "9+" past nine', (tester) async {
    final few = await _repo(tester, unread: 3);
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: NotificationBellButton(repo: few))),
    );
    await tester.pump();
    expect(find.byKey(const ValueKey('unread-badge')), findsOneWidget);
    expect(find.text('3'), findsNothing);
    expect(find.text('9+'), findsNothing);

    final many = await _repo(tester, unread: 14);
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: NotificationBellButton(repo: many))),
    );
    await tester.pump();
    expect(find.text('9+'), findsOneWidget);
  });

  testWidgets('the header shows one start-place pill with a name, never raw coordinates', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(900, 2000);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final repo = await _repo(tester);
    await tester.pumpWidget(MaterialApp(home: HomeChatScreen(repo: repo)));
    await tester.pump();
    expect(find.text('Set starting place'), findsOneWidget);

    repo.setManualOrigin(label: 'Tubaon, Tarragona', lat: 6.9, lng: 126.2);
    await tester.pump();
    expect(find.text('Start: Tubaon, Tarragona'), findsOneWidget);

    // A pin with no name shows a plain label, not "7.092°, 126.399°".
    repo.setManualOrigin(label: '', lat: 7.092, lng: 126.399);
    await tester.pump();
    expect(find.text('Start: Pinned location'), findsOneWidget);
    expect(find.textContaining('126.399'), findsNothing);
    // And there is no second start control under the composer.
    expect(find.textContaining('Start:'), findsOneWidget);
  });
}
