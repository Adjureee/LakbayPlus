/// Public-transport directions to a place, verified by Lakbay admins.
///
/// Nothing here is guessed: a time, fare or charging unit the admin did not
/// state stays null, and the totals say whether they cover the whole trip.
class CommuteStep {
  final String vehicle;
  final String? fromPlace;
  final String? toPlace;
  final String? getOffAt;
  final int? minutes;
  final double? farePhp;
  final String? chargingUnit; // 'per_person' | 'per_trip' | null
  final String? notes;

  const CommuteStep({
    required this.vehicle,
    this.fromPlace,
    this.toPlace,
    this.getOffAt,
    this.minutes,
    this.farePhp,
    this.chargingUnit,
    this.notes,
  });

  factory CommuteStep.fromJson(Map<String, dynamic> json) {
    String? text(String key) {
      final value = (json[key] ?? '').toString().trim();
      return value.isEmpty ? null : value;
    }

    return CommuteStep(
      vehicle: (json['vehicle'] ?? '').toString(),
      fromPlace: text('from_place'),
      toPlace: text('to_place'),
      getOffAt: text('get_off_at'),
      minutes: (json['minutes'] as num?)?.toInt(),
      farePhp: json['fare_php'] == null
          ? null
          : double.tryParse(json['fare_php'].toString()),
      chargingUnit: text('charging_unit'),
      notes: text('notes'),
    );
  }

  static const _names = {
    'jeepney': 'Jeepney',
    'tricycle': 'Tricycle',
    'habal_habal': 'Habal-habal',
    'van': 'Van',
    'bus': 'Bus',
    'taxi': 'Taxi',
    'ferry': 'Ferry',
    'walk': 'Walk',
    'fee': 'Local fee',
  };

  String get vehicleLabel => _names[vehicle] ?? vehicle;

  bool get isRide => const {
        'jeepney', 'tricycle', 'habal_habal', 'van', 'bus', 'taxi', 'ferry',
      }.contains(vehicle);

  /// "₱30 per person", "₱100 per trip", "₱20" (unit not stated) or null.
  String? get fareLabel {
    final fare = farePhp;
    if (fare == null) return null;
    final amount = fare == fare.roundToDouble()
        ? fare.toStringAsFixed(0)
        : fare.toStringAsFixed(2);
    return switch (chargingUnit) {
      'per_person' => '₱$amount per person',
      'per_trip' => '₱$amount per trip',
      _ => '₱$amount',
    };
  }

  /// One plain sentence for the directions list.
  String get instruction {
    final from = fromPlace;
    final to = toPlace;
    switch (vehicle) {
      case 'walk':
        return [
          'Walk',
          if (from != null) 'from $from',
          if (to != null) 'to $to',
        ].join(' ');
      case 'fee':
        return notes ?? 'Pay the local fee';
      default:
        final lead = switch (vehicle) {
          'ferry' => 'Take a ferry',
          'jeepney' => 'Ride a jeepney',
          'tricycle' => 'Ride a tricycle',
          'habal_habal' => 'Ride a habal-habal',
          'van' => 'Ride a van',
          'bus' => 'Ride a bus',
          'taxi' => 'Take a taxi',
          _ => 'Take $vehicleLabel',
        };
        return [
          lead,
          if (from != null) 'from $from',
          if (to != null) 'to $to',
        ].join(' ');
    }
  }
}

class CommuteRoute {
  final int id;
  final String? startArea;
  final List<CommuteStep> steps;
  final int totalMinutes;
  final bool minutesComplete;
  final double totalFarePerPersonPhp;
  final bool fareComplete;
  final int transfers;
  final String? sourceUrl;

  const CommuteRoute({
    required this.id,
    required this.steps,
    this.startArea,
    this.totalMinutes = 0,
    this.minutesComplete = false,
    this.totalFarePerPersonPhp = 0,
    this.fareComplete = false,
    this.transfers = 0,
    this.sourceUrl,
  });

  factory CommuteRoute.fromJson(Map<String, dynamic> json) {
    final area = (json['start_area'] ?? '').toString().trim();
    return CommuteRoute(
      id: (json['commute_route_id'] as num?)?.toInt() ?? 0,
      startArea: area.isEmpty ? null : area,
      steps: [
        for (final raw in (json['steps'] as List? ?? const []))
          if (raw is Map<String, dynamic>) CommuteStep.fromJson(raw),
      ],
      totalMinutes: (json['total_minutes'] as num?)?.toInt() ?? 0,
      minutesComplete: json['minutes_complete'] == true,
      totalFarePerPersonPhp:
          double.tryParse('${json['total_fare_per_person_php']}') ?? 0,
      fareComplete: json['fare_complete'] == true,
      transfers: (json['transfers'] as num?)?.toInt() ?? 0,
      sourceUrl: (json['source_url'] as String?)?.trim().isEmpty ?? true
          ? null
          : json['source_url'] as String,
    );
  }

  /// "≈45 min", "at least 40 min" when some steps have no time, or null.
  String? get timeLabel {
    if (totalMinutes <= 0) return null;
    final text = _duration(totalMinutes);
    return minutesComplete ? '≈$text' : 'at least $text';
  }

  /// "₱130 per person", "₱130+ per person" when other fares are not listed,
  /// or null when no per-person fare is known.
  String? get fareLabel {
    // A route that is only walking costs nothing to ride.
    if (steps.isNotEmpty && steps.every((s) => s.vehicle == 'walk')) {
      return 'Free';
    }
    if (totalFarePerPersonPhp <= 0) return null;
    final amount = totalFarePerPersonPhp == totalFarePerPersonPhp.roundToDouble()
        ? totalFarePerPersonPhp.toStringAsFixed(0)
        : totalFarePerPersonPhp.toStringAsFixed(2);
    return fareComplete ? '₱$amount per person' : '₱$amount+ per person';
  }

  /// The vehicles in order, e.g. "Jeepney → Tricycle".
  String get summary => steps
      .where((s) => s.vehicle != 'fee')
      .map((s) => s.vehicleLabel)
      .join(' → ');

  /// Directions as plain text, for copying or sharing.
  String toPlainText(String placeName) {
    final lines = <String>['How to get to $placeName'];
    if (startArea != null) lines.add('Starting from $startArea');
    for (var i = 0; i < steps.length; i++) {
      final step = steps[i];
      final extras = [
        if (step.getOffAt != null) 'get off at ${step.getOffAt}',
        if (step.minutes != null) _duration(step.minutes!),
        ?step.fareLabel,
      ];
      lines.add(
        '${i + 1}. ${step.instruction}'
        '${extras.isEmpty ? '' : ' (${extras.join(', ')})'}',
      );
    }
    return lines.join('\n');
  }

  static String _duration(int minutes) {
    if (minutes < 60) return '$minutes min';
    final hours = minutes ~/ 60;
    final rest = minutes % 60;
    return rest == 0 ? '$hours h' : '$hours h $rest min';
  }
}
