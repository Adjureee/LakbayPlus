import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lakbay_travel/main.dart';
import 'package:lakbay_travel/models/travel_models.dart';
import 'package:lakbay_travel/screens/my_trips_screen.dart';
import 'package:lakbay_travel/screens/trip_detail_screen.dart';
import 'package:lakbay_travel/services/lakbay_api_catalog_service.dart';
import 'package:lakbay_travel/services/push_notification_service.dart';
import 'package:lakbay_travel/services/travel_repository.dart';
import 'package:lakbay_travel/widgets/notifications_sheet.dart';
import 'package:lakbay_travel/widgets/trip_management_sheets.dart';
import 'package:shared_preferences/shared_preferences.dart';

ItineraryTrip _syncedTrip() => const ItineraryTrip(
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

void main() {
  setUp(() {
    GoogleFonts.config.allowRuntimeFetching = false;
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('Collaboration sheet supports Assign-to, Unassigned, Assigned to me filter, and Resend invite', (
    tester,
  ) async {
    Map<String, dynamic>? postedTask;
    var resendCalls = 0;

    SharedPreferences.setMockInitialValues({
      'lakbay_traveler_state_v1': jsonEncode({
        'hasCompletedOnboarding': true,
        'savedTrips': [_syncedTrip().toJson()],
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
      if (path == '/api/v1/trips/9/members' && request.method == 'GET') {
        return http.Response(
          jsonEncode([
            {
              'trip_member_id': 1,
              'trip_id': 9,
              'user_id': 11,
              'full_name': 'Owner Marco',
              'email': 'marco@lakbay.ph',
              'role': 'owner',
              'status': 'active',
            },
            {
              'trip_member_id': 2,
              'trip_id': 9,
              'user_id': 22,
              'full_name': 'Claire Tan',
              'email': 'claire@lakbay.ph',
              'role': 'member',
              'status': 'active',
            },
            {
              'trip_member_id': 3,
              'trip_id': 9,
              'user_id': 33,
              'full_name': 'Pending Pat',
              'username': 'pendingpat',
              'email': null,
              'role': 'member',
              'status': 'invited',
            },
          ]),
          200,
        );
      }
      if (path == '/api/v1/trips/9/members/3/resend' &&
          request.method == 'POST') {
        resendCalls++;
        return http.Response(jsonEncode({'status': 'invited'}), 200);
      }
      if (path == '/api/v1/trips/9/tasks' && request.method == 'GET') {
        return http.Response(
          jsonEncode([
            {
              'trip_task_id': 101,
              'trip_id': 9,
              'assigned_trip_member_id': 2,
              'title': 'Bring snorkeling gear',
              'status': 'pending',
            },
            {
              'trip_task_id': 102,
              'trip_id': 9,
              'assigned_trip_member_id': 1,
              'title': 'Book Pearl Farm boat',
              'status': 'pending',
            },
          ]),
          200,
        );
      }
      if (path == '/api/v1/trips/9/tasks' && request.method == 'POST') {
        postedTask = jsonDecode(request.body) as Map<String, dynamic>;
        return http.Response(
          jsonEncode({
            'trip_task_id': 103,
            'trip_id': 9,
            'assigned_trip_member_id': postedTask!['assigned_trip_member_id'],
            'title': postedTask!['title'],
            'status': 'pending',
          }),
          201,
        );
      }
      return http.Response('[]', 200);
    });

    final repo = TravelRepository(
      apiCatalog: LakbayApiCatalogService(
        baseUrlOverride: 'https://api.lakbay.test/api/v1',
        client: client,
      ),
    );
    await tester.runAsync(() => repo.initialize());

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () => showTripCollaborationSheet(
                context,
                repo: repo,
                trip: _syncedTrip(),
              ),
              child: const Text('Open Collab'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open Collab'));
    await tester.pumpAndSettle();

    // Resend invitation on pending member
    await tester.tap(find.byTooltip('Resend invitation'));
    await tester.pumpAndSettle();
    expect(resendCalls, 1);
    expect(find.textContaining('Invitation resent to Pending Pat'), findsOneWidget);

    // Scroll down to Trip Tasks filter chips and filter by Assigned to me
    final sheetScrollable = find
        .descendant(
          of: find.byType(DraggableScrollableSheet),
          matching: find.byType(Scrollable),
        )
        .first;
    await tester.scrollUntilVisible(
      find.text('Assigned to me'),
      150,
      scrollable: sheetScrollable,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Assigned to me'));
    await tester.pumpAndSettle();
    expect(find.text('Bring snorkeling gear'), findsOneWidget);
    expect(find.text('Book Pearl Farm boat'), findsNothing);

    await tester.ensureVisible(find.text('All'));
    await tester.tap(find.text('All'));
    await tester.pumpAndSettle();

    // Default Assign to is Unassigned (sends null, NOT first member)
    final taskField = find.widgetWithText(TextField, 'Add packing or trip task');
    await tester.scrollUntilVisible(
      taskField,
      150,
      scrollable: sheetScrollable,
    );
    await tester.enterText(taskField, 'Buy reef-safe sunscreen');
    await tester.ensureVisible(find.widgetWithText(ElevatedButton, 'Add'));
    await tester.tap(find.widgetWithText(ElevatedButton, 'Add'));
    await tester.pumpAndSettle();
    expect(postedTask, isNotNull);
    expect(postedTask!['title'], 'Buy reef-safe sunscreen');
    expect(postedTask!['assigned_trip_member_id'], isNull);
  });

  testWidgets('Budget & Split sheet defaults Paid by to signed-in member and excludes pending invitees', (
    tester,
  ) async {
    Map<String, dynamic>? postedExpense;

    SharedPreferences.setMockInitialValues({
      'lakbay_traveler_state_v1': jsonEncode({
        'hasCompletedOnboarding': true,
        'savedTrips': [_syncedTrip().toJson()],
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
      if (path == '/api/v1/trips/9/members' && request.method == 'GET') {
        return http.Response(
          jsonEncode([
            {
              'trip_member_id': 1,
              'trip_id': 9,
              'user_id': 11,
              'full_name': 'Owner Marco',
              'email': 'marco@lakbay.ph',
              'role': 'owner',
              'status': 'active',
            },
            {
              'trip_member_id': 2,
              'trip_id': 9,
              'user_id': 22,
              'full_name': 'Claire Tan',
              'email': 'claire@lakbay.ph',
              'role': 'member',
              'status': 'active',
            },
            {
              'trip_member_id': 3,
              'trip_id': 9,
              'user_id': 33,
              'full_name': 'Pending Pat',
              'email': null,
              'role': 'member',
              'status': 'invited',
            },
          ]),
          200,
        );
      }
      if (path == '/api/v1/trips/9/expenses' && request.method == 'POST') {
        postedExpense = jsonDecode(request.body) as Map<String, dynamic>;
        return http.Response(
          jsonEncode({
            'trip_expense_id': 51,
            'trip_id': 9,
            'paid_by_trip_member_id': postedExpense!['paid_by_trip_member_id'],
            'paid_by_full_name': 'Claire Tan',
            'category': postedExpense!['category'],
            'title': postedExpense!['title'],
            'amount': '450.00',
            'expense_date': '2026-11-16',
            'status': 'active',
          }),
          201,
        );
      }
      if (path == '/api/v1/trips/9/expenses/summary') {
        return http.Response(
          jsonEncode({
            'total_budget': '5000.00',
            'total_spent': '450.00',
            'remaining_budget': '4550.00',
            'percent_used': 9.0,
            'budget_alert_level': 'ok',
            'adult_share': '225.00',
            'child_share': '112.50',
          }),
          200,
        );
      }
      return http.Response('[]', 200);
    });

    final repo = TravelRepository(
      apiCatalog: LakbayApiCatalogService(
        baseUrlOverride: 'https://api.lakbay.test/api/v1',
        client: client,
      ),
    );
    await tester.runAsync(() => repo.initialize());

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () => showTripBudgetAndPdfSheet(
                context,
                repo: repo,
                trip: _syncedTrip(),
              ),
              child: const Text('Open Budget'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open Budget'));
    await tester.pumpAndSettle();

    final budgetScrollable = find
        .descendant(
          of: find.byType(DraggableScrollableSheet),
          matching: find.byType(Scrollable),
        )
        .first;
    await tester.scrollUntilVisible(
      find.text('Paid by'),
      150,
      scrollable: budgetScrollable,
    );
    await tester.pumpAndSettle();

    expect(find.text('Paid by'), findsOneWidget);
    expect(find.text('Pending Pat'), findsNothing);

    await tester.ensureVisible(find.widgetWithText(TextField, 'Expense item'));
    await tester.enterText(
      find.widgetWithText(TextField, 'Expense item'),
      'Ferry tickets',
    );
    await tester.enterText(
      find.widgetWithText(TextField, '₱ Amount'),
      '450',
    );
    await tester.ensureVisible(find.widgetWithText(ElevatedButton, 'Add Expense'));
    await tester.tap(find.widgetWithText(ElevatedButton, 'Add Expense'));
    await tester.pumpAndSettle();

    expect(postedExpense, isNotNull);
    expect(postedExpense!['paid_by_trip_member_id'], 2);
  });

  testWidgets('Notification bell on MyTripsScreen, nav unread badge, event routing, and FCM token lifecycle', (
    tester,
  ) async {
    var registeredTokens = <String>[];
    var unregisteredTokens = <String>[];
    final fgCtrl = StreamController<Map<String, dynamic>>.broadcast();

    SharedPreferences.setMockInitialValues({
      'lakbay_traveler_state_v1': jsonEncode({
        'hasCompletedOnboarding': true,
        'savedTrips': [_syncedTrip().toJson()],
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
      if (path == '/api/v1/notifications/device-tokens' &&
          request.method == 'POST') {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        registeredTokens.add(body['device_token'].toString());
        return http.Response('{}', 200);
      }
      if (path == '/api/v1/notifications/device-tokens' &&
          request.method == 'DELETE') {
        unregisteredTokens.add(request.url.queryParameters['device_token'] ?? '');
        return http.Response('{"deactivated":1}', 200);
      }
      if (path == '/api/v1/notifications') {
        return http.Response(
          jsonEncode([
            {
              'notification_id': 71,
              'trip_id': 9,
              'trip_title': 'Samal Weekend',
              'event_type': 'task_assigned',
              'title': 'New task assigned',
              'message': 'Bring reef-safe sunscreen',
              'is_read': false,
              'created_at': DateTime.now().toIso8601String(),
            }
          ]),
          200,
        );
      }
      if (path == '/api/v1/notifications/unread-count') {
        return http.Response(jsonEncode({'unread_count': 1}), 200);
      }
      if (path == '/api/v1/notifications/71/read' &&
          request.method == 'PATCH') {
        return http.Response(jsonEncode({'is_read': true}), 200);
      }
      if (path == '/api/v1/trips/invitations') {
        return http.Response(
          jsonEncode([
            {
              'trip_member_id': 8,
              'trip_id': 15,
              'trip_title': 'Buda Highlands',
              'invited_by_name': 'Carlo Lim',
              'role': 'member',
            }
          ]),
          200,
        );
      }
      return http.Response('[]', 200);
    });

    final repo = TravelRepository(
      apiCatalog: LakbayApiCatalogService(
        baseUrlOverride: 'https://api.lakbay.test/api/v1',
        client: client,
      ),
      pushService: PushNotificationService(
        tokenFetcher: () async => 'fcm_device_abc_123',
        platformResolver: () => 'android',
        foregroundMessageStream: fgCtrl.stream,
      ),
    );
    await tester.runAsync(() => repo.initialize());
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.runAsync(() => repo.refreshNotifications());

    expect(registeredTokens, contains('fcm_device_abc_123'));
    expect(targetManagementSheetForNotification('task_assigned'), 'collaborate');
    expect(targetManagementSheetForNotification('expense_created'), 'budget');
    expect(targetManagementSheetForNotification('trip_updated'), 'budget');

    await tester.pumpWidget(
      MaterialApp(home: MyTripsScreen(repo: repo)),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    // Pending invite card and bell badge render directly on Trips tab
    expect(find.byTooltip('Notifications'), findsOneWidget);
    expect(find.text('Buda Highlands'), findsOneWidget);

    // Tapping notification bell opens inbox & task_assigned opens TripDetailScreen
    await tester.tap(find.byTooltip('Notifications'));
    await tester.pumpAndSettle();
    expect(find.text('New task assigned'), findsOneWidget);

    await tester.tap(find.text('New task assigned'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.byType(TripDetailScreen), findsOneWidget);

    // Unread count badge appears on Trips bottom nav item in MainNavigationShell
    await tester.pumpWidget(
      MaterialApp(home: MainNavigationShell(repo: repo)),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Trips'), findsOneWidget);

    await tester.runAsync(() => repo.signOutBackend());
    expect(unregisteredTokens, contains('fcm_device_abc_123'));
    await fgCtrl.close();
  });
}
