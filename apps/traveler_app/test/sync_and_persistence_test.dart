import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lakbay_travel/models/travel_models.dart';
import 'package:lakbay_travel/screens/auth_screen.dart';
import 'package:lakbay_travel/services/google_auth_service.dart';
import 'package:lakbay_travel/services/lakbay_api_catalog_service.dart';
import 'package:lakbay_travel/services/location_service.dart';
import 'package:lakbay_travel/services/travel_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('SharedPreferences round-trip persists profile, trips, bucket, bookings, and auth', () async {
    final repo1 = TravelRepository(
      apiCatalog: LakbayApiCatalogService(baseUrlOverride: ''),
    );
    await repo1.initialize();

    repo1.completeOnboarding();
    repo1.updateProfile(
      firstName: 'Andrea',
      lastName: 'Reyes',
      headline: 'Island Explorer',
      location: 'Davao City, Philippines',
      email: 'andrea@lakbay.ph',
    );
    repo1.setCurrency('USD');
    repo1.toggleBucketListCity('Mati City');

    final customTrip = repo1.generateCustomTrip(
      destination: 'Dahican Surf Sanctuary',
      daysCount: 3,
      vibe: 'Beach',
    );
    repo1.saveTripToMyTrips(customTrip);
    repo1.addToBasket(
      BasketItem(
        id: 'stay_test_1',
        title: 'Lane Beach Resort',
        category: 'Stay',
        subtitle: '2 nights • Mati',
        priceUsd: 80,
        imageAsset: 'assets/home_backdrops/04-thoddoo.jpg',
        backendDestinationId: 42,
      ),
    );
    await repo1.recordReservationCheckout(paymentMethod: 'GCash');
    await repo1.createTripFromAiPrompt('Plan 2 days in Samal Island');
    await Future<void>.delayed(Duration.zero);

    final repo2 = TravelRepository(
      apiCatalog: LakbayApiCatalogService(baseUrlOverride: ''),
    );
    await repo2.initialize();

    expect(repo2.hasCompletedOnboarding, isTrue);
    expect(repo2.profile.firstName, equals('Andrea'));
    expect(repo2.profile.lastName, equals('Reyes'));
    expect(repo2.profile.email, equals('andrea@lakbay.ph'));
    expect(repo2.currency, equals('USD'));
    expect(repo2.bucketListCities, contains('Mati City'));
    expect(repo2.savedTrips.any((t) => t.title.contains('Dahican')), isTrue);
    expect(repo2.bookings.length, equals(1));
    expect(repo2.bookings.first.itemsSummary, contains('Lane Beach Resort'));
    expect(repo2.bookings.first.paymentMethod, equals('GCash'));
    expect(repo2.chatSessions, isNotEmpty);
  });

  test('Catalog sync paginates active destinations, updates changes, and removes deactivated items', () async {
    var syncRound = 0;
    final mockClient = MockClient((request) async {
      final path = request.url.path;
      final offset = int.tryParse(request.url.queryParameters['offset'] ?? '0') ?? 0;

      if (path == '/api/v1/destinations') {
        if (syncRound == 0) {
          if (offset == 0) {
            final page1 = List.generate(
              100,
              (i) => {
                'destination_id': i + 1,
                'name': 'Davao Spot ${i + 1}',
                'district': 'Davao City',
                'category': 'Nature',
                'lat': 7.07 + i * 0.0001,
                'lng': 125.61,
                'image_url': 'https://cdn.example.com/spot_${i + 1}.jpg',
                'description': 'Active stop ${i + 1}',
                'estimated_cost': 1200,
              },
            );
            return http.Response(jsonEncode(page1), 200);
          }
          return http.Response(
            jsonEncode([
              {
                'destination_id': 201,
                'name': 'Mount Apo Basecamp',
                'district': 'Davao del Sur',
                'category': 'Mountain',
                'lat': 6.987,
                'lng': 125.271,
                'image_url': 'https://cdn.example.com/apo.jpg',
                'description': 'Original Mt Apo description',
                'estimated_cost': 2500,
                'entrance_fee': 'PHP 500',
              },
            ]),
            200,
          );
        } else {
          // Second sync: spot #2 was deactivated; spot #201 cost & description updated
          return http.Response(
            jsonEncode([
              {
                'destination_id': 201,
                'name': 'Mount Apo Basecamp',
                'district': 'Davao del Sur',
                'category': 'Mountain',
                'lat': 6.987,
                'lng': 125.271,
                'image_url': 'https://cdn.example.com/apo_v2.jpg',
                'description': 'Updated trail status',
                'estimated_cost': 3200,
                'entrance_fee': 'PHP 650',
              },
            ]),
            200,
          );
        }
      }
      return http.Response('{}', 404);
    });

    final repo = TravelRepository(
      apiCatalog: LakbayApiCatalogService(
        client: mockClient,
        baseUrlOverride: 'https://api.test/api/v1',
      ),
    );
    await repo.initialize();
    await repo.refreshFromApi();

    expect(repo.allTrips.any((t) => t.id == 'api_201'), isTrue);
    expect(repo.allTrips.any((t) => t.id == 'api_2'), isTrue);
    expect(
      repo.allTrips.firstWhere((t) => t.id == 'api_201').estimatedCostPhp,
      equals(2500),
    );

    syncRound = 1;
    final syncedCount = await repo.syncCatalogWithApi();
    expect(syncedCount, equals(1));
    expect(repo.allTrips.any((t) => t.id == 'api_2'), isFalse);
    final updated = repo.allTrips.firstWhere((t) => t.id == 'api_201');
    expect(updated.description, equals('Updated trail status'));
    expect(updated.estimatedCostPhp, equals(3200));
    expect(updated.thumbnailUrl, equals('https://cdn.example.com/apo_v2.jpg'));
  });

  test('Backend auth, market rates, OSRM polyline routing, live FX, and AI proxy work end-to-end', () async {
    final postedBodies = <Map<String, dynamic>>[];

    final mockClient = MockClient((request) async {
      final path = request.url.path;
      if (request.url.host == 'open.er-api.com') {
        return http.Response(
          jsonEncode({
            'rates': {
              'PHP': 58.2,
              'USD': 1.0,
              'EUR': 0.92,
              'GBP': 0.79,
              'AUD': 1.53,
              'JPY': 152.0,
            },
          }),
          200,
        );
      }
      if (path == '/api/v1/destinations') {
        return http.Response(
          jsonEncode([
            {
              'destination_id': 77,
              'name': 'Aliwagwag Falls',
              'district': 'Davao Oriental',
              'category': 'Waterfall',
              'lat': 7.734,
              'lng': 126.364,
              'image_url': 'https://cdn.example.com/aliwagwag.jpg',
              'estimated_cost': 1800,
            },
          ]),
          200,
        );
      }
      if (path == '/api/v1/auth/login') {
        return http.Response(
          jsonEncode({
            'tokens': {
              'access_token': 'jwt_access_123',
              'refresh_token': 'jwt_refresh_456',
            },
            'user': {
              'user_id': 9,
              'full_name': 'Marco Santos',
              'email': 'marco@lakbay.ph',
              'role': 'traveler',
            },
          }),
          200,
        );
      }
      if (path == '/api/v1/trips' && request.method == 'GET') {
        return http.Response(
          jsonEncode([
            {
              'trip_id': 501,
              'title': 'Saved Cloud Davao Escapade',
              'description': 'Synced from Postgres',
              'traveler_count': 2,
              'total_budget': '15000.00',
              'estimated_total_cost': '9500.00',
              'destination_ids': [77],
            },
          ]),
          200,
        );
      }
      if (path == '/api/v1/trips' && request.method == 'POST') {
        postedBodies.add(jsonDecode(request.body) as Map<String, dynamic>);
        return http.Response(jsonEncode({'trip_id': 888}), 201);
      }
      if (path == '/api/v1/destinations/77/accommodations') {
        return http.Response(
          jsonEncode([
            {
              'accommodation_id': 12,
              'name': 'Cateel Eco Lodge',
              'room_type': 'Deluxe Cottage',
              'price': '3420.00',
              'capacity': 4,
              'charging_unit': 'per_room_per_night',
              'is_available': true,
            },
          ]),
          200,
        );
      }
      if (path == '/api/v1/destinations/77/transportations') {
        return http.Response(
          jsonEncode([
            {
              'transport_id': 31,
              'vehicle_type': 'Private Van',
              'route_description': 'Davao City -> Cateel',
              'fee': '4500.00',
              'charging_unit': 'per_trip',
              'is_available': true,
            },
          ]),
          200,
        );
      }
      if (path == '/api/v1/weather/current') {
        return http.Response(
          jsonEncode({
            'temp_c': 31.4,
            'condition': {'code': 801, 'main': 'Partly Cloudy'},
          }),
          200,
        );
      }
      if (path == '/api/v1/routes/preview') {
        // Precision-5 polyline for (7.0644, 125.6088) -> (7.7340, 126.3640)
        return http.Response(
          jsonEncode({
            'route_provider': 'osrm',
            'is_estimated': false,
            'total_distance_km': 134.8,
            'total_duration_minutes': 162,
            'polyline': '_p~iF~ps|U_ulLnnqC',
            'stops': [
              {'destination_id': 77, 'name': 'Aliwagwag Falls', 'lat': 7.734, 'lng': 126.364},
            ],
          }),
          200,
        );
      }
      if (path == '/api/v1/ai/chat') {
        return http.Response(
          jsonEncode({
            'chat_response': 'Visit Aliwagwag Falls early morning for the clearest cascades.',
            'model_id': 'groq-llama-proxy',
            'results': [],
          }),
          200,
        );
      }
      return http.Response('{}', 404);
    });

    final api = LakbayApiCatalogService(
      client: mockClient,
      baseUrlOverride: 'https://api.test/api/v1',
    );
    final repo = TravelRepository(apiCatalog: api);
    await repo.initialize();

    await repo.signInWithBackend(
      email: 'marco@lakbay.ph',
      password: 'Password123!',
    );
    expect(repo.isSignedIn, isTrue);
    expect(repo.profile.firstName, equals('Marco'));
    expect(repo.savedTrips.any((t) => t.backendTripId == 501), isTrue);

    await repo.refreshLiveFxRates();
    expect(repo.formatPrice(10), equals('₱582'));

    // Load live market rates + weather for synced trip
    final cloudTrip = repo.savedTrips.firstWhere((t) => t.backendTripId == 501);
    final enriched = await repo.loadLiveDetailsForTrip(cloudTrip);
    expect(enriched.hotels.any((h) => h.name == 'Cateel Eco Lodge'), isTrue);
    expect(
      repo.transportRatesForDestination(77).any((r) => r.vehicleType == 'Private Van'),
      isTrue,
    );
    expect(enriched.avgTemp, contains('31°C'));

    // OSRM route preview + polyline decode
    final route = await repo.fetchRoadRouteForTrip(enriched);
    expect(route, isNotNull);
    expect(route!.routeProvider, equals('osrm'));
    expect(route.totalDistanceKm, closeTo(134.8, 0.1));
    expect(route.geometryPoints.length, equals(2));

    // Checkout syncs reservation to POST /trips
    repo.addToBasket(
      BasketItem(
        id: 'hotel_12',
        title: 'Cateel Eco Lodge',
        category: 'Stay',
        subtitle: '1 night',
        priceUsd: 60,
        imageAsset: 'assets/home_backdrops/04-thoddoo.jpg',
        backendDestinationId: 77,
      ),
    );
    final reservation = await repo.recordReservationCheckout(paymentMethod: 'Maya');
    expect(reservation.syncedToCloud, isTrue);
    expect(reservation.backendTripId, equals(888));
    expect(postedBodies.single['destination_ids'], equals([77]));

    // Backend AI chat proxy
    await repo.sendChatMessage('Give me a tip for Aliwagwag Falls');
    final assistantMessages =
        repo.chatMessages.where((m) => !m.isUser).toList();
    expect(
      assistantMessages.last.text,
      contains('Visit Aliwagwag Falls early morning'),
    );
  });

  test('LocationService reverse geocodes and TravelRepository persists granted/denied GPS state', () async {
    final geocodeClient = MockClient((request) async {
      if (request.url.host == 'nominatim.openstreetmap.org') {
        return http.Response(
          jsonEncode({
            'address': {'city': 'Tagum City', 'country': 'Philippines'},
          }),
          200,
        );
      }
      return http.Response('{}', 404);
    });

    final reverseOnly = LocationService(httpClient: geocodeClient);
    final label = await reverseOnly.reverseGeocode(7.4478, 125.8078);
    expect(label, equals('Tagum City, Philippines'));

    var grant = true;
    final repo1 = TravelRepository(
      apiCatalog: LakbayApiCatalogService(baseUrlOverride: ''),
      locationService: LocationService(
        customFetcher: () async => grant
            ? const LocationResult(
                granted: true,
                lat: 7.4478,
                lng: 125.8078,
                accuracyMeters: 12,
                resolvedLabel: 'Tagum City, Philippines',
                statusMessage: 'Location detected: Tagum City, Philippines',
              )
            : const LocationResult(
                granted: false,
                statusMessage: 'Location permission was declined.',
              ),
      ),
    );
    await repo1.initialize();

    final res1 = await repo1.requestAndSaveCurrentLocation();
    expect(res1.granted, isTrue);
    expect(repo1.hasUserLocation, isTrue);
    expect(repo1.userLat, closeTo(7.4478, 0.0001));
    expect(repo1.profile.location, equals('Tagum City, Philippines'));

    // Restored across restart
    final repo2 = TravelRepository(
      apiCatalog: LakbayApiCatalogService(baseUrlOverride: ''),
    );
    await repo2.initialize();
    expect(repo2.hasUserLocation, isTrue);
    expect(repo2.userLat, closeTo(7.4478, 0.0001));
    expect(repo2.locationSharingEnabled, isTrue);
    expect(repo2.profile.location, equals('Tagum City, Philippines'));

    // Declining later updates locationSharingEnabled cleanly
    grant = false;
    final res2 = await repo1.requestAndSaveCurrentLocation();
    expect(res2.granted, isFalse);
    expect(repo1.locationSharingEnabled, isFalse);
  });

  testWidgets('AuthScreen handles email registration, password confirmation, mode switch, and Google OAuth', (tester) async {
    String? postedEndpoint;
    Map<String, dynamic>? postedBody;

    final mockClient = MockClient((request) async {
      postedEndpoint = request.url.path;
      if (request.method == 'POST') {
        postedBody = jsonDecode(request.body) as Map<String, dynamic>;
      }
      if (request.url.path == '/api/v1/auth/register') {
        return http.Response(
          jsonEncode({
            'tokens': {
              'access_token': 'reg_jwt_1',
              'refresh_token': 'reg_ref_1',
            },
            'user': {
              'user_id': 21,
              'full_name': postedBody?['full_name'] ?? 'Test User',
              'email': postedBody?['email'] ?? 'user@lakbay.ph',
              'role': 'user',
            },
          }),
          201,
        );
      }
      if (request.url.path == '/api/v1/auth/google') {
        return http.Response(
          jsonEncode({
            'tokens': {
              'access_token': 'google_jwt_1',
              'refresh_token': 'google_ref_1',
            },
            'user': {
              'user_id': 22,
              'full_name': 'Sofia Reyes',
              'email': 'sofia@gmail.com',
              'role': 'user',
            },
          }),
          200,
        );
      }
      if (request.url.path == '/api/v1/trips') {
        return http.Response(jsonEncode([]), 200);
      }
      return http.Response('[]', 200);
    });

    final repo = TravelRepository(
      apiCatalog: LakbayApiCatalogService(
        client: mockClient,
        baseUrlOverride: 'https://api.test/api/v1',
      ),
      googleAuthService: GoogleAuthService(
        customTokenFetcher: () async => 'mock_google_id_token_xyz',
      ),
    );

    var authenticatedCount = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: AuthScreen(
          repo: repo,
          initialRegisterMode: true,
          onAuthenticated: () => authenticatedCount++,
        ),
      ),
    );

    expect(find.text('Create your account'), findsOneWidget);
    expect(find.text('Continue with Google'), findsOneWidget);

    // Mismatched confirmation password blocks request
    final fields = find.byType(TextField);
    await tester.enterText(fields.at(0), 'elena.cruz@lakbay.ph');
    await tester.enterText(fields.at(1), 'Password123!');
    await tester.enterText(fields.at(2), 'Different123!');
    await tester.ensureVisible(find.text('Create account'));
    await tester.tap(find.text('Create account'));
    await tester.pump();
    expect(find.text('Passwords do not match.'), findsOneWidget);
    expect(postedEndpoint, isNull);

    // Matching passwords submit to /auth/register
    await tester.enterText(fields.at(2), 'Password123!');
    await tester.ensureVisible(find.text('Create account'));
    await tester.tap(find.text('Create account'));
    await tester.pump();
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
    await tester.pump();
    expect(postedEndpoint, equals('/api/v1/auth/register'));
    expect(postedBody?['email'], equals('elena.cruz@lakbay.ph'));
    expect(postedBody?['confirm_password'], equals('Password123!'));
    expect(repo.isSignedIn, isTrue);
    expect(authenticatedCount, equals(1));

    // Continue with Google calls /auth/google
    await tester.ensureVisible(find.text('Continue with Google'));
    await tester.tap(find.text('Continue with Google'));
    await tester.pump();
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
    await tester.pump();
    expect(repo.authSession?.email, equals('sofia@gmail.com'));
    expect(authenticatedCount, equals(2));
  });
}
