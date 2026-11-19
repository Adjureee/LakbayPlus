import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lakbay_travel/models/timeline_models.dart';
import 'package:lakbay_travel/services/lakbay_api_catalog_service.dart';
import 'package:lakbay_travel/services/location_service.dart';
import 'package:lakbay_travel/services/pdf_share.dart';
import 'package:lakbay_travel/services/timeline_pdf.dart';
import 'package:lakbay_travel/services/travel_repository.dart';
import 'package:lakbay_travel/widgets/timeline_widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

Map<String, dynamic> _item(
  String kind,
  String label, {
  String? start = '08:00:00',
  String? end = '09:00:00',
  int? minutes = 60,
  String basis = 'estimated',
  int? destinationId,
  Map<String, dynamic>? travel,
  List<Map<String, dynamic>> costs = const [],
  List<String> notes = const [],
  String? booking,
}) => {
  'kind': kind,
  'day': 1,
  'starts_at': start,
  'ends_at': end,
  'duration_minutes': minutes,
  'time_basis': basis,
  'duration_basis': 'recorded',
  'label': label,
  'destination_id': destinationId,
  'travel': travel,
  'costs': costs,
  'booking': booking,
  'notes': notes,
};

TimelineData _timeline({bool conflict = true}) => TimelineData.fromJson({
  'days': [
    {
      'day': 1,
      'date': '2026-11-20',
      'items': [
        _item('depart', 'Leave Davao City',
            end: '08:00:00', minutes: 0, basis: 'confirmed'),
        _item('travel', 'Travel to Hagimit Falls',
            start: '08:00:00', end: null, minutes: null, basis: 'provisional',
            travel: {
              'from_label': 'Davao City',
              'to_label': 'Hagimit Falls',
              'minutes': null,
              'basis': 'unknown',
              'mode': null,
              'route_verified': false,
            },
            notes: ['No travel time is available for this leg.']),
        _item('visit', 'Hagimit Falls',
            start: '08:00:00', end: '11:30:00', minutes: 210,
            destinationId: 77,
            booking: 'Booking required. Call two days ahead',
            costs: [
              {'label': 'Entrance', 'amount': '100.00', 'status': 'known',
               'scope': 'per_person', 'included_in': null},
              {'label': 'Zipline', 'amount': null, 'status': 'unknown',
               'scope': 'shared', 'included_in': null},
            ]),
        _item('visit', 'Museo Davao',
            start: '12:30:00', end: '13:30:00', destinationId: 88),
      ],
    },
  ],
  'conflicts': conflict
      ? [
          {
            'code': 'does_not_fit_hours',
            'destination_id': 88,
            'day': 1,
            'message':
                'A 60-minute visit to Museo Davao does not fit its opening hours that day.',
            'choices': [
              'prioritise_places',
              'change_time_window',
              'relax_another_constraint',
            ],
          },
        ]
      : [],
  'checks': [
    {'id': 'chronological_order', 'status': 'passed', 'message': 'Items are in order.', 'destination_ids': []},
    {'id': 'travel_times', 'status': 'cannot_verify', 'message': '1 travel leg has no travel time.', 'destination_ids': []},
    {'id': 'opening_hours', 'status': 'failed', 'message': 'Some visits do not fit.', 'destination_ids': [88]},
  ],
  'budget': {
    'known_total': '300.00',
    'estimated_total': '1500.00',
    'unknown': ['Zipline (Hagimit Falls)'],
    'unbased': ['Catalog estimate (Museo Davao): about PHP 600'],
    'to_complete': ['Provide night_count before completing the estimate.'],
    'subtotal': '1800.00',
    'complete': false,
    'total_budget': '5000.00',
    'remaining': null,
    'fit': 'undetermined',
    'notes': ['This is not the full trip cost: 1 cost(s) are unknown.'],
  },
  'feasible': !conflict,
  'unverified': ['1 travel leg has no travel time.'],
  'assumptions': ['The day starts at 8:00 (a planning default).'],
});

