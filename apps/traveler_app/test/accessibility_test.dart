import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lakbay_travel/design/design.dart';
import 'package:lakbay_travel/main.dart';
import 'package:lakbay_travel/models/travel_models.dart';
import 'package:lakbay_travel/screens/auth_screen.dart';
import 'package:lakbay_travel/screens/live_day_screen.dart';
import 'package:lakbay_travel/screens/trip_detail_screen.dart';
import 'package:lakbay_travel/services/lakbay_api_catalog_service.dart';
import 'package:lakbay_travel/services/location_service.dart';
import 'package:lakbay_travel/services/travel_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Phase 5: every main screen at phone size, 130% text and animations off,
/// checked with Flutter's accessibility guidelines.
Future<TravelRepository> _repo({required bool signedIn}) async {
  SharedPreferences.setMockInitialValues({
    'lakbay_traveler_state_v1': jsonEncode({
      'hasCompletedOnboarding': signedIn,
      if (signedIn)
        'authSession': {
          'accessToken': 'a11y-token',
          'refreshToken': 'r',
          'userId': 7,
          'fullName': 'Ana Reyes',
          'email': 'ana@example.com',
        },
    }),
  });
  return TravelRepository(
    apiCatalog: LakbayApiCatalogService(baseUrlOverride: ''),
    locationService: LocationService(
      customFetcher: () async => const LocationResult(
        granted: false,
        statusMessage: 'Declined',
      ),
    ),
  );
}

Future<void> _setUpPhone(WidgetTester tester) async {
  tester.view
    ..physicalSize = const Size(412, 900)
    ..devicePixelRatio = 1;
  tester.platformDispatcher
    ..textScaleFactorTestValue = 1.3
    ..accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearAllTestValues);
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 3; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump(const Duration(milliseconds: 300));
  }
}

Future<void> _checkGuidelines(WidgetTester tester, String screen) async {
  expect(tester.takeException(), isNull, reason: '$screen threw');
  await expectLater(
    tester,
    meetsGuideline(androidTapTargetGuideline),
    reason: '$screen: 48dp targets',
  );
  await expectLater(
    tester,
    meetsGuideline(labeledTapTargetGuideline),
    reason: '$screen: labelled targets',
  );
  await expectLater(
    tester,
    meetsGuideline(textContrastGuideline),
    reason: '$screen: text contrast',
  );
}

ItineraryTrip _samal(TravelRepository repo, {DateTime? start}) =>
    repo.generateCustomTrip(
      title: 'Samal Island Weekend',
      destination: 'Samal Island, Davao del Norte',
      daysCount: 3,
      vibe: 'Beaches & islands',
    ).copyWith(startDate: start);

void main() {
  testWidgets('main tabs at 130% text', (tester) async {
    await _setUpPhone(tester);
    final handle = tester.ensureSemantics();
    final repo = await _repo(signedIn: true);
    await tester.runAsync(repo.initialize);
    repo.saveTripToMyTrips(
      _samal(repo, start: DateTime.now().add(const Duration(days: 5))),
    );

    await tester.pumpWidget(LakbayTravelApp(repository: repo));
    const names = ['Trips', 'Discover', 'Chat', 'Memories', 'Profile'];
    for (var i = 0; i < names.length; i++) {
      repo.setActiveNavIndex(i);
      await _settle(tester);
      await _checkGuidelines(tester, names[i]);
    }

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
    handle.dispose();
  });

  testWidgets('trip detail and live day at 130% text', (tester) async {
    await _setUpPhone(tester);
    final handle = tester.ensureSemantics();
    final repo = await _repo(signedIn: true);
    await tester.runAsync(repo.initialize);
    final trip = _samal(
      repo,
      start: DateTime.now().subtract(const Duration(days: 1)),
    );

    await tester.pumpWidget(
      MaterialApp(home: TripDetailScreen(repo: repo, trip: trip)),
    );
    await _settle(tester);
    await _checkGuidelines(tester, 'Trip detail');

    await tester.pumpWidget(
      MaterialApp(home: LiveDayScreen(repo: repo, trip: trip)),
    );
    await _settle(tester);
    await _checkGuidelines(tester, 'Live day');

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
    handle.dispose();
  });

  testWidgets('welcome and sign-in at 130% text', (tester) async {
    await _setUpPhone(tester);
    final handle = tester.ensureSemantics();
    final repo = await _repo(signedIn: false);
    await tester.runAsync(repo.initialize);

    await tester.pumpWidget(LakbayTravelApp(repository: repo));
    await _settle(tester);
    await _checkGuidelines(tester, 'Welcome');

    await tester.pumpWidget(
      MaterialApp(home: AuthScreen(repo: repo, initialRegisterMode: true)),
    );
    await _settle(tester);
    await _checkGuidelines(tester, 'Sign-in');

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
    handle.dispose();
  });

  testWidgets('cards work from the keyboard with a visible focus ring', (
    tester,
  ) async {
    var taps = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: LakbayDesignTheme.dark,
        home: Scaffold(
          body: Center(
            child: LkPressable(
              onTap: () => taps++,
              child: const SizedBox(
                width: 200,
                height: 80,
                child: Text('Samal Island Weekend'),
              ),
            ),
          ),
        ),
      ),
    );
    FocusManager.instance.highlightStrategy =
        FocusHighlightStrategy.alwaysTraditional;
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();

    final ring = tester.widget<DecoratedBox>(
      find.descendant(
        of: find.byType(LkPressable),
        matching: find.byType(DecoratedBox),
      ),
    );
    final border = (ring.decoration as BoxDecoration).border as Border?;
    expect(border?.top.color, LkColors.mango);

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(taps, 1);
    FocusManager.instance.highlightStrategy = FocusHighlightStrategy.automatic;
  });
}
