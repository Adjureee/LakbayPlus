/// Words for the itinerary timeline, shared by the screen and the PDF so both say the
/// same thing about how far to trust a time, a check or a cost.
library;

/// How far to trust a time, in the traveler's words.
const timelineBasisLabels = <String, String>{
  'confirmed': 'Confirmed',
  'estimated': 'Estimated',
  'provisional': 'Provisional',
  'unknown': 'Unknown',
};

/// What each trust label means, for the legend in the PDF.
const timelineBasisMeanings = <String, String>{
  'confirmed': 'fixed by you or by recorded opening hours',
  'estimated': 'calculated from recorded or estimated durations and travel times',
  'provisional': 'depends on a planning default or on a leg with no travel time',
  'unknown': 'not known',
};

const timelineCheckTitles = <String, String>{
  'chronological_order': 'Order of the day',
  'selected_places': 'Your places',
  'travel_date': 'Travel date',
  'geographic_scope': 'Inside the Davao Region',
  'operating_status': 'Open at all',
  'opening_hours': 'Opening hours',
  'travel_times': 'Travel times',
  'visit_durations': 'Visit lengths',
  'return_deadline': 'Return deadline',
  'activity_suitability': 'Suitable for children',
  'overnight_stay': 'Where you stay',
  'budget_arithmetic': 'Costs add up',
};

String timelineStatusText(String status) => switch (status) {
  'passed' => 'Passed',
  'failed' => 'Failed',
  _ => "Can't verify",
};

const timelineChoiceLabels = <String, String>{
  'prioritise_places': 'Choose which places to keep',
  'change_time_window': 'Change the time window',
  'relax_another_constraint': 'Change another limit',
};

/// 1500 as "₱1,500", 49.5 as "₱49.50".
String pesoText(double amount, {String symbol = '₱'}) {
  final whole = amount == amount.roundToDouble();
  final text = whole ? amount.toStringAsFixed(0) : amount.toStringAsFixed(2);
  final parts = text.split('.');
  final grouped = parts[0].replaceAllMapped(
    RegExp(r'\B(?=(\d{3})+(?!\d))'),
    (_) => ',',
  );
  return '$symbol${parts.length > 1 ? '$grouped.${parts[1]}' : grouped}';
}
