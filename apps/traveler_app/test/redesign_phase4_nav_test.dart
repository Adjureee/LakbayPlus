import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:lakbay_travel/main.dart';
import 'package:lakbay_travel/models/travel_models.dart';
import 'package:lakbay_travel/services/lakbay_api_catalog_service.dart';
import 'package:lakbay_travel/services/travel_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<TravelRepository> _repo(WidgetTester tester, {int messages = 0}) async {
  final session = ChatSession(
    id: 'c1',
    title: 'Long chat',
    groupLabel: 'Today',
    isTrip: false,
    createdAt: DateTime(2026, 11, 17),
    messages: [
      for (var i = 0; i < messages; i++)
        ChatMessage(
          id: 'm$i',
          isUser: i.isEven,
          text: 'Message number $i with a few words so it takes some room.',
          timestamp: DateTime(2026, 11, 17),
        ),
    ],
  );
  SharedPreferences.setMockInitialValues({
    'lakbay_traveler_state_v1': jsonEncode({
      'hasCompletedOnboarding': true,
      if (messages > 0) 'chatSessions': [session.toJson()],
      if (messages > 0) 'activeChatId': 'c1',
    }),
  });
  final repo = TravelRepository(
    apiCatalog: LakbayApiCatalogService(baseUrlOverride: ''),
  );
  await tester.runAsync(() => repo.initialize());
  return repo;
}

Future<void> _pumpShell(WidgetTester tester, TravelRepository repo) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(400, 800);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    ListenableBuilder(
      listenable: repo,
      builder: (_, _) => MaterialApp(home: MainNavigationShell(repo: repo)),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

Color? _labelColor(WidgetTester tester, String label) {
  final text = tester.widget<Text>(find.text(label).first);
  return text.style?.color;
}

void main() {
  setUp(() {
    GoogleFonts.config.allowRuntimeFetching = false;
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('the selected tab is filled and bold; the others are outline at 60%', (
    tester,
  ) async {
    final repo = await _repo(tester);
    repo.setActiveNavIndex(0);
    await _pumpShell(tester, repo);

    // Selected Trips uses the filled map icon, the others the outline ones.
    Finder navIcon(String label, IconData icon) => find.descendant(
          of: find.ancestor(
            of: find.text(label),
            matching: find.byType(GestureDetector),
          ).first,
          matching: find.byIcon(icon),
        );
    expect(navIcon('Trips', Icons.map), findsOneWidget);
    expect(navIcon('Trips', Icons.map_outlined), findsNothing);
    expect(navIcon('Discover', Icons.ondemand_video_outlined), findsOneWidget);
    expect(navIcon('Memories', Icons.photo_library_outlined), findsOneWidget);

    final selected = _labelColor(tester, 'Trips')!;
    final other = _labelColor(tester, 'Discover')!;
    expect(selected.a, 1.0);
    expect(other.a, closeTo(0.6, 0.02));

    // No pill behind the selected tab.
    final pills = find.byWidgetPredicate(
      (w) =>
          w is Container &&
          w.decoration is BoxDecoration &&
          (w.decoration as BoxDecoration).color == const Color(0xFFD7F0EC) &&
          (w.decoration as BoxDecoration).borderRadius ==
              BorderRadius.circular(22),
    );
    expect(pills, findsNothing);
  });

  testWidgets('every tab keeps a 48 dp tap target', (tester) async {
    final repo = await _repo(tester);
    repo.setActiveNavIndex(0);
    await _pumpShell(tester, repo);
    for (final label in ['Trips', 'Discover', 'Memories']) {
      final box = tester.getRect(
        find.ancestor(of: find.text(label), matching: find.byType(Container)).first,
      );
      expect(box.height, greaterThanOrEqualTo(48), reason: label);
    }
  });

  testWidgets('scrolling down through a chat slides the bar away and scrolling up brings it back', (
    tester,
  ) async {
    final repo = await _repo(tester, messages: 40);
    repo.setActiveNavIndex(2);
    await _pumpShell(tester, repo);

    expect(repo.chatNavHidden.value, isFalse);
    double slideY() =>
        tester.widget<AnimatedSlide>(find.byType(AnimatedSlide).first).offset.dy;
    expect(slideY(), 0);

    // Dragging the list up scrolls down through the conversation.
    await tester.drag(find.byType(ListView).first, const Offset(0, -300));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(repo.chatNavHidden.value, isTrue);
    expect(slideY(), greaterThan(1));

    // Dragging down scrolls back up.
    await tester.drag(find.byType(ListView).first, const Offset(0, 200));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(repo.chatNavHidden.value, isFalse);
    expect(slideY(), 0);
  });

  testWidgets('the bar stays put on other tabs even if the chat flag is set', (
    tester,
  ) async {
    final repo = await _repo(tester);
    repo.setActiveNavIndex(0);
    await _pumpShell(tester, repo);
    repo.chatNavHidden.value = true;
    await tester.pump(const Duration(milliseconds: 400));
    expect(
      tester.widget<AnimatedSlide>(find.byType(AnimatedSlide).first).offset.dy,
      0,
    );
  });
}
