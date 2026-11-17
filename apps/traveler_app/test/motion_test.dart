import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lakbay_travel/design/design.dart';
import 'package:lakbay_travel/main.dart';
import 'package:lakbay_travel/screens/onboarding_screen.dart';
import 'package:lakbay_travel/services/lakbay_api_catalog_service.dart';
import 'package:lakbay_travel/services/travel_repository.dart';
import 'package:lakbay_travel/widgets/lakbay_intro.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Motion is off in widget tests by default; these switch it on.
void main() {
  setUp(() {
    LkMotion.globallyEnabled = true;
    LakbayIntro.enabled = true;
  });
  tearDown(() {
    LkMotion.globallyEnabled = false;
    LakbayIntro.enabled = false;
  });

  testWidgets('the intro plays on open, then hands over to onboarding', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'lakbay_traveler_state_v1': jsonEncode({}),
    });
    final repo = TravelRepository(
      apiCatalog: LakbayApiCatalogService(baseUrlOverride: ''),
    );
    await tester.runAsync(repo.initialize);
    await tester.pumpWidget(LakbayTravelApp(repository: repo));

    expect(find.byType(LakbayIntro), findsOneWidget);
    expect(find.byType(OnboardingScreen), findsNothing);
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.byType(LakbayIntro), findsOneWidget);

    await tester.pump(LakbayIntro.length);
    await tester.pump(const Duration(milliseconds: 700));
    expect(find.byType(LakbayIntro), findsNothing);
    expect(find.byType(OnboardingScreen), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('tapping the intro skips it', (tester) async {
    var finished = 0;
    await tester.pumpWidget(
      MaterialApp(home: LakbayIntro(onFinished: () => finished++)),
    );
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byType(LakbayIntro));
    await tester.pump();
    expect(finished, 1);
  });

  testWidgets('with animations off the intro finishes at once', (tester) async {
    var finished = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: LakbayIntro(onFinished: () => finished++),
        ),
      ),
    );
    await tester.pump();
    expect(finished, 1);
  });

  testWidgets('rise-in and count-up reach their final state', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Column(
          children: [
            LkRiseIn(
              delay: LkRiseIn.stagger(2),
              child: const Text('Samal Island Weekend'),
            ),
            LkCountUp(value: 5, style: const TextStyle(fontSize: 40)),
          ],
        ),
      ),
    );
    final opacity = tester.widget<Opacity>(
      find.ancestor(
        of: find.text('Samal Island Weekend'),
        matching: find.byType(Opacity),
      ),
    );
    expect(opacity.opacity, 0);
    await tester.pump(const Duration(milliseconds: 150));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<Opacity>(
            find.ancestor(
              of: find.text('Samal Island Weekend'),
              matching: find.byType(Opacity),
            ),
          )
          .opacity,
      1,
    );
    expect(find.text('5'), findsOneWidget);
  });
}
