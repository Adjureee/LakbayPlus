import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lakbay_travel/models/travel_models.dart';
import 'package:lakbay_travel/screens/memories_screen.dart';
import 'package:lakbay_travel/screens/trip_detail_screen.dart';
import 'package:lakbay_travel/services/lakbay_api_catalog_service.dart';
import 'package:lakbay_travel/services/travel_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _jpegSample = Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3, 4]);
final _validPngSample = Uint8List.fromList([
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D,
  0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x02, 0x00, 0x00, 0x00, 0x90, 0x77, 0x53, 0xDE, 0x00, 0x00, 0x00,
  0x0C, 0x49, 0x44, 0x41, 0x54, 0x08, 0xD7, 0x63, 0xF8, 0xFF, 0xFF, 0x3F,
  0x00, 0x05, 0xFE, 0x02, 0xFE, 0xDC, 0xCC, 0x59, 0xE7, 0x00, 0x00, 0x00,
  0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
]);

ItineraryTrip _sampleTrip({
  int? backendTripId = 77,
  String backendStatus = 'planned',
  DateTime? endDate,
}) =>
    ItineraryTrip(
      id: 'trip_samal_77',
      title: 'Samal Escape',
      destination: 'Samal Island',
      daysCount: 2,
      centerLat: 7.05,
      centerLng: 125.71,
      heroAsset: 'assets/home_backdrops/01-samal-island.jpg',
      remoteImageUrl: 'https://cdn.example.com/samal-stock.jpg',
      vibeTag: 'Beaches',
      overviewText: 'Island getaway.',
      bestMonths: 'Dec – May',
      avgTemp: '29°C',
      expertName: 'Lakbay+ AI',
      expertTip: 'Arrive early at Sasa Wharf.',
      days: const [],
      flights: const [],
      hotels: const [],
      backendTripId: backendTripId,
      backendDestinationIds: const [12],
      backendStatus: backendStatus,
      endDate: endDate,
    );

Map<String, dynamic> _signedInState(ItineraryTrip? trip) => {
      'hasCompletedOnboarding': true,
      if (trip != null) 'savedTrips': [trip.toJson()],
      'authSession': {
        'accessToken': 'jwt_tok_1',
        'refreshToken': 'ref_tok_1',
        'userId': 9,
        'email': 'ana@lakbay.ph',
        'fullName': 'Ana Reyes',
      },
    };

