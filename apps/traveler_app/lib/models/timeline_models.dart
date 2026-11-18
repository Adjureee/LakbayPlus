/// The itinerary timeline the server builds (`POST /planning/timeline`).
///
/// The server's JSON is kept as received (`raw`) so a revision can send the previous
/// timeline back unchanged; the typed views below only read it. Nothing here guesses:
/// a missing time stays null, an unknown cost stays null, and a check the server could
/// not verify stays "cannot_verify".
library;

double? _money(Object? value) {
  if (value == null) return null;
  return double.tryParse(value.toString());
}

List<Map<String, dynamic>> _maps(Object? value) =>
    (value as List<dynamic>? ?? const []).whereType<Map<String, dynamic>>().toList();

/// "08:45:00" as "8:45 AM"; null stays null.
String? clockLabel(String? hhmmss) {
  if (hhmmss == null || hhmmss.length < 5) return null;
  final hour = int.tryParse(hhmmss.substring(0, 2));
  final minute = hhmmss.substring(3, 5);
  if (hour == null) return null;
  final h12 = hour % 12 == 0 ? 12 : hour % 12;
  return '$h12:$minute ${hour < 12 ? 'AM' : 'PM'}';
}

/// "1 h 20 min", "45 min"; null for an unknown duration.
String? durationLabel(int? minutes) {
  if (minutes == null) return null;
  if (minutes < 60) return '$minutes min';
  final hours = minutes ~/ 60;
  final rest = minutes % 60;
  return rest == 0 ? '$hours h' : '$hours h $rest min';
}

class TimelineCost {
  const TimelineCost({
    required this.label,
    required this.amount,
    required this.status,
    required this.scope,
    this.includedIn,
  });

  final String label;

  /// Null when the cost is unknown.
  final double? amount;
  final String status; // known | estimated | unknown
  final String scope; // per_person | shared
  final String? includedIn;

  factory TimelineCost.fromJson(Map<String, dynamic> json) => TimelineCost(
    label: json['label']?.toString() ?? '',
    amount: _money(json['amount']),
    status: json['status']?.toString() ?? 'unknown',
    scope: json['scope']?.toString() ?? 'shared',
    includedIn: json['included_in']?.toString(),
  );
}

class TimelineTravel {
  const TimelineTravel({
    required this.fromLabel,
    required this.toLabel,
    required this.minutes,
    required this.basis,
    this.mode,
    this.routeVerified = false,
  });

  final String fromLabel;
  final String toLabel;
  final int? minutes;
  final String basis; // supported | estimated | unknown
  final String? mode;
  final bool routeVerified;

  factory TimelineTravel.fromJson(Map<String, dynamic> json) => TimelineTravel(
    fromLabel: json['from_label']?.toString() ?? '',
    toLabel: json['to_label']?.toString() ?? '',
    minutes: (json['minutes'] as num?)?.toInt(),
    basis: json['basis']?.toString() ?? 'unknown',
    mode: json['mode']?.toString(),
    routeVerified: json['route_verified'] == true,
  );
}

class TimelineItem {
  const TimelineItem({
    required this.kind,
    required this.day,
    required this.startsAt,
    required this.endsAt,
    required this.durationMinutes,
    required this.timeBasis,
    required this.durationBasis,
    required this.label,
    this.destinationId,
    this.travel,
    this.costs = const [],
    this.booking,
    this.notes = const [],
  });

  final String kind; // depart travel visit meal rest buffer return
  final int day;
  final String? startsAt;
  final String? endsAt;
  final int? durationMinutes;
  final String timeBasis; // confirmed | estimated | provisional | unknown
  final String durationBasis;
  final String label;
  final int? destinationId;
  final TimelineTravel? travel;
  final List<TimelineCost> costs;
  final String? booking;
  final List<String> notes;

  /// "8:45 AM to 10:45 AM", "8:45 AM" when there is no end, or null.
  String? get timeRange {
    final start = clockLabel(startsAt);
    final end = clockLabel(endsAt);
    if (start == null) return null;
    return end == null || end == start ? start : '$start to $end';
  }

