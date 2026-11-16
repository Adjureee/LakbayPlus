import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lakbay_travel/models/travel_models.dart';
import 'package:lakbay_travel/services/access_notices.dart';
import 'package:lakbay_travel/services/travel_repository.dart';
import 'package:lakbay_travel/widgets/access_notice_card.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _mountApo = ExploreTrip(
  locale: 'en',
  id: 'api_5',
  apiDestinationId: 5,
  title: 'Mount Apo Trail Area',
  lat: 6.9875,
  lng: 125.2708,
  thumbnailUrl: '',
  tag: 'Mountain',
);

const _eden = ExploreTrip(
  locale: 'en',
  id: 'api_3',
  apiDestinationId: 3,
  title: 'Eden Nature Park',
  lat: 7.0282,
  lng: 125.4018,
  thumbnailUrl: '',
  tag: 'Nature',
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('Mount Apo trip carries the permit notice once', () {
    final trip = TravelRepository().buildDetailedItineraryFromExplore(
      _mountApo,
      overrideDays: 2,
    );
    final notices = accessNoticesForTrip(trip);
    expect(notices, hasLength(1));
    expect(notices.single.title, contains('permit'));
    expect(accessNoticeForDay(trip.days.first), isNotNull);
  });

  test('Other places have no permit notice', () {
    final trip = TravelRepository().buildDetailedItineraryFromExplore(_eden);
    expect(accessNoticesForTrip(trip), isEmpty);
  });

  test('Name match catches climbs but not Mt. Apo coffee or views', () {
    expect(accessNoticeFor(name: 'Mt. Apo Summit Trek'), isNotNull);
    expect(accessNoticeFor(name: 'Mount Apo'), isNotNull);
    expect(accessNoticeFor(name: 'Mt. Apo Arabica coffee tasting'), isNull);
    expect(accessNoticeFor(name: 'Kapatagan views of Mt. Apo'), isNull);
  });

  testWidgets('AccessNoticeCard shows title and body', (tester) async {
    final notice = accessNoticeFor(destinationId: 5)!;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: AccessNoticeCard(notice: notice)),
      ),
    );
    expect(find.text(notice.title), findsOneWidget);
    expect(find.textContaining('Kapatagan'), findsOneWidget);
  });
}