void main() {
  setUp(() {
    GoogleFonts.config.allowRuntimeFetching = false;
    SharedPreferences.setMockInitialValues({});
  });

  test('uploadAndAddMemory sends image/jpeg bytes and retries 1 transient failure automatically', () async {
    var uploadAttempts = 0;
    String? sentFilename;
    SharedPreferences.setMockInitialValues({
      'lakbay_traveler_state_v1': jsonEncode(_signedInState(_sampleTrip())),
    });

    final client = MockClient((request) async {
      if (request.url.path == '/api/v1/trips/77/memories/upload') {
        uploadAttempts++;
        sentFilename = utf8.decode(request.bodyBytes, allowMalformed: true);
        if (uploadAttempts == 1) {
          return http.Response('{"detail":"Temporary upstream error"}', 503);
        }
        return http.Response(
          jsonEncode({
            'image_url': 'https://res.cloudinary.com/demo/image/upload/sunset.jpg',
            'cloudinary_public_id': 'lakbay/trips/77/memories/sunset',
          }),
          200,
        );
      }
      if (request.url.path == '/api/v1/trips/77/memories' &&
          request.method == 'POST') {
        return http.Response(
          jsonEncode({
            'trip_memory_id': 501,
            'trip_id': 77,
            'uploaded_by_full_name': 'Ana Reyes',
            'image_url': 'https://res.cloudinary.com/demo/image/upload/sunset.jpg',
            'caption': 'Sunset dock',
            'location_tag': 'Samal Island',
            'like_count': 0,
            'comment_count': 0,
            'created_at': DateTime.now().toIso8601String(),
          }),
          201,
        );
      }
      return http.Response('[]', 200);
    });

    final repo = TravelRepository(
      apiCatalog: LakbayApiCatalogService(
        baseUrlOverride: 'https://api.lakbay.test/api/v1',
        client: client,
      ),
    );
    await repo.initialize();

    final created = await repo.uploadAndAddMemory(
      trip: repo.savedTrips.first,
      imageBytes: _jpegSample,
      fileName: 'sunset.jpg',
      caption: 'Sunset dock',
      locationTag: 'Samal Island',
    );

    expect(uploadAttempts, 2);
    expect(sentFilename, contains('image/jpeg'));
    expect(created, isNotNull);
    expect(created!.isOutbox, isFalse);
    expect(created.tripMemoryId, 501);
    expect(repo.memories.single.caption, 'Sunset dock');
  });

  testWidgets('Failed upload queues explicit outbox item (no fake thumbnail) and Retry promotes on confirmation', (
    tester,
  ) async {
    var shouldFail = true;
    SharedPreferences.setMockInitialValues({
      'lakbay_traveler_state_v1': jsonEncode(_signedInState(_sampleTrip())),
    });

    final client = MockClient((request) async {
      if (request.url.path == '/api/v1/trips/77/memories/upload') {
        if (shouldFail) {
          return http.Response('{"detail":"Storage unreachable"}', 502);
        }
        return http.Response(
          jsonEncode({
            'image_url': 'https://res.cloudinary.com/demo/image/upload/beach.jpg',
            'cloudinary_public_id': 'lakbay/beach',
          }),
          200,
        );
      }
      if (request.url.path == '/api/v1/trips/77/memories' &&
          request.method == 'POST') {
        return http.Response(
          jsonEncode({
            'trip_memory_id': 888,
            'trip_id': 77,
            'uploaded_by_full_name': 'Ana Reyes',
            'image_url': 'https://res.cloudinary.com/demo/image/upload/beach.jpg',
            'caption': 'Beach morning',
            'location_tag': 'Samal Island',
            'like_count': 0,
            'comment_count': 0,
            'created_at': DateTime.now().toIso8601String(),
          }),
          201,
        );
      }
      return http.Response('[]', 200);
    });

    final repo = TravelRepository(
      apiCatalog: LakbayApiCatalogService(
        baseUrlOverride: 'https://api.lakbay.test/api/v1',
        client: client,
      ),
    );
    await tester.runAsync(() => repo.initialize());

    final outbox = await tester.runAsync(
      () => repo.uploadAndAddMemory(
        trip: repo.savedTrips.first,
        imageBytes: _validPngSample,
        fileName: 'beach.png',
        caption: 'Beach morning',
      ),
    );

    expect(outbox, isNotNull);
    expect(outbox!.isOutbox, isTrue);
    expect(outbox.imageUrl, isEmpty);

    await tester.pumpWidget(MaterialApp(home: MemoriesScreen(repo: repo)));
    await tester.pumpAndSettle();

    expect(find.textContaining('Not uploaded yet.'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);

    shouldFail = false;
    await tester.tap(find.text('Retry'));
    await tester.pump();
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pumpAndSettle();

    expect(find.textContaining('Not uploaded yet.'), findsNothing);
    expect(repo.memories.single.isOutbox, isFalse);
    expect(repo.memories.single.tripMemoryId, 888);
  });

  test('Archived trips, signed-out users, and 404 pending invitees explain rules without local fallback', () async {
    SharedPreferences.setMockInitialValues({
      'lakbay_traveler_state_v1': jsonEncode(
        _signedInState(_sampleTrip(backendStatus: 'archived')),
      ),
    });

    final client404 = MockClient((request) async {
      if (request.url.path.contains('/memories/upload')) {
        return http.Response('{"detail":"Trip not found"}', 404);
      }
      return http.Response('[]', 200);
    });

    final repo = TravelRepository(
      apiCatalog: LakbayApiCatalogService(
        baseUrlOverride: 'https://api.lakbay.test/api/v1',
        client: client404,
      ),
    );
    await repo.initialize();

    await expectLater(
      () => repo.uploadAndAddMemory(
        trip: repo.savedTrips.first,
        imageBytes: _jpegSample,
        fileName: 'a.jpg',
      ),
      throwsA(
        isA<LakbayApiException>().having(
          (e) => e.message,
          'message',
          contains('Archived trips are read-only'),
        ),
      ),
    );
    expect(repo.memories, isEmpty);

    // Pending / unaccepted invitee returns 404 -> actionable invitation rule
    await expectLater(
      () => repo.uploadAndAddMemory(
        trip: _sampleTrip(backendStatus: 'planned'),
        imageBytes: _jpegSample,
        fileName: 'a.jpg',
      ),
      throwsA(
        isA<LakbayApiException>().having(
          (e) => e.message,
          'message',
          contains('Accept your trip invitation'),
        ),
      ),
    );
    expect(repo.memories, isEmpty);
  });

  test('likeMemory confirms server count and rolls back optimistic increment on failure', () async {
    var failLike = false;
    SharedPreferences.setMockInitialValues({
      'lakbay_traveler_state_v1': jsonEncode(_signedInState(_sampleTrip())),
    });

    final client = MockClient((request) async {
      if (request.url.path == '/api/v1/trips/77/memories/12/likes') {
        if (failLike) return http.Response('{"detail":"Server error"}', 500);
        return http.Response(
          jsonEncode({
            'trip_memory_id': 12,
            'trip_id': 77,
            'uploaded_by_full_name': 'Ana Reyes',
            'image_url': 'https://res.cloudinary.com/demo/image/upload/p.jpg',
            'like_count': 4,
            'comment_count': 0,
            'created_at': DateTime.now().toIso8601String(),
          }),
          200,
        );
      }
      if (request.url.path == '/api/v1/trips/77/memories') {
        return http.Response(
          jsonEncode([
            {
              'trip_memory_id': 12,
              'trip_id': 77,
              'uploaded_by_full_name': 'Ana Reyes',
              'image_url': 'https://res.cloudinary.com/demo/image/upload/p.jpg',
              'like_count': 3,
              'comment_count': 0,
              'created_at': DateTime.now().toIso8601String(),
            }
          ]),
          200,
        );
      }
      return http.Response('[]', 200);
    });

    final repo = TravelRepository(
      apiCatalog: LakbayApiCatalogService(
        baseUrlOverride: 'https://api.lakbay.test/api/v1',
        client: client,
      ),
    );
    await repo.initialize();
    await repo.refreshMemoriesForSavedTrips();

    expect(repo.memories.single.likeCount, 3);
    final ok = await repo.likeMemory(repo.memories.single);
    expect(ok, isTrue);
    expect(repo.memories.single.likeCount, 4);

    failLike = true;
    final failed = await repo.likeMemory(repo.memories.single);
    expect(failed, isFalse);
    expect(repo.memories.single.likeCount, 4);
  });

  testWidgets('Empty trips guide traveler to Plan a trip, and post-trip & TripDetail entry points appear', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'lakbay_traveler_state_v1': jsonEncode(_signedInState(null)),
    });
    final repoNoTrips = TravelRepository(
      apiCatalog: LakbayApiCatalogService(baseUrlOverride: ''),
    );
    await tester.runAsync(() => repoNoTrips.initialize());

    await tester.pumpWidget(MaterialApp(home: MemoriesScreen(repo: repoNoTrips)));
    await tester.pumpAndSettle();

    expect(find.text('Plan a trip to start your album'), findsOneWidget);
    await tester.tap(find.text('Plan a trip'));
    await tester.pump();
    expect(repoNoTrips.activeNavIndex, 2);

    // Post-trip prompt + TripDetailScreen entry point
    final endedTrip = _sampleTrip(
      backendStatus: 'completed',
      endDate: DateTime.now().subtract(const Duration(days: 1)),
    );
    SharedPreferences.setMockInitialValues({
      'lakbay_traveler_state_v1': jsonEncode(_signedInState(endedTrip)),
    });
    final repoWithEnded = TravelRepository(
      apiCatalog: LakbayApiCatalogService(baseUrlOverride: ''),
    );
    await tester.runAsync(() => repoWithEnded.initialize());

    await tester.pumpWidget(MaterialApp(home: MemoriesScreen(repo: repoWithEnded)));
    await tester.pumpAndSettle();
    expect(find.textContaining('How was Samal Escape?'), findsOneWidget);

    // The screen is a lazy list, so a taller view keeps every entry built.
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(800, 2400);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: TripDetailScreen(trip: endedTrip, repo: repoWithEnded),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Add memory'), findsWidgets);
    await tester.dragUntilVisible(
      find.text('Trip Memories'),
      find.byType(ListView).first,
      const Offset(0, -250),
    );
    expect(find.text('Trip Memories'), findsOneWidget);
  });
}
