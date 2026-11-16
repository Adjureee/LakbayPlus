import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lakbay_travel/main.dart';
import 'package:lakbay_travel/models/travel_models.dart';
import 'package:lakbay_travel/screens/auth_screen.dart';
import 'package:lakbay_travel/screens/explore_screen.dart';
import 'package:lakbay_travel/screens/home_chat_screen.dart';
import 'package:lakbay_travel/screens/profile_screen.dart';
import 'package:lakbay_travel/services/google_auth_service.dart';
import 'package:lakbay_travel/services/lakbay_ai_service.dart';
import 'package:lakbay_travel/services/lakbay_api_catalog_service.dart';
import 'package:lakbay_travel/services/location_service.dart';
import 'package:lakbay_travel/services/travel_repository.dart';
import 'package:lakbay_travel/widgets/lakbay_mapbox_widget.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('SharedPreferences round-trip persists profile, trips, bucket, memories, preferences, and auth', () async {
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
    repo1.setStrictBudgetFilter(true);
    repo1.setPreferredTravelMode('public_transport');
    repo1.toggleBucketListCity('Mati City');

    final customTrip = repo1.generateCustomTrip(
      destination: 'Dahican Surf Sanctuary',
      daysCount: 3,
      vibe: 'Beach',
    );
    repo1.saveTripToMyTrips(customTrip);
    await repo1.uploadAndAddMemory(
      trip: customTrip,
      localFilePath: 'assets/home_backdrops/01-samal-island.jpg',
      caption: 'Morning waves at Dahican Beach',
      locationTag: 'Mati City',
    );
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
    expect(repo2.strictBudgetFilter, isTrue);
    expect(repo2.preferredTravelMode, equals('public_transport'));
    expect(repo2.bucketListCities, contains('Mati City'));
    expect(repo2.savedTrips.any((t) => t.title.contains('Dahican')), isTrue);
    expect(repo2.memories.length, equals(1));
    expect(repo2.memories.first.caption, contains('Dahican Beach'));
    expect(repo2.memories.first.locationTag, equals('Mati City'));
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
      if (path == '/api/v1/notifications') {
        return http.Response(jsonEncode([]), 200);
      }
      if (path == '/api/v1/notifications/unread-count') {
        return http.Response(jsonEncode({'user_id': 9, 'unread_count': 0}), 200);
      }
      if (path == '/api/v1/trips/501/memories/upload' &&
          request.method == 'POST') {
        return http.Response(
          jsonEncode({
            'image_url': 'https://res.cloudinary.com/bh2rda7z/image/upload/v1/lakbay/aliwagwag_mem.jpg',
            'cloudinary_public_id': 'lakbay/aliwagwag_mem',
          }),
          200,
        );
      }
      if (path == '/api/v1/trips/501/memories' && request.method == 'POST') {
        final reqJson = jsonDecode(request.body) as Map<String, dynamic>;
        postedBodies.add(reqJson);
        return http.Response(
          jsonEncode({
            'trip_memory_id': 701,
            'trip_id': 501,
            'uploaded_by_full_name': 'Marco Santos',
            'destination_id': reqJson['destination_id'],
            'destination_name': 'Aliwagwag Falls',
            'image_url': reqJson['image_url'],
            'caption': reqJson['caption'],
            'location_tag': reqJson['location_tag'],
            'like_count': 0,
            'comment_count': 0,
            'created_at': '2026-11-15T12:00:00Z',
          }),
          201,
        );
      }
      if (path == '/api/v1/trips/501/memories' && request.method == 'GET') {
        return http.Response(jsonEncode([]), 200);
      }
      if (path == '/api/v1/trips/501/memories/701/likes' &&
          request.method == 'POST') {
        return http.Response(jsonEncode({'liked': true}), 200);
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

    // Upload & create cloud memory + like action
    await repo.uploadAndAddMemory(
      trip: enriched,
      localFilePath: 'assets/home_backdrops/01-samal-island.jpg',
      caption: 'Aliwagwag Waterfall Mist',
      locationTag: 'Cateel',
    );
    expect(repo.memories.length, equals(1));
    expect(repo.memories.first.tripMemoryId, equals(701));
    expect(postedBodies.single['caption'], equals('Aliwagwag Waterfall Mist'));
    await repo.likeMemory(repo.memories.first);
    expect(repo.memories.first.likeCount, equals(1));

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

    // Registration requires full name before checking passwords
    final fields = find.byType(TextField);
    await tester.enterText(fields.at(1), 'elena.cruz@lakbay.ph');
    await tester.enterText(fields.at(2), 'Password123!');
    await tester.enterText(fields.at(3), 'Password123!');
    await tester.ensureVisible(find.text('Create account'));
    await tester.tap(find.text('Create account'));
    await tester.pump();
    expect(
      find.text('Please enter your full name (at least 2 characters).'),
      findsOneWidget,
    );
    expect(postedEndpoint, isNull);

    // Mismatched confirmation password blocks request
    await tester.enterText(fields.at(0), 'Elena Cruz');
    await tester.enterText(fields.at(3), 'Different123!');
    await tester.ensureVisible(find.text('Create account'));
    await tester.tap(find.text('Create account'));
    await tester.pump();
    expect(find.text('Passwords do not match.'), findsOneWidget);
    expect(postedEndpoint, isNull);

    // Matching passwords submit to /auth/register with explicit full name
    await tester.enterText(fields.at(3), 'Password123!');
    await tester.ensureVisible(find.text('Create account'));
    await tester.tap(find.text('Create account'));
    await tester.pump();
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
    await tester.pump();
    expect(postedEndpoint, equals('/api/v1/auth/register'));
    expect(postedBody?['full_name'], equals('Elena Cruz'));
    expect(postedBody?['email'], equals('elena.cruz@lakbay.ph'));
    expect(postedBody?['confirm_password'], equals('Password123!'));
    expect(repo.isSignedIn, isTrue);
    expect(repo.travelerId, equals('usr_21'));
    expect(authenticatedCount, equals(1));

    // Continue with Google calls /auth/google and replaces previous account profile
    await tester.ensureVisible(find.text('Continue with Google'));
    await tester.tap(find.text('Continue with Google'));
    await tester.pump();
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
    await tester.pump();
    expect(repo.authSession?.email, equals('sofia@gmail.com'));
    expect(repo.profile.firstName, equals('Sofia'));
    expect(repo.profile.email, equals('sofia@gmail.com'));
    expect(repo.travelerId, equals('usr_22'));
    expect(authenticatedCount, equals(2));

    // Signing out resets profile, travelerId, and session data cleanly
    await tester.runAsync(() => repo.signOutBackend());
    expect(repo.isSignedIn, isFalse);
    expect(repo.profile.email, isEmpty);
    expect(repo.profile.firstName, isEmpty);
    expect(repo.profile.lastName, isEmpty);
    expect(repo.profile.initials, equals('ME'));
    expect(repo.travelerId, equals('guest'));
    expect(repo.savedTrips, isEmpty);
  });

  test('UserProfile defaults empty location and autoDetectLocationOnShellEntry resolves GPS without clobbering consent', () async {
    const emptyProfile = UserProfile();
    expect(emptyProfile.location, isEmpty);

    var shouldGrant = false;
    final repo = TravelRepository(
      apiCatalog: LakbayApiCatalogService(baseUrlOverride: ''),
      locationService: LocationService(
        customFetcher: () async {
          if (!shouldGrant) {
            return const LocationResult(
              granted: false,
              statusMessage: 'Denied cleanly',
            );
          }
          return const LocationResult(
            granted: true,
            lat: 6.9551,
            lng: 126.2166,
            resolvedLabel: 'Mati City, Davao Oriental',
            statusMessage: 'GPS fix acquired',
          );
        },
      ),
    );
    await repo.initialize();
    expect(repo.hasOrigin, isFalse);
    expect(repo.resolvedOriginLabel, isNull);
    expect(repo.effectiveOriginLabel, isEmpty);
    expect(repo.locationSharingEnabled, isTrue);

    // Denied auto-detect on shell entry preserves locationSharingEnabled
    await repo.autoDetectLocationOnShellEntry();
    expect(repo.hasUserLocation, isFalse);
    expect(repo.locationSharingEnabled, isTrue);

    // Calling again once granted (via refreshCurrentLocationSilently) updates origin & coordinates
    shouldGrant = true;
    final refreshed = await repo.refreshCurrentLocationSilently();
    expect(refreshed, isTrue);
    expect(repo.hasUserLocation, isTrue);
    expect(repo.userLat, closeTo(6.9551, 0.0001));
    expect(repo.effectiveOriginLabel, equals('Mati City, Davao Oriental'));
  });

  test('LakbayAiService.chatOrPlan asks the backend trip-draft endpoint (no AI key in the app)', () async {
    Map<String, dynamic>? capturedRequest;
    String? capturedAuth;
    String? capturedPath;
    final backendClient = MockClient((request) async {
      capturedPath = request.url.path;
      capturedAuth = request.headers['Authorization'];
      capturedRequest = jsonDecode(request.body) as Map<String, dynamic>;
      return http.Response(
        jsonEncode({
          'model_id': 'openai/gpt-oss-120b',
          'provider': 'groq',
          'draft': {
            'reply':
                'Starting from Mati City, catch sunrise at Dahican before heading west toward Samal reefs.',
            'should_create_itinerary': false,
            'destination': 'Mati & Samal Coast',
            'suggested_replies': [
              'Add Sleeping Dinosaur ridge stop',
              'Keep it slow for 3 days',
            ],
            'days': [],
          },
        }),
        200,
      );
    });

    final service = LakbayAiService(
      backend: LakbayApiCatalogService(
        client: backendClient,
        baseUrlOverride: 'https://api.test/api/v1',
      ),
      accessToken: () => null, // guest
    );
    final result = await service.chatOrPlan(
      userPrompt: 'Inspire me!',
      history: const [
        {'role': 'assistant', 'content': 'Hey there!'},
      ],
      currentLocation: 'Mati City, Davao Oriental',
      userLat: 6.9551,
      userLng: 126.2166,
      preferredVibes: const {'beach', 'nature'},
      strictBudget: true,
    );

    expect(capturedPath, '/api/v1/ai/trip-draft');
    expect(capturedAuth, isNull);
    expect(capturedRequest!['history'], [
      {'role': 'assistant', 'content': 'Hey there!'},
    ]);
    expect(capturedRequest!['current_location'], 'Mati City, Davao Oriental');
    expect((capturedRequest!['user_lat'] as num).toDouble(), closeTo(6.9551, 0.0001));
    expect(capturedRequest!['strict_budget'], isTrue);
    expect(result.suggestedReplies, contains('Add Sleeping Dinosaur ridge stop'));
    expect(result.modelUsed, 'openai/gpt-oss-120b');
  });

  testWidgets('LakbayMapboxMap renders photo pinpoints without price tags and supports pinch-to-zoom', (tester) async {
    final repo = TravelRepository(
      apiCatalog: LakbayApiCatalogService(baseUrlOverride: ''),
      locationService: LocationService(
        customFetcher: () async => const LocationResult(
          granted: true,
          lat: 7.4478,
          lng: 125.8078,
          resolvedLabel: 'Tagum City, Philippines',
          statusMessage: 'GPS fixed',
        ),
      ),
    );
    await tester.runAsync(() async {
      await repo.initialize();
      await repo.requestAndSaveCurrentLocation();
    });

    final mapKey = GlobalKey<LakbayMapboxMapState>();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 400,
            height: 500,
            child: LakbayMapboxMap(
              key: mapKey,
              repo: repo,
              initialLat: repo.userLat!,
              initialLng: repo.userLng!,
              initialZoom: 9.0,
              markers: [
                LakbayMapMarker(
                  id: 'user_gps',
                  lat: repo.userLat!,
                  lng: repo.userLng!,
                  title: 'You (${repo.effectiveOriginLabel})',
                  isUserLocation: true,
                ),
                const LakbayMapMarker(
                  id: 'day_1',
                  lat: 7.0742,
                  lng: 125.7089,
                  badgeText: 'D1',
                  title: 'Samal Island',
                  imageAsset: 'assets/home_backdrops/01-samal-island.jpg',
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    // User location marker & photo pinpoint label render cleanly without any currency prices
    expect(find.text('You'), findsOneWidget);
    expect(find.text('D1'), findsOneWidget);
    expect(find.textContaining('₱'), findsNothing);
    expect(find.textContaining('\$'), findsNothing);
    expect(find.byType(Image), findsWidgets);

    // Two-finger pinch-out increases map zoom cleanly
    final initialZoom = mapKey.currentState!.currentZoom;
    final box = tester.renderObject<RenderBox>(find.byType(LakbayMapboxMap));
    final center = box.localToGlobal(box.size.center(Offset.zero));
    final f1 = await tester.startGesture(center - const Offset(30, 0), pointer: 11);
    final f2 = await tester.startGesture(center + const Offset(30, 0), pointer: 12);
    await tester.pump();
    await f1.moveBy(const Offset(-90, 0));
    await f2.moveBy(const Offset(90, 0));
    await tester.pump();
    await f1.up();
    await f2.up();
    await tester.pump(const Duration(milliseconds: 500));

    expect(mapKey.currentState!.currentZoom, greaterThan(initialZoom));
  });

  testWidgets('ExploreScreen map view renders photo pinpoint markers without prices and includes GPS marker', (tester) async {
    final repo = TravelRepository(
      apiCatalog: LakbayApiCatalogService(baseUrlOverride: ''),
      locationService: LocationService(
        customFetcher: () async => const LocationResult(
          granted: true,
          lat: 7.4478,
          lng: 125.8078,
          resolvedLabel: 'Tagum City, Philippines',
          statusMessage: 'GPS fixed',
        ),
      ),
    );
    await tester.runAsync(() async {
      await repo.initialize();
      await repo.requestAndSaveCurrentLocation();
    });

    await tester.pumpWidget(
      MaterialApp(
        home: ExploreScreen(repo: repo),
      ),
    );
    await tester.pump();

    await tester.tap(find.text('Mapbox'));
    await tester.pump();

    expect(find.byType(LakbayMapboxMap), findsOneWidget);
    expect(find.text('You'), findsOneWidget);
    final mapWidget = tester.widget<LakbayMapboxMap>(find.byType(LakbayMapboxMap));
    expect(mapWidget.initialLat, closeTo(repo.userLat!, 0.0001));
    expect(mapWidget.initialLng, closeTo(repo.userLng!, 0.0001));
    final spotMarkers = mapWidget.markers.where((m) => !m.isUserLocation).toList();
    expect(spotMarkers, isNotEmpty);
    for (final marker in spotMarkers) {
      expect(marker.badgeText, isNot(contains('₱')));
      expect(marker.badgeText, isNot(contains('\$')));
      expect(marker.imageAsset, isNotNull);
    }
  });

  test('Local Buda & Samal trips avoid fabricated DVO Airport flights when includeFlights is false', () async {
    final repo = TravelRepository(
      apiCatalog: LakbayApiCatalogService(baseUrlOverride: ''),
    );
    await repo.initialize();

    final buda = repo.generateCustomTrip(
      destination: 'Buda & Marilog Pine Highlands',
      daysCount: 2,
      vibe: 'Misty Pine Cabins & Cafes',
      includeFlights: false,
    );
    expect(buda.flights, isEmpty);
    expect(buda.days.first.transportDuration, isNot(contains('DVO Airport')));
    expect(buda.days.first.transportFromPrevious, isNot(TransportMode.flight));

    final samal = repo.generateCustomTrip(
      destination: 'Samal Island',
      daysCount: 3,
      vibe: 'Beach & Reefs',
      includeFlights: false,
    );
    expect(samal.flights, isEmpty);
    expect(samal.days.first.transportDuration, isNot(contains('DVO Airport')));
    expect(samal.days.first.transportFromPrevious, isNot(TransportMode.flight));
  });

  test('Origin handling never defaults to Davao, supports search/pin, and allows outside-Region-XI starts with note', () async {
    final repo = TravelRepository(
      apiCatalog: LakbayApiCatalogService(baseUrlOverride: ''),
      locationService: LocationService(
        customPlaceSearcher: (q) async => [
          const PlaceSuggestion(
            label: 'Makati City, Metro Manila',
            lat: 14.5547,
            lng: 121.0244,
          ),
        ],
        customReverseGeocoder: (lat, lng) async => 'Tagum City, Davao del Norte',
      ),
    );
    await repo.initialize();

    expect(repo.hasOrigin, isFalse);
    expect(repo.resolvedOriginLabel, isNull);
    const missingPoint = ExploreTrip(
      locale: 'en',
      id: 'x',
      title: 'Test Overlook',
      days: 1,
      lat: 7.0,
      lng: 125.6,
      thumbnailUrl: '',
    );
    expect(missingPoint.regionName, equals('Region XI'));

    final hits = await repo.searchStartingPlaces('Makati');
    expect(hits, hasLength(1));
    repo.setManualOrigin(
      label: hits.first.label,
      lat: hits.first.lat,
      lng: hits.first.lng,
    );
    expect(repo.hasOrigin, isTrue);
    expect(repo.resolvedOriginLabel, equals('Makati City, Metro Manila'));
    expect(repo.isOriginOutsideRegionXi, isTrue);
    expect(
      repo.originRegionNote,
      contains('Road routes are planned inside Region XI'),
    );

    final pinLabel = await repo.reverseGeocodePoint(7.4479, 125.8078);
    repo.setManualOrigin(label: pinLabel, lat: 7.4479, lng: 125.8078);
    expect(repo.resolvedOriginLabel, equals('Tagum City, Davao del Norte'));
    expect(repo.isOriginOutsideRegionXi, isFalse);
    expect(repo.originRegionNote, isNull);
  });

  testWidgets('HomeChatScreen prompts to set starting place when unset and updates via search', (tester) async {
    final repo = TravelRepository(
      apiCatalog: LakbayApiCatalogService(baseUrlOverride: ''),
      locationService: LocationService(
        customFetcher: () async => const LocationResult(
          granted: false,
          statusMessage: 'Location permission declined.',
        ),
        customPlaceSearcher: (q) async => [
          const PlaceSuggestion(
            label: 'Cebu City, Philippines',
            lat: 10.3157,
            lng: 123.8854,
          ),
        ],
      ),
    );
    await tester.runAsync(() async {
      await repo.initialize();
    });

    await tester.pumpWidget(
      MaterialApp(
        home: HomeChatScreen(repo: repo),
      ),
    );
    await tester.pump();

    expect(find.text('Set starting place (search or pin)'), findsOneWidget);
    await tester.tap(find.text('Set starting place (search or pin)'));
    await tester.pumpAndSettle();

    expect(find.text('Set your starting place'), findsOneWidget);
    await tester.enterText(find.byType(TextField).last, 'Cebu City');
    await tester.tap(find.text('Search'));
    await tester.pumpAndSettle();

    expect(find.text('Cebu City, Philippines'), findsOneWidget);
    await tester.tap(find.text('Cebu City, Philippines'));
    await tester.pumpAndSettle();

    expect(repo.resolvedOriginLabel, equals('Cebu City, Philippines'));
    expect(repo.isOriginOutsideRegionXi, isTrue);
    expect(
      find.textContaining('Road routes are planned inside Region XI'),
      findsOneWidget,
    );
  });

  testWidgets('UserProfile migrates Lakbay Traveler placeholder and ProfileScreen prompts Add your name', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'lakbay_traveler_state_v1': jsonEncode({
        'hasCompletedOnboarding': true,
        'profile': {
          'firstName': 'Lakbay',
          'lastName': 'Traveler',
          'headline': '',
          'location': '',
          'email': 'juan@example.com',
        },
      }),
    });

    final repo = TravelRepository(
      apiCatalog: LakbayApiCatalogService(baseUrlOverride: ''),
      locationService: LocationService(
        customFetcher: () async => const LocationResult(
          granted: false,
          statusMessage: 'Declined',
        ),
      ),
    );
    await tester.runAsync(() async {
      await repo.initialize();
    });

    expect(repo.profile.firstName, isEmpty);
    expect(repo.profile.lastName, isEmpty);
    expect(repo.profile.fullName, isEmpty);
    expect(repo.profile.initials, equals('ME'));
    final prefs = await SharedPreferences.getInstance();
    final stored = jsonDecode(prefs.getString('lakbay_traveler_state_v1')!)
        as Map<String, dynamic>;
    expect(stored['placeholderNameMigrated'], isTrue);

    await tester.pumpWidget(
      MaterialApp(
        home: ProfileScreen(repo: repo),
      ),
    );
    await tester.pump();

    expect(find.text('Add your name'), findsOneWidget);
    expect(find.text('Lakbay Traveler'), findsNothing);

    await tester.tap(find.text('Add your name'));
    await tester.pumpAndSettle();
    expect(find.text('Edit profile'), findsOneWidget);
  });

  testWidgets('Signed-out users never reach MainNavigationShell (root & onboarding skip)', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'lakbay_traveler_state_v1': jsonEncode({
        'hasCompletedOnboarding': true,
      }),
    });
    final returningRepo = TravelRepository(
      apiCatalog: LakbayApiCatalogService(
        baseUrlOverride: 'https://api.lakbay.test/api/v1',
      ),
      locationService: LocationService(
        customFetcher: () async => const LocationResult(
          granted: false,
          statusMessage: 'Declined',
        ),
      ),
    );
    await tester.runAsync(() => returningRepo.initialize());

    await tester.pumpWidget(
      LakbayTravelApp(
        key: const ValueKey('returning'),
        repository: returningRepo,
      ),
    );
    await tester.pump();

    expect(find.byType(AuthScreen), findsOneWidget);
    expect(find.byType(MainNavigationShell), findsNothing);
    expect(find.byTooltip('Back'), findsNothing);

    // Fresh user skipping onboarding still lands on AuthScreen, never dashboard
    SharedPreferences.setMockInitialValues({});
    final freshRepo = TravelRepository(
      apiCatalog: LakbayApiCatalogService(
        baseUrlOverride: 'https://api.lakbay.test/api/v1',
      ),
      locationService: LocationService(
        customFetcher: () async => const LocationResult(
          granted: false,
          statusMessage: 'Declined',
        ),
      ),
    );
    await tester.runAsync(() => freshRepo.initialize());

    await tester.pumpWidget(
      LakbayTravelApp(
        key: const ValueKey('fresh'),
        repository: freshRepo,
      ),
    );
    await tester.pump();

    await tester.tap(find.text('Get started'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    await tester.tap(find.text('Skip'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));

    expect(find.byType(AuthScreen), findsOneWidget);
    expect(find.byType(MainNavigationShell), findsNothing);
  });

  testWidgets('Sign-in from root AuthScreen lands on MainNavigationShell dashboard and sign-out returns to AuthScreen', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'lakbay_traveler_state_v1': jsonEncode({
        'hasCompletedOnboarding': true,
      }),
    });
    final mockClient = MockClient((request) async {
      if (request.url.path == '/api/v1/auth/login') {
        return http.Response(
          jsonEncode({
            'tokens': {
              'access_token': 'login_jwt_1',
              'refresh_token': 'login_ref_1',
            },
            'user': {
              'user_id': 31,
              'full_name': 'Mateo Reyes',
              'email': 'mateo@lakbay.ph',
              'role': 'user',
            },
          }),
          200,
        );
      }
      if (request.url.path == '/api/v1/destinations') {
        return http.Response(jsonEncode({'items': [], 'total': 0}), 200);
      }
      if (request.url.path == '/api/v1/trips') {
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
          granted: false,
          statusMessage: 'Declined',
        ),
      ),
    );
    await tester.runAsync(() => repo.initialize());

    await tester.pumpWidget(LakbayTravelApp(repository: repo));
    await tester.pump();

    expect(find.byType(AuthScreen), findsOneWidget);
    final fields = find.byType(TextField);
    await tester.enterText(fields.at(0), 'mateo@lakbay.ph');
    await tester.enterText(fields.at(1), 'Password123!');
    await tester.ensureVisible(find.text('Sign in').first);
    await tester.pump();
    await tester.tap(find.text('Sign in').first);
    await tester.pump();
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 120)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(repo.isSignedIn, isTrue);
    expect(find.byType(MainNavigationShell), findsOneWidget);
    expect(find.byType(AuthScreen), findsNothing);

    await tester.runAsync(() => repo.signOutBackend());
    await tester.pump();
    expect(repo.isSignedIn, isFalse);
    expect(find.byType(AuthScreen), findsOneWidget);
    expect(find.byType(MainNavigationShell), findsNothing);
  });

  testWidgets('Onboarding order holds: try AI -> rating -> register -> MainNavigationShell with saved trip', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final mockClient = MockClient((request) async {
      if (request.url.path == '/api/v1/auth/register') {
        return http.Response(
          jsonEncode({
            'tokens': {
              'access_token': 'onb_jwt_1',
              'refresh_token': 'onb_ref_1',
            },
            'user': {
              'user_id': 42,
              'full_name': 'Clara Lim',
              'email': 'clara@lakbay.ph',
              'role': 'user',
            },
          }),
          201,
        );
      }
      if (request.url.path == '/api/v1/destinations') {
        return http.Response(jsonEncode({'items': [], 'total': 0}), 200);
      }
      if (request.url.path == '/api/v1/trips') {
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
          granted: false,
          statusMessage: 'Declined',
        ),
      ),
    );
    await tester.runAsync(() => repo.initialize());

    await tester.pumpWidget(LakbayTravelApp(repository: repo));
    await tester.pump();

    // Welcome -> Trip decision ('Yes' selected by default) -> YesAiOnboardingFlow Stage 0 (Try AI)
    await tester.tap(find.text('Get started'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    await tester.tap(find.text('Continue'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.textContaining("I'll plan it."), findsOneWidget);

    // Stage 0 -> Stage 1 (Rating)
    await tester.tap(find.text('Skip'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('Good so far?'), findsOneWidget);
    expect(find.byType(MainNavigationShell), findsNothing);

    // Stage 1 -> Stage 2 (First plan, done -> requires AuthScreen before dashboard)
    await tester.tap(find.text('Rate Lakbay+✦'));
    await tester.pump();
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 1400)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('First plan, done.'), findsOneWidget);
    expect(find.byType(MainNavigationShell), findsNothing);

    await tester.ensureVisible(find.text('Sign in or create account to save trip'));
    await tester.pump();
    await tester.tap(find.text('Sign in or create account to save trip'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));

    // AuthScreen (Register mode) -> lands on dashboard with onboarding trip saved
    expect(find.byType(AuthScreen), findsOneWidget);
    final fields = find.byType(TextField);
    await tester.enterText(fields.at(0), 'Clara Lim');
    await tester.enterText(fields.at(1), 'clara@lakbay.ph');
    await tester.enterText(fields.at(2), 'Password123!');
    await tester.enterText(fields.at(3), 'Password123!');
    await tester.ensureVisible(find.text('Create account'));
    await tester.pump();
    await tester.tap(find.text('Create account'));
    await tester.pump();
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 150)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));

    expect(repo.isSignedIn, isTrue);
    expect(repo.hasCompletedOnboarding, isTrue);
    expect(repo.savedTrips, isNotEmpty);
    expect(find.byType(MainNavigationShell), findsOneWidget);
  });

  testWidgets(
    'HomeChatScreen renders destination cards for show_places intent and plain text for question intent',
    (tester) async {
      final mockClient = MockClient((request) async {
        if (request.url.path == '/api/v1/ai/chat/guest') {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          final msg = (body['message'] ?? '').toString().toLowerCase();
          if (msg.contains('mountains in davao de oro')) {
            return http.Response(
              jsonEncode({
                'chat_response': 'Here are mountains in Davao de Oro.',
                'model_id': 'mock-groq',
                'ai_generation_run_id': 1,
                'planning': {
                  'input_revision': 0,
                  'intent': 'show_places',
                  'place_query': {
                    'categories': ['mountain'],
                    'province': 'Davao de Oro',
                    'limit': 5,
                  },
                  'suggested_replies': ['Check Samal beaches'],
                  'state_updates': {},
                  'update_status': 'no_changes',
                  'preview': {'state': body['planning_state']},
                  'recommendations': [
                    {
                      'destination_id': 77,
                      'name': 'Maragusan Sea of Clouds',
                      'district': 'Maragusan',
                      'category': 'Mountain',
                      'score': 88.5,
                      'matched_fields': ['category'],
                      'reasons': ['Matches mountain'],
                      'route_verified': true,
                      'travel_mode': 'driving',
                      'route_duration_minutes': 95,
                      'route_distance_km': '78.00',
                    },
                  ],
                  'recommendation_total_candidates': 1,
                },
              }),
              200,
            );
          }
          return http.Response(
            jsonEncode({
              'chat_response': 'Mornings are best for clear views!',
              'model_id': 'mock-groq',
              'ai_generation_run_id': 2,
              'planning': {
                'input_revision': 0,
                'intent': 'question',
                'suggested_replies': [],
                'state_updates': {},
                'update_status': 'no_changes',
                'preview': {'state': body['planning_state']},
                'recommendations': [
                  {
                    'destination_id': 88,
                    'name': 'Ignored Card',
                    'score': 50.0,
                    'matched_fields': [],
                    'reasons': [],
                    'route_verified': false,
                    'travel_mode': 'driving',
                  },
                ],
                'recommendation_total_candidates': 1,
              },
            }),
            200,
          );
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
            granted: false,
            statusMessage: 'Declined',
          ),
        ),
      );
      await tester.runAsync(() => repo.initialize());
      repo.setManualOrigin(
        label: 'Davao City',
        lat: 7.0731,
        lng: 125.6128,
      );

      await tester.pumpWidget(
        MaterialApp(
          home: HomeChatScreen(repo: repo),
        ),
      );
      await tester.pump();

      await tester.enterText(
        find.byType(TextField).first,
        'Show me mountains in Davao de Oro',
      );
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 120)));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 450));

      expect(find.text('Recommended Destinations'), findsOneWidget);
      expect(find.text('Maragusan Sea of Clouds'), findsOneWidget);
      expect(find.text('Mountain'), findsOneWidget);
      expect(find.text('Maragusan • ~95 min'), findsOneWidget);

      await tester.tap(find.text('+ Add'));
      await tester.pump();
      expect(
        repo.tripBuilderStops.any((s) => s.title == 'Maragusan Sea of Clouds'),
        isTrue,
      );
      expect(find.text('Added'), findsOneWidget);

      await tester.enterText(
        find.byType(TextField).first,
        'When is the best time to visit Davao?',
      );
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 120)));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      expect(find.text('Mornings are best for clear views!'), findsOneWidget);
      expect(find.text('Ignored Card'), findsNothing);
    },
  );

  test(
    'Single-place catalog loads 41 places, allows 12 tray stops, and migrates legacy combo favorites',
    () async {
      SharedPreferences.setMockInitialValues({
        'lakbay_traveler_state_v1': jsonEncode({
          'hasCompletedOnboarding': true,
          'legacyFavoritesMigrated': false,
          'bucketListTripIds': ['01KJKDPNA1XT4W2RHRA6GQVNVX', 'dead_combo_id', 'api_6'],
          'savedTrips': [
            {
              'id': '01KJKDPNA1XT4W2RHRA6GQVNVX',
              'title': '4-Day Samal & Talikud Island Hopping Escape',
              'destination': 'Samal Island',
              'daysCount': 4,
              'adults': 2,
              'children': 0,
              'centerLat': 7.0742,
              'centerLng': 125.7089,
              'heroAsset': 'assets/home_backdrops/01-samal-island.jpg',
              'vibeTag': 'Island',
              'overviewText': 'Saved legacy trip stays intact',
              'bestMonths': 'Dec - May',
              'avgTemp': '29°C',
              'wmoWeatherCode': 1,
              'expertName': 'Lakbay',
              'expertAvatarAsset': 'assets/home_backdrops/01-samal-island.jpg',
              'expertTip': 'Pack sunscreen',
              'days': [],
              'hotels': [],
              'flights': [],
            },
          ],
        }),
      });

      final repo = TravelRepository();
      await repo.initialize();

      expect(repo.allTrips.length, greaterThanOrEqualTo(41));
      expect(repo.suggestedRoutes.length, equals(20));
      expect(repo.bucketListTripIds, containsAll(['api_4', 'api_6']));
      expect(repo.bucketListTripIds, isNot(contains('01KJKDPNA1XT4W2RHRA6GQVNVX')));
      expect(repo.bucketListTripIds, isNot(contains('dead_combo_id')));
      expect(
        repo.savedTrips.any((t) => t.id == '01KJKDPNA1XT4W2RHRA6GQVNVX'),
        isTrue,
      );

      for (final place in repo.allTrips.take(15)) {
        repo.toggleTripBuilderStop(place);
      }
      expect(repo.tripBuilderStops.length, equals(12));
    },
  );

  testWidgets(
    'ExploreScreen shows single places with visit lengths and Suggested routes pre-filling tray',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final repo = TravelRepository();
      await tester.runAsync(() => repo.initialize());

      await tester.pumpWidget(
        MaterialApp(
          home: ExploreScreen(repo: repo),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Suggested routes'), findsOneWidget);
      final routeFinder = find.text('Samal & Talikud Island Hopping Escape');
      expect(routeFinder, findsOneWidget);
      expect(find.textContaining('＋ Add to trip'), findsWidgets);

      await tester.ensureVisible(routeFinder);
      await tester.pumpAndSettle();
      await tester.tap(routeFinder);
      await tester.pumpAndSettle();

      expect(repo.tripBuilderStops.length, equals(4));
      expect(find.textContaining('4 places selected'), findsOneWidget);
      expect(find.text('Plan trip'), findsOneWidget);
    },
  );

  test(
    'fetchRoadRouteForTrip refreshes expired tokens on 401 and falls back to /routes/plan/guest when refresh fails',
    () async {
      SharedPreferences.setMockInitialValues({});
      var refreshAllowed = true;
      var previewCalls = 0;
      var guestPlanCalls = 0;
      final mockClient = MockClient((request) async {
        final path = request.url.path;
        final auth = request.headers['Authorization'] ?? '';
        if (path == '/api/v1/auth/login') {
          return http.Response(
            jsonEncode({
              'tokens': {
                'access_token': 'expired_access',
                'refresh_token': 'valid_refresh',
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
        if (path == '/api/v1/auth/refresh') {
          if (!refreshAllowed) {
            return http.Response(jsonEncode({'detail': 'Expired refresh'}), 401);
          }
          return http.Response(
            jsonEncode({
              'tokens': {
                'access_token': 'fresh_access',
                'refresh_token': 'fresh_refresh',
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
        if (path == '/api/v1/routes/preview') {
          previewCalls++;
          if (auth != 'Bearer fresh_access' || !refreshAllowed) {
            return http.Response(jsonEncode({'detail': 'Unauthorized'}), 401);
          }
          return http.Response(
            jsonEncode({
              'route_provider': 'osrm+sea_links',
              'is_estimated': false,
              'total_distance_km': 33.4,
              'total_duration_minutes': 76,
              'polyline': '_p~iF~ps|U_ulLnnqC',
              'stops': [
                {'destination_id': 16, 'name': 'Aqua Water Park', 'lat': 7.087, 'lng': 125.667},
              ],
            }),
            200,
          );
        }
        if (path == '/api/v1/routes/plan/guest') {
          guestPlanCalls++;
          return http.Response(
            jsonEncode({
              'order_method': 'requested',
              'cost_source': 'osrm+sea_links',
              'pace': 'balanced',
              'suggested_days': 1,
              'warnings': [],
              'skipped_destination_ids': [],
              'days': [],
              'route': {
                'route_provider': 'osrm+sea_links',
                'is_estimated': false,
                'total_distance_km': 33.4,
                'total_duration_minutes': 76,
                'polyline': '_p~iF~ps|U_ulLnnqC',
                'stops': [
                  {'destination_id': 16, 'name': 'Aqua Water Park', 'lat': 7.087, 'lng': 125.667},
                ],
              },
            }),
            200,
          );
        }
        if (path == '/api/v1/destinations' || path == '/api/v1/trips') {
          return http.Response('[]', 200);
        }
        if (path == '/api/v1/notifications/unread-count') {
          return http.Response(jsonEncode({'unread_count': 0}), 200);
        }
        return http.Response('{}', 200);
      });

      final repo = TravelRepository(
        apiCatalog: LakbayApiCatalogService(
          client: mockClient,
          baseUrlOverride: 'https://api.lakbay.test/api/v1',
        ),
      );
      await repo.initialize();
      await repo.signInWithBackend(
        email: 'marco@lakbay.ph',
        password: 'password123',
      );
      final trip = ItineraryTrip(
        id: 'panabo_aqua',
        title: 'Aqua Water Park',
        destination: 'Samal',
        daysCount: 1,
        centerLat: 7.087,
        centerLng: 125.667,
        heroAsset: 'assets/home_backdrops/01-samal-island.jpg',
        vibeTag: 'Island',
        overviewText: 'Samal water park day trip.',
        bestMonths: 'Dec - May',
        avgTemp: '29°C',
        expertName: 'Carla',
        expertTip: 'Arrive before midday.',
        days: const [],
        flights: const [],
        hotels: const [],
        backendDestinationIds: const [16],
      );

      final refreshedRoute = await repo.fetchRoadRouteForTrip(trip);
      expect(refreshedRoute, isNotNull);
      expect(refreshedRoute!.isEstimated, isFalse);
      expect(refreshedRoute.geometryPoints.length, equals(2));
      expect(repo.authSession?.accessToken, equals('fresh_access'));
      expect(previewCalls, equals(2));
      expect(guestPlanCalls, equals(0));

      // Even if refresh is rejected, road geometry still loads via /routes/plan/guest.
      refreshAllowed = false;
      final guestFallback = await repo.fetchRoadRouteForTrip(trip);
      expect(guestFallback, isNotNull);
      expect(guestFallback!.isEstimated, isFalse);
      expect(guestFallback.geometryPoints.length, equals(2));
      expect(guestPlanCalls, equals(1));
    },
  );
}
