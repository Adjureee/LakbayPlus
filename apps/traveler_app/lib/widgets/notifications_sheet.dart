import 'package:flutter/material.dart';

import '../models/travel_models.dart';
import '../screens/trip_detail_screen.dart';
import '../services/notification_routing.dart';
export '../services/notification_routing.dart'
    show targetManagementSheetForNotification;
import '../services/travel_repository.dart';
import '../theme/lakbay_theme.dart';

/// Shared notification bell icon button with unread badge for Chat & Trips headers.
class NotificationBellButton extends StatelessWidget {
  final TravelRepository repo;
  final Color? backgroundColor;
  final Color? iconColor;
  final double elevation;

  const NotificationBellButton({
    super.key,
    required this.repo,
    this.backgroundColor,
    this.iconColor,
    this.elevation = 2,
  });

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: repo,
      builder: (context, _) {
        final unread = repo.unreadNotificationCount;
        return Material(
          color: backgroundColor ?? Colors.white.withValues(alpha: 0.94),
          shape: const CircleBorder(),
          elevation: elevation,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              IconButton(
                tooltip: 'Notifications',
                onPressed: () => showNotificationsSheet(context, repo),
                icon: Icon(
                  Icons.notifications_none_rounded,
                  color: iconColor ?? LakbayColors.tealDeep,
                ),
              ),
              if (unread > 0)
                Positioned(
                  right: 6,
                  top: 6,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 5,
                      vertical: 1,
                    ),
                    decoration: BoxDecoration(
                      color: LakbayColors.primary,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      unread > 99 ? '99+' : '$unread',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 10,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

/// Opens the traveler's inbox with inline invite answers and event-type routing.
Future<void> showNotificationsSheet(
  BuildContext context,
  TravelRepository repo,
) async {
  repo.refreshNotifications();
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.white,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
    builder: (ctx) => ListenableBuilder(
      listenable: repo,
      builder: (_, _) => _NotificationInbox(repo: repo, sheetContext: ctx),
    ),
  );
}

/// The inbox list with Unread and type filters.
class _NotificationInbox extends StatefulWidget {
  final TravelRepository repo;
  final BuildContext sheetContext;

  const _NotificationInbox({required this.repo, required this.sheetContext});

  @override
  State<_NotificationInbox> createState() => _NotificationInboxState();
}

class _NotificationInboxState extends State<_NotificationInbox> {
  bool _unreadOnly = false;
  NotificationGroup? _group;

  static const _groupLabels = {
    NotificationGroup.invitations: 'Invitations',
    NotificationGroup.tasks: 'Tasks',
    NotificationGroup.money: 'Money',
    NotificationGroup.trips: 'Trips',
  };

  @override
  Widget build(BuildContext context) {
    final repo = widget.repo;
    final all = repo.notifications;
    final items = [
      for (final n in all)
        if ((!_unreadOnly || !n.isRead) &&
            (_group == null || notificationGroupFor(n.eventType) == _group))
          n,
    ];
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
                    fontFamily: 'FigGrotesk',
                    fontSize: 21,
                    fontWeight: FontWeight.w800,
                    color: LakbayColors.tealDeep,
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
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                FilterChip(
                  key: const ValueKey('notif-filter-unread'),
                  label: const Text('Unread'),
                  selected: _unreadOnly,
                  onSelected: (v) => setState(() => _unreadOnly = v),
                ),
                const SizedBox(width: 6),
                for (final entry in _groupLabels.entries) ...[
                  ChoiceChip(
                    key: ValueKey('notif-filter-${entry.key.name}'),
                    label: Text(entry.value),
                    selected: _group == entry.key,
                    onSelected: (v) =>
                        setState(() => _group = v ? entry.key : null),
                  ),
                  const SizedBox(width: 6),
                ],
              ],
            ),
          ),
          const SizedBox(height: 8),
          if (items.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 28),
              child: Center(
                child: Text(
                  all.isNotEmpty
                      ? 'Nothing matches this filter.'
                      : repo.isSignedIn
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
                      : LakbayColors.primary.withValues(alpha: 0.16),
                  child: Icon(
                    _iconForNotificationEvent(n.eventType),
                    color: n.isRead
                        ? Colors.grey.shade600
                        : LakbayColors.primary,
                    size: 20,
                  ),
                ),
                title: Text(
                  n.title,
                  style: TextStyle(
                    fontWeight: n.isRead ? FontWeight.w500 : FontWeight.w700,
                  ),
                ),
                subtitle: _NotificationBody(repo: repo, notification: n),
                trailing: n.isRead
                    ? null
                    : const Icon(
                        Icons.circle,
                        size: 9,
                        color: LakbayColors.primary,
                      ),
                onTap: () =>
                    handleNotificationTap(widget.sheetContext, repo, n),
              ),
        ],
      ),
    );
  }
}

