import '../models/travel_models.dart';

/// Access rules a traveler must know before going, such as climb permits.
///
/// Kept in the app (not in trip advisories) because server advisories are
/// replaced whenever a trip is refreshed, and this must always show.
class AccessNotice {
  final String title;
  final String body;

  /// Short label for tight spaces such as the map day card.
  final String shortLabel;

  const AccessNotice({
    required this.title,
    required this.body,
    required this.shortLabel,
  });
}

const _mountApoPermit = AccessNotice(
  title: 'Mount Apo: permit and guide required',
  body:
      'Climbing Mt. Apo needs a DENR–PAMB climb permit and an accredited '
      'guide, booked ahead. The route ends at the Trekkers\' Information '
      'Center in Kapatagan, Digos, where climbers register — not at the '
      'summit. Check current permit slots and trail status with Digos City '
      'Tourism before you travel.',
  shortLabel: 'Permit & guide required · register in Kapatagan',
);

/// Backend destination id → notice. 5 = "Mount Apo Trail Area".
const Map<int, AccessNotice> _byDestinationId = {5: _mountApoPermit};

/// Name match for trips without backend ids (AI or custom trips).
final RegExp _mountApoName = RegExp(
  r'\b(mount|mt\.?)\s*apo\b',
  caseSensitive: false,
);

AccessNotice? accessNoticeFor({int? destinationId, String? name}) {
  if (destinationId != null) {
    final byId = _byDestinationId[destinationId];
    if (byId != null) return byId;
  }
  if (name != null && _mountApoName.hasMatch(name)) {
    // "Mt. Apo Arabica coffee" or a view "of Mt. Apo" is not a climb.
    final lower = name.toLowerCase();
    final isClimb =
        lower.contains('trail') ||
        lower.contains('climb') ||
        lower.contains('summit') ||
        lower.contains('trek') ||
        RegExp(
          r'^\s*(mount|mt\.?)\s*apo\s*$',
          caseSensitive: false,
        ).hasMatch(name);
    if (isClimb) return _mountApoPermit;
  }
  return null;
}

/// Notice for one itinerary day, from its destination ids or stop titles.
AccessNotice? accessNoticeForDay(ItineraryDay day) {
  final fromDay = accessNoticeFor(destinationId: day.apiDestinationId);
  if (fromDay != null) return fromDay;
  for (final stop in day.stops) {
    final notice = accessNoticeFor(
      destinationId: stop.destinationId,
      name: stop.title,
    );
    if (notice != null) return notice;
  }
  return null;
}

/// Distinct notices for a whole trip, in first-seen order.
List<AccessNotice> accessNoticesForTrip(ItineraryTrip trip) {
  final notices = <AccessNotice>[];
  void add(AccessNotice? notice) {
    if (notice != null && !notices.contains(notice)) notices.add(notice);
  }

  for (final id in trip.effectiveBackendDestinationIds) {
    add(accessNoticeFor(destinationId: id));
  }
  for (final day in trip.days) {
    add(accessNoticeForDay(day));
  }
  return notices;
}
