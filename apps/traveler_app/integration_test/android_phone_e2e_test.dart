import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:lakbay_travel/main.dart';
import 'package:lakbay_travel/screens/explore_screen.dart';
import 'package:lakbay_travel/services/env_config.dart';
import 'package:lakbay_travel/services/voice_input_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> _pumpUntil(
  WidgetTester tester,
  Finder finder, {
  Duration timeout = const Duration(seconds: 25),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 200));
    if (finder.evaluate().isNotEmpty) {
      return;
    }
  }
  throw TestFailure('Timed out waiting for widget: $finder');
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Android phone E2E: .env, Render auth, account switch, 5 tabs, and voice check',
      (tester) async {
    final originalOnError = FlutterError.onError;
    final frameworkErrors = <FlutterErrorDetails>[];
    FlutterError.onError = (details) {
      frameworkErrors.add(details);
      originalOnError?.call(details);
    };

    try {
      await EnvConfig.load();
      expect(EnvConfig.hasLakbayApi, isTrue,
          reason: '.env LAKBAY_API_BASE_URL must be bundled in Android APK');
      expect(EnvConfig.lakbayApiBaseUrl, startsWith('https://'));
      expect(EnvConfig.hasGoogleOAuth, isTrue,
          reason: '.env GOOGLE_OAUTH_CLIENT_ID must be bundled in Android APK');
      expect(const VoiceInputService().isSupported, isTrue);

      final prefs = await SharedPreferences.getInstance();
      await prefs.clear();

      await tester.pumpWidget(const LakbayTravelApp());
      // Use bounded pumping because OnboardingScreen runs an infinite pulse animation.
      await _pumpUntil(tester, find.text('Get started'));

      // Step 0 onboarding should render Get started + Sign in link cleanly.
      expect(find.text('Get started'), findsOneWidget);
      final signInFinder = find.textContaining('Sign in', findRichText: true);
      expect(signInFinder, findsWidgets);
      await tester.tap(signInFinder.first);
      await _pumpUntil(tester, find.text('Sign in to Lakbay+'));

      expect(find.text('Sign in to Lakbay+'), findsOneWidget);
      expect(find.text('Continue with Google'), findsOneWidget);

      // Switch to Create your account and register Account A on live Render API.
      final toggleToRegister = find.textContaining(
        'New to Lakbay+?',
        findRichText: true,
      );
      await tester.ensureVisible(toggleToRegister.first);
      await tester.tap(toggleToRegister.first);
      await _pumpUntil(tester, find.text('Create your account'));

      final stamp = DateTime.now().millisecondsSinceEpoch;
      final emailA = 'e2e.phone.a.$stamp@lakbay.ph';
      final emailB = 'e2e.phone.b.$stamp@lakbay.ph';
      const password = 'LakbayTest123!';

      var fields = find.byType(TextField);
      await tester.enterText(fields.at(0), emailA);
      await tester.enterText(fields.at(1), password);
      await tester.enterText(fields.at(2), password);
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pump(const Duration(milliseconds: 300));

      await tester.ensureVisible(find.text('Create account'));
      await tester.pump(const Duration(milliseconds: 200));
      await tester.tap(find.text('Create account'));

      // Wait for Render + Neon response.
      await _pumpUntil(
        tester,
        find.byType(MainNavigationShell),
        timeout: const Duration(seconds: 40),
      );
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.byType(MainNavigationShell), findsOneWidget);
      expect(find.text('JLL'), findsNothing);

      // Navigate across bottom tabs and verify Discover title stays single-line.
      await tester.tap(find.text('Discover').last);
      await tester.pump(const Duration(milliseconds: 600));
      final discoverHeader = find.descendant(
        of: find.byType(ExploreScreen),
        matching: find.text('Discover'),
      );
      expect(tester.getSize(discoverHeader.first).height, lessThan(48.0),
          reason: 'Discover header must not wrap across two lines on phone width');

      await tester.tap(find.text('Trips').last);
      await tester.pump(const Duration(milliseconds: 400));

      await tester.tap(find.text('Bookings').last);
      await tester.pump(const Duration(milliseconds: 400));

      await tester.tap(find.text('Profile').last);
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.textContaining(emailA), findsWidgets);
      expect(find.textContaining('John Lyold'), findsNothing);
      expect(find.textContaining('traveler@lakbay.ph'), findsNothing);

      // Sign out and verify clean guest reset (no stale email or trips).
      await tester.ensureVisible(find.text('Sign out'));
      await tester.pump(const Duration(milliseconds: 200));
      await tester.tap(find.text('Sign out'));
      await _pumpUntil(tester, find.text('Create account / Sign in'));
      await tester.ensureVisible(find.text('Create account / Sign in'));
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.textContaining(emailA), findsNothing);

      // Register second distinct account and confirm clean account switch.
      await tester.tap(find.text('Create account / Sign in'));
      await _pumpUntil(tester, find.text('Create your account'));

      fields = find.byType(TextField);
      expect(
        tester.widget<TextField>(fields.at(0)).controller?.text ?? '',
        isEmpty,
        reason: 'Email field must be empty after signing out',
      );

      await tester.enterText(fields.at(0), emailB);
      await tester.enterText(fields.at(1), password);
      await tester.enterText(fields.at(2), password);
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pump(const Duration(milliseconds: 300));

      await tester.ensureVisible(find.text('Create account'));
      await tester.pump(const Duration(milliseconds: 200));
      await tester.tap(find.text('Create account'));

      await _pumpUntil(
        tester,
        find.textContaining(emailB),
        timeout: const Duration(seconds: 40),
      );
      expect(find.textContaining(emailB), findsWidgets);
      expect(find.textContaining(emailA), findsNothing);

      expect(frameworkErrors, isEmpty,
          reason:
              'Unexpected Flutter errors during on-device run: ${frameworkErrors.map((e) => e.exceptionAsString()).join('; ')}');

      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pump(const Duration(milliseconds: 500));
    } finally {
      FlutterError.onError = originalOnError;
    }
  });
}
