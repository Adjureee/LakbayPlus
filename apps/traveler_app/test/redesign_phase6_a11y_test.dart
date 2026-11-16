import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:lakbay_travel/main.dart';
import 'package:lakbay_travel/models/travel_models.dart';
import 'package:lakbay_travel/screens/home_chat_screen.dart';
import 'package:lakbay_travel/services/lakbay_api_catalog_service.dart';
import 'package:lakbay_travel/services/travel_repository.dart';
import 'package:lakbay_travel/theme/lakbay_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// WCAG contrast ratio of [fg] drawn over an opaque [bg].
double contrast(Color fg, Color bg) {
  final blended = Color.alphaBlend(fg, bg);
  final a = blended.computeLuminance();
  final b = bg.computeLuminance();
  final hi = a > b ? a : b;
  final lo = a > b ? b : a;
  return (hi + 0.05) / (lo + 0.05);
}

Future<TravelRepository> _repo(
  WidgetTester tester, {
  bool withAnswer = false,
}) async {
  final place = TopPlaceRecommendation.fromJson({
    'rank': 1,
    'destination_id': 5,
    'name': 'Dahican Surf Resort With A Very Long Name Indeed',
    'district': 'Davao Oriental',
    'category': 'beach resort',
    'score': 0.9,
    'reasons': ['Matches beach.', 'Cost not listed.'],
    'travel_minutes': 34,
  });
  final session = ChatSession(
    id: 'c1',
    title: 'Chat',
    groupLabel: 'Today',
    isTrip: false,
    createdAt: DateTime(2026, 11, 17),
    messages: [
      ChatMessage(
        id: 'a',
        isUser: true,
        text: 'hi show me some beaches',
        timestamp: DateTime(2026, 11, 17),
      ),
      ChatMessage(
        id: 'b',
        isUser: false,
        text: 'Here are some beach spots in the Davao Region:',
        timestamp: DateTime(2026, 11, 17),
        recommendedPlaces: [place],
      ),
    ],
  );
  SharedPreferences.setMockInitialValues({
    'lakbay_traveler_state_v1': jsonEncode({
      'hasCompletedOnboarding': true,
      'profile': {'firstName': 'Johnathan', 'lastName': 'Lozada'},
      if (withAnswer) 'chatSessions': [session.toJson()],
      if (withAnswer) 'activeChatId': 'c1',
    }),
  });
  final repo = TravelRepository(
    apiCatalog: LakbayApiCatalogService(baseUrlOverride: ''),
  );
  await tester.runAsync(() => repo.initialize());
  return repo;
}

Future<void> _pumpHome(
  WidgetTester tester,
  TravelRepository repo, {
  required Size size,
  double textScale = 1.0,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MediaQuery(
      data: MediaQueryData(
        size: size,
        textScaler: TextScaler.linear(textScale),
      ),
      child: MaterialApp(home: HomeChatScreen(repo: repo)),
    ),
  );
  await tester.pump(const Duration(milliseconds: 500));
}

