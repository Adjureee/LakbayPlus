import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lakbay_travel/main.dart';
import 'package:lakbay_travel/models/travel_models.dart';
import 'package:lakbay_travel/screens/trip_detail_screen.dart';
import 'package:lakbay_travel/services/lakbay_api_catalog_service.dart';
import 'package:lakbay_travel/services/notification_routing.dart';
import 'package:lakbay_travel/services/push_notification_service.dart';
import 'package:lakbay_travel/services/travel_repository.dart';
import 'package:lakbay_travel/widgets/notifications_sheet.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _trip = ItineraryTrip(
  id: 'cloud_9',
  title: 'Samal Weekend',
  destination: 'Samal Island',
  daysCount: 2,
  centerLat: 7.05,
  centerLng: 125.71,
  heroAsset: 'assets/home_backdrops/01-samal-island.jpg',
  vibeTag: 'Beaches',
  overviewText: 'Island weekend.',
  bestMonths: 'Dec – May',
  avgTemp: '29°C',
  expertName: 'Lakbay+ AI',
  expertTip: 'Book ferry early.',
  days: [],
  flights: [],
  hotels: [],
  backendTripId: 9,
  backendDestinationIds: [12],
);

Map<String, dynamic> _note(int id, String type, {bool read = false, int tripId = 9}) => {
  'notification_id': id,
  'trip_id': tripId,
  'trip_title': 'Samal Weekend',
  'event_type': type,
  'title': 'Title $id',
  'message': 'Message $id',
  'is_read': read,
  'created_at': DateTime.now().toIso8601String(),
};

Future<TravelRepository> _repo(
  WidgetTester tester, {
  required List<Map<String, dynamic>> notifications,
  StreamController<Map<String, dynamic>>? opened,
  List<Map<String, dynamic>> invitations = const [],
}) async {
  SharedPreferences.setMockInitialValues({
    'lakbay_traveler_state_v1': jsonEncode({
      'hasCompletedOnboarding': true,
      'savedTrips': [_trip.toJson()],
      'authSession': {
        'accessToken': 'tok_1',
        'refreshToken': 'ref_1',
        'userId': 22,
        'email': 'claire@lakbay.ph',
        'fullName': 'Claire Tan',
      },
    }),
  });
  final client = MockClient((request) async {
    final path = request.url.path;
    if (path == '/api/v1/notifications') {
      return http.Response(jsonEncode(notifications), 200);
    }
    if (path == '/api/v1/notifications/unread-count') {
      return http.Response(
        jsonEncode({'unread_count': notifications.where((n) => n['is_read'] != true).length}),
        200,
      );
    }
    if (path == '/api/v1/trips/invitations') {
      return http.Response(jsonEncode(invitations), 200);
    }
    if (request.method == 'PATCH' && path.endsWith('/read')) {
      return http.Response('{"is_read":true}', 200);
    }
    return http.Response('[]', 200);
  });
  final repo = TravelRepository(
    apiCatalog: LakbayApiCatalogService(
      baseUrlOverride: 'https://api.lakbay.test/api/v1',
      client: client,
    ),
    pushService: PushNotificationService(
      tokenFetcher: () async => 'tok',
      platformResolver: () => 'android',
      openedMessageStream: opened?.stream,
    ),
  );
  await tester.runAsync(() => repo.initialize());
  await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
  await tester.runAsync(() => repo.refreshNotifications());
  return repo;
}

