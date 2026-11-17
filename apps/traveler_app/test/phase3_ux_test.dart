import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lakbay_travel/models/travel_models.dart';
import 'package:lakbay_travel/screens/my_trips_screen.dart';
import 'package:lakbay_travel/services/friendly_error.dart';
import 'package:lakbay_travel/services/lakbay_api_catalog_service.dart';
import 'package:lakbay_travel/services/travel_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Phase 3: real trip dates, safe deletes, honest numbers and plain errors.
void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  ItineraryTrip trip({
    String id = 't1',
    String title = 'Samal weekend',
    int days = 3,
    DateTime? start,
    DateTime? end,
  }) {
    final base = TravelRepository().generateCustomTrip(
      destination: 'Samal Island, Davao del Norte',
      daysCount: days,
      vibe: 'Beaches & islands',
    );
    return ItineraryTrip.fromJson({...base.toJson(), 'id': id, 'title': title})
        .copyWith(startDate: start, endDate: end);
  }

  final now = DateTime(2026, 11, 17, 15, 30);

  group('trip timing', () {
    test('a trip without dates is undated and has no label', () {
      final t = trip();
      expect(t.timingOn(now), TripTiming.undated);
      expect(t.whenLabel(now), isNull);
      expect(t.dateRangeLabel, isNull);
    });

    test('upcoming trips count down', () {
      expect(trip(start: DateTime(2026, 11, 18)).whenLabel(now), 'Tomorrow');
      final t = trip(start: DateTime(2026, 11, 22));
      expect(t.timingOn(now), TripTiming.upcoming);
      expect(t.whenLabel(now), 'In 5 days');
      expect(trip(start: DateTime(2027, 1, 9)).whenLabel(now), 'Starts Jan 9');
    });

    test('the end date follows the day count when not stored', () {
      final t = trip(days: 3, start: DateTime(2026, 11, 16));
      expect(t.lastDay, DateTime(2026, 11, 18));
      expect(t.timingOn(now), TripTiming.ongoing);
      expect(t.whenLabel(now), 'Day 2 of 3');
      expect(t.dateRangeLabel, 'Nov 16 – 18');
    });

    test('one-day trips today and finished trips', () {
      expect(
        trip(days: 1, start: DateTime(2026, 11, 17)).whenLabel(now),
        'Today',
      );
      final past = trip(start: DateTime(2026, 11, 1));
      expect(past.timingOn(now), TripTiming.past);
      expect(past.whenLabel(now), 'Ended');
    });

    test('ranges across months name both months', () {
      final t = trip(start: DateTime(2026, 12, 30), end: DateTime(2027, 1, 2));
      expect(t.dateRangeLabel, 'Dec 30 – Jan 2');
    });

    test('dates survive a save and restore', () {
      final t = trip(start: DateTime(2026, 12, 4), end: DateTime(2026, 12, 6));
      final json = t.toJson();
      expect(json['startDate'], '2026-12-04');
      expect(json['endDate'], '2026-12-06');
      final back = ItineraryTrip.fromJson(json);
      expect(back.startDate, DateTime(2026, 12, 4));
      expect(back.endDate, DateTime(2026, 12, 6));
      expect(back.copyWith(clearDates: true).startDate, isNull);
    });
  });

  group('honest numbers', () {
    test('stays carry no invented star class or guest score', () {
      final t = trip();
      expect(t.hotels, isNotEmpty);
      for (final h in t.hotels) {
        expect(h.stars, isNull);
        expect(h.rating, isNull);
        expect(h.partnerName, 'Estimated rate');
      }
      final restored = HotelOffer.fromJson({
        ...t.hotels.first.toJson(),
        'rating': 9.2,
        'stars': 4,
      });
      expect(restored.rating, isNull);
      expect(restored.stars, isNull);
    });
  });

  group('friendlyError', () {
    test('maps failures to plain sentences', () {
      expect(
        friendlyError(Exception('SocketException: Failed host lookup')),
        startsWith('No internet connection'),
      );
      expect(
        friendlyError(TimeoutException('x')),
        startsWith('Lakbay+ took too long'),
      );
      expect(
        friendlyError(const LakbayApiException('boom', statusCode: 503)),
        startsWith('Lakbay+ is busy'),
      );
      expect(
        friendlyError(
          const LakbayApiException(
            'Incorrect email or password.',
            statusCode: 401,
          ),
        ),
        'Incorrect email or password.',
      );
      expect(
        friendlyError(
          const LakbayApiException('{"detail":"invalid"}', statusCode: 401),
        ),
        "That didn't work. Check your details and try again.",
      );
      expect(
        friendlyError(
          const LakbayApiException('Google Sign-In failed: PlatformException'),
        ),
        startsWith("Google sign-in didn't finish"),
      );
      expect(
        friendlyError(StateError('Bad state: null')),
        'Something went wrong. Please try again.',
      );
    });
  });

  group('removal with undo', () {
    test('a taken trip can be restored in place', () {
      final repo = TravelRepository();
      repo.saveTripToMyTrips(trip(id: 'b', title: 'B'));
      repo.saveTripToMyTrips(trip(id: 'a', title: 'A'));
      final a = repo.savedTrips.first;
      final index = repo.takeSavedTrip('a');
      expect(index, 0);
      expect(repo.savedTrips.map((t) => t.id), ['b']);
      repo.restoreSavedTrip(a, index);
      expect(repo.savedTrips.map((t) => t.id), ['a', 'b']);
    });

    test('memories can be taken and restored', () async {
      final repo = TravelRepository();
      final memory = TripMemoryItem(
        tripMemoryId: 7,
        tripId: 3,
        uploadedByFullName: 'Ana',
        imageUrl: '',
        caption: 'Sunset',
        createdAt: DateTime(2026, 11, 1),
      );
      repo.restoreMemory(memory, 0);
      expect(repo.memories, [memory]);
      final index = repo.takeMemory(memory);
      expect(repo.memories, isEmpty);
      repo.restoreMemory(memory, index);
      expect(repo.memories, [memory]);
      repo.takeMemory(memory);
      await repo.commitMemoryRemoval(memory);
      expect(repo.memories, isEmpty);
    });
  });

  group('My Trips screen', () {
    Future<TravelRepository> pumpTrips(
      WidgetTester tester,
      List<ItineraryTrip> trips,
    ) async {
      // A tall phone, so the whole trip list is built.
      tester.view
        ..physicalSize = const Size(412, 2400)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final repo = TravelRepository();
      for (final t in trips.reversed) {
        repo.saveTripToMyTrips(t);
      }
      await tester.pumpWidget(
        MaterialApp(
          home: ListenableBuilder(
            listenable: repo,
            builder: (_, _) => MyTripsScreen(repo: repo),
          ),
        ),
      );
      await tester.pump();
      return repo;
    }

    testWidgets('filters use real dates', (tester) async {
      final today = DateTime.now();
      await pumpTrips(tester, [
        trip(
          id: 'u',
          title: 'Upcoming Mati',
          start: today.add(const Duration(days: 5)),
        ),
        trip(
          id: 'p',
          title: 'Past Davao',
          start: today.subtract(const Duration(days: 30)),
        ),
        trip(id: 'n', title: 'Someday Apo'),
      ]);

      // The countdown and the list both use the real date.
      expect(find.text('5'), findsOneWidget);
      expect(
        find.textContaining('In 5 days', findRichText: true),
        findsOneWidget,
      );
      expect(find.text('Starts tomorrow'), findsNothing);

      await tester.ensureVisible(find.widgetWithText(ChoiceChip, 'Past'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ChoiceChip, 'Past'));
      await tester.pump();
      expect(find.text('Past Davao'), findsOneWidget);
      expect(find.text('Someday Apo'), findsNothing);

      await tester.ensureVisible(find.widgetWithText(ChoiceChip, 'No dates'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ChoiceChip, 'No dates'));
      await tester.pump();
      expect(find.text('Someday Apo'), findsOneWidget);
      expect(find.text('Past Davao'), findsNothing);
    });

    testWidgets('delete asks first and can be undone', (tester) async {
      final repo = await pumpTrips(tester, [
        trip(id: 'x', title: 'Island hop'),
        trip(id: 'y', title: 'Highlands'),
      ]);

      await tester.tap(find.byTooltip('Delete trip').last);
      await tester.pumpAndSettle();
      expect(find.text('Delete "Highlands"?'), findsOneWidget);

      // Cancel keeps it.
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(repo.savedTrips, hasLength(2));

      await tester.tap(find.byTooltip('Delete trip').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete trip').last);
      await tester.pumpAndSettle();
      expect(repo.savedTrips.map((t) => t.id), ['x']);
      expect(find.text('Trip deleted'), findsOneWidget);

      await tester.tap(find.text('Undo'));
      await tester.pumpAndSettle();
      expect(repo.savedTrips.map((t) => t.id), ['x', 'y']);
    });
  });
}