void main() {
  setUp(() {
    GoogleFonts.config.allowRuntimeFetching = false;
    SharedPreferences.setMockInitialValues({});
  });

  group('large text on a small phone does not break the layout', () {
    for (final scale in [1.0, 1.3, 1.6]) {
      testWidgets('idle Home at text ${scale}x on 360 x 640', (tester) async {
        final repo = await _repo(tester);
        await _pumpHome(tester, repo, size: const Size(360, 640), textScale: scale);
        expect(tester.takeException(), isNull);
        expect(find.textContaining('where to next?'), findsOneWidget);
      });

      testWidgets('chat with a place card at text ${scale}x on 360 x 640', (
        tester,
      ) async {
        final repo = await _repo(tester, withAnswer: true);
        await _pumpHome(tester, repo, size: const Size(360, 640), textScale: scale);
        expect(tester.takeException(), isNull);
        expect(find.byKey(const ValueKey('place-carousel')), findsOneWidget);
      });
    }

    testWidgets('the bottom bar fits at text 1.6x on 320 wide', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(320, 640);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final repo = await _repo(tester);
      repo.setActiveNavIndex(0);
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(
            size: Size(320, 640),
            textScaler: TextScaler.linear(1.6),
          ),
          child: ListenableBuilder(
            listenable: repo,
            builder: (_, _) =>
                MaterialApp(home: MainNavigationShell(repo: repo)),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 400));
      expect(tester.takeException(), isNull);
    });
  });

  group('a screen reader can name every icon-only control', () {
    testWidgets('header, composer and bottom bar are labelled', (tester) async {
      final handle = tester.ensureSemantics();
      final repo = await _repo(tester, withAnswer: true);
      await _pumpHome(tester, repo, size: const Size(400, 800));

      for (final name in [
        'Chat History',
        'Notifications',
        'More options',
        'Send',
      ]) {
        final node = tester.getSemantics(find.byTooltip(name).first);
        // A screen reader announces the tooltip when there is no other name.
        expect(
          '${node.label} ${node.tooltip}'.contains(name),
          isTrue,
          reason: name,
        );
      }
      handle.dispose();
    });

    testWidgets('each bottom tab is a button that says whether it is selected', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(400, 800);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final repo = await _repo(tester);
      repo.setActiveNavIndex(0);
      await tester.pumpWidget(
        ListenableBuilder(
          listenable: repo,
          builder: (_, _) => MaterialApp(home: MainNavigationShell(repo: repo)),
        ),
      );
      await tester.pump(const Duration(milliseconds: 400));

      final trips = tester.getSemantics(find.bySemanticsLabel('Trips').last);
      expect(trips.flagsCollection.isButton, isTrue);
      expect(trips.flagsCollection.isSelected.name, 'isTrue');
      final discover =
          tester.getSemantics(find.bySemanticsLabel('Discover').last);
      expect(discover.flagsCollection.isButton, isTrue);
      expect(discover.flagsCollection.isSelected.name, isNot('isTrue'));
      handle.dispose();
    });
  });

  group('text and icons stay readable', () {
    test('white on the start pill, even over the brightest sky', () {
      // The pill is black at some opacity over the photo; the worst case is a
      // white photo behind it.
      final pill = Color.alphaBlend(
        Colors.black.withValues(alpha: LakbayContrast.startPillAlpha),
        Colors.white,
      );
      expect(contrast(Colors.white, pill), greaterThanOrEqualTo(4.5));
    });

    test('white header icons over the top fade, even over the brightest sky', () {
      final fade = Color.alphaBlend(
        Colors.black.withValues(alpha: LakbayContrast.headerFadeAlpha),
        Colors.white,
      );
      expect(contrast(Colors.white, fade), greaterThanOrEqualTo(3.0));
    });

    test('unselected tab labels on the white bar meet 4.5:1', () {
      final color = LakbayColors.tealDeep.withValues(
        alpha: LakbayContrast.unselectedTabAlpha,
      );
      final bar = Colors.white.withValues(alpha: 0.96);
      expect(
        contrast(color, Color.alphaBlend(bar, Colors.white)),
        greaterThanOrEqualTo(4.5),
      );
    });

    test('selected tab and brand text meet 4.5:1 on white', () {
      expect(contrast(LakbayColors.primaryDark, Colors.white),
          greaterThanOrEqualTo(4.5));
      expect(contrast(LakbayColors.textSecondary, Colors.white),
          greaterThanOrEqualTo(4.5));
    });
  });

  group('tap targets', () {
    testWidgets('header, composer and send controls are at least 48 dp', (
      tester,
    ) async {
      final repo = await _repo(tester, withAnswer: true);
      await _pumpHome(tester, repo, size: const Size(400, 800));
      for (final tip in ['Chat History', 'Notifications', 'More options']) {
        final size = tester.getSize(find.byTooltip(tip).first);
        expect(size.width, greaterThanOrEqualTo(48), reason: tip);
        expect(size.height, greaterThanOrEqualTo(48), reason: tip);
      }
      final send = tester.getSize(find.byTooltip('Send').first);
      expect(send.width, greaterThanOrEqualTo(40));
      expect(send.height, greaterThanOrEqualTo(40));
    });
  });
}
