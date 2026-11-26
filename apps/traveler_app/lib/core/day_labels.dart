/// Wording for how long a trip is, so "1 Days" can never be printed.
class DayLabels {
  DayLabels._();

  /// "1 day" or "3 days".
  static String count(int days) => days == 1 ? '1 day' : '$days days';

  /// Title-case version for list rows: "1 Day", "3 Days".
  static String countTitle(int days) => days == 1 ? '1 Day' : '$days Days';

  /// The upper-case badge on a place or trip header: "3 DAYS • BEACHES".
  /// A one-day visit says nothing useful about length, so the count is left
  /// out and only the kind is shown.
  static String badge(int days, String kind) {
    final label = kind.toUpperCase();
    return days > 1 ? '$days DAYS • $label' : label;
  }

  /// The badge on the featured trip, from its real start date. A trip with no
  /// date says so, instead of claiming it starts tomorrow.
  static String startsLabel(DateTime? start, {DateTime? now}) {
    if (start == null) return 'Dates not set';
    final today = now ?? DateTime.now();
    final days = DateTime.utc(start.year, start.month, start.day)
        .difference(DateTime.utc(today.year, today.month, today.day))
        .inDays;
    if (days < 0) return 'Dates passed';
    if (days == 0) return 'Starts today';
    if (days == 1) return 'Starts tomorrow';
    return 'Starts in $days days';
  }

  /// Joins the parts with " • " and drops repeats, ignoring case, so
  /// "Davao del Norte • Davao Del Norte" reads once.
  static String joinDistinct(Iterable<String> parts) {
    final seen = <String>{};
    final out = <String>[];
    for (final part in parts) {
      for (final piece in part.split('•')) {
        final text = piece.trim();
        if (text.isNotEmpty && seen.add(text.toLowerCase())) out.add(text);
      }
    }
    return out.join(' • ');
  }
}
