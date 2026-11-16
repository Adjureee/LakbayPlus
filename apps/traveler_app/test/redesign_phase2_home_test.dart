import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:lakbay_travel/screens/home_chat_screen.dart';
import 'package:lakbay_travel/services/lakbay_api_catalog_service.dart';
import 'package:lakbay_travel/services/travel_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<TravelRepository> _repo(WidgetTester tester) async {
  SharedPreferences.setMockInitialValues({
    'lakbay_traveler_state_v1': jsonEncode({
      'hasCompletedOnboarding': true,
      'profile': {'firstName': 'John', 'lastName': 'Lozada'},
    }),
  });
  final repo = TravelRepository(
    apiCatalog: LakbayApiCatalogService(baseUrlOverride: ''),
  );
  await tester.runAsync(() => repo.initialize());
  return repo;
}

Future<void> _pump(WidgetTester tester, TravelRepository repo) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(900, 2000);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    ListenableBuilder(
      listenable: repo,
      builder: (_, _) => MaterialApp(home: HomeChatScreen(repo: repo)),
    ),
  );
  await tester.pump();
}

void main() {
  setUp(() {
    GoogleFonts.config.allowRuntimeFetching = false;
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('the idle Home has one short headline and one composer', (tester) async {
    final repo = await _repo(tester);
    await _pump(tester, repo);

    expect(find.textContaining('where to next?'), findsOneWidget);
    expect(find.text('wake up'), findsNothing);
    expect(find.byType(TextField), findsOneWidget);
    // The big separate mic button and its caption are gone.
    expect(find.text('Tap and tell Lakbay+'), findsNothing);
    expect(find.byKey(const ValueKey('composer-mic')), findsOneWidget);
    // Two suggestion chips, not three, and no start-place chip among them.
    expect(find.text('Surprise me'), findsOneWidget);
    expect(find.textContaining('Things to do in'), findsOneWidget);
    expect(find.text('Set starting place (search or pin)'), findsNothing);
  });

  testWidgets('Within budget lives in the + menu and shows a chip only while on', (
    tester,
  ) async {
    final repo = await _repo(tester);
    await _pump(tester, repo);

    expect(find.byKey(const ValueKey('budget-chip')), findsNothing);
    expect(repo.strictBudgetFilter, isFalse);

    await tester.tap(find.byKey(const ValueKey('composer-plus-menu')));
    await tester.pumpAndSettle();
    expect(find.text('New chat'), findsOneWidget);
    expect(find.text('Set starting place'), findsWidgets);
    await tester.tap(find.text('Within budget'), warnIfMissed: false);
    await tester.pumpAndSettle();

    expect(repo.strictBudgetFilter, isTrue);
    expect(find.byKey(const ValueKey('budget-chip')), findsOneWidget);

    // The chip's own close button turns it off again.
    await tester.tap(find.descendant(of: find.byKey(const ValueKey('budget-chip')), matching: find.byType(Icon)).last);
    await tester.pump();
    expect(repo.strictBudgetFilter, isFalse);
    expect(find.byKey(const ValueKey('budget-chip')), findsNothing);
  });

  testWidgets('without a name the headline still reads naturally', (tester) async {
    SharedPreferences.setMockInitialValues({
      'lakbay_traveler_state_v1': jsonEncode({'hasCompletedOnboarding': true}),
    });
    final repo = TravelRepository(
      apiCatalog: LakbayApiCatalogService(baseUrlOverride: ''),
    );
    await tester.runAsync(() => repo.initialize());
    await _pump(tester, repo);
    expect(find.textContaining('where to next?'), findsOneWidget);
    expect(find.textContaining('Hi ,'), findsNothing);
  });
}
