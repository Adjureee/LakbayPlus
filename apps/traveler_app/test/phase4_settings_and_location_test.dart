import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lakbay_travel/main.dart';
import 'package:lakbay_travel/screens/onboarding_screen.dart';
import 'package:lakbay_travel/screens/profile_screen.dart';
import 'package:lakbay_travel/screens/settings_screen.dart';
import 'package:lakbay_travel/services/lakbay_api_catalog_service.dart';
import 'package:lakbay_travel/services/location_service.dart';
import 'package:lakbay_travel/services/travel_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    GoogleFonts.config.allowRuntimeFetching = false;
    SharedPreferences.setMockInitialValues({});
  });

  test('Legacy saved state with preferredPaymentMethod loads without error', () async {
    SharedPreferences.setMockInitialValues({
      'lakbay_traveler_state_v1': jsonEncode({
        'hasCompletedOnboarding': true,
        'locale': 'en',
        'preferredPaymentMethod': 'GCash / Maya',
        'currency': 'PHP',
      }),
    });

    final repo = TravelRepository(
      apiCatalog: LakbayApiCatalogService(baseUrlOverride: ''),
    );
    await repo.initialize();

    expect(repo.hasCompletedOnboarding, isTrue);
    expect(repo.currency, 'PHP');
  });

  testWidgets('SettingsScreen & ProfileScreen hide Payment and Connected apps (diagnostics debug-only)', (
    tester,
  ) async {
    var openAppSettingsCalls = 0;
    final repo = TravelRepository(
      apiCatalog: LakbayApiCatalogService(baseUrlOverride: ''),
      locationService: LocationService(
        customFetcher: () async => const LocationResult(
          granted: false,
          permissionOutcome: LocationPermissionOutcome.deniedForever,
          statusMessage: 'Location blocked.',
        ),
        customOpenAppSettings: () async {
          openAppSettingsCalls++;
          return true;
        },
      ),
    );
    await tester.runAsync(() => repo.initialize());

    // Release behavior: showDiagnosticsOverride = false
    await tester.pumpWidget(
      MaterialApp(
        home: SettingsScreen(repo: repo, showDiagnosticsOverride: false),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Payment'), findsNothing);
    expect(find.text('Connected apps'), findsNothing);
    expect(find.text('Connection diagnostics (Debug)'), findsNothing);
    await tester.dragUntilVisible(
      find.text('Location sharing'),
      find.byType(ListView),
      const Offset(0, -200),
    );
    expect(find.text('Location sharing'), findsOneWidget);
    expect(find.text('Not shared'), findsOneWidget);

    // Toggle Location sharing off -> then back on -> deniedForever reveals Open app settings
    await tester.tap(find.byType(Switch).last);
    await tester.pumpAndSettle();
    await tester.tap(find.byType(Switch).last);
    await tester.pumpAndSettle();

    expect(find.text('Blocked in settings'), findsOneWidget);
    await tester.ensureVisible(find.text('Open app settings'));
    await tester.tap(find.text('Open app settings'));
    await tester.pump();
    expect(openAppSettingsCalls, 1);

    // Debug behavior: Connection diagnostics (Debug) is visible
    await tester.pumpWidget(
      MaterialApp(
        home: SettingsScreen(repo: repo, showDiagnosticsOverride: true),
      ),
    );
    await tester.pumpAndSettle();
    await tester.dragUntilVisible(
      find.text('Connection diagnostics (Debug)'),
      find.byType(ListView),
      const Offset(0, -250),
    );
    expect(find.text('Connection diagnostics (Debug)'), findsOneWidget);

    // ProfileScreen hides Connected apps too
    await tester.pumpWidget(
      MaterialApp(
        home: ProfileScreen(repo: repo),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Connected apps'), findsNothing);
  });

  testWidgets('Onboarding asks location BEFORE AI chat when allowed and forwards coords', (
    tester,
  ) async {
    var aiChatReceivedLat = false;
    final mockClient = MockClient((request) async {
      if (request.url.path == '/api/v1/ai/chat/guest') {
        final decoded = jsonDecode(request.body) as Map<String, dynamic>;
        final planning = decoded['planning_state'] as Map<String, dynamic>?;
        final origin = planning?['origin'] as Map<String, dynamic>?;
        if (origin?['lat'] != null && origin?['lng'] != null) {
          aiChatReceivedLat = true;
        }
        return http.Response(
          jsonEncode({
            'chat_response': 'From Panabo City, Samal Island is just nearby!',
            'model_id': 'mock',
            'ai_generation_run_id': 1,
            'planning': {
              'input_revision': 0,
              'intent': 'brainstorm',
              'suggested_replies': [],
              'state_updates': {},
              'update_status': 'no_changes',
              'preview': {'state': planning ?? <String, dynamic>{}},
              'recommendations': [],
            },
          }),
          200,
        );
      }
      if (request.url.path == '/api/v1/destinations/facets') {
        return http.Response(jsonEncode({'groups': [], 'categories': []}), 200);
      }
      if (request.url.path == '/api/v1/destinations') {
        return http.Response(jsonEncode({'items': [], 'total': 0}), 200);
      }
      return http.Response('{}', 200);
    });

    final repo = TravelRepository(
      apiCatalog: LakbayApiCatalogService(
        baseUrlOverride: 'https://api.lakbay.test/api/v1',
        client: mockClient,
      ),
      locationService: LocationService(
        customFetcher: () async => const LocationResult(
          granted: true,
          permissionOutcome: LocationPermissionOutcome.granted,
          lat: 7.3081,
          lng: 125.6844,
          resolvedLabel: 'Panabo City, Davao del Norte',
          statusMessage: 'Location detected: Panabo City, Davao del Norte',
        ),
      ),
    );
    await tester.runAsync(() => repo.initialize());

    await tester.pumpWidget(MaterialApp(home: OnboardingScreen(repo: repo)));
    await tester.pump();

    await tester.tap(find.text('Get started'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // Ready to plan -> Location step BEFORE AI chat
    await tester.tap(find.text('Continue'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('First, share your location'), findsOneWidget);
    expect(
      find.textContaining('helps Lakbay AI calculate travel time and route your stops'),
      findsOneWidget,
    );
    expect(find.text('Allow location'), findsOneWidget);
    expect(find.text("Not now, I'll choose a starting place"), findsOneWidget);

    await tester.ensureVisible(find.text('Allow location'));
    await tester.tap(find.text('Allow location'));
    await tester.pump();
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // Coordinates & label saved before entering AI chat
    expect(repo.hasUserLocation, isTrue);
    expect(repo.effectiveOriginLabel, 'Panabo City, Davao del Norte');
    expect(find.textContaining("I'll plan it."), findsOneWidget);

    // Send an AI prompt and ensure coordinates are forwarded
    await tester.tap(find.text('Inspire me!'));
    await tester.pump();
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();
    expect(aiChatReceivedLat, isTrue);
  });

  testWidgets('Onboarding handles denied once and permanently denied with Open app settings', (
    tester,
  ) async {
    var outcome = LocationPermissionOutcome.denied;
    var openSettingsTapped = 0;

    final repo = TravelRepository(
      apiCatalog: LakbayApiCatalogService(baseUrlOverride: ''),
      locationService: LocationService(
        customFetcher: () async {
          if (outcome == LocationPermissionOutcome.deniedForever) {
            return const LocationResult(
              granted: false,
              permissionOutcome: LocationPermissionOutcome.deniedForever,
              statusMessage: 'Location permission is blocked in settings.',
            );
          }
          return const LocationResult(
            granted: false,
            permissionOutcome: LocationPermissionOutcome.denied,
            statusMessage: 'Location permission was declined.',
          );
        },
        customOpenAppSettings: () async {
          openSettingsTapped++;
          return true;
        },
      ),
    );
    await tester.runAsync(() => repo.initialize());

    await tester.pumpWidget(MaterialApp(home: OnboardingScreen(repo: repo)));
    await tester.pump();
    await tester.tap(find.text('Get started'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Continue'));
    await tester.pump(const Duration(milliseconds: 300));

    // Denied once -> stays on Location step, shows Try again & Not now choice
    await tester.ensureVisible(find.text('Allow location'));
    await tester.tap(find.text('Allow location'));
    await tester.pump();
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump();

    expect(find.text('First, share your location'), findsOneWidget);
    expect(find.textContaining('Location permission was declined'), findsOneWidget);
    expect(find.text('Try location again'), findsOneWidget);
    expect(find.text('Open app settings'), findsNothing);

    // Permanently denied -> stays on Location step and shows Open app settings button
    outcome = LocationPermissionOutcome.deniedForever;
    await tester.ensureVisible(find.text('Try location again'));
    await tester.tap(find.text('Try location again'));
    await tester.pump();
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump();

    expect(find.text('First, share your location'), findsOneWidget);
    expect(find.text('Open app settings'), findsOneWidget);
    await tester.ensureVisible(find.text('Open app settings'));
    await tester.tap(find.text('Open app settings'));
    await tester.pump();
    expect(openSettingsTapped, 1);
  });

  testWidgets('MainNavigationShell startup does not silently prompt OS location permission', (
    tester,
  ) async {
    var captureCalls = 0;
    SharedPreferences.setMockInitialValues({
      'lakbay_traveler_state_v1': jsonEncode({
        'hasCompletedOnboarding': true,
        'authSession': {
          'accessToken': 'tok_1',
          'refreshToken': 'ref_1',
          'userId': 1,
          'email': 'test@lakbay.ph',
          'fullName': 'Test User',
        },
      }),
    });

    final repo = TravelRepository(
      apiCatalog: LakbayApiCatalogService(baseUrlOverride: ''),
      locationService: LocationService(
        customFetcher: () async {
          captureCalls++;
          return const LocationResult(
            granted: false,
            permissionOutcome: LocationPermissionOutcome.denied,
            statusMessage: 'Declined',
          );
        },
      ),
    );
    await tester.runAsync(() => repo.initialize());

    await tester.pumpWidget(LakbayTravelApp(repository: repo));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.byType(MainNavigationShell), findsOneWidget);
    expect(captureCalls, 0);
  });
}
