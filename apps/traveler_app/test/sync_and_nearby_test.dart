import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lakbay_travel/models/travel_models.dart';
import 'package:lakbay_travel/services/lakbay_api_catalog_service.dart';
import 'package:lakbay_travel/services/nearby_places.dart';
import 'package:lakbay_travel/services/travel_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

ExploreTrip _place(int id, String title, double lat, double lng) => ExploreTrip(
      locale: 'en',
      id: 'api_$id',
      apiDestinationId: id,
      title: title,
      lat: lat,
      lng: lng,
      thumbnailUrl: '',
    );

Map<String, dynamic> _row(
  int id,
  String name,
  double lat,
  double lng, {
  String fee = 'PHP 50',
}) =>
    {
      'destination_id': id,
      'name': name,
      'district': 'Maragusan, Davao de Oro',
      'category': 'Waterfall',
      'lat': lat,
      'lng': lng,
      'description': 'Falls in Maragusan.',
      'entrance_fee': fee,
      'is_active': true,
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('nearbyPlacesForTrip', () {
    final tagbibinta = _place(8, 'Tagbibinta Falls', 7.3164, 126.1719);
    final pyalitan = _place(26, 'Pyalitan Falls', 7.2992, 126.1707); // ~2 km
    final mainit = _place(9, 'Mainit Hot Springs', 7.4014, 126.0289); // ~17 km
    final samal = _place(4, 'Samal Island Beach Area', 7.0744, 125.7087);

    test('finds catalog places near the trip, nearest first, not its own', () {
      final trip = TravelRepository().buildDetailedItineraryFromExplore(
        tagbibinta,
      );
      final nearby = nearbyPlacesForTrip(
        trip,
        [tagbibinta, mainit, pyalitan, samal],
        radiusKm: 20,
      );
      expect(nearby.map((n) => n.place.title), [
        'Pyalitan Falls',
        'Mainit Hot Springs',
      ]);
      expect(nearby.first.distanceKm, closeTo(1.9, 0.3));
      expect(nearby.first.nearestStopName, 'Tagbibinta Falls');
    });

    test('respects radius and limit', () {
      final trip = TravelRepository().buildDetailedItineraryFromExplore(
        tagbibinta,
      );
      expect(
        nearbyPlacesForTrip(trip, [mainit, pyalitan], radiusKm: 10)
            .map((n) => n.place.title),
        ['Pyalitan Falls'],
      );
      expect(
        nearbyPlacesForTrip(trip, [mainit, pyalitan], radiusKm: 50, limit: 1),
        hasLength(1),
      );
    });

    test('addPlaceToTrip inserts after the closest stop and routes it', () {
      final trip = TravelRepository().buildDetailedItineraryFromExplore(
        tagbibinta,
      );
      final updated = addPlaceToTrip(trip, pyalitan);
      final titles = updated.days.first.stops.map((s) => s.title).toList();
      expect(titles, ['Tagbibinta Falls', 'Pyalitan Falls']);
      expect(updated.effectiveBackendDestinationIds, [8, 26]);
      expect(updated.routeSegments, isEmpty);
      // Adding the same place again changes nothing.
      expect(identical(addPlaceToTrip(updated, pyalitan), updated), isTrue);
    });
  });

  group('catalog sync', () {
    test('fee-only admin edit and a moved pin both reach the app', () async {
      var feeText = 'PHP 50';
      var lat = 7.3164;
      final api = LakbayApiCatalogService(
        baseUrlOverride: 'https://api.lakbay.test/api/v1',
        client: MockClient((request) async {
          final offset = request.url.queryParameters['offset'];
          final rows = offset == '0'
              ? [_row(8, 'Tagbibinta Falls', lat, 126.1719, fee: feeText)]
              : const [];
          return http.Response(jsonEncode(rows), 200);
        }),
      );
      final repo = TravelRepository(apiCatalog: api);
      await repo.refreshFromApi();
      expect(repo.allTrips.firstWhere((t) => t.id == 'api_8').entranceFee,
          'PHP 50');

      final saved = repo.buildDetailedItineraryFromExplore(
        repo.allTrips.firstWhere((t) => t.id == 'api_8'),
      );
      repo.saveTripToMyTrips(saved);

      // Admin changes only the fee, then moves the pin ~1 km.
      feeText = 'PHP 80';
      await repo.refreshFromApi();
      expect(repo.allTrips.firstWhere((t) => t.id == 'api_8').entranceFee,
          'PHP 80');

      lat = 7.3254;
      await repo.refreshFromApi();
      final trip = repo.savedTrips.firstWhere((t) => t.id == saved.id);
      expect(trip.days.first.stops.first.lat, 7.3254);
      expect(trip.days.first.lat, 7.3254);
    });
  });
}
