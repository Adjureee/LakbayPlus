import 'dart:convert';
import 'dart:io' show zlib;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lakbay_travel/core/theme/app_theme.dart';
import 'package:lakbay_travel/models/travel_models.dart';
import 'package:lakbay_travel/services/lakbay_api_catalog_service.dart';
import 'package:lakbay_travel/services/pdf_design_tokens.dart';
import 'package:lakbay_travel/services/pdf_share.dart';
import 'package:lakbay_travel/services/travel_repository.dart';
import 'package:lakbay_travel/services/trip_pdf.dart';
import 'package:lakbay_travel/theme/lakbay_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

// A real 1x1 PNG header is enough: the service only reads the first bytes.
final _png = Uint8List.fromList([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 0]);

LakbayApiCatalogService _service(Future<http.Response> Function(http.BaseRequest) handler) =>
    LakbayApiCatalogService(
      baseUrlOverride: 'https://api.lakbay.test/api/v1',
      client: MockClient.streaming((request, body) async {
        await body.drain<void>();
        final res = await handler(request);
        return http.StreamedResponse(
          Stream.value(res.bodyBytes), res.statusCode,
          headers: res.headers, request: request,
        );
      }),
    );

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
    text: '%PDF-check ${pageTexts.join('\n')}',
    unmappedCids: unmappedCids,
    hasType1Fallback: hasType1Fallback,
    pageCount: pageCount,
  );
}

