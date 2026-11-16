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
}
