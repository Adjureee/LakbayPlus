import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:lakbay_travel/models/travel_models.dart';
import 'package:lakbay_travel/services/travel_repository.dart';

void main() {
  test('All Region XI ExploreTrip fallback assets map strictly to Davao backdrops', () {
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

    for (final trip in samples) {
      expect(trip.localAssetPath, startsWith('assets/home_backdrops/'));
      expect(trip.localAssetPath, isNot(contains('thoddoo')));
      expect(trip.localAssetPath, isNot(contains('seceda')));
      expect(trip.localAssetPath, isNot(contains('explore/trip_images')));
      expect(File(trip.localAssetPath).existsSync(), isTrue,
          reason: 'Expected ${trip.localAssetPath} to exist on disk');
    }
  });

  test('Manifest & explore_trips.csv contain zero legacy foreign destinations', () {
    final manifest = File('assets/home_backdrops/manifest.json').readAsStringSync();
    final csv = File('assets/data/explore_trips.csv').readAsStringSync();
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

  test('Thesis models parse expense age-split, 80% alert, TOPSIS ranking, and memories', () {
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

    final top = TopPlacesResult.fromJson({
      'method': 'topsis',
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
    expect(top.method, 'topsis');
    expect(top.items.single.name, 'Dahican Beach');
    expect(top.items.single.score, closeTo(94.5, 0.01));

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
}
