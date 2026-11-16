import '../models/travel_models.dart';
import 'travel_repository.dart';

/// Where tapping a notification (in the app or a push) should take the traveler.
class NotificationTarget {
  /// A pending invitation: shown on the Trips tab, where it can be answered.
  final bool showInvitations;

  /// The trip to open, with the management sheet to open on it
  /// ('collaborate' for tasks and members, 'budget' for money), if any.
  final ItineraryTrip? trip;
  final String? sheet;

  const NotificationTarget({this.showInvitations = false, this.trip, this.sheet});
}

/// A push the traveler tapped: what happened and which trip it was about.
class PushOpenRequest {
  final int? notificationId;
  final String eventType;
  final int? tripId;

  const PushOpenRequest({this.notificationId, required this.eventType, this.tripId});

  /// Reads the data a Lakbay push carries (`notification_id`, `event_type`,
  /// `trip_id`, all text). Returns null when it is not a Lakbay notification.
  static PushOpenRequest? fromPushData(Map<String, dynamic> data) {
    final type = (data['event_type'] ?? '').toString().trim();
    if (type.isEmpty) return null;
    return PushOpenRequest(
      notificationId: int.tryParse('${data['notification_id']}'),
      eventType: type,
      tripId: int.tryParse('${data['trip_id']}'),
    );
  }
}

/// The filter groups of the notification center.
enum NotificationGroup { invitations, tasks, money, trips }

NotificationGroup notificationGroupFor(String eventType) => switch (eventType) {
      'trip_invitation' ||
      'trip_invitation_accepted' ||
      'trip_invitation_declined' ||
      'trip_member_added' =>
        NotificationGroup.invitations,
      'task_assigned' || 'task_updated' => NotificationGroup.tasks,
      'expense_created' ||
      'expense_updated' ||
      'expense_voided' ||
      'budget_warning' ||
      'budget_exceeded' =>
        NotificationGroup.money,
      _ => NotificationGroup.trips,
    };

String? targetManagementSheetForNotification(String eventType) {
  return switch (eventType) {
    'task_assigned' ||
    'task_updated' ||
    'trip_member_added' ||
    'trip_invitation_accepted' ||
    'trip_invitation_declined' =>
      'collaborate',
    'expense_created' ||
    'expense_updated' ||
    'expense_voided' ||
    'trip_updated' =>
      'budget',
    _ => null,
  };
}

/// Works out where a notification leads, syncing trips once if the trip is not
/// on the phone yet. Returns null when there is nowhere to go (for example the
/// traveler was removed from the trip).
Future<NotificationTarget?> resolveNotificationTarget(
  TravelRepository repo, {
  required String eventType,
  required int? tripId,
}) async {
  if (eventType == 'trip_invitation' && repo.hasPendingInvitation(tripId)) {
    return const NotificationTarget(showInvitations: true);
  }
  if (tripId == null) return null;

  Iterable<ItineraryTrip> matches() =>
      repo.savedTrips.where((t) => t.backendTripId == tripId);
  if (matches().isEmpty && repo.isSignedIn) {
    await repo.syncTripsFromBackend();
  }
  if (matches().isEmpty) return null;
  return NotificationTarget(
    trip: matches().first,
    sheet: targetManagementSheetForNotification(eventType),
  );
}
