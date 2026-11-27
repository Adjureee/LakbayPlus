import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:lakbay_travel/models/travel_models.dart';
import 'package:lakbay_travel/screens/explore_screen.dart';
import 'package:lakbay_travel/services/lakbay_api_catalog_service.dart';
import 'package:lakbay_travel/services/travel_repository.dart';

void main() {
  test('An ExploreTrip bundled photo is only ever its own place and exists on disk', () {
    const samples = [
      ExploreTrip(
        locale: 'en',
        id: 'api_1',
        title: 'Samal Coral Reefs — Davao del Norte',
        days: 2,
        lat: 7.07,
        lng: 125.70,
        thumbnailUrl: '',
      ),
      ExploreTrip(
        locale: 'en',
        id: 'api_2',
        title: 'Dahican Beach — Mati, Davao Oriental',
        days: 3,
        lat: 6.95,
        lng: 126.21,
        thumbnailUrl: '',
      ),
      ExploreTrip(
        locale: 'en',
        id: 'api_3',
        title: 'BuDa Highland Ridge — Marilog',
        days: 2,
        lat: 7.45,
        lng: 125.25,
        thumbnailUrl: '',
      ),
      ExploreTrip(
        locale: 'en',
        id: 'api_4',
        title: 'Aliwagwag Falls — Cateel',
        days: 2,
        lat: 7.73,
        lng: 126.31,
        thumbnailUrl: '',
      ),
    ];

    // Only a place that is the photo's own subject has a bundled photo; the rest
    // get none (the card shows a placeholder), never a nearby region's photo.
    const ownPhoto = {'api_2', 'api_4'}; // Dahican Beach, Aliwagwag Falls
    for (final trip in samples) {
      if (!ownPhoto.contains(trip.id)) {
        expect(trip.localAssetPath, isEmpty, reason: trip.title);
        continue;
      }
      expect(trip.localAssetPath, startsWith('assets/home_backdrops/'));
      expect(trip.localAssetPath, isNot(contains('thoddoo')));
      expect(trip.localAssetPath, isNot(contains('seceda')));
      expect(trip.localAssetPath, isNot(contains('explore/trip_images')));
      expect(File(trip.localAssetPath).existsSync(), isTrue,
          reason: 'Expected ${trip.localAssetPath} to exist on disk');
    }
  });

  test('Manifest & places.csv contain zero legacy foreign destinations and no days column', () {
    final manifest = File('assets/home_backdrops/manifest.json').readAsStringSync();
    final csv = File('assets/data/places.csv').readAsStringSync();
    final header = const LineSplitter().convert(csv).first.split(',');
    expect(
      header,
      equals([
        'id',
        'name',
        'district',
        'category',
        'lat',
        'lng',
        'island_group',
        'stay_duration_type',
        'thumbnail',
      ]),
    );
    expect(header, isNot(contains('days')));
    for (final forbidden in [
      'zakynthos',
      'thoddoo',
      'seceda',
      'whitehaven',
      'lago-di-braies',
      'lake-louise',
      'explore/trip_images',
    ]) {
      expect(manifest.toLowerCase(), isNot(contains(forbidden)));
      expect(csv.toLowerCase(), isNot(contains(forbidden)));
    }
    expect(csv, contains('res.cloudinary.com/bh2rda7z'));
  });

  test('Local Davao trip does not fabricate domestic flights or Pearl Farm mock', () {
    final repo = TravelRepository();
    final samal = repo.generateCustomTrip(
      destination: 'Samal Island, Davao del Norte',
      daysCount: 3,
      vibe: 'Island Hopping',
      includeFlights: false,
    );

    expect(samal.isLocalOnly, isTrue);
    expect(samal.flights, isEmpty);
    expect(
      samal.hotels.any((h) => h.name.contains('Pearl Farm')),
      isFalse,
    );
    expect(samal.totalEstimatedCostUsd, lessThan(400));
  });

  test('Multi-stop Explore Trip Builder produces optimized Region XI route', () async {
    final repo = TravelRepository();
    const samal = ExploreTrip(
      locale: 'en',
      id: 'api_10',
      title: 'Hagimit Falls — Samal',
      days: 1,
      lat: 7.05,
      lng: 125.71,
      thumbnailUrl: 'https://res.cloudinary.com/bh2rda7z/image/upload/v1/lakbay/test1.jpg',
      apiDestinationId: 10,
      whatToBring: 'Aqua shoes, Dry bag',
    );
    const mati = ExploreTrip(
      locale: 'en',
      id: 'api_20',
      title: 'Dahican Surf — Mati',
      days: 2,
      lat: 6.95,
      lng: 126.21,
      thumbnailUrl: 'https://res.cloudinary.com/bh2rda7z/image/upload/v1/lakbay/test2.jpg',
      apiDestinationId: 20,
      whatToBring: 'Sunscreen, Towel',
    );
    const davao = ExploreTrip(
      locale: 'en',
      id: 'api_30',
      title: 'Malagos Garden — Davao City',
      days: 1,
      lat: 7.18,
      lng: 125.43,
      thumbnailUrl: 'https://res.cloudinary.com/bh2rda7z/image/upload/v1/lakbay/test3.jpg',
      apiDestinationId: 30,
      whatToBring: 'Camera, Rain jacket',
    );

    repo.toggleTripBuilderStop(samal);
    repo.toggleTripBuilderStop(mati);
    repo.toggleTripBuilderStop(davao);
    expect(repo.tripBuilderStops.length, 3);

    final built = await repo.buildMultiStopExploreTrip(daysCount: 3, travelers: 2);
    expect(built.daysCount, 3);
    expect(built.backendDestinationIds, containsAll([10, 20, 30]));
    expect(built.whatToBring, contains('Aqua shoes'));
    expect(built.remoteImageUrl, startsWith('https://res.cloudinary.com/bh2rda7z'));
    expect(repo.tripBuilderStops, isEmpty);

    final optimized = await repo.optimizeStopsForTrip(built);
    expect(optimized.days.length, 3);
  });

  test('ChatMessage & AiItineraryOptionDraft round-trip JSON cleanly', () {
    final repo = TravelRepository();
    final trip = repo.generateCustomTrip(
      destination: 'Mati Dahican, Davao Oriental',
      daysCount: 2,
      vibe: 'Budget Surf',
      remoteImageUrl: 'https://res.cloudinary.com/bh2rda7z/image/upload/v1/lakbay/mati.jpg',
    );
    final msg = ChatMessage(
      id: 'ai_1',
      isUser: false,
      text: 'Here are two curated options for Mati.',
      timestamp: DateTime(2026, 11, 15, 14, 0),
      aiOptions: [
        AiItineraryOptionDraft(
          optionNumber: 1,
          title: 'Budget Mati Surf Escape',
          summary: 'Transit van + Dahican sunrise',
          estimatedTotalCostPhp: 4500,
          isOverBudget: false,
          generationRunId: 42,
          trip: trip,
        ),
      ],
    );

    final restored = ChatMessage.fromJson(msg.toJson());
    expect(restored.aiOptions, hasLength(1));
    expect(restored.aiOptions.first.optionNumber, 1);
    expect(restored.aiOptions.first.generationRunId, 42);
    expect(restored.aiOptions.first.trip.remoteImageUrl,
        'https://res.cloudinary.com/bh2rda7z/image/upload/v1/lakbay/mati.jpg');
  });

  test('Thesis models parse expense age-split, 80% alert, weighted SAW ranking default, and memories', () {
    final summary = TripExpenseSummary.fromJson({
      'trip_id': 7,
      'total_budget': '1000.00',
      'total_spent': '850.00',
      'remaining_budget': '150.00',
      'over_budget_amount': '0.00',
      'is_over_budget': false,
      'percent_used': '85.00',
      'budget_alert_level': 'warning_80',
      'adult_count': 2,
      'child_count': 1,
      'adult_share': '340.00',
      'child_share': '170.00',
      'category_breakdown': [
        {'category': 'meals', 'total': '850.00'},
      ],
      'member_balances': [],
    });
    expect(summary.budgetAlertLevel, 'warning_80');
    expect(summary.adultShare, closeTo(340.0, 0.01));
    expect(summary.childShare, closeTo(170.0, 0.01));

    final topDefault = TopPlacesResult.fromJson({
      'items': [
        {
          'rank': 1,
          'destination_id': 42,
          'name': 'Dahican Beach',
          'district': 'Mati City',
          'category': 'beach',
          'score': 94.5,
          'reasons': ['Matches beach'],
          'route_verified': true,
          'travel_mode': 'driving',
        },
      ],
    });
    expect(topDefault.method, 'simple_additive_weighting');
    expect(topDefault.items.single.name, 'Dahican Beach');
    expect(topDefault.items.single.score, closeTo(94.5, 0.01));

    final topSaw = TopPlacesResult.fromJson({
      'method': 'simple_additive_weighting',
      'items': const [],
    });
    expect(topSaw.method, 'simple_additive_weighting');

    final memory = TripMemoryItem.fromJson({
      'trip_memory_id': 11,
      'trip_id': 7,
      'uploaded_by_full_name': 'Andrea Reyes',
      'image_url': 'https://res.cloudinary.com/bh2rda7z/image/upload/v1/lakbay/test.jpg',
      'caption': 'Sunset swim',
      'location_tag': 'Samal Island',
      'like_count': 3,
      'created_at': '2026-11-15T12:00:00Z',
    });
    expect(memory.caption, 'Sunset swim');
    expect(memory.likeCount, 3);
  });

  test('fetchTopPlaces sends simple_additive_weighting by default', () async {
    String? sentRankingMethod;
    final client = MockClient((req) async {
      final body = jsonDecode(req.body) as Map<String, dynamic>;
      sentRankingMethod = body['ranking_method'] as String?;
      return http.Response(
        jsonEncode({
          'method': 'simple_additive_weighting',
          'items': const [],
        }),
        200,
      );
    });
    final api = LakbayApiCatalogService(
      client: client,
      baseUrlOverride: 'https://api.lakbay.test',
    );
    final result = await api.fetchTopPlaces('token', interests: ['beach']);
    expect(sentRankingMethod, 'simple_additive_weighting');
    expect(result?.method, 'simple_additive_weighting');
  });

  testWidgets('Top 5 sheet shows no method chips and invents no offline ranking', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final repo = TravelRepository(
      apiCatalog: LakbayApiCatalogService(baseUrlOverride: ''),
    );
    await tester.runAsync(() async {
      await repo.initialize();
    });

    await tester.pumpWidget(
      MaterialApp(
        home: ExploreScreen(repo: repo),
      ),
    );
    await tester.pump();

    await tester.tap(find.text('Top 5 for you'));
    await tester.pumpAndSettle();

    expect(find.text('Personalized Top 5'), findsOneWidget);
    expect(find.textContaining('TOPSIS'), findsNothing);
    expect(find.textContaining('Weighted SAW'), findsNothing);
    expect(find.textContaining('Method:'), findsNothing);
    // Preferences come from the server; offline there are none to choose from,
    // and none is pre-selected or typed into the app.
    expect(find.text('Preferences load from Lakbay when you are online.'),
        findsOneWidget);
    expect(find.byType(FilterChip), findsNothing);

    await tester.tap(find.text('Rank Top 5'));
    await tester.pumpAndSettle();

    // Signed out: no invented offline matches or scores, just the reason.
    expect(find.text('Sign in to get matches ranked for you.'), findsOneWidget);
    expect(find.textContaining('Match '), findsNothing);
    expect(find.textContaining('Fits your interests'), findsNothing);
  });
}