  factory TimelineItem.fromJson(Map<String, dynamic> json) => TimelineItem(
    kind: json['kind']?.toString() ?? 'visit',
    day: (json['day'] as num?)?.toInt() ?? 1,
    startsAt: json['starts_at']?.toString(),
    endsAt: json['ends_at']?.toString(),
    durationMinutes: (json['duration_minutes'] as num?)?.toInt(),
    timeBasis: json['time_basis']?.toString() ?? 'unknown',
    durationBasis: json['duration_basis']?.toString() ?? 'unknown',
    label: json['label']?.toString() ?? '',
    destinationId: (json['destination_id'] as num?)?.toInt(),
    travel: json['travel'] is Map<String, dynamic>
        ? TimelineTravel.fromJson(json['travel'] as Map<String, dynamic>)
        : null,
    costs: _maps(json['costs']).map(TimelineCost.fromJson).toList(),
    booking: json['booking']?.toString(),
    notes: (json['notes'] as List<dynamic>? ?? const []).map((e) => e.toString()).toList(),
  );
}

class TimelineDay {
  const TimelineDay({required this.day, this.date, required this.items});

  final int day;
  final String? date;
  final List<TimelineItem> items;

  factory TimelineDay.fromJson(Map<String, dynamic> json) => TimelineDay(
    day: (json['day'] as num?)?.toInt() ?? 1,
    date: json['date']?.toString(),
    items: _maps(json['items']).map(TimelineItem.fromJson).toList(),
  );
}

class TimelineConflict {
  const TimelineConflict({
    required this.code,
    required this.destinationId,
    required this.day,
    required this.message,
    required this.choices,
  });

  final String code;
  final int? destinationId;
  final int? day;
  final String message;

  /// prioritise_places, change_time_window, relax_another_constraint.
  final List<String> choices;

  factory TimelineConflict.fromJson(Map<String, dynamic> json) => TimelineConflict(
    code: json['code']?.toString() ?? '',
    destinationId: (json['destination_id'] as num?)?.toInt(),
    day: (json['day'] as num?)?.toInt(),
    message: json['message']?.toString() ?? '',
    choices: (json['choices'] as List<dynamic>? ?? const []).map((e) => e.toString()).toList(),
  );
}

class TimelineCheck {
  const TimelineCheck({
    required this.id,
    required this.status,
    required this.message,
    this.destinationIds = const [],
  });

  final String id;
  final String status; // passed | failed | cannot_verify
  final String message;
  final List<int> destinationIds;

  factory TimelineCheck.fromJson(Map<String, dynamic> json) => TimelineCheck(
    id: json['id']?.toString() ?? '',
    status: json['status']?.toString() ?? 'cannot_verify',
    message: json['message']?.toString() ?? '',
    destinationIds: (json['destination_ids'] as List<dynamic>? ?? const [])
        .whereType<num>()
        .map((e) => e.toInt())
        .toList(),
  );
}

class TimelineBudget {
  const TimelineBudget({
    required this.knownTotal,
    required this.estimatedTotal,
    required this.unknown,
    this.unbased = const [],
    this.toComplete = const [],
    required this.subtotal,
    required this.complete,
    required this.fit,
    this.totalBudget,
    this.remaining,
    this.notes = const [],
  });

  final double knownTotal;
  final double estimatedTotal;
  final List<String> unknown;

  /// Estimates with no recorded charging basis: shown, never used to judge the budget.
  final List<String> unbased;

  /// What the traveler could add to complete the estimate (prompts, not costs).
  final List<String> toComplete;
  final double subtotal;
  final bool complete;
  final double? totalBudget;

  /// Only when the picture is complete and a budget is set.
  final double? remaining;
  final String fit; // fits_known_costs | over_budget | undetermined
  final List<String> notes;

  factory TimelineBudget.fromJson(Map<String, dynamic> json) => TimelineBudget(
    knownTotal: _money(json['known_total']) ?? 0,
    estimatedTotal: _money(json['estimated_total']) ?? 0,
    unknown: (json['unknown'] as List<dynamic>? ?? const []).map((e) => e.toString()).toList(),
    unbased: (json['unbased'] as List<dynamic>? ?? const []).map((e) => e.toString()).toList(),
    toComplete: (json['to_complete'] as List<dynamic>? ?? const []).map((e) => e.toString()).toList(),
    subtotal: _money(json['subtotal']) ?? 0,
    complete: json['complete'] == true,
    totalBudget: _money(json['total_budget']),
    remaining: _money(json['remaining']),
    fit: json['fit']?.toString() ?? 'undetermined',
    notes: (json['notes'] as List<dynamic>? ?? const []).map((e) => e.toString()).toList(),
  );
}

