import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lakbay_travel/models/travel_models.dart';
import 'package:lakbay_travel/screens/live_day_screen.dart';
import 'package:lakbay_travel/services/lakbay_api_catalog_service.dart';
import 'package:lakbay_travel/services/live_day.dart';
import 'package:lakbay_travel/services/location_service.dart';
import 'package:lakbay_travel/services/travel_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

ItineraryStop _stop(String time, String title, double lng, {int? id}) =>
    ItineraryStop(
      time: time,
      title: title,
      description: '$title description',
      category: 'sight',
      costEstimateUsd: 5,
      lat: 7.07,
      lng: lng,
      destinationId: id,
      travelFromPrevMinutes: 20,
    );

ItineraryTrip _trip({DateTime? start}) {
  final base = TravelRepository().generateCustomTrip(
    title: 'Samal Island Weekend',
    destination: 'Samal Island, Davao del Norte',
    daysCount: 2,
    vibe: 'Beaches & islands',
  );
  return base.copyWith(
    startDate: start,
    days: [
      ItineraryDay(
        dayNumber: 1,
        cityTitle: 'Day 1',
        summary: '',
        lat: 7.07,
        lng: 125.6,
        stops: [
          _stop('08:30 AM', 'Hagimit Falls', 125.60, id: 1),
          _stop('11:30 AM', 'Kaputian Beach', 125.62, id: 2),
          _stop('05:10 PM', 'Monfort Bat Sanctuary', 125.64, id: 3),
        ],
      ),
      ItineraryDay(
        dayNumber: 2,
        cityTitle: 'Day 2',
        summary: '',
        lat: 7.07,
        lng: 125.6,
        stops: [_stop('09:00 AM', 'Ferry back to Davao', 125.58)],
      ),
    ],
  );
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('clock and opening hours', () {
    test('parses common clock formats', () {
      expect(parseClockMinutes('08:30 AM'), 8 * 60 + 30);
      expect(parseClockMinutes('5 PM'), 17 * 60);
      expect(parseClockMinutes('5:10pm'), 17 * 60 + 10);
      expect(parseClockMinutes('12:00 AM'), 0);
      expect(parseClockMinutes('12:15 PM'), 12 * 60 + 15);
      expect(parseClockMinutes('14:30'), 14 * 60 + 30);
      expect(parseClockMinutes('5'), isNull);
      expect(parseClockMinutes('Morning'), isNull);
      expect(formatClockMinutes(17 * 60), '5:00 PM');
    });

    test('opening hours only from real clock ranges', () {
      expect(parseOpeningHours('7:00 AM – 5:00 PM'), (open: 420, close: 1020));
      expect(parseOpeningHours('08:00-17:00'), (open: 480, close: 1020));
      expect(parseOpeningHours('8 AM to 5 PM'), (open: 480, close: 1020));
      expect(parseOpeningHours('Daytime visits'), isNull);
      expect(parseOpeningHours('Confirm current park hours.'), isNull);
      expect(parseOpeningHours(null), isNull);
    });
  });

  group('LiveDayPlan', () {
    test('picks today while the trip is on', () {
      final now = DateTime(2026, 11, 22, 10);
      final plan = LiveDayPlan.forTrip(
        _trip(start: DateTime(2026, 11, 21)),
        now: now,
      )!;
      expect(plan.isLive, isTrue);
      expect(plan.day.dayNumber, 2);
      expect(plan.headline, 'Day 2 live, Sun 22');
    });

    test('previews day 1 when the trip is not on', () {
      final plan = LiveDayPlan.forTrip(_trip(), now: DateTime(2026, 11, 17))!;
      expect(plan.isLive, isFalse);
      expect(plan.headline, 'Day 1 preview');
      expect(plan.stops, hasLength(3));
    });

    test('warns only when the plan arrives after a known closing time', () {
      final plan = LiveDayPlan.forTrip(
        _trip(),
        now: DateTime(2026, 11, 17),
        hoursFor: (s) =>
            s.destinationId == 3 ? parseOpeningHours('9:00 AM – 5:00 PM') : null,
      )!;
      expect(plan.stops[0].closingWarning, isNull);
      expect(plan.stops[2].closingWarning, 'Closes 5:00 PM, planned 5:10 PM');
    });

    test('moving a stop earlier swaps places and keeps the time slots', () {
      final plan = LiveDayPlan.forTrip(_trip(), now: DateTime(2026, 11, 17))!;
      final day = plan.dayWithStopMovedEarlier(2);
      expect(day.stops.map((s) => s.title), [
        'Hagimit Falls',
        'Monfort Bat Sanctuary',
        'Kaputian Beach',
      ]);
      expect(day.stops.map((s) => s.time), ['08:30 AM', '11:30 AM', '05:10 PM']);
    });
  });

  testWidgets('live day: next stop, I am here, and progress', (tester) async {
    tester.view
      ..physicalSize = const Size(412, 900)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final repo = TravelRepository(
      apiCatalog: LakbayApiCatalogService(baseUrlOverride: ''),
      locationService: LocationService(
        customFetcher: () async => const LocationResult(
          granted: false,
          statusMessage: 'Declined',
        ),
      ),
    );
    await tester.runAsync(repo.initialize);
    await tester.pumpWidget(
      MaterialApp(home: LiveDayScreen(repo: repo, trip: _trip())),
    );
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('Day 1 preview'), findsOneWidget);
    expect(find.text('Hagimit Falls'), findsWidgets);
    expect(find.text('Route to Hagimit Falls'), findsOneWidget);
    expect(find.text('0 of 3 done'), findsOneWidget);

    await tester.tap(find.text('I’m here'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('1 of 3 done'), findsOneWidget);
    expect(find.text('Route to Kaputian Beach'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  });
}