String _pdfText(Uint8List bytes) => _inspectPdf(bytes).text;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('profile photo', () {
    test('uploads to /users/me/avatar as a multipart file and returns the new address', () async {
      http.BaseRequest? seen;
      final service = _service((request) async {
        seen = request;
        return http.Response(
          jsonEncode({'avatar_url': 'https://cdn.test/me.jpg'}), 200,
          headers: {'content-type': 'application/json'},
        );
      });

      final url = await service.uploadMyAvatar('tok', fileBytes: _png, filename: 'me.png');

      expect(url, 'https://cdn.test/me.jpg');
      expect(seen!.url.path, '/api/v1/users/me/avatar');
      expect(seen!.headers['Authorization'], 'Bearer tok');
      expect(seen!.headers['content-type'], startsWith('multipart/form-data'));
    });

    test('a refusal shows the server reason instead of a generic failure', () async {
      final service = _service((_) async => http.Response(
            jsonEncode({
              'error': {'code': 'image_too_large', 'message': 'Image must be 5 MB or smaller.'},
            }),
            413,
            headers: {'content-type': 'application/json'},
          ));

      expect(
        () => service.uploadMyAvatar('tok', fileBytes: _png, filename: 'big.png'),
        throwsA(
          isA<LakbayApiException>()
              .having((e) => e.message, 'message', contains('5 MB'))
              .having((e) => e.statusCode, 'status', 413),
        ),
      );
    });

    test('no connection is explained, not swallowed', () async {
      final service = _service((_) async => throw Exception('offline'));
      expect(
        () => service.uploadMyAvatar('tok', fileBytes: _png, filename: 'me.png'),
        throwsA(isA<LakbayApiException>().having((e) => e.message, 'message', contains('connection'))),
      );
    });

    test('signed out, the repository asks the traveler to sign in and sends nothing', () async {
      var requests = 0;
      final repo = TravelRepository(
        apiCatalog: _service((_) async {
          requests++;
          return http.Response('{}', 200);
        }),
      );
      await repo.initialize();

      // Signed out: asked to sign in, nothing is sent.
      expect(await repo.uploadProfilePhoto(bytes: _png, filename: 'a.png'),
          contains('Sign in'));
      expect(requests, 0);
    });

    test('the photo address survives saving and loading the profile', () {
      const profile = UserProfile(firstName: 'A', avatarUrl: 'https://cdn.test/a.jpg');
      expect(UserProfile.fromJson(profile.toJson()).avatarUrl, 'https://cdn.test/a.jpg');
      expect(UserProfile.fromJson(const {}).avatarUrl, '');
    });
  });

  group('PDF made on the phone', () {
    test('design tokens mirror canonical LakbayColors and AppTheme', () {
      expect(LakbayPdfTokens.primary.toInt(), LakbayColors.primary.toARGB32());
      expect(LakbayPdfTokens.primaryDark.toInt(), LakbayColors.primaryDark.toARGB32());
      expect(LakbayPdfTokens.tealDeep.toInt(), LakbayColors.tealDeep.toARGB32());
      expect(LakbayPdfTokens.cocoaOrange.toInt(), LakbayColors.cocoaOrange.toARGB32());
      expect(LakbayPdfTokens.canvasBg.toInt(), LakbayColors.canvasBg.toARGB32());
      expect(LakbayPdfTokens.textPrimary.toInt(), LakbayColors.textPrimary.toARGB32());
      expect(LakbayPdfTokens.successGreen.toInt(), LakbayColors.successGreen.toARGB32());
      expect(LakbayPdfTokens.warning.toInt(), AppTheme.warning.toARGB32());
    });

    test('contains the trip, its days and stops, and says what is not known', () async {
      final repo = TravelRepository(apiCatalog: LakbayApiCatalogService(baseUrlOverride: ''));
      await repo.initialize();
      final trip = repo.generateCustomTrip(
        destination: 'Samal Island', daysCount: 2, vibe: 'Beach',
      );

      final bytes = await TripPdfBuilder.build(
        trip, phpPerUsd: 57, compress: false,
        now: DateTime(2026, 11, 17),
      );
      final inspected = _inspectPdf(bytes);
      final text = inspected.text;

      expect(inspected.hasType1Fallback, isFalse);
      expect(inspected.unmappedCids, 0);
      expect(text, isNotEmpty);
      expect(text, contains('Samal Island'));
      expect(text, contains('Day 1:'));
      expect(text, contains('Travelers: not set'));
      expect(text, contains('Start date: not set'));
      expect(text, contains('Nov 17, 2026'));
      expect(text, contains('Page 1 of'));
      for (final stop in trip.days.expand((d) => d.stops).take(2)) {
        expect(text, contains(stop.title));
      }
    });

    test('needs no sign-in and no connection, and never invents a cost', () async {
      final repo = TravelRepository(apiCatalog: LakbayApiCatalogService(baseUrlOverride: ''));
      await repo.initialize();
      final trip = repo.generateCustomTrip(destination: 'Atlantis', daysCount: 2, vibe: 'x');

      final text = _pdfText(
        await TripPdfBuilder.build(trip, phpPerUsd: 57, compress: false),
      );

      expect(repo.isSignedIn, isFalse);
      expect(text, contains('Cost not listed'));
      expect(text, contains('Travelers: not set'));
      expect(text, isNot(contains('PHP 0')));
      expect(text, isNot(contains('₱0')));
    });

    test('a known traveler count and start date are printed', () async {
      final repo = TravelRepository(apiCatalog: LakbayApiCatalogService(baseUrlOverride: ''));
      await repo.initialize();
      final trip = repo
          .generateCustomTrip(destination: 'Samal Island', daysCount: 1, vibe: 'Beach')
          .copyWith(adults: 3, startDate: DateTime(2026, 12, 5));

      final text = _pdfText(
        await TripPdfBuilder.build(trip, phpPerUsd: 57, compress: false),
      );
      expect(text, contains('Travelers: 3'));
      expect(text, contains('Starts Dec 5, 2026'));
    });

    test('renders peso symbol, Filipino diacritics, status badge, and FlateDecode multi-page wrapping cleanly', () async {
      final longDesc = List.filled(
        18,
        'Coastal trail overlooking Davao Gulf — shaded palms and local crafts.',
      ).join(' ');
      final trip = ItineraryTrip(
        id: 'flagship-1',
        title: 'Santo Niño & Davao Heritage Tour 🌴',
        destination: 'Davao City',
        daysCount: 5,
        adults: 2,
        children: 1,
        centerLat: 7.07,
        centerLng: 125.61,
        heroAsset: '',
        vibeTag: 'Culture',
        overviewText: 'Heritage stops with Santo Niño Shrine and coastal lunch.',
        bestMonths: 'Dec – May',
        avgTemp: '29°C • Clear',
        startDate: DateTime(2026, 12, 10),
        expertName: 'Carla',
        expertTip: 'Start early.',
        flights: const [],
        hotels: const [
          HotelOffer(
            id: 'h1',
            name: 'Apo View Stay',
            city: 'Davao City',
            pricePhp: 3200,
            chargingUnit: 'per_room_per_night',
            lat: 7.07,
            lng: 125.61,
          ),
        ],
        backendBudgetPhp: 15000,
        backendStatus: 'completed',
        advisories: const ['Bring reef-safe sunscreen — ₱150 ferry terminal fee.'],
        whatToBring: 'Light clothes, reusable bottle.',
        days: [
          for (var d = 1; d <= 5; d++)
            ItineraryDay(
              dayNumber: d,
              cityTitle: d == 1 ? 'Santo Niño District' : 'Samal Island Day $d',
              summary: 'Day $d highlights around Davao Gulf.',
              lat: 7.07,
              lng: 125.61,
              tempCelsius: 29,
              stops: [
                for (var s = 1; s <= 4; s++)
                  ItineraryStop(
                    time: '0${7 + s}:00 AM',
                    title: d == 1 && s == 1
                        ? 'Santo Niño Shrine & Museo'
                        : 'Stop $d.$s — Scenic Overlook',
                    description: longDesc,
                    category: s == 2 ? 'food' : 'sight',
                    costEstimateUsd: 10,
                    lat: 7.07,
                    lng: 125.61,
                    travelFromPrevMinutes: s == 1 ? null : 25,
                    travelFromPrevKm: s == 1 ? null : 8.4,
                    isSeaCrossingFromPrev: d == 2 && s == 1,
                  ),
              ],
            ),
        ],
      );

      final bytes = await TripPdfBuilder.build(
        trip,
        phpPerUsd: 57,
        origin: const GeoPoint(lat: 7.07, lng: 125.61, label: 'Davao Airport'),
        now: DateTime(2026, 11, 27),
        compress: true,
      );
      expect(String.fromCharCodes(bytes.take(5)), '%PDF-');

      final inspected = _inspectPdf(bytes);
      expect(inspected.hasType1Fallback, isFalse);
      expect(inspected.unmappedCids, 0);
      expect(inspected.pageCount, greaterThan(1));
      expect(inspected.text, contains('Santo Niño Shrine & Museo'));
      expect(inspected.text, contains('29°C'));
      expect(inspected.text, contains('₱15,000'));
      expect(inspected.text, contains('₱570'));
      expect(inspected.text, contains('₱3,200'));
      expect(inspected.text, contains('Completed'));
      expect(inspected.text, contains('Travelers: 3'));
      expect(inspected.text, contains('Page 1 of ${inspected.pageCount}'));
      expect(inspected.text, contains('Page 2 of ${inspected.pageCount}'));
      expect(inspected.text, contains('Sea crossing'));
      expect(inspected.text, isNot(contains('🌴')));
    });

    test('handles oversized overview and stop descriptions (>2,000 chars) without PdfException and supports PdfShare override', () async {
      LakbayPdfTokens.resetCache();
      final hugeOverview = List.filled(45, 'Panoramic view of Davao Gulf with verified ferry transfers.').join(' ');
      final hugeStopDesc = List.filled(45, 'Walk along the heritage boardwalk past local craft stalls and cafes.').join(' ');
      final trip = ItineraryTrip(
        id: 'oversized-1',
        title: 'Long Text Dossier',
        destination: 'Davao Region',
        daysCount: 1,
        centerLat: 7.07,
        centerLng: 125.61,
        heroAsset: '',
        vibeTag: 'Scenic',
        overviewText: hugeOverview,
        bestMonths: '',
        avgTemp: '',
        expertName: 'Carla',
        expertTip: 'Hydrate.',
        flights: const [],
        hotels: const [],
        days: [
          ItineraryDay(
            dayNumber: 1,
            cityTitle: 'Davao City',
            summary: 'Full day tour.',
            lat: 7.07,
            lng: 125.61,
            stops: [
              ItineraryStop(
                time: '08:00 AM',
                title: 'Boardwalk Heritage Walk',
                description: hugeStopDesc,
                category: 'sight',
                lat: 7.07,
                lng: 125.61,
              ),
            ],
          ),
        ],
      );

      final bytes = await TripPdfBuilder.build(trip, phpPerUsd: 57, compress: true);
      final inspected = _inspectPdf(bytes);
      expect(inspected.hasType1Fallback, isFalse);
      expect(inspected.unmappedCids, 0);
      expect(inspected.text, contains('Boardwalk Heritage Walk'));
      expect(inspected.text, contains('Page 1 of ${inspected.pageCount}'));

      List<int>? shared;
      String? sharedName;
      PdfShare.override = (b, name, text) async {
        shared = b;
        sharedName = name;
      };
      addTearDown(() => PdfShare.override = null);
      await PdfShare.share(bytes, 'lakbay-oversized.pdf', 'Long Text Dossier');
      expect(shared, bytes);
      expect(sharedName, 'lakbay-oversized.pdf');
    });
  });
}
