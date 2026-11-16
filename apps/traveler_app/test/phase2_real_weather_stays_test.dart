import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lakbay_travel/models/travel_models.dart';
import 'package:lakbay_travel/screens/trip_detail_screen.dart';
import 'package:lakbay_travel/services/lakbay_api_catalog_service.dart';
import 'package:lakbay_travel/services/location_service.dart';
import 'package:lakbay_travel/services/travel_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

String _date(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

class _Server {
  _Server({this.forecastDays = 0, this.stays = const []});

  final int forecastDays;
  final List<Map<String, dynamic>> stays;
  var forecastCalls = 0;

  MockClient get client => MockClient((request) async {
        final path = request.url.path.replaceFirst('/api/v1', '');
        if (path == '/destinations/5/accommodations') {
          return http.Response(jsonEncode(stays), 200);
        }
        if (path == '/destinations/5/transportations') {
          return http.Response('[]', 200);
        }
        if (path == '/weather/current') {
          return http.Response(
            jsonEncode({
              'temp_c': 31.4,
              'condition': {'code': 800, 'main': 'Clear', 'description': 'clear sky'},
            }),
            200,
          );
        }
        if (path == '/weather/forecast') {
          forecastCalls++;
          final today = DateTime.now();
          return http.Response(
            jsonEncode({
              'lat': 7.0,
              'lng': 125.0,
              'days': [
                for (var i = 0; i < forecastDays; i++)
                  {
                    'date': _date(today.add(Duration(days: i))),
                    'temp_avg_c': 28.0 + i,
                    'rain_chance_percent': 10,
                    'advisory': '',
                    'condition': {'code': 801, 'main': 'Clouds', 'description': 'few clouds'},
                  },
              ],
            }),
            200,
          );
        }
        return http.Response('{}', 404);
      });
}

Future<TravelRepository> _signedInRepo(_Server server) async {
  SharedPreferences.setMockInitialValues({
    'lakbay_traveler_state_v1': jsonEncode({
      'hasCompletedOnboarding': true,
      'authSession': const LakbayAuthSession(
        accessToken: 'token',
        refreshToken: 'refresh',
        userId: 2,
        fullName: 'Weather Tester',
        email: 'w@example.com',
        role: 'traveler',
      ).toJson(),
    }),
  });
  final repo = TravelRepository(
    apiCatalog: LakbayApiCatalogService(
      baseUrlOverride: 'https://api.lakbay.test/api/v1',
      client: server.client,
    ),
    locationService: LocationService(
      customFetcher: () async => const LocationResult(
        granted: false,
        statusMessage: 'Declined',
      ),
    ),
  );
  await repo.initialize();
  return repo;
}

ItineraryTrip _threeDayTrip(TravelRepository repo) => repo
    .generateCustomTrip(destination: 'Samal Island', daysCount: 3, vibe: 'Beach')
    .copyWith(backendDestinationIds: [5]);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('stays only say what the catalog says', () {
    test('a stay saved by an older version (made-up rating and price) is dropped', () {
      final legacy = {
        'id': 'ht_1',
        'name': 'Samal Eco Lodge & Resort Stay',
        'city': 'Samal',
        'rating': 9.2,
        'stars': 4,
        'pricePerNightUsd': 65,
        'partnerName': 'Region XI Estimate',
        'lat': 7.1,
        'lng': 125.7,
      };
      expect(HotelOffer.tryFromJson(legacy), isNull);

      final trip = TravelRepository()
          .generateCustomTrip(destination: 'Samal', daysCount: 2, vibe: 'Beach')
          .toJson()
        ..['hotels'] = [legacy];
      expect(ItineraryTrip.fromJson(trip).hotels, isEmpty);
    });

    test('a catalog stay keeps unknowns unknown and survives saving', () {
      const stay = HotelOffer(
        id: 'acc_7',
        name: 'Hagimit Beach House',
        city: 'Samal',
        lat: 7.1,
        lng: 125.7,
      );
      expect(stay.rating, isNull);
      expect(stay.stars, isNull);
      expect(stay.pricePhp, isNull);
      expect(stay.chargingUnit, isNull);
      expect(stay.capacity, isNull);
      expect(stay.isPricedPerNight, isFalse);
      expect(stay.nightlyUsd(57), isNull);
      expect(stay.chargingUnitLabel, isNull);

      final again = HotelOffer.tryFromJson(stay.toJson())!;
      expect(again.name, 'Hagimit Beach House');
      expect(again.rating, isNull);
      expect(again.pricePhp, isNull);
    });

    test('only a price the catalog gives per night counts toward the trip cost', () {
      HotelOffer stay(String? unit) => HotelOffer(
            id: 'a',
            name: 'Stay',
            city: 'X',
            pricePhp: 2850,
            chargingUnit: unit,
            lat: 7,
            lng: 125,
          );
      final repo = TravelRepository();
      final base = repo.generateCustomTrip(destination: 'X', daysCount: 3, vibe: 'v');

      final perNight = base.copyWith(hotels: [stay('per_room_per_night')]);
      expect(perNight.hotels.first.nightlyUsd(57), closeTo(50, 0.01));
      expect(perNight.totalEstimatedCostUsd,
          greaterThan(base.copyWith(hotels: [stay(null)]).totalEstimatedCostUsd));
      expect(stay('per_room_per_night').chargingUnitLabel, 'per room per night');
    });

    test('the catalog mapping invents no rating, stars, unit, capacity or "verified" label', () async {
      final server = _Server(stays: [
        {'accommodation_id': 1, 'name': 'Full Stay', 'room_type': 'Deluxe', 'price': '3500.00', 'capacity': 4, 'charging_unit': 'per_room_per_night', 'is_available': true},
        {'accommodation_id': 2, 'name': 'Bare Stay', 'is_available': true},
        {'accommodation_id': 3, 'name': '   ', 'price': '100', 'is_available': true},
        {'accommodation_id': 4, 'name': 'Hidden Stay', 'price': '999', 'is_available': false},
      ]);
      final catalog = LakbayApiCatalogService(
        baseUrlOverride: 'https://api.lakbay.test/api/v1',
        client: server.client,
      );

      final market = await catalog.fetchDestinationMarketRates(5, lat: 7.0, lng: 125.0);

      expect(market.hotels.map((h) => h.name), ['Full Stay', 'Bare Stay']);
      final full = market.hotels.first;
      expect(full.pricePhp, 3500.0);
      expect(full.chargingUnit, 'per_room_per_night');
      expect(full.capacity, 4);
      expect(full.facilities, ['Deluxe']);
      final bare = market.hotels.last;
      expect(bare.pricePhp, isNull);
      expect(bare.chargingUnit, isNull);
      expect(bare.capacity, isNull);
      expect(bare.facilities, isEmpty);
      for (final h in market.hotels) {
        expect(h.rating, isNull);
        expect(h.stars, isNull);
        expect(h.sourceLabel, 'Lakbay catalog');
      }
    });

    test('a new trip starts with no stays at all', () {
      final repo = TravelRepository();
      expect(
        repo.generateCustomTrip(destination: 'Mati', daysCount: 2, vibe: 'Beach').hotels,
        isEmpty,
      );
    });

    testWidgets('the Stays tab says when none are listed, and never shows invented ones', (tester) async {
      final repo = TravelRepository(apiCatalog: LakbayApiCatalogService(baseUrlOverride: ''));
      await tester.runAsync(() => repo.initialize());
      final trip = repo.generateCustomTrip(destination: 'Mati', daysCount: 2, vibe: 'Beach');

      await tester.pumpWidget(MaterialApp(home: TripDetailScreen(trip: trip, repo: repo)));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text('Stays & Transit'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));

      expect(find.text('Stays from the Lakbay catalog'), findsOneWidget);
      expect(find.text('No stays are listed for this place yet.'), findsOneWidget);
      expect(find.textContaining('Handpicked'), findsNothing);
      expect(find.textContaining('Eco Lodge'), findsNothing);
      expect(find.textContaining('Region XI Estimate'), findsNothing);
    });

    testWidgets('a stay shows its real price and unit, or says the price is not listed', (tester) async {
      // A tall screen so both stay cards are built (the list builds lazily).
      tester.view.physicalSize = const Size(900, 4000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final repo = TravelRepository(apiCatalog: LakbayApiCatalogService(baseUrlOverride: ''));
      await tester.runAsync(() => repo.initialize());
      final trip = repo
          .generateCustomTrip(destination: 'Mati', daysCount: 2, vibe: 'Beach')
          .copyWith(hotels: const [
        HotelOffer(
          id: 'a', name: 'Priced Stay', city: 'Mati', pricePhp: 2850,
          chargingUnit: 'per_room_per_night', capacity: 4, lat: 6.9, lng: 126.2,
        ),
        HotelOffer(id: 'b', name: 'Unpriced Stay', city: 'Mati', lat: 6.9, lng: 126.2),
      ]);

      await tester.pumpWidget(MaterialApp(home: TripDetailScreen(trip: trip, repo: repo)));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text('Stays & Transit'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));

      expect(find.text('Priced Stay'), findsOneWidget);
      expect(find.textContaining('per room per night'), findsOneWidget);
      expect(find.textContaining('Sleeps 4'), findsOneWidget);
      expect(find.text('Unpriced Stay'), findsOneWidget);
      expect(find.text('Price not listed'), findsOneWidget);
      expect(find.textContaining('★'), findsNothing); // no rating or stars were given
    });
  });

  group('weather only comes from a real forecast', () {
    test('days carry no weather unless a forecast set it; old saved 2 / 29 are ignored', () {
      const day = ItineraryDay(dayNumber: 1, cityTitle: 'Day 1', summary: '', lat: 7, lng: 125, stops: []);
      expect(day.wmoWeatherCode, isNull);
      expect(day.tempCelsius, isNull);

      final old = {...day.toJson(), 'wmoWeatherCode': 2, 'tempCelsius': 29};
      expect(ItineraryDay.fromJson(old).wmoWeatherCode, isNull);
      expect(ItineraryDay.fromJson(old).tempCelsius, isNull);

      final real = day.copyWith(wmoWeatherCode: 3, tempCelsius: 27);
      expect(ItineraryDay.fromJson(real.toJson()).tempCelsius, 27);
      expect(real.copyWith(clearWeather: true).tempCelsius, isNull);
    });

    test('invented trip-level defaults from older builds are dropped', () {
      final repo = TravelRepository();
      final json = repo
          .generateCustomTrip(destination: 'Samal', daysCount: 2, vibe: 'Beach')
          .toJson()
        ..['avgTemp'] = '29°C / 84°F'
        ..['wmoWeatherCode'] = 2
        ..['bestMonths'] = 'Dec – May (Dry)';
      final trip = ItineraryTrip.fromJson(json);
      expect(trip.avgTemp, isEmpty);
      expect(trip.wmoWeatherCode, isNull);
      expect(trip.bestMonths, isEmpty);

      json['avgTemp'] = '31°C • Clear';
      json['wmoWeatherCode'] = 0;
      expect(ItineraryTrip.fromJson(json).wmoWeatherCode, 0);
    });

    test('a new trip and the city guides have no weather', () async {
      final repo = TravelRepository();
      await repo.initialize();
      final trip = repo.generateCustomTrip(destination: 'Samal', daysCount: 3, vibe: 'Beach');
      expect(trip.avgTemp, isEmpty);
      expect(trip.wmoWeatherCode, isNull);
      expect(trip.days.every((d) => d.wmoWeatherCode == null && d.tempCelsius == null), isTrue);
      expect(repo.cityDescriptions.every((c) => c.wmoWeatherCode == null), isTrue);
    });

    test('with a start date, only the days the forecast covers get weather', () async {
      final server = _Server(forecastDays: 2); // today and tomorrow
      final repo = await _signedInRepo(server);
      final today = DateTime.now();
      final trip = _threeDayTrip(repo).copyWith(
        startDate: DateTime(today.year, today.month, today.day),
      );

      final loaded = await repo.loadLiveDetailsForTrip(trip);

      expect(loaded.days[0].tempCelsius, 28);
      expect(loaded.days[1].tempCelsius, 29);
      expect(loaded.days[2].tempCelsius, isNull); // beyond the forecast: nothing is guessed
      expect(loaded.days[2].wmoWeatherCode, isNull);
      expect(loaded.avgTemp, startsWith('31°C')); // today's weather, shown as "now"
    });

    test('without a start date no day gets weather, even though a forecast exists', () async {
      final repo = await _signedInRepo(_Server(forecastDays: 5));

      final loaded = await repo.loadLiveDetailsForTrip(_threeDayTrip(repo));

      expect(loaded.days.every((d) => d.wmoWeatherCode == null), isTrue);
    });

    test('a trip that starts after the forecast window gets none', () async {
      final repo = await _signedInRepo(_Server(forecastDays: 5));
      final later = DateTime.now().add(const Duration(days: 40));
      final trip = _threeDayTrip(repo).copyWith(startDate: later);

      final loaded = await repo.loadLiveDetailsForTrip(trip);

      expect(loaded.days.every((d) => d.tempCelsius == null), isTrue);
    });

    test('setting the start date saves it and loads the forecast for it', () async {
      final server = _Server(forecastDays: 5);
      final repo = await _signedInRepo(server);
      final trip = _threeDayTrip(repo);
      repo.saveTripToMyTrips(trip);

      final updated = await repo.setTripStartDate(trip, DateTime.now());

      expect(updated.startDate, isNotNull);
      expect(updated.days.first.tempCelsius, isNotNull);
      expect(repo.savedTrips.first.startDate, isNotNull);
      expect(server.forecastCalls, greaterThan(0));
    });

    test('the forecast client returns nothing when the server has none', () async {
      final catalog = LakbayApiCatalogService(
        baseUrlOverride: 'https://api.lakbay.test/api/v1',
        client: MockClient((_) async => http.Response('down', 503)),
      );
      expect(await catalog.getWeatherForecast('token', lat: 7, lng: 125), isEmpty);
    });

    testWidgets('the Day-by-Day tab explains the missing forecast and offers to set the date', (tester) async {
      final repo = TravelRepository(apiCatalog: LakbayApiCatalogService(baseUrlOverride: ''));
      await tester.runAsync(() => repo.initialize());
      final trip = repo.generateCustomTrip(destination: 'Mati', daysCount: 2, vibe: 'Beach');

      await tester.pumpWidget(MaterialApp(home: TripDetailScreen(trip: trip, repo: repo)));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text('Day-by-Day'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));

      expect(find.text('Add your travel date to see the weather forecast.'), findsOneWidget);
      expect(find.text('Set date'), findsOneWidget);
      expect(find.textContaining('°C'), findsNothing);
    });

    testWidgets('with a start date beyond the window the note says when the forecast appears', (tester) async {
      final repo = TravelRepository(apiCatalog: LakbayApiCatalogService(baseUrlOverride: ''));
      await tester.runAsync(() => repo.initialize());
      final trip = repo
          .generateCustomTrip(destination: 'Mati', daysCount: 2, vibe: 'Beach')
          .copyWith(startDate: DateTime.now().add(const Duration(days: 60)));

      await tester.pumpWidget(MaterialApp(home: TripDetailScreen(trip: trip, repo: repo)));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text('Day-by-Day'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));

      expect(find.text('The forecast shows within 5 days of travel.'), findsOneWidget);
      expect(find.text('Change date'), findsOneWidget);
    });
  });
}
