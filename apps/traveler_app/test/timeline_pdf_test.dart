import 'dart:convert';
import 'dart:io' show zlib;
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

/// Extracts Unicode text from `/Type0` CID + `/ToUnicode` CMap + `FlateDecode`
/// PDFs (as well as uncompressed streams), tracking unmapped CIDs and Type1
/// Helvetica fallback fonts.
({String text, int unmappedCids, bool hasType1Fallback, int pageCount})
_inspectPdf(Uint8List bytes) {
  final raw = latin1.decode(bytes, allowInvalid: false);
  final objDicts = <int, String>{};
  final objStreams = <int, Uint8List>{};

  final objHeaderRe = RegExp(r'(?:^|\n)(\d+)\s+0\s+obj\b');
  final headers = objHeaderRe.allMatches(raw).toList();
  for (var i = 0; i < headers.length; i++) {
    final objId = int.parse(headers[i].group(1)!);
    final bodyStart = headers[i].end;
    final bodyLimit = i + 1 < headers.length ? headers[i + 1].start : raw.length;
    final segment = raw.substring(bodyStart, bodyLimit);

    final streamMarker = RegExp(r'>>\s*stream\r?\n').firstMatch(segment);
    if (streamMarker != null) {
      final dict = segment.substring(0, streamMarker.start + 2);
      objDicts[objId] = dict;
      final dataStart = bodyStart + streamMarker.end;
      final lenMatch = RegExp(r'/Length\s+(\d+)').firstMatch(dict);
      Uint8List streamBytes;
      if (lenMatch != null) {
        final len = int.parse(lenMatch.group(1)!);
        streamBytes = bytes.sublist(dataStart, dataStart + len);
      } else {
        final endIdx = raw.indexOf('endstream', dataStart);
        var endPos = endIdx == -1 ? bodyLimit : endIdx;
        if (endPos > dataStart && bytes[endPos - 1] == 0x0A) endPos--;
        if (endPos > dataStart && bytes[endPos - 1] == 0x0D) endPos--;
        streamBytes = bytes.sublist(dataStart, endPos);
      }
      if (dict.contains('/FlateDecode')) {
        try {
          streamBytes = Uint8List.fromList(zlib.decode(streamBytes));
        } catch (_) {
          // Leave raw bytes if a non-zlib stream occurs.
        }
      }
      objStreams[objId] = streamBytes;
    } else {
      final endObjIdx = segment.indexOf('endobj');
      objDicts[objId] = endObjIdx == -1 ? segment : segment.substring(0, endObjIdx);
    }
  }

  var hasType1Fallback = false;
  final fontCmaps = <int, Map<int, int>>{};
  for (final entry in objDicts.entries) {
    final dict = entry.value;
    if (!dict.contains('/Type /Font') && !dict.contains('/Type/Font')) continue;
    if (dict.contains('/Subtype /Type1') ||
        dict.contains('/Subtype/Type1') ||
        dict.contains('/Helvetica')) {
      hasType1Fallback = true;
    }
    final toUni = RegExp(r'/ToUnicode\s+(\d+)\s+0\s+R').firstMatch(dict);
    if (toUni != null) {
      final cmapObjId = int.parse(toUni.group(1)!);
      final cmapBytes = objStreams[cmapObjId];
      if (cmapBytes != null) {
        final cmapText = latin1.decode(cmapBytes, allowInvalid: true);
        final map = <int, int>{};
        final bfSectionRe = RegExp(r'beginbfchar([\s\S]*?)endbfchar');
        for (final sec in bfSectionRe.allMatches(cmapText)) {
          final pairRe = RegExp(r'<([0-9A-Fa-f]+)>\s*<([0-9A-Fa-f]+)>');
          for (final pair in pairRe.allMatches(sec.group(1)!)) {
            final cid = int.parse(pair.group(1)!, radix: 16);
            final unicode = int.parse(pair.group(2)!, radix: 16);
            map[cid] = unicode;
          }
        }
        fontCmaps[entry.key] = map;
      }
    }
  }

  var unmappedCids = 0;
  var pageCount = 0;
  final pageTexts = <String>[];

  for (final entry in objDicts.entries) {
    final dict = entry.value;
    if (!RegExp(r'/Type\s*/Page\b').hasMatch(dict)) continue;
    pageCount++;

    final resourceFontMap = <String, int>{};
    for (final m in RegExp(r'/(F\d+)\s+(\d+)\s+0\s+R').allMatches(dict)) {
      resourceFontMap[m.group(1)!] = int.parse(m.group(2)!);
    }

    final contentIds = <int>[];
    final singleContent = RegExp(r'/Contents\s+(\d+)\s+0\s+R').firstMatch(dict);
    if (singleContent != null) {
      contentIds.add(int.parse(singleContent.group(1)!));
    } else {
      final multiContent = RegExp(r'/Contents\s*\[(.*?)\]').firstMatch(dict);
      if (multiContent != null) {
        for (final ref in RegExp(r'(\d+)\s+0\s+R').allMatches(multiContent.group(1)!)) {
          contentIds.add(int.parse(ref.group(1)!));
        }
      }
    }

    final words = <String>[];
    int? activeFontObjId;

    void decodeRun(String run) {
      final buf = StringBuffer();
      for (final part in RegExp(r'<([0-9A-Fa-f]+)>|\((?:\\.|[^\\)])*\)').allMatches(run)) {
        final token = part.group(0)!;
        if (token.startsWith('<')) {
          final hex = part.group(1)!;
          final cmap = activeFontObjId == null ? null : fontCmaps[activeFontObjId];
          for (var i = 0; i + 4 <= hex.length; i += 4) {
            final cid = int.parse(hex.substring(i, i + 4), radix: 16);
            final cp = cmap?[cid];
            if (cid == 0 || cp == null) {
              unmappedCids++;
            } else {
              buf.writeCharCode(cp);
            }
          }
        } else {
          final lit = token
              .substring(1, token.length - 1)
              .replaceAll(r'\(', '(')
              .replaceAll(r'\)', ')')
              .replaceAll(r'\\', r'\');
          buf.write(lit);
        }
      }
      if (buf.isNotEmpty) words.add(buf.toString());
    }

    for (final cid in contentIds) {
      final streamBytes = objStreams[cid];
      if (streamBytes == null) continue;
      final cs = latin1.decode(streamBytes, allowInvalid: true);
      final opRe = RegExp(
        r'/(F\d+)\s+[\d.]+\s+Tf|\[(.*?)\]TJ|(<[0-9A-Fa-f]+>|\((?:\\.|[^\\)])*\))\s*Tj',
        dotAll: true,
      );
      for (final m in opRe.allMatches(cs)) {
        if (m.group(1) != null) {
          activeFontObjId = resourceFontMap[m.group(1)!];
        } else if (m.group(2) != null) {
          decodeRun(m.group(2)!);
        } else if (m.group(3) != null) {
          decodeRun(m.group(3)!);
        }
      }
    }
    pageTexts.add(words.join(' '));
  }

  return (
    text: pageTexts.join('\n'),
    unmappedCids: unmappedCids,
    hasType1Fallback: hasType1Fallback,
    pageCount: pageCount,
  );
}

String _pdfText(Uint8List bytes) => _inspectPdf(bytes).text;

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
    final inspected = _inspectPdf(bytes);
    final text = inspected.text;

    expect(inspected.hasType1Fallback, isFalse);
    expect(inspected.unmappedCids, 0);
    expect(text, contains('Hagimit weekend'));
    expect(text, contains('Starting from: Davao City'));
    // The legend and the trust label on every time.
    expect(text, contains('Provisional: depends on a planning default'));
    expect(text, contains('Hagimit Falls'));
    expect(text, contains('[Estimated]'));
    expect(text, contains('3 h 30 min'));
    expect(text, contains('Travel to Hagimit Falls'));
    expect(text, contains('[Provisional]'));
    expect(text, contains('travel time unknown'));
    expect(text, contains('Leave Davao City'));
    expect(text, contains('[Confirmed]'));
    // Unknown stays unknown, and Inter renders ₱ cleanly.
    expect(text, contains('Cost — Zipline: unknown'));
    expect(text, contains('Cost — Entrance: ₱100 per person'));
    expect(
      text,
      contains('From Davao City to Hagimit Falls: unknown time (no travel time available)'),
    );
    expect(text, contains('Booking: Booking required. Call two days ahead'));
    expect(text, contains('Page 1 of ${inspected.pageCount}'));
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
    expect(text, contains('₱300'));
    expect(text, contains('₱1,800'));
    expect(text, contains('₱5,000'));
  });

  test('a clean itinerary does not print a problems section', () async {
    final text = _pdfText(
      await TimelinePdfBuilder.build(_timeline(conflict: false), compress: false),
    );
    expect(text, isNot(contains('Places that do not fit')));
    expect(text, contains('Nothing we can check conflicts with your places.'));
  });

  test('preserves Unicode typography and Filipino diacritics while stripping unsupported emoji', () async {
    final data = TimelineData.fromJson({
      ..._timeline(conflict: false).toJson(),
      'assumptions': ['A‑B “quoted” ₱50 • Santo Niño — 29°C 🌴 ok'],
    });
    final bytes = await TimelinePdfBuilder.build(data, compress: true);
    final inspected = _inspectPdf(bytes);
    expect(inspected.hasType1Fallback, isFalse);
    expect(inspected.unmappedCids, 0);
    expect(inspected.text, contains('A‑B “quoted” ₱50 • Santo Niño — 29°C ok'));
    expect(inspected.text, isNot(contains('🌴')));
  });

  test('multi-page compressed timeline renders cleanly with Page X of Y', () async {
    final baseDay = (_timeline(conflict: false).toJson()['days'] as List).first as Map<String, dynamic>;
    final manyDays = [
      for (var d = 1; d <= 5; d++)
        {
          ...baseDay,
          'day': d,
          'date': '2026-11-${19 + d}',
          'items': [
            for (var i = 1; i <= 4; i++)
              _item(
                'visit',
                'Day $d Stop $i — Santo Niño Park',
                minutes: 90,
                costs: [
                  {
                    'label': 'Entry',
                    'amount': '250.00',
                    'status': 'known',
                    'scope': 'per_person',
                    'included_in': null,
                  },
                ],
                notes: ['Bring water and check local schedule.'],
              ),
          ],
        },
    ];
    final data = TimelineData.fromJson({
      ..._timeline(conflict: false).toJson(),
      'days': manyDays,
    });
    final bytes = await TimelinePdfBuilder.build(
      data,
      title: 'Davao 5-Day Plan',
      startingFrom: 'Davao City',
      compress: true,
    );
    final inspected = _inspectPdf(bytes);
    expect(inspected.hasType1Fallback, isFalse);
    expect(inspected.unmappedCids, 0);
    expect(inspected.pageCount, greaterThan(1));
    expect(inspected.text, contains('Page 1 of ${inspected.pageCount}'));
    expect(inspected.text, contains('Page ${inspected.pageCount} of ${inspected.pageCount}'));
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
