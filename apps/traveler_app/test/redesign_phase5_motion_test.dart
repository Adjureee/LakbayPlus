import 'dart:convert';

import 'package:animations/animations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:lakbay_travel/core/lakbay_motion.dart';
import 'package:lakbay_travel/main.dart';
import 'package:lakbay_travel/models/travel_models.dart';
import 'package:lakbay_travel/screens/home_chat_screen.dart';
import 'package:lakbay_travel/screens/trip_detail_screen.dart';
import 'package:lakbay_travel/services/lakbay_api_catalog_service.dart';
import 'package:lakbay_travel/services/travel_repository.dart';
import 'package:lakbay_travel/theme/lakbay_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<TravelRepository> _repo(
  WidgetTester tester, {
  List<ChatMessage> messages = const [],
}) async {
  final session = ChatSession(
    id: 'c1',
    title: 'Chat',
    groupLabel: 'Today',
    isTrip: false,
    createdAt: DateTime(2026, 11, 17),
    messages: messages,
  );
  SharedPreferences.setMockInitialValues({
    'lakbay_traveler_state_v1': jsonEncode({
      'hasCompletedOnboarding': true,
      if (messages.isNotEmpty) 'chatSessions': [session.toJson()],
      if (messages.isNotEmpty) 'activeChatId': 'c1',
    }),
  });
  final repo = TravelRepository(
    apiCatalog: LakbayApiCatalogService(baseUrlOverride: ''),
  );
  await tester.runAsync(() => repo.initialize());
  return repo;
}

ChatMessage _msg(
  String id,
  String text, {
  bool user = false,
  List<TopPlaceRecommendation>? places,
}) =>
    ChatMessage(
      id: id,
      isUser: user,
      text: text,
      timestamp: DateTime(2026, 11, 17),
      recommendedPlaces: places ?? const [],
    );

void main() {
  setUp(() {
    GoogleFonts.config.allowRuntimeFetching = false;
    SharedPreferences.setMockInitialValues({});
  });

  group('the motion rules', () {
    testWidgets('durations stay in range and drop to zero when animations are off', (
      tester,
    ) async {
      for (final d in [
        LakbayMotion.quick,
        LakbayMotion.standard,
        LakbayMotion.page,
        LakbayMotion.container,
        LakbayMotion.stagger,
      ]) {
        expect(d.inMilliseconds, inInclusiveRange(60, 400));
      }
      late BuildContext normal;
      late BuildContext reduced;
      await tester.pumpWidget(
        MaterialApp(
          home: Column(
            children: [
              Builder(builder: (c) {
                normal = c;
                return const SizedBox();
              }),
              MediaQuery(
                data: const MediaQueryData(disableAnimations: true),
                child: Builder(builder: (c) {
                  reduced = c;
                  return const SizedBox();
                }),
              ),
            ],
          ),
        ),
      );
      expect(LakbayMotion.of(normal, LakbayMotion.standard), LakbayMotion.standard);
      expect(LakbayMotion.of(reduced, LakbayMotion.standard), Duration.zero);
    });

    testWidgets('pushed screens use the shared-axis transition', (tester) async {
      final builders = LakbayTheme.lightTheme.pageTransitionsTheme.builders;
      expect(
        builders[TargetPlatform.android],
        isA<SharedAxisPageTransitionsBuilder>(),
      );
    });
  });

  testWidgets('switching tabs fades the new tab in', (tester) async {
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

    double opacity() => tester
        .widget<FadeTransition>(
          find
              .descendant(
                of: find.byType(FadeThroughIndexedStack),
                matching: find.byType(FadeTransition),
              )
              .first,
        )
        .opacity
        .value;
    expect(opacity(), 1.0);

    repo.setActiveNavIndex(1);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    expect(opacity(), lessThan(1.0));
    await tester.pump(const Duration(milliseconds: 400));
    expect(opacity(), 1.0);
  });

  testWidgets('messages already in a chat are simply there', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(400, 900);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final repo = await _repo(
      tester,
      messages: [
        _msg('a', 'first message', user: true),
        _msg('b', 'an old answer'),
      ],
    );
    await tester.pumpWidget(MaterialApp(home: HomeChatScreen(repo: repo)));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(const ValueKey('enter-a')), findsNothing);
    expect(find.byKey(const ValueKey('enter-b')), findsNothing);
    expect(find.text('an old answer'), findsOneWidget);
  });

  testWidgets('LakbayEntrance starts hidden and ends fully shown, after its delay', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: LakbayEntrance(
          delay: Duration(milliseconds: 60),
          child: Text('hello'),
        ),
      ),
    );
    double opacity() => tester
        .widget<FadeTransition>(find.byType(FadeTransition).last)
        .opacity
        .value;
    expect(opacity(), 0.0);
    await tester.pump(const Duration(milliseconds: 30));
    expect(opacity(), 0.0);
    await tester.pump(const Duration(milliseconds: 80));
    await tester.pump(const Duration(milliseconds: 300));
    expect(opacity(), 1.0);
  });

  testWidgets('with animations off an entrance is shown at once', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(disableAnimations: true),
          child: LakbayEntrance(
            delay: Duration(milliseconds: 60),
            child: Text('hello'),
          ),
        ),
      ),
    );
    final opacity = tester
        .widget<FadeTransition>(find.byType(FadeTransition).last)
        .opacity
        .value;
    expect(opacity, 1.0);
  });

  testWidgets('View opens the place screen from its card', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(360, 780);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final place = TopPlaceRecommendation.fromJson({
      'rank': 1,
      'destination_id': 5,
      'name': 'Dahican Surf Resort',
      'district': 'Davao Oriental',
      'category': 'beach resort',
      'score': 0.9,
      'reasons': ['Cost not listed.'],
      'travel_minutes': 34,
    });
    final repo = await _repo(
      tester,
      messages: [
        _msg('a', 'beaches', user: true),
        _msg('b', 'Here you go', places: [place]),
      ],
    );
    await tester.pumpWidget(MaterialApp(home: HomeChatScreen(repo: repo)));
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.byType(OpenContainer<void>), findsOneWidget);
    await tester.tap(find.text('View'));
    // The card grows into the screen over 350 ms. (The place screen has a
    // looping indicator, so pumpAndSettle would never settle.)
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(TripDetailScreen), findsOneWidget);
  });
}
