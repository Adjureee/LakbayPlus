import 'package:flutter_test/flutter_test.dart';
import 'package:lakbay_travel/models/travel_models.dart';
import 'package:lakbay_travel/services/travel_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _tagbibinta = ExploreTrip(
  locale: 'en',
  id: 'api_8',
  apiDestinationId: 8,
  title: 'Tagbibinta Falls',
  days: 1,
  lat: 7.3476,
  lng: 126.1514,
  thumbnailUrl: '',
  tag: 'Waterfall',
  district: 'Maragusan, Davao de Oro',
  description: 'Multi-tiered waterfall in Maragusan.',
  operatingHours: '7:00 AM – 5:00 PM',
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('Explore trip day 1 is the chosen place, not a San Pedro template', () {
    final repo = TravelRepository();
    final trip = repo.buildDetailedItineraryFromExplore(_tagbibinta);

    final day1 = trip.days.first;
    expect(day1.cityTitle, 'Tagbibinta Falls');
    expect(day1.summary, 'Multi-tiered waterfall in Maragusan.');
    expect(day1.lat, 7.3476);
    expect(day1.lng, 126.1514);
    expect(day1.stops, hasLength(1));
    expect(day1.stops.single.title, 'Tagbibinta Falls');
    expect(day1.stops.single.lat, 7.3476);
    expect(day1.stops.single.destinationId, 8);
    expect(day1.stops.single.category, 'nature');

    final allText = [
      for (final d in trip.days) ...[
        d.cityTitle,
        d.summary,
        for (final s in d.stops) s.title,
      ],
    ].join(' ');
    expect(allText, isNot(contains('San Pedro')));
    expect(trip.routeWaypoints, hasLength(1));
  });

  test('Multi-day Explore trip keeps later days at the same place', () {
    final repo = TravelRepository();
    final trip = repo.buildDetailedItineraryFromExplore(
      _tagbibinta,
      overrideDays: 3,
    );

    expect(trip.days, hasLength(3));
    for (final day in trip.days.skip(1)) {
      expect(day.isContinuationDay, isTrue);
      expect(day.stops, isEmpty);
      expect(day.lat, 7.3476);
      expect(day.cityTitle, contains('Tagbibinta Falls'));
    }
    expect(trip.routeWaypoints, hasLength(1));
  });
}
