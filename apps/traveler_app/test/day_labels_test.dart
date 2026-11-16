import 'package:flutter_test/flutter_test.dart';
import 'package:lakbay_travel/core/day_labels.dart';

void main() {
  test('one day is never printed as "1 Days"', () {
    expect(DayLabels.count(1), '1 day');
    expect(DayLabels.count(3), '3 days');
    expect(DayLabels.countTitle(1), '1 Day');
    expect(DayLabels.countTitle(6), '6 Days');
  });

  test('the header badge leaves out the count for a one-day visit', () {
    expect(DayLabels.badge(1, 'Park / Public Plaza'), 'PARK / PUBLIC PLAZA');
    expect(DayLabels.badge(0, 'Nature'), 'NATURE');
    expect(DayLabels.badge(3, 'Beaches'), '3 DAYS • BEACHES');
  });
}