class TimelineData {
  TimelineData._({
    required this.raw,
    required this.days,
    required this.conflicts,
    required this.checks,
    required this.budget,
    required this.feasible,
    required this.unverified,
    required this.assumptions,
  });

  /// The server's JSON, sent back unchanged as `previous` when revising.
  final Map<String, dynamic> raw;
  final List<TimelineDay> days;
  final List<TimelineConflict> conflicts;
  final List<TimelineCheck> checks;
  final TimelineBudget budget;

  /// True only when nothing failed and no pick is in conflict; never "fully verified".
  final bool feasible;
  final List<String> unverified;
  final List<String> assumptions;

  factory TimelineData.fromJson(Map<String, dynamic> json) => TimelineData._(
    raw: json,
    days: _maps(json['days']).map(TimelineDay.fromJson).toList(),
    conflicts: _maps(json['conflicts']).map(TimelineConflict.fromJson).toList(),
    checks: _maps(json['checks']).map(TimelineCheck.fromJson).toList(),
    budget: TimelineBudget.fromJson(
      json['budget'] is Map<String, dynamic> ? json['budget'] as Map<String, dynamic> : const {},
    ),
    feasible: json['feasible'] == true,
    unverified: (json['unverified'] as List<dynamic>? ?? const []).map((e) => e.toString()).toList(),
    assumptions: (json['assumptions'] as List<dynamic>? ?? const []).map((e) => e.toString()).toList(),
  );

  Map<String, dynamic> toJson() => raw;

  int count(String status) => checks.where((c) => c.status == status).length;

  /// The picks in order, with their names.
  List<({int id, String name})> get places => [
    for (final day in days)
      for (final item in day.items)
        if (item.kind == 'visit' && item.destinationId != null)
          (id: item.destinationId!, name: item.label),
  ];
}

class TimelineResult {
  const TimelineResult({
    required this.timeline,
    this.changes = const [],
    this.routeStatus = 'not_requested',
    this.unavailableDestinationIds = const [],
  });

  final TimelineData timeline;

  /// Plain sentences for what moved since the previous timeline.
  final List<String> changes;
  final String routeStatus;
  final List<int> unavailableDestinationIds;

  factory TimelineResult.fromJson(Map<String, dynamic> json) => TimelineResult(
    timeline: TimelineData.fromJson(json['timeline'] as Map<String, dynamic>),
    changes: (json['changes'] as List<dynamic>? ?? const []).map((e) => e.toString()).toList(),
    routeStatus: json['route_status']?.toString() ?? 'not_requested',
    unavailableDestinationIds: (json['unavailable_destination_ids'] as List<dynamic>? ?? const [])
        .whereType<num>()
        .map((e) => e.toInt())
        .toList(),
  );
}

/// One saved version of the trip's timeline (the revision log).
class TimelineRevisionSummary {
  const TimelineRevisionSummary({
    required this.revision,
    required this.createdAt,
    this.changes = const [],
  });

  final int revision;
  final DateTime? createdAt;

  /// Plain sentences for what moved since the previous revision.
  final List<String> changes;

  factory TimelineRevisionSummary.fromJson(Map<String, dynamic> json) =>
      TimelineRevisionSummary(
        revision: (json['revision'] as num?)?.toInt() ?? 0,
        createdAt: DateTime.tryParse(json['created_at']?.toString() ?? ''),
        changes: (json['changes'] as List<dynamic>? ?? const [])
            .map((e) => e.toString())
            .toList(),
      );
}

/// The outcome of restoring an older revision: the revision now saved as the newest.
class TimelineRestoreResult {
  const TimelineRestoreResult({
    this.revision,
    this.timeline,
    this.state,
    this.changes = const [],
    this.errorCode,
  });

  final int? revision;
  final TimelineData? timeline;

  /// The planning state that revision was built from.
  final Map<String, dynamic>? state;
  final List<String> changes;

  /// Set when it failed: for example `trip_permission_denied`.
  final String? errorCode;

  bool get ok => timeline != null && state != null;
}

/// What the traveler changes in the Revise sheet; null fields are left as they are.
class TimelineRevision {
  const TimelineRevision({
    this.departureTime,
    this.returnDeadline,
    this.dayCount,
    this.pace,
    this.destinationIds,
  });

  /// "HH:MM:SS".
  final String? departureTime;
  final String? returnDeadline;
  final int? dayCount;
  final String? pace;

  /// The places kept, in order; removing one is the traveler's own choice.
  final List<int>? destinationIds;
}
