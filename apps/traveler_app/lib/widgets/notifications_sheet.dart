import 'package:flutter/material.dart';

import '../design/lakbay_tokens.dart';
import '../design/lakbay_type.dart';
import '../models/travel_models.dart';
import '../screens/trip_detail_screen.dart';
import '../services/travel_repository.dart';

Widget _buildNotificationBody(
  BuildContext context,
  TravelRepository repo,
  AppNotificationItem n,
) {
  final open =
      n.eventType == 'trip_invitation' && repo.hasPendingInvitation(n.tripId);
  if (!open) return Text(n.message);
  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(n.message),
      const SizedBox(height: 6),
      Row(
        children: [
          ElevatedButton(
            onPressed: () => _answerInvitation(context, repo, n, accept: true),
            style: ElevatedButton.styleFrom(
              minimumSize: Size.zero,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
            ),
            child: const Text('Accept'),
          ),
          const SizedBox(width: 8),
          OutlinedButton(
            onPressed: () => _answerInvitation(context, repo, n, accept: false),
            style: OutlinedButton.styleFrom(
              minimumSize: Size.zero,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
            ),
            child: const Text('Decline'),
          ),
        ],
      ),
    ],
  );
}

Future<void> _answerInvitation(
  BuildContext context,
  TravelRepository repo,
  AppNotificationItem n, {
  required bool accept,
}) async {
  final tripId = n.tripId;
  if (tripId == null) return;
  final messenger = ScaffoldMessenger.of(context);
  final ok = await repo.answerInvitation(tripId, accept: accept);
  if (n.isRead == false) repo.markNotificationRead(n.notificationId);
  messenger.showSnackBar(
    SnackBar(
      content: Text(
        !ok
            ? "That didn't go through. Please try again."
            : accept
            ? 'You joined ${n.tripTitle ?? 'the trip'}.'
            : 'Invitation declined.',
      ),
    ),
  );
}

/// Opens the trip a notification is about, when it is one of the traveler's trips.
void _openNotifiedTrip(
  BuildContext context,
  TravelRepository repo,
  AppNotificationItem n,
) {
  final tripId = n.tripId;
  if (tripId == null) return;
  final matches = repo.savedTrips.where((t) => t.backendTripId == tripId);
  if (matches.isEmpty) return;
  final navigator = Navigator.of(context);
  navigator.pop(); // close the notifications sheet
  navigator.push(
    MaterialPageRoute(
      builder: (_) => TripDetailScreen(trip: matches.first, repo: repo),
    ),
  );
}

/// Notifications and trip invitations, opened from the Trips and Chat
/// headers.
void showNotificationsSheet(BuildContext context, TravelRepository repo) {
  repo.refreshNotifications();
  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: LkColors.s1,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
    builder: (ctx) {
      return ListenableBuilder(
        listenable: repo,
        builder: (_, _) {
          final items = repo.notifications;
          return DraggableScrollableSheet(
            expand: false,
            initialChildSize: 0.65,
            maxChildSize: 0.9,
            builder: (_, scrollCtrl) => ListView(
              controller: scrollCtrl,
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
              children: [
                Row(
                  children: [
                    const Expanded(
                      child: Text(
                        'Notifications',
                        style: TextStyle(
                          fontFamily: LkType.displayFamily,
                          fontSize: 21,
                          fontWeight: FontWeight.w800,
                          color: LkColors.text,
                        ),
                      ),
                    ),
                    if (repo.unreadNotificationCount > 0)
                      TextButton(
                        onPressed: repo.markAllNotificationsRead,
                        child: const Text('Mark all read'),
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                if (items.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 28),
                    child: Center(
                      child: Text(
                        repo.isSignedIn
                            ? 'No notifications yet. Group updates and 80% budget alerts appear here.'
                            : 'Sign in to receive group invites, task updates, and 80% budget alerts.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.grey.shade600),
                      ),
                    ),
                  )
                else
                  for (final n in items)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: CircleAvatar(
                        backgroundColor: n.isRead
                            ? Colors.grey.shade200
                            : LkColors.s3.withValues(alpha: 0.16),
                        child: Icon(
                          n.eventType == 'trip_updated'
                              ? Icons.warning_amber_rounded
                              : Icons.notifications_active_outlined,
                          color: n.isRead
                              ? Colors.grey.shade600
                              : LkColors.lagoon,
                          size: 20,
                        ),
                      ),
                      title: Text(
                        n.title,
                        style: TextStyle(
                          fontWeight: n.isRead
                              ? FontWeight.w500
                              : FontWeight.w700,
                        ),
                      ),
                      subtitle: _buildNotificationBody(ctx, repo, n),
                      trailing: n.isRead
                          ? null
                          : const Icon(
                              Icons.circle,
                              size: 9,
                              color: LkColors.lagoon,
                            ),
                      onTap: () {
                        repo.markNotificationRead(n.notificationId);
                        _openNotifiedTrip(ctx, repo, n);
                      },
                    ),
              ],
            ),
          );
        },
      );
    },
  );
}