/// The text the PDF draws (the builder writes one word per `[(word)]TJ`).
String _pdfText(Uint8List bytes) {
  final raw = latin1.decode(bytes, allowInvalid: true);
  final words = RegExp(r'\[\((.*?)\)\]TJ')
      .allMatches(raw)
      .map((m) => m.group(1)!.replaceAll(r'\(', '(').replaceAll(r'\)', ')'));
  return words.join(' ');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('the PDF is a real PDF that says how far to trust each time', () async {
    final bytes = await TimelinePdfBuilder.build(
      _timeline(),
      title: 'Hagimit weekend',
      startingFrom: 'Davao City',
      now: DateTime(2026, 11, 18),
      compress: false,
    );
    expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
    final text = _pdfText(bytes);

    expect(text, contains('Hagimit weekend'));
    expect(text, contains('Starting from: Davao City'));
    // The legend and the trust label on every time.
    expect(text, contains('Provisional: depends on a planning default'));
    expect(text, contains('Hagimit Falls [Estimated] - 3 h 30 min'));
    expect(text, contains('Travel to Hagimit Falls [Provisional] - travel time unknown'));
    expect(text, contains('Leave Davao City [Confirmed]'));
    // Unknown stays unknown, and the peso sign is written as PHP.
    expect(text, contains('Cost - Zipline: unknown'));
    expect(text, contains('Cost - Entrance: PHP 100 per person'));
    expect(
      text,
      contains('From Davao City to Hagimit Falls: unknown time (no travel time available)'),
    );
    expect(text, contains('Booking: Booking required. Call two days ahead'));
    expect(text, isNot(contains('₱')));
  });

  test('conflicts, checks and costs are printed honestly', () async {
    final text = _pdfText(await TimelinePdfBuilder.build(_timeline(), compress: false));
    expect(text, contains('Places that do not fit'));
    expect(text, contains('does not fit its opening hours that day'));
    expect(text, contains('Nothing has been removed.'));
    expect(text, contains("Travel times: Can't verify. 1 travel leg has no travel time."));
    expect(text, contains('Opening hours: Failed.'));
    expect(text, contains('never counted as passed'));
    expect(text, contains('Unknown costs (not in the subtotal):'));
    expect(text, contains('Zipline (Hagimit Falls)'));
    expect(text, contains('Estimates with no recorded basis'));
    expect(text, contains('To complete the estimate:'));
    expect(text, contains('We cannot say yet whether it fits your budget.'));
    // A remaining amount is never invented for an incomplete budget.
    expect(text, isNot(contains('Remaining:')));
    expect(text, contains('has not been confirmed: check opening hours'));
  });

  test('a clean itinerary does not print a problems section', () async {
    final text = _pdfText(
      await TimelinePdfBuilder.build(_timeline(conflict: false), compress: false),
    );
    expect(text, isNot(contains('Places that do not fit')));
    expect(text, contains('Nothing we can check conflicts with your places.'));
  });

  test('text the PDF font cannot draw is replaced with plain text', () async {
    final data = TimelineData.fromJson({
      ..._timeline(conflict: false).toJson(),
      'assumptions': ['A‑B “quoted” ₱50 • ok'],
    });
    final text = _pdfText(await TimelinePdfBuilder.build(data, compress: false));
    expect(text, contains('A-B "quoted" PHP 50 - ok'));
  });

  testWidgets('Export PDF builds the file on the phone and hands it to the share sheet', (
    tester,
  ) async {
    List<int>? sharedBytes;
    String? sharedName;
    PdfShare.override = (bytes, name, text) async {
      sharedBytes = bytes;
      sharedName = name;
    };
    addTearDown(() => PdfShare.override = null);

    final repo = TravelRepository(
      apiCatalog: LakbayApiCatalogService(
        baseUrlOverride: 'https://api.lakbay.test/api/v1',
        client: MockClient((_) async => http.Response('{}', 200)),
      ),
      locationService: LocationService(
        customFetcher: () async =>
            const LocationResult(granted: false, statusMessage: 'Declined'),
      ),
    );
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(900, 2400);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: TimelineCard(timeline: _timeline(), repo: repo),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // No sign-in, no saved trip, no network: the button is still there and works.
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const ValueKey('timeline-export-pdf')));
      await Future<void>.delayed(const Duration(milliseconds: 500));
    });
    await tester.pump();

    expect(sharedName, 'lakbay-itinerary.pdf');
    expect(String.fromCharCodes(sharedBytes!.take(5)), '%PDF-');
  });
}
