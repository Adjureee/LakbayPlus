import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lakbay_admin/services/api_service.dart';
import 'package:lakbay_admin/widgets/prices_section.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A JSON reply; the charset lets the body carry the peso sign.
http.Response _json(Object body, [int status = 200]) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

Future<void> _pump(WidgetTester tester, ApiService api) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(1400, 2400);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: PricesSection(api: api, destinationId: '3'),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('a price row becomes an API row only when its amount is a number', () {
    final row = PriceRow(amount: '1,500', ageMin: '4', ageMax: '12', note: ' kids ');
    expect(row.toJson(), {
      'item': 'entrance',
      'audience': 'adult',
      'amount': '1500',
      'unit': 'per_person',
      'age_min': 4,
      'age_max': 12,
      'note': 'kids',
    });
    expect(PriceRow(amount: '').toJson(), isNull);
    expect(PriceRow(amount: 'free').toJson(), isNull);
    row.dispose();
  });

  testWidgets('loads prices, saves what was typed, and refuses a blank amount', (
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
            'prices': saved!['prices'],
            'summary': 'Entrance: adult ₱100 per person',
            'data_quality': 'estimated',
          });
        }
        return _json({
          'destination_id': 3,
          'prices': [
            {
              'item': 'entrance',
              'audience': 'adult',
              'amount': '100.00',
              'unit': 'per_person',
            },
          ],
          'summary': 'Entrance: adult ₱100 per person',
          'data_quality': 'unknown',
        });
      }),
    );
    await _pump(tester, api);

    // The loaded amount shows as typed (100, not 100.00).
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('price-amount-0')))
          .controller!
          .text,
      '100',
    );

    // A new row with no amount blocks the save and sends nothing.
    await tester.tap(find.byKey(const ValueKey('prices-add')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('prices-save')));
    await tester.pumpAndSettle();
    expect(saved, isNull);
    expect(find.textContaining('needs an amount'), findsOneWidget);

    // Fill it in (0 means free) and save: both rows are sent.
    await tester.enterText(find.byKey(const ValueKey('price-amount-1')), '0');
    await tester.tap(find.byKey(const ValueKey('prices-save')));
    await tester.pumpAndSettle();
    expect((saved!['prices'] as List).length, 2);
    expect((saved!['prices'] as List).last['amount'], '0');
    expect(saved!['fees_source_url'], isNull);
    expect(find.text('Prices saved.'), findsOneWidget);
  });

  testWidgets('an API refusal is shown and nothing is marked saved', (tester) async {
    final api = ApiService(
      tokenProvider: () async => 't',
      apiBaseUrl: 'http://lakbay.test/api/v1',
      client: MockClient((request) async {
        if (request.method == 'PUT') return http.Response('{"detail":"bad"}', 422);
        return http.Response(jsonEncode({'destination_id': 3, 'prices': const []}), 200);
      }),
    );
    await _pump(tester, api);

    expect(find.text('No prices entered yet.'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('prices-save')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Could not save prices'), findsOneWidget);
    expect(find.text('Prices saved.'), findsNothing);
  });
}
