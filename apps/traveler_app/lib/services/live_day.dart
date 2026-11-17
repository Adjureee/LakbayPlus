import '../models/travel_models.dart';
import 'route_progress.dart';

/// Minutes after midnight for a clock time such as "08:30 AM", "5 PM",
/// "5:10pm" or "14:30". Null when [text] is not a clock time.
int? parseClockMinutes(String text) {
  final m = RegExp(r'^\s*(\d{1,2})(?::(\d{2}))?\s*([AaPp]\.?\s*[Mm]\.?)?\s*$')
      .firstMatch(text);
  if (m == null) return null;
  var hour = int.parse(m.group(1)!);
  final minute = int.parse(m.group(2) ?? '0');
  final suffix = m.group(3)?.toLowerCase().replaceAll(RegExp(r'[\s.]'), '');
  if (minute > 59) return null;
  if (suffix == null) {
    // A bare "5" is not a time; 24-hour times need minutes.
    if (m.group(2) == null || hour > 23) return null;
  } else {
    if (hour < 1 || hour > 12) return null;
    if (suffix == 'pm' && hour != 12) hour += 12;
    if (suffix == 'am' && hour == 12) hour = 0;
  }
  return hour * 60 + minute;
}

/// "5:00 PM" for 1020.
String formatClockMinutes(int minutes) {
  final h24 = (minutes ~/ 60) % 24;
  final m = minutes % 60;
  final h = h24 % 12 == 0 ? 12 : h24 % 12;
  return '$h:${m.toString().padLeft(2, '0')} ${h24 < 12 ? 'AM' : 'PM'}';
}

/// Opening hours from catalog text such as "7:00 AM – 5:00 PM" or
/// "08:00-17:00". Free text ("Daytime visits", "Confirm current park
/// hours.") returns null, so no warning is ever guessed from it.
({int open, int close})? parseOpeningHours(String? text) {
  if (text == null) return null;
  final parts = text.split(RegExp(r'\s*(?:–|—|-|to)\s*'));
  if (parts.length != 2) return null;
  final open = parseClockMinutes(parts[0]);
  final close = parseClockMinutes(parts[1]);
  if (close == null) return null;
  // "8 – 5 PM": the opening time borrows nothing; it must parse alone.
  if (open == null) return null;
  if (close <= open) return null;
  return (open: open, close: close);
}

/// A planned stop on the live day, with what the catalog says about it.
class LiveDayStop {
  const LiveDayStop({
    required this.stop,
    required this.plannedMinutes,
    required this.hours,
  });

  final ItineraryStop stop;

  /// Planned arrival, from the stop's time slot. Null if unreadable.
  final int? plannedMinutes;

  /// Opening hours, only when the catalog gives clock times.
  final ({int open, int close})? hours;

  /// "Closes 5:00 PM, planned 5:10 PM" when the plan arrives at or after
  /// closing. Null otherwise.
  String? get closingWarning {
    final h = hours, at = plannedMinutes;
    if (h == null || at == null || at < h.close) return null;
    return 'Closes ${formatClockMinutes(h.close)}, '
        'planned ${formatClockMinutes(at)}';
  }

  /// "Opens 8:00 AM" when the plan arrives before opening.
  String? get openingNote {
    final h = hours, at = plannedMinutes;
    if (h == null || at == null || at >= h.open) return null;
    return 'Opens ${formatClockMinutes(h.open)}';
  }

  GeoPoint get point => GeoPoint(lat: stop.lat, lng: stop.lng);
}

/// One day of a trip seen "on the ground": which day it is, its stops in
/// order, and where the traveler is along them.
class LiveDayPlan {
  LiveDayPlan._({
    required this.trip,
    required this.day,
    required this.totalDays,
    required this.isLive,
    required this.date,
    required this.stops,
  });

  final ItineraryTrip trip;
  final ItineraryDay day;
  final int totalDays;

  /// True while the trip is happening today; false for a preview of a day.
  final bool isLive;

