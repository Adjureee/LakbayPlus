import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:lakbay_travel/core/day_labels.dart';
import 'package:lakbay_travel/screens/my_trips_screen.dart';
import 'package:lakbay_travel/services/travel_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Words travelers do not use: the government label, an insider acronym, a
/// developer term and the names of vendors and models (docs/FLAGSHIP_UX_PLAN.md, F1).
final _banned = RegExp(r'Region XI|IGaCoS|trip tray|Mapbox|Groq|Gemini');

/// The only places an old word may stay, each with the reason.
const _allowed = <(String, String)>[
  // The map's terms require this credit on the map itself.
  ('lakbay_mapbox_widget.dart', '© Mapbox'),
  // A saved key for the bucket list: changing it would orphan saved choices.
  ('travel_repository.dart', 'Island Garden City of Samal (IGaCoS)'),
  // Token entry for developers; the menu item is built only in debug builds.
  ('lakbay_mapbox_widget.dart', 'Mapbox Style & API Configuration'),
  ('lakbay_mapbox_widget.dart', 'Mapbox Access Token activated!'),
  ('lakbay_mapbox_widget.dart', 'Save Mapbox Settings'),
  ('lakbay_mapbox_widget.dart', 'Mapbox Token (Live)'),
  ('lakbay_mapbox_widget.dart', 'Set Mapbox Access Token'),
];

/// String literals in [source] that hold a banned word and are not allowed.
List<String> findJargon(String source, String file) {
  final literal = RegExp(r'''(['"])((?:(?!\1).)*)\1''');
  final found = <String>[];
  for (final line in source.split('\n')) {
    if (line.trimLeft().startsWith('//')) continue;
    for (final match in literal.allMatches(line)) {
      final text = match.group(2)!;
      if (!_banned.hasMatch(text)) continue;
      final ok = _allowed.any(
        (a) => file.endsWith(a.$1) && text.contains(a.$2),
      );
      if (!ok) found.add(text);
    }
  }
  return found;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('plain words', () {
    test('no screen or model prints an insider or vendor word', () {
      final problems = <String>[];
      for (final entity in Directory('lib').listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        final path = entity.path.replaceAll(r'\', '/');
        for (final text in findJargon(entity.readAsStringSync(), path)) {
          problems.add('$path: $text');
        }
      }
      expect(problems, isEmpty, reason: problems.join('\n'));
    });

    test('the scan really catches a planted word and respects the allow list',
        () {
      expect(findJargon("final a = 'Davao Region XI Explorer';", 'x.dart'),
          hasLength(1));
      expect(findJargon("tooltip: 'View on Mapbox',", 'x.dart'), hasLength(1));
      expect(findJargon("'© Mapbox'", 'lib/widgets/lakbay_mapbox_widget.dart'),
          isEmpty);
      expect(findJargon("'© Mapbox'", 'lib/screens/explore_screen.dart'),
          hasLength(1));
      expect(findJargon("// 'Region XI' in a comment", 'x.dart'), isEmpty);
    });
  });

  group('DayLabels', () {
    final now = DateTime(2026, 11, 27, 15);

    test('startsLabel follows the real start date', () {
      expect(DayLabels.startsLabel(null, now: now), 'Dates not set');
      expect(DayLabels.startsLabel(DateTime(2026, 11, 26), now: now),
          'Dates passed');
      expect(DayLabels.startsLabel(DateTime(2026, 11, 27, 6), now: now),
          'Starts today');
      expect(DayLabels.startsLabel(DateTime(2026, 11, 28), now: now),
          'Starts tomorrow');
      expect(DayLabels.startsLabel(DateTime(2026, 12, 5), now: now),
          'Starts in 8 days');
    });

    test('joinDistinct drops repeats and ignores case', () {
      expect(
        DayLabels.joinDistinct([
          '6 Days',
          '1 traveller',
          'Davao Del Norte • Davao del Norte',
        ]),
        '6 Days • 1 traveller • Davao Del Norte',
      );
      expect(DayLabels.joinDistinct(['', 'A', ' a ']), 'A');
    });
  });

  group('removing a trip', () {
    TravelRepository repoWithTrips(int count) {
      SharedPreferences.setMockInitialValues({});
      final repo = TravelRepository();
      for (var i = 0; i < count; i++) {
        repo.saveTripToMyTrips(
          repo.generateCustomTrip(
            id: 'trip_$i',
            destination: 'Place $i',
            daysCount: 2,
            vibe: 'Beach',
          ),
        );
      }
      return repo;
    }

    test('undo puts the trip back where it was', () {
      final repo = repoWithTrips(3); // newest first: trip_2, trip_1, trip_0
      repo.removeSavedTripWithUndo('trip_1');
      expect(repo.savedTrips.map((t) => t.id), ['trip_2', 'trip_0']);
      expect(repo.undoRemoveSavedTrip('trip_1'), isTrue);
      expect(repo.savedTrips.map((t) => t.id), ['trip_2', 'trip_1', 'trip_0']);
      expect(repo.undoRemoveSavedTrip('trip_1'), isFalse);
    });

    testWidgets('after the undo window the removal is final', (tester) async {
      final repo = repoWithTrips(2);
      repo.removeSavedTripWithUndo('trip_0');
      await tester.pump(TravelRepository.undoWindow + const Duration(seconds: 1));
      expect(repo.undoRemoveSavedTrip('trip_0'), isFalse);
      expect(repo.savedTrips.map((t) => t.id), ['trip_1']);
    });

    test('closing the repository makes a pending removal final', () {
      final repo = repoWithTrips(2);
      repo.removeSavedTripWithUndo('trip_0');
      repo.dispose();
      expect(repo.undoRemoveSavedTrip('trip_0'), isFalse);
    });
  });

  group('My Trips', () {
    setUpAll(() => GoogleFonts.config.allowRuntimeFetching = false);

    testWidgets('the featured trip is not listed twice and its badge is true',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      final repo = TravelRepository();
      final trip = repo.generateCustomTrip(
        id: 'only_trip',
        title: 'Samal Weekend',
        destination: 'Samal Island',
        daysCount: 2,
        vibe: 'Beach',
      );
      repo.saveTripToMyTrips(trip); // no start date

      await tester.pumpWidget(MaterialApp(home: MyTripsScreen(repo: repo)));
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('Samal Weekend'), findsOneWidget);
      expect(find.text('Starts tomorrow'), findsNothing);
      expect(find.text('Dates not set'), findsOneWidget);
    });

    testWidgets('removing a trip offers Undo that brings it back',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      final repo = TravelRepository();
      for (final name in ['First Trip', 'Second Trip']) {
        repo.saveTripToMyTrips(
          repo.generateCustomTrip(
            id: name,
            title: name,
            destination: 'Place',
            daysCount: 2,
            vibe: 'Beach',
          ),
        );
      }
      // Newest first: "Second Trip" is featured, "First Trip" is in the list.
      await tester.pumpWidget(MaterialApp(home: MyTripsScreen(repo: repo)));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('First Trip'), findsOneWidget);

      await tester.tap(find.byTooltip('Remove trip'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('First Trip'), findsNothing);
      expect(find.text('Undo'), findsOneWidget);

      await tester.tap(find.text('Undo'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('First Trip'), findsOneWidget);
      expect(repo.savedTrips.map((t) => t.id), ['Second Trip', 'First Trip']);
      await tester.pumpAndSettle();
    });
  });
}
