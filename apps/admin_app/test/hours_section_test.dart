import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lakbay_admin/services/api_service.dart';
import 'package:lakbay_admin/widgets/hours_section.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('API times convert both ways', () {
    expect(parseApiTime('08:30:00'), const TimeOfDay(hour: 8, minute: 30));
    expect(parseApiTime(null), isNull);
    expect(parseApiTime('nonsense'), isNull);
    expect(apiTime(const TimeOfDay(hour: 17, minute: 5)), '17:05:00');
  });

  testWidgets('loads hours, leaves unset days out of the save and copies Monday', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1200, 2400);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    Map<String, dynamic>? saved;
    final api = ApiService(
      tokenProvider: () async => 't',
      apiBaseUrl: 'http://lakbay.test/api/v1',
      client: MockClient((request) async {
        if (request.url.path != '/api/v1/destinations/3/hours') {
          return http.Response('{}', 404);
        }
        if (request.method == 'PUT') {
          saved = jsonDecode(request.body) as Map<String, dynamic>;
          return http.Response(
            jsonEncode({
              'destination_id': 3,
              'weekly': saved!['weekly'],
              'exceptions': const [],
              'summary': 'Mon 8:00 AM to 5:00 PM',
              'data_quality': 'estimated',
            }),
            200,
          );
        }
        return http.Response(
          jsonEncode({
            'destination_id': 3,
            'weekly': [
              {'weekday': 0, 'is_closed': false, 'opens_at': '08:00:00', 'closes_at': '17:00:00'},
              {'weekday': 6, 'is_closed': true},
            ],
            'exceptions': const [],
            'summary': 'Mon 8:00 AM to 5:00 PM; Sun closed',
            'data_quality': 'unknown',
          }),
          200,
        );
      }),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: HoursSection(api: api, destinationId: '3'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('Travelers see: Mon 8:00 AM'), findsOneWidget);

    // Only Monday (open) and Sunday (closed) were loaded; saving keeps Tue to Sat unset.
    await tester.tap(find.byKey(const ValueKey('hours-save')));
    await tester.pumpAndSettle();
    final weekly = (saved!['weekly'] as List).cast<Map>();
    expect(weekly.map((r) => r['weekday']).toList(), [0, 6]);
    expect(weekly.first['opens_at'], '08:00:00');
    expect(weekly.last['is_closed'], true);
    expect(saved!['open_24_hours'], isNull);
    expect(find.text('Hours saved.'), findsOneWidget);

    // Copy Monday to every day, then save: seven days are sent.
    await tester.tap(find.byKey(const ValueKey('hours-copy')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('hours-save')));
    await tester.pumpAndSettle();
    expect((saved!['weekly'] as List).length, 7);
  });

  testWidgets('open 24 hours sends no weekly windows and a failed save is shown', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1200, 2400);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    Map<String, dynamic>? saved;
    var fail = true;
    final api = ApiService(
      tokenProvider: () async => 't',
      apiBaseUrl: 'http://lakbay.test/api/v1',
      client: MockClient((request) async {
        if (request.method == 'PUT') {
          saved = jsonDecode(request.body) as Map<String, dynamic>;
          if (fail) return http.Response('{"detail":"bad"}', 422);
          return http.Response(
            jsonEncode({'destination_id': 3, 'open_24_hours': true, 'weekly': const [],
              'exceptions': const [], 'summary': 'Open 24 hours', 'data_quality': 'estimated'}),
            200,
          );
        }
        return http.Response(
          jsonEncode({'destination_id': 3, 'weekly': const [], 'exceptions': const []}),
          200,
        );
      }),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: HoursSection(api: api, destinationId: '3'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('hours-24')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('hours-save')));
    await tester.pumpAndSettle();
    expect(saved!['open_24_hours'], true);
    expect(saved!['weekly'], isEmpty);
    expect(find.textContaining('Could not save hours'), findsOneWidget);

    fail = false;
    await tester.tap(find.byKey(const ValueKey('hours-save')));
    await tester.pumpAndSettle();
    expect(find.text('Hours saved.'), findsOneWidget);
    expect(find.textContaining('Travelers see: Open 24 hours'), findsOneWidget);
  });
}