void main() {
  setUp(() {
    GoogleFonts.config.allowRuntimeFetching = false;
    SharedPreferences.setMockInitialValues({});
  });

  group('what a push carries and where it leads', () {
    test('the push data is read, and a push without an event type is ignored', () {
      final request = PushOpenRequest.fromPushData(
        {'notification_id': '71', 'event_type': 'task_assigned', 'trip_id': '9'},
      )!;
      expect(request.notificationId, 71);
      expect(request.eventType, 'task_assigned');
      expect(request.tripId, 9);

      expect(PushOpenRequest.fromPushData({'trip_id': '9'}), isNull);
      expect(PushOpenRequest.fromPushData({'event_type': 'x', 'trip_id': ''})!.tripId, isNull);
    });

    test('every event type belongs to one filter group', () {
      expect(notificationGroupFor('trip_invitation'), NotificationGroup.invitations);
      expect(notificationGroupFor('trip_invitation_accepted'), NotificationGroup.invitations);
      expect(notificationGroupFor('task_assigned'), NotificationGroup.tasks);
      expect(notificationGroupFor('expense_created'), NotificationGroup.money);
      expect(notificationGroupFor('trip_updated'), NotificationGroup.trips);
      expect(notificationGroupFor('something_new'), NotificationGroup.trips);
    });

    testWidgets('a task opens its trip on Collaborate, money on the budget sheet', (tester) async {
      final repo = await _repo(tester, notifications: [_note(1, 'task_assigned')]);

      final task = await tester.runAsync(
        () => resolveNotificationTarget(repo, eventType: 'task_assigned', tripId: 9),
      );
      expect(task!.trip!.backendTripId, 9);
      expect(task.sheet, 'collaborate');

      final money = await tester.runAsync(
        () => resolveNotificationTarget(repo, eventType: 'expense_created', tripId: 9),
      );
      expect(money!.sheet, 'budget');
    });

    testWidgets('a pending invitation goes to the invitation card, not a trip', (tester) async {
      final repo = await _repo(
        tester,
        notifications: [_note(2, 'trip_invitation', tripId: 15)],
        invitations: [
          {
            'trip_member_id': 8, 'trip_id': 15, 'trip_title': 'Buda Highlands',
            'invited_by_name': 'Carlo Lim', 'role': 'member',
          },
        ],
      );
      final target = await tester.runAsync(
        () => resolveNotificationTarget(repo, eventType: 'trip_invitation', tripId: 15),
      );
      expect(target!.showInvitations, isTrue);
      expect(target.trip, isNull);
    });

    testWidgets('a trip the traveler is no longer in leads nowhere', (tester) async {
      final repo = await _repo(tester, notifications: const []);
      final target = await tester.runAsync(
        () => resolveNotificationTarget(repo, eventType: 'task_assigned', tripId: 404),
      );
      expect(target, isNull);
      expect(
        await tester.runAsync(
          () => resolveNotificationTarget(repo, eventType: 'task_assigned', tripId: null),
        ),
        isNull,
      );
    });
  });

  testWidgets('tapping a push opens the trip it was about', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(900, 2400);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final opened = StreamController<Map<String, dynamic>>.broadcast();
    addTearDown(opened.close);
    final repo = await _repo(
      tester,
      notifications: [_note(71, 'task_assigned')],
      opened: opened,
    );

    await tester.pumpWidget(MaterialApp(home: MainNavigationShell(repo: repo)));
    await tester.pump();
    expect(find.byType(TripDetailScreen), findsNothing);

    opened.add({'notification_id': '71', 'event_type': 'task_assigned', 'trip_id': '9'});
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.byType(TripDetailScreen), findsOneWidget);
    expect(repo.pushOpenRequest.value, isNull);
  });

  testWidgets('the inbox filters by unread and by type, and says when nothing matches', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(900, 2000);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final repo = await _repo(tester, notifications: [
      _note(1, 'task_assigned'),
      _note(2, 'expense_created', read: true),
      _note(3, 'trip_updated'),
    ]);

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showNotificationsSheet(context, repo),
              child: const Text('open inbox'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open inbox'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('Title 1'), findsOneWidget);
    expect(find.text('Title 2'), findsOneWidget);
    expect(find.text('Title 3'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('notif-filter-unread')));
    await tester.pump();
    expect(find.text('Title 2'), findsNothing);
    expect(find.text('Title 1'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('notif-filter-money')));
    await tester.pump();
    expect(find.text('Nothing matches this filter.'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('notif-filter-unread')));
    await tester.pump();
    expect(find.text('Title 2'), findsOneWidget);
    expect(find.text('Title 1'), findsNothing);
  });
}
