import 'travel_models.dart';

/// Where a trip sits in time, worked out from its real dates.
enum TripTiming { upcoming, ongoing, past, undated }

DateTime _day(DateTime d) => DateTime(d.year, d.month, d.day);

/// Parses a `yyyy-mm-dd` (or full ISO) string to a date, or null.
DateTime? parseTripDate(Object? raw) {
  if (raw == null) return null;
  final parsed = DateTime.tryParse(raw.toString());
  return parsed == null ? null : _day(parsed);
}

/// `yyyy-mm-dd`, the format the API stores trip dates in.
String formatTripDate(DateTime d) {
  final mm = d.month.toString().padLeft(2, '0');
  final dd = d.day.toString().padLeft(2, '0');
  return '${d.year}-$mm-$dd';
}

const _months = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

extension TripTimingX on ItineraryTrip {
  /// The last day of the trip: the stored end date, or the start date plus
  /// the number of planned days.
  DateTime? get lastDay {
    if (endDate != null) return _day(endDate!);
    if (startDate == null) return null;
    final days = daysCount < 1 ? 1 : daysCount;
    return _day(startDate!).add(Duration(days: days - 1));
  }

  TripTiming timingOn(DateTime now) {
    final start = startDate;
    final end = lastDay;
    if (start == null || end == null) return TripTiming.undated;
    final today = _day(now);
    if (today.isBefore(_day(start))) return TripTiming.upcoming;
    if (today.isAfter(end)) return TripTiming.past;
    return TripTiming.ongoing;
  }

  /// A short relative label: "Today", "Tomorrow", "In 5 days",
  /// "Day 2 of 3", "Ended". Null when the trip has no dates.
  String? whenLabel(DateTime now) {
    final start = startDate;
    final end = lastDay;
    if (start == null || end == null) return null;
    final today = _day(now);
    switch (timingOn(now)) {
      case TripTiming.upcoming:
        final days = _day(start).difference(today).inDays;
        if (days == 1) return 'Tomorrow';
        if (days < 14) return 'In $days days';
        return 'Starts ${_months[start.month - 1]} ${start.day}';
      case TripTiming.ongoing:
        final total = end.difference(_day(start)).inDays + 1;
        if (total == 1) return 'Today';
        final dayNo = today.difference(_day(start)).inDays + 1;
        return 'Day $dayNo of $total';
      case TripTiming.past:
        return 'Ended';
      case TripTiming.undated:
        return null;
    }
  }

  /// "Dec 4 – 6", "Dec 30 – Jan 2", or "Dec 4" for a one-day trip.
  String? get dateRangeLabel {
    final start = startDate;
    final end = lastDay;
    if (start == null || end == null) return null;
    final from = '${_months[start.month - 1]} ${start.day}';
    if (_day(start) == end) return from;
    final to = start.month == end.month && start.year == end.year
        ? '${end.day}'
        : '${_months[end.month - 1]} ${end.day}';
    return '$from – $to';
  }
}