IconData _iconForNotificationEvent(String eventType) {
  return switch (eventType) {
    'trip_invitation' ||
    'trip_invitation_accepted' ||
    'trip_invitation_declined' ||
    'trip_member_added' =>
      Icons.group_add_outlined,
    'task_assigned' || 'task_updated' => Icons.check_circle_outline,
    'expense_created' ||
    'expense_updated' ||
    'expense_voided' ||
    'trip_updated' =>
      Icons.pie_chart_outline_rounded,
    'trip_route_updated' => Icons.route_outlined,
    _ => Icons.notifications_active_outlined,
  };
}

/// Marks [notification] read and navigates according to `eventType`.
Future<void> handleNotificationTap(
  BuildContext sheetContext,
  TravelRepository repo,
  AppNotificationItem notification,
) async {
  repo.markNotificationRead(notification.notificationId);
  final navigator = Navigator.of(sheetContext);
  final target = await resolveNotificationTarget(
    repo,
    eventType: notification.eventType,
    tripId: notification.tripId,
  );
  if (target == null) return;
  if (target.showInvitations || target.trip == null) {
    repo.setActiveNavIndex(0);
    navigator.pop();
    return;
  }
  navigator.pop();
  navigator.push(
    MaterialPageRoute(
      builder: (_) => TripDetailScreen(
        trip: target.trip!,
        repo: repo,
        initialManagementSheet: target.sheet,
      ),
    ),
  );
}

class _NotificationBody extends StatelessWidget {
  final TravelRepository repo;
  final AppNotificationItem notification;

  const _NotificationBody({
    required this.repo,
    required this.notification,
  });

  Future<void> _answer(BuildContext context, {required bool accept}) async {
    final tripId = notification.tripId;
    if (tripId == null) return;
    final messenger = ScaffoldMessenger.of(context);
    final ok = await repo.answerInvitation(tripId, accept: accept);
    if (!notification.isRead) {
      repo.markNotificationRead(notification.notificationId);
    }
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          !ok
              ? "That didn't go through. Please try again."
              : accept
                  ? 'You joined ${notification.tripTitle ?? 'the trip'}.'
                  : 'Invitation declined.',
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final open = notification.eventType == 'trip_invitation' &&
        repo.hasPendingInvitation(notification.tripId);
    if (!open) return Text(notification.message);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(notification.message),
        const SizedBox(height: 6),
        Row(
          children: [
            ElevatedButton(
              onPressed: () => _answer(context, accept: true),
              style: ElevatedButton.styleFrom(
                minimumSize: Size.zero,
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 6,
                ),
              ),
              child: const Text('Accept'),
            ),
            const SizedBox(width: 8),
            OutlinedButton(
              onPressed: () => _answer(context, accept: false),
              style: OutlinedButton.styleFrom(
                minimumSize: Size.zero,
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 6,
                ),
              ),
              child: const Text('Decline'),
            ),
          ],
        ),
      ],
    );
  }
}