  /// The calendar date of [day], when the trip has dates.
  final DateTime? date;
  final List<LiveDayStop> stops;

  static const _weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  static const _months = [
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

  /// Today's day while the trip is on, otherwise [previewDay] (day 1 by
  /// default). Null when the trip has no days with stops.
  static LiveDayPlan? forTrip(
    ItineraryTrip trip, {
    required DateTime now,
    int? previewDay,
    ({int open, int close})? Function(ItineraryStop stop)? hoursFor,
  }) {
    final days = trip.days.where((d) => !d.isContinuationDay).toList();
    if (days.isEmpty) return null;
    final totalDays = trip.daysCount < 1 ? days.length : trip.daysCount;

    final live = trip.timingOn(now) == TripTiming.ongoing;
    final rawStart = trip.startDate;
    // Date only: a stored time of day must not shift which day it is.
    final start = rawStart == null
        ? null
        : DateTime(rawStart.year, rawStart.month, rawStart.day);
    int dayNumber;
    if (live) {
      final today = DateTime(now.year, now.month, now.day);
      dayNumber = today.difference(start!).inDays + 1;
    } else {
      dayNumber = previewDay ?? days.first.dayNumber;
    }
    final day = days.firstWhere(
      (d) => d.dayNumber == dayNumber,
      orElse: () => days[(dayNumber - 1).clamp(0, days.length - 1)],
    );
    final date = start?.add(Duration(days: day.dayNumber - 1));

    final stops = [
      for (final s in day.stops)
        if (s.category != 'stay')
          LiveDayStop(
            stop: s,
            plannedMinutes: parseClockMinutes(s.time),
            hours: hoursFor?.call(s),
          ),
    ];
    if (stops.isEmpty) return null;
    return LiveDayPlan._(
      trip: trip,
      day: day,
      totalDays: totalDays,
      isLive: live,
      date: date,
      stops: stops,
    );
  }

  /// "Day 1 live, Sat 22" or "Day 1 preview".
  String get headline {
    final d = date;
    final when = d == null ? '' : ', ${_weekdays[d.weekday - 1]} ${d.day}';
    return isLive
        ? 'Day ${day.dayNumber} live$when'
        : 'Day ${day.dayNumber} preview$when';
  }

  /// "Sat 22 Nov" or null.
  String? get dateLabel {
    final d = date;
    if (d == null) return null;
    return '${_weekdays[d.weekday - 1]} ${d.day} ${_months[d.month - 1]}';
  }

  /// Sum of the stops' own estimates, in US dollars (0 when none priced).
  double get estimatedCostUsd =>
      stops.fold(0, (sum, s) => sum + s.stop.costEstimateUsd);

  /// Index of the stop the traveler reached at [lat]/[lng], counting only
  /// stops after the [reached] ones. Null if none is within reach.
  int? arrivalAt(double lat, double lng, int reached) => detectArrival(
    lat: lat,
    lng: lng,
    stops: [for (final s in stops) s.point],
    reachedCount: reached,
  );

  /// Straight-line distance in meters from [lat]/[lng] to stop [index].
  double distanceTo(int index, double lat, double lng) {
    final p = stops[index].point;
    return haversineMeters(lat, lng, p.lat, p.lng);
  }

  /// The day's stops with stop [index] moved one slot earlier. Each slot
  /// keeps its time, so the places swap and the schedule stays in order.
  ItineraryDay dayWithStopMovedEarlier(int index) {
    final visible = [
      for (var i = 0; i < day.stops.length; i++)
        if (day.stops[i].category != 'stay') i,
    ];
    if (index <= 0 || index >= visible.length) return day;
    final a = visible[index - 1], b = visible[index];
    final list = List<ItineraryStop>.from(day.stops);
    final earlier = list[a], later = list[b];
    list[a] = later.copyWith(time: earlier.time);
    list[b] = earlier.copyWith(time: later.time);
    return day.copyWith(stops: list);
  }
}
