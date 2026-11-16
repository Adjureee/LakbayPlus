import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lakbay_travel/models/travel_models.dart';
import 'package:lakbay_travel/screens/auth_screen.dart';
import 'package:lakbay_travel/screens/explore_screen.dart';
import 'package:lakbay_travel/services/google_auth_service.dart';
import 'package:lakbay_travel/services/lakbay_api_catalog_service.dart';
import 'package:lakbay_travel/services/location_service.dart';
import 'package:lakbay_travel/services/travel_repository.dart';
import 'package:lakbay_travel/widgets/onboarding_preferences.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _facets = {
  'total_places': 49,
  'groups': [
    {
      'key': 'nature_attractions',
      'label': 'Nature attractions',
      'description': 'Waterfalls, mountains and parks.',
      'count': 21,
      'subtypes': [
        {'key': 'waterfalls', 'label': 'Waterfalls', 'count': 4},
      ],
    },
    {
      'key': 'beaches',
      'label': 'Beaches',
      'description': 'Beaches and beach resorts.',
      'count': 7,
      'subtypes': [],
    },
  ],
};

TravelRepository _repo(MockClient client, {GoogleAuthService? google}) =>
    TravelRepository(
      apiCatalog: LakbayApiCatalogService(
        baseUrlOverride: 'https://api.lakbay.test/api/v1',
        client: client,
      ),
      locationService: LocationService(
        customFetcher: () async => const LocationResult(
          granted: false,
          statusMessage: 'Declined',
        ),
      ),
      googleAuthService: google,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('no hidden party size', () {
    test('a new trip has no traveler count until the traveler gives one', () async {
      final repo = TravelRepository();
      await repo.initialize();

      final trip = repo.generateCustomTrip(
        destination: 'Samal Island',
        daysCount: 2,
        vibe: 'Beach',
      );

      expect(trip.adults, isNull);
      expect(trip.travelerCount, isNull);
      expect(trip.copyWith(adults: 3, children: 1).travelerCount, 4);
      // Nothing was invented in the saved form either.
      expect(trip.toJson()['adults'], isNull);
      expect(ItineraryTrip.fromJson(trip.toJson()).travelerCount, isNull);
    });

    test('a count the traveler chose survives saving and loading', () async {
      final repo = TravelRepository();
      await repo.initialize();
      final trip = repo
          .generateCustomTrip(destination: 'Mati', daysCount: 2, vibe: 'Beach')
          .copyWith(adults: 2, children: 1);

      expect(ItineraryTrip.fromJson(trip.toJson()).travelerCount, 3);
    });

    test('a suggested route with no length does not claim a number of days', () {
      final route = SuggestedRoute.fromJson({
        'id': 'r1',
        'title': 'Samal Escape',
        'destination_ids': ['api_1', 'api_2'],
      });
      expect(route.suggestedDays, isNull);
      expect(
        SuggestedRoute.fromJson({
          'id': 'r2',
          'title': 'Mati',
          'destination_ids': ['api_3'],
          'suggested_days': 2,
        }).suggestedDays,
        2,
      );
    });
  });

  group('Discover', () {
    testWidgets('has no sync button or currency picker, and refreshes by pulling down', (tester) async {
      var catalogRequests = 0;
      final client = MockClient((request) async {
        if (request.url.path.endsWith('/destinations')) catalogRequests++;
        return http.Response('{"items":[],"total":0}', 200);
      });
      final repo = _repo(client);
      await tester.runAsync(() => repo.initialize());

      await tester.pumpWidget(MaterialApp(home: ExploreScreen(repo: repo)));
      await tester.pumpAndSettle();

      expect(find.byTooltip('Sync Live Catalog'), findsNothing);
      expect(find.byIcon(Icons.sync_rounded), findsNothing);
      expect(find.text('PHP'), findsNothing); // the currency picker is gone
      expect(find.byType(RefreshIndicator), findsOneWidget);

      final before = catalogRequests;
      await tester.fling(find.byType(CustomScrollView).first, const Offset(0, 500), 1200);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 150)));
      await tester.pumpAndSettle();

      expect(catalogRequests, greaterThan(before));
    });
  });

  group('expenses and Android settings', () {
    test('the expenses sheet no longer carries the age-weighted split wording', () {
      final source = File('lib/widgets/trip_management_sheets.dart').readAsStringSync();
      expect(source.contains('Age-Weighted'), isFalse);
      expect(source.contains('Thesis formula'), isFalse);
    });

    test('Android backup is off so a saved sign-in is never restored onto a phone', () {
      final manifest = File('android/app/src/main/AndroidManifest.xml').readAsStringSync();
      expect(manifest, contains('android:allowBackup="false"'));
    });
  });

  group('preferences in onboarding', () {
    Future<TravelRepository> repoWithFacets() async {
      final client = MockClient((request) async {
        if (request.url.path.endsWith('/destinations/facets')) {
          return http.Response(jsonEncode(_facets), 200);
        }
        return http.Response('{"items":[],"total":0}', 200);
      });
      final repo = _repo(client);
      await repo.initialize();
      return repo;
    }

    testWidgets('shows the live categories, saves picks, and can be skipped', (tester) async {
      final repo = await tester.runAsync(repoWithFacets) as TravelRepository;
      var continued = 0;

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: OnboardingPreferencesStep(repo: repo, onContinue: () => continued++),
        ),
      ));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pumpAndSettle();

      expect(find.text('What do you enjoy?'), findsOneWidget);
      expect(find.text('Nature attractions'), findsOneWidget);
      expect(find.text('Beaches'), findsOneWidget);
      // Nothing is pre-selected; with no picks the button says so.
      expect(repo.selectedVibes, isEmpty);
      expect(find.text('Skip for now'), findsOneWidget);

      await tester.tap(find.text('Nature attractions'));
      await tester.pumpAndSettle();
      expect(repo.selectedVibes, contains('nature_attractions'));
      expect(find.text('Waterfalls'), findsOneWidget); // narrowing appears
      expect(find.text('Continue'), findsOneWidget);

      await tester.tap(find.text('Family'));
      await tester.pumpAndSettle();
      expect(repo.travelCompanion, 'Family');

      await tester.tap(find.text('Continue'));
      expect(continued, 1);
    });

    testWidgets('says so, and can still be skipped, when the choices cannot load', (tester) async {
      final client = MockClient((request) async => http.Response('down', 503));
      final repo = _repo(client);
      await tester.runAsync(() => repo.initialize());
      var continued = 0;

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: OnboardingPreferencesStep(repo: repo, onContinue: () => continued++),
        ),
      ));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pumpAndSettle();

      expect(find.textContaining("Couldn't load the choices"), findsOneWidget);
      await tester.tap(find.text('Skip for now'));
      expect(continued, 1);
    });
  });

  group('Google sign-in asks before creating an account', () {
    const session = {
      'tokens': {'access_token': 'a', 'refresh_token': 'r'},
      'user': {
        'user_id': 5,
        'full_name': 'New Person',
        'email': 'new.person@gmail.com',
        'role': 'user',
      },
    };

    MockClient server(List<Map<String, dynamic>> bodies) => MockClient((request) async {
          final path = request.url.path.replaceFirst('/api/v1', '');
          if (path == '/auth/google') {
            final body = jsonDecode(request.body) as Map<String, dynamic>;
            bodies.add(body);
            if (body['confirm_new_account'] != true) {
              return http.Response(
                jsonEncode({
                  'error': {
                    'code': 'google_account_not_registered',
                    'message': 'No Lakbay account uses this Google email yet.',
                    'details': {'email': 'new.person@gmail.com', 'full_name': 'New Person'},
                  },
                }),
                409,
              );
            }
            return http.Response(jsonEncode(session), 200);
          }
          return http.Response('[]', 200);
        });

    test('the first sign-in reports who it is and creates nothing', () async {
      final bodies = <Map<String, dynamic>>[];
      final repo = _repo(
        server(bodies),
        google: GoogleAuthService(customTokenFetcher: () async => 'google-token-123456'),
      );
      await repo.initialize();

      await expectLater(
        repo.signInWithGoogleBackend(),
        throwsA(isA<GoogleAccountNotRegistered>()
            .having((e) => e.email, 'email', 'new.person@gmail.com')
            .having((e) => e.fullName, 'fullName', 'New Person')
            .having((e) => e.idToken, 'idToken', 'google-token-123456')),
      );

      expect(repo.isSignedIn, isFalse);
      expect(bodies.single.containsKey('confirm_new_account'), isFalse);
    });

    test('confirming sends the same token with the confirmation and signs in', () async {
      final bodies = <Map<String, dynamic>>[];
      final repo = _repo(
        server(bodies),
        google: GoogleAuthService(customTokenFetcher: () async => 'google-token-123456'),
      );
      await repo.initialize();

      await repo.signInWithGoogleBackend(
        existingIdToken: 'google-token-123456',
        confirmNewAccount: true,
      );

      expect(repo.isSignedIn, isTrue);
      expect(bodies.single['confirm_new_account'], isTrue);
      expect(bodies.single['id_token'], 'google-token-123456');
    });

    testWidgets('the sign-in screen asks, and "Not now" creates nothing', (tester) async {
      final bodies = <Map<String, dynamic>>[];
      final repo = _repo(
        server(bodies),
        google: GoogleAuthService(customTokenFetcher: () async => 'google-token-123456'),
      );
      await tester.runAsync(() => repo.initialize());

      await tester.pumpWidget(MaterialApp(
        home: AuthScreen(repo: repo, initialRegisterMode: false),
      ));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Continue with Google'));
      await tester.tap(find.text('Continue with Google'));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      // A spinner animates while the sign-in is busy, so pump instead of settling.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.text('Create a Lakbay account?'), findsOneWidget);
      expect(find.textContaining('new.person@gmail.com'), findsOneWidget);

      await tester.tap(find.text('Not now'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(repo.isSignedIn, isFalse);
      expect(bodies, hasLength(1)); // no second call, so nothing was created
    });
  });
}
