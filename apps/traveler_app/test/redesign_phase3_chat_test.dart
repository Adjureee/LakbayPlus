import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:lakbay_travel/models/travel_models.dart';
import 'package:lakbay_travel/screens/home_chat_screen.dart';
import 'package:lakbay_travel/services/lakbay_api_catalog_service.dart';
import 'package:lakbay_travel/services/travel_repository.dart';
import 'package:lakbay_travel/theme/lakbay_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

TopPlaceRecommendation _place(String name, {List<String>? reasons}) =>
    TopPlaceRecommendation.fromJson({
      'rank': 1,
      'destination_id': 5,
      'name': name,
      'district': 'Davao Oriental',
      'category': 'beach resort',
      'score': 0.9,
      'reasons': reasons ??
          [
            'Matches beach, beach resort.',
            'About 34 min by car (straight-line estimate).',
            'Cost not listed.',
          ],
      'travel_minutes': 34,
    });

Future<TravelRepository> _chatRepo(WidgetTester tester) async {
  final session = ChatSession(
    id: 'c1',
    title: 'Beaches',
    groupLabel: 'Today',
    isTrip: false,
    createdAt: DateTime(2026, 11, 17),
    messages: [
      ChatMessage(
        id: 'm1',
        isUser: true,
        text: 'hi show me some beaches',
        timestamp: DateTime(2026, 11, 17),
      ),
      ChatMessage(
        id: 'm2',
        isUser: false,
        text: 'Here are some beach spots in the Davao Region:',
        timestamp: DateTime(2026, 11, 17),
        recommendedPlaces: [
          _place('Dahican Surf Resort'),
          _place('Pujada Bay Cove', reasons: ['Matches beach.']),
        ],
      ),
    ],
  );
  SharedPreferences.setMockInitialValues({
    'lakbay_traveler_state_v1': jsonEncode({
      'hasCompletedOnboarding': true,
      'chatSessions': [session.toJson()],
      'activeChatId': 'c1',
    }),
  });
  final repo = TravelRepository(
    apiCatalog: LakbayApiCatalogService(baseUrlOverride: ''),
  );
  await tester.runAsync(() => repo.initialize());
  return repo;
}

void main() {
  setUp(() {
    GoogleFonts.config.allowRuntimeFetching = false;
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('an answer with places is a compact carousel whose buttons stay visible on a small phone', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(360, 780);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final repo = await _chatRepo(tester);
    await tester.pumpWidget(MaterialApp(home: HomeChatScreen(repo: repo)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.byKey(const ValueKey('place-carousel')), findsOneWidget);
    expect(find.text('Recommended places'), findsOneWidget);
    // Name, one info line and one honest price line.
    expect(find.text('Dahican Surf Resort'), findsOneWidget);
    expect(find.text('Davao Oriental • ~34 min'), findsWidgets);
    expect(find.text('Cost not listed.'), findsOneWidget);
    // The long reasons are behind "Why this?", not on the card.
    expect(find.textContaining('straight-line'), findsNothing);
    // Both actions are on screen without scrolling.
    final view = find.text('View').first;
    final add = find.text('+ Add').first;
    expect(tester.getBottomLeft(view).dy, lessThan(780));
    expect(tester.getBottomLeft(add).dy, lessThan(780));
  });

  testWidgets('"Why this?" shows every reason, in the server\'s words', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(360, 780);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final repo = await _chatRepo(tester);
    await tester.pumpWidget(MaterialApp(home: HomeChatScreen(repo: repo)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    await tester.tap(find.byKey(const ValueKey('why-Dahican Surf Resort')));
    await tester.pumpAndSettle();
    expect(find.text('Why Dahican Surf Resort?'), findsOneWidget);
    expect(find.textContaining('straight-line estimate'), findsOneWidget);
    expect(find.text('Matches beach, beach resort.'), findsOneWidget);
  });

  testWidgets('while reading an answer: one small mark, no category strip, a + menu in the composer', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(360, 780);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final repo = await _chatRepo(tester);
    await tester.pumpWidget(MaterialApp(home: HomeChatScreen(repo: repo)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    // The compass appears once, beside the answer (not also in the composer).
    expect(find.byType(LakbayAvatar), findsOneWidget);
    expect(find.text('Browse by category'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('chat-plus-menu')));
    await tester.pumpAndSettle();
    expect(find.text('New chat'), findsOneWidget);
    expect(find.text('Within budget'), findsOneWidget);
    expect(find.text('Set starting place'), findsWidgets);
  });
}
