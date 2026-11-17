import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lakbay_admin/screens/reviews_screen.dart';
import 'package:lakbay_admin/screens/trips_screen.dart';
import 'package:lakbay_admin/screens/users_screen.dart';
import 'package:lakbay_admin/services/api_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('UsersScreen loads admin directory and toggles user status', (
    tester,
  ) async {
    var active = true;
    final api = ApiService(
      tokenProvider: () async => 'admin-token',
      client: MockClient((request) async {
        if (request.url.path == '/api/v1/users/me') {
          return http.Response(
            jsonEncode({
              'user_id': 1,
              'full_name': 'Admin User',
              'email': 'admin@lakbay.test',
              'role': 'admin',
              'is_active': true,
            }),
            200,
          );
        }
        if (request.url.path == '/api/v1/admin/users') {
          return http.Response(
            jsonEncode({
              'total_users': 1,
              'signed_in_users': 1,
              'matching_users': 1,
              'items': [
                {
                  'user_id': 7,
                  'full_name': 'Juan Dela Cruz',
                  'email': 'juan@lakbay.test',
                  'role': 'traveler',
                  'is_active': active,
                  'has_active_session': true,
                },
              ],
            }),
            200,
          );
        }
        if (request.url.path == '/api/v1/admin/users/7' &&
            request.method == 'PATCH') {
          active = false;
          return http.Response(
            jsonEncode({'user_id': 7, 'is_active': false}),
            200,
          );
        }
        return http.Response('{}', 404);
      }),
    );

    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: UsersScreen(api: api))),
    );
    await tester.pumpAndSettle();

    expect(find.text('Juan Dela Cruz'), findsOneWidget);
    expect(find.text('Deactivate'), findsOneWidget);

    await tester.tap(find.text('Deactivate'));
    await tester.pumpAndSettle();

    expect(active, isFalse);
    expect(find.text('Reactivate'), findsOneWidget);
  });

  testWidgets('TripsScreen renders admin trip directory rows', (tester) async {
    final api = ApiService(
      tokenProvider: () async => 'admin-token',
      client: MockClient((request) async {
        if (request.url.path == '/api/v1/admin/trips') {
          return http.Response(
            jsonEncode({
              'total_trips': 1,
              'matching_trips': 1,
              'items': [
                {
                  'trip_id': 12,
                  'title': 'Samal Weekend Escape',
                  'owner_name': 'Maria Santos',
                  'owner_email': 'maria@lakbay.test',
                  'status': 'planned',
                  'traveler_count': 2,
                  'total_budget': 8500,
                  'estimated_total_cost': 6400,
                  'destination_names': ['Samal Island', 'Talicud Island'],
                },
              ],
            }),
            200,
          );
        }
        return http.Response('{}', 404);
      }),
    );

    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: TripsScreen(api: api))),
    );
    await tester.pumpAndSettle();

    expect(find.text('Samal Weekend Escape'), findsOneWidget);
    expect(find.textContaining('Maria Santos'), findsOneWidget);
    expect(find.textContaining('Samal Island'), findsOneWidget);
  });

  testWidgets('ReviewsScreen loads reviews and archives selected review', (
    tester,
  ) async {
    var archived = false;
    final api = ApiService(
      tokenProvider: () async => 'admin-token',
      client: MockClient((request) async {
        if (request.url.path == '/api/v1/evaluation/app-assessments/summary') {
          return http.Response(
            jsonEncode({'total_submissions': 3, 'average_overall': 4.7}),
            200,
          );
        }
        if (request.url.path == '/api/v1/admin/reviews') {
          return http.Response(
            jsonEncode({
              'total_reviews': archived ? 0 : 1,
              'matching_reviews': archived ? 0 : 1,
              'items': archived
                  ? []
                  : [
                      {
                        'trip_review_id': 55,
                        'trip_title': 'Eden Pine Retreat',
                        'destination_name': 'Eden Nature Park',
                        'full_name': 'Pedro Reyes',
                        'email': 'pedro@lakbay.test',
                        'overall_experience_rating': 5,
                        'accuracy_rating': 5,
                        'route_efficiency_rating': 5,
                        'budget_adherence_rating': 4,
                        'status': 'active',
                        'comments': 'Cool pine breeze and organized trails.',
                      },
                    ],
            }),
            200,
          );
        }
        if (request.url.path == '/api/v1/admin/reviews/55' &&
            request.method == 'DELETE') {
          archived = true;
          return http.Response(
            jsonEncode({'trip_review_id': 55, 'status': 'archived'}),
            200,
          );
        }
        return http.Response('{}', 404);
      }),
    );

    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: ReviewsScreen(api: api))),
    );
    await tester.pumpAndSettle();

    expect(find.text('Eden Nature Park'), findsOneWidget);
    expect(find.text('Archive'), findsOneWidget);

    await tester.tap(find.text('Archive'));
    await tester.pumpAndSettle();

    expect(archived, isTrue);
  });
}
