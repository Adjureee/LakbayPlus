import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lakbay_admin/services/api_service.dart';
import 'package:lakbay_admin/widgets/activities_section.dart';
import 'package:shared_preferences/shared_preferences.dart';

http.Response _json(Object body, [int status = 200]) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

Future<void> _pump(WidgetTester tester, ApiService api) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(1400, 3000);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: ActivitiesSection(api: api, destinationId: '3'),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('empty fields save as null and bad numbers are named', () {
    final row = ActivityRow(data: {'name': 'Zipline', 'extra_fee': '500.00'});
    final (json, problem) = row.toJson();
    expect(problem, isNull);
    expect(json!['name'], 'Zipline');
    expect(json['extra_fee'], '500');
    expect(json['availability'], isNull);
    expect(json['description'], isNull);
    expect(json['fee_included_in_admission'], isNull);
    expect(json.containsKey('min_age'), isFalse);

    row.controllers['min_age']!.text = 'seven';
    expect(row.toJson().$1, isNull);
    expect(row.toJson().$2, contains('min_age'));
    row.controllers['min_age']!.text = '';
    row.controllers['name']!.text = ' ';
    expect(row.toJson().$2, 'Every activity needs a name.');
    row.dispose();
  });

  testWidgets('loads activities, adds one, and saves the whole list', (
    tester,
  ) async {
    Map<String, dynamic>? saved;
    final api = ApiService(
      tokenProvider: () async => 't',
      apiBaseUrl: 'http://lakbay.test/api/v1',
      client: MockClient((request) async {
        if (request.method == 'PUT') {
          saved = jsonDecode(request.body) as Map<String, dynamic>;
          return _json({
            'destination_id': 3,
            'activities': (saved!['activities'] as List)
                .map(
                  (a) => {
                    ...a as Map<String, dynamic>,
                    'summary': 'x',
                    'data_quality': 'estimated',
                  },
                )
                .toList(),
          });
        }
        return _json({
          'destination_id': 3,
          'activities': [
            {
              'name': 'Zipline',
              'availability': 'scheduled',
              'effort_level': 'challenging',
              'extra_fee': '500.00',
              'fee_included_in_admission': false,
              'summary': 'Zipline: challenging; runs on a schedule',
              'data_quality': 'unknown',
            },
          ],
        });
      }),
    );
    await _pump(tester, api);
    expect(find.text('Zipline'), findsOneWidget);
    expect(
      find.textContaining('Travelers see: Zipline: challenging'),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const ValueKey('activities-add')));
    await tester.pump();
    await tester.enterText(
      find.byKey(const ValueKey('activity-name-1')),
      'Nature walk',
    );
    await tester.tap(find.byKey(const ValueKey('activities-save')));
    await tester.pumpAndSettle();

    final list = (saved!['activities'] as List).cast<Map>();
    expect(list.map((a) => a['name']).toList(), ['Zipline', 'Nature walk']);
    expect(list.first['availability'], 'scheduled');
    expect(list.first['fee_included_in_admission'], false);
    expect(list.last['availability'], isNull); // left unset stays unknown
    expect(find.text('Activities saved.'), findsOneWidget);
  });

  testWidgets('a nameless activity blocks the save; an API refusal is shown', (
    tester,
  ) async {
    var puts = 0;
    final api = ApiService(
      tokenProvider: () async => 't',
      apiBaseUrl: 'http://lakbay.test/api/v1',
      client: MockClient((request) async {
        if (request.method == 'PUT') {
          puts++;
          return http.Response('{"detail":"bad"}', 422);
        }
        return _json({'destination_id': 3, 'activities': const []});
      }),
    );
    await _pump(tester, api);
    expect(find.text('No activities entered yet.'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('activities-add')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('activities-save')));
    await tester.pumpAndSettle();
    expect(puts, 0);
    expect(find.text('Every activity needs a name.'), findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey('activity-name-0')),
      'Zipline',
    );
    await tester.tap(find.byKey(const ValueKey('activities-save')));
    await tester.pumpAndSettle();
    expect(puts, 1);
    expect(find.textContaining('Could not save activities'), findsOneWidget);
    expect(find.text('Activities saved.'), findsNothing);
  });
}
