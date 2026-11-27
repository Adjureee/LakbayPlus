import 'dart:convert';
import 'dart:io' show zlib;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lakbay_travel/models/timeline_models.dart';
import 'package:lakbay_travel/models/travel_models.dart';
import 'package:lakbay_travel/services/lakbay_api_catalog_service.dart';
import 'package:lakbay_travel/services/location_service.dart';
import 'package:lakbay_travel/services/pdf_share.dart';
import 'package:lakbay_travel/services/travel_repository.dart';
import 'package:lakbay_travel/theme/lakbay_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Deterministic Davao Region coordinates for offline testing.
const GeoPoint davaoCityHallOrigin = GeoPoint(
  lat: 7.0644,
  lng: 125.6078,
  label: 'Davao City Hall',
);

const GeoPoint peoplesParkPoint = GeoPoint(
  lat: 7.0707,
  lng: 125.6096,
  label: "People's Park",
);

const GeoPoint eagleCenterPoint = GeoPoint(
  lat: 7.1854,
  lng: 125.4169,
  label: 'Philippine Eagle Center',
);

const GeoPoint edenNatureParkPoint = GeoPoint(
  lat: 7.02824,
  lng: 125.401755,
  label: 'Eden Nature Park',
);

const GeoPoint samalIslandPoint = GeoPoint(
  lat: 7.0744,
  lng: 125.7087,
  label: 'Samal Island Beach Area',
);

const GeoPoint mountApoPoint = GeoPoint(
  lat: 6.9875,
  lng: 125.2708,
  label: 'Mount Apo Trail Area',
);

const GeoPoint museoDabawenyoPoint = GeoPoint(
  lat: 7.07939,
  lng: 125.60449,
  label: 'Museo Dabawenyo',
);

const GeoPoint sasaWharfPoint = GeoPoint(
  lat: 7.1145,
  lng: 125.6562,
  label: 'Sasa Wharf',
);

const GeoPoint babakWharfPoint = GeoPoint(
  lat: 7.1258,
  lng: 125.6881,
  label: 'Babak Wharf',
);

/// Standard phone & compact viewports for responsive UI/UX verification.
const Size phoneViewport390x844 = Size(390, 844);
const Size phoneViewport360x800 = Size(360, 800);
const Size phoneViewport320x568 = Size(320, 568);
const Size desktopViewport1280x800 = Size(1280, 800);

/// Widens `normalizeStayDurationType(...)` safely for both pre-M6 (`String`)
/// and post-M6 (`String?`) signatures with zero analyzer lint warnings.
String? asNullableDuration(String? value) => value;

/// Recorded HTTP request captured by [E2eMockRouter].
class E2eRecordedRequest {
  const E2eRecordedRequest({
    required this.method,
    required this.path,
    required this.queryParameters,
    required this.headers,
    required this.body,
  });

  final String method;
  final String path;
  final Map<String, String> queryParameters;
  final Map<String, String> headers;
  final Map<String, dynamic> body;
}

typedef E2eRouteHandler =
    Future<http.Response> Function(E2eRecordedRequest request);

/// Strictly offline HTTP router for Traveler App E2E tests.
///
/// Any unmocked endpoint fails fast with HTTP 500 instead of hitting the real
/// network.
class E2eMockRouter {
  E2eMockRouter({
    List<Map<String, dynamic>>? destinations,
    this.onPostRoutesPreview,
    this.onPostRoutesOptimize,
    this.onPostRoutesPlan,
    this.onPostAiChat,
    this.onPostPlanningTimeline,
    this.onPostAiItinerariesGenerate,
    this.onPostAiTripDraft,
    this.onPatchTrip,
    this.onGetTrips,
    this.onPostTrips,
    this.onGetTripById,
    this.onPostTopPlaces,
  }) : _destinations = destinations ?? davaoDestinationsCatalogJson();

  final List<Map<String, dynamic>> _destinations;
  E2eRouteHandler? onPostRoutesPreview;
  E2eRouteHandler? onPostRoutesOptimize;
  E2eRouteHandler? onPostRoutesPlan;
  E2eRouteHandler? onPostAiChat;
  E2eRouteHandler? onPostPlanningTimeline;
  E2eRouteHandler? onPostAiItinerariesGenerate;
  E2eRouteHandler? onPostAiTripDraft;
  E2eRouteHandler? onPatchTrip;
  E2eRouteHandler? onGetTrips;
  E2eRouteHandler? onPostTrips;
  E2eRouteHandler? onGetTripById;
  E2eRouteHandler? onPostTopPlaces;

  final List<E2eRecordedRequest> requests = [];

  List<E2eRecordedRequest> requestsFor(String path) => [
    for (final r in requests)
      if (r.path == path) r,
  ];

  List<E2eRecordedRequest> get routeRequests => [
    for (final r in requests)
      if (r.path.startsWith('/routes/')) r,
  ];

  MockClient get client => MockClient((rawRequest) async {
    final normalizedPath = rawRequest.url.path.replaceFirst('/api/v1', '');
    Map<String, dynamic> decodedBody = const {};
    if (rawRequest.body.isNotEmpty) {
      final parsed = jsonDecode(rawRequest.body);
      if (parsed is Map<String, dynamic>) {
        decodedBody = parsed;
      }
    }
    final recorded = E2eRecordedRequest(
      method: rawRequest.method,
      path: normalizedPath,
      queryParameters: rawRequest.url.queryParameters,
      headers: rawRequest.headers,
      body: decodedBody,
    );
    requests.add(recorded);

    if (rawRequest.method == 'GET' && normalizedPath == '/destinations') {
      final offset =
          int.tryParse(rawRequest.url.queryParameters['offset'] ?? '0') ?? 0;
      final limit =
          int.tryParse(rawRequest.url.queryParameters['limit'] ?? '100') ?? 100;
      final slice = _destinations.skip(offset).take(limit).toList();
      return http.Response(
        jsonEncode({'items': slice, 'total': _destinations.length}),
        200,
        headers: const {'content-type': 'application/json; charset=utf-8'},
      );
    }

    if (rawRequest.method == 'GET' &&
        normalizedPath == '/destinations/facets') {
      return http.Response(
        jsonEncode({
          'total_places': _destinations.length,
          'groups': [
            {
              'key': 'nature_attractions',
              'label': 'Nature',
              'count': 3,
              'subtypes': [
                {'key': 'mountain', 'label': 'Mountain', 'count': 1},
                {'key': 'nature_resort', 'label': 'Nature Resort', 'count': 1},
                {'key': 'wildlife', 'label': 'Wildlife', 'count': 1},
              ],
            },
            {
              'key': 'beaches',
              'label': 'Beaches',
              'count': 1,
              'subtypes': [
                {'key': 'beach', 'label': 'Beach', 'count': 1},
              ],
            },
          ],
          'categories': [
            {'key': 'park', 'label': 'Parks', 'count': 1},
            {'key': 'beach', 'label': 'Beaches', 'count': 1},
            {'key': 'mountain', 'label': 'Mountains', 'count': 1},
          ],
        }),
        200,
        headers: const {'content-type': 'application/json; charset=utf-8'},
      );
    }

    if (rawRequest.method == 'GET' &&
        normalizedPath == '/destinations/browse') {
      return http.Response(
        jsonEncode(const <dynamic>[]),
        200,
        headers: const {'content-type': 'application/json; charset=utf-8'},
      );
    }

    if (rawRequest.method == 'POST' && normalizedPath == '/routes/preview') {
      if (onPostRoutesPreview != null) {
        return onPostRoutesPreview!(recorded);
      }
      return http.Response(
        jsonEncode(
          buildMockRouteJson(
            destinationIds: _intList(decodedBody['destination_ids']),
            useLiveTraffic: decodedBody['use_live_traffic'] == true,
          ),
        ),
        200,
        headers: const {'content-type': 'application/json; charset=utf-8'},
      );
    }

    if (rawRequest.method == 'POST' && normalizedPath == '/routes/optimize') {
      if (onPostRoutesOptimize != null) {
        return onPostRoutesOptimize!(recorded);
      }
      return http.Response(
        jsonEncode(
          buildMockRouteJson(
            destinationIds: _intList(decodedBody['destination_ids']),
            useLiveTraffic: decodedBody['use_live_traffic'] == true,
          ),
        ),
        200,
        headers: const {'content-type': 'application/json; charset=utf-8'},
      );
    }

    if (rawRequest.method == 'POST' &&
        (normalizedPath == '/routes/plan' ||
            normalizedPath == '/routes/plan/guest')) {
      if (onPostRoutesPlan != null) {
        return onPostRoutesPlan!(recorded);
      }
      final ids = _intList(decodedBody['destination_ids']);
      final routeJson = buildMockRouteJson(
        destinationIds: ids,
        useLiveTraffic: decodedBody['use_live_traffic'] == true,
      );
      return http.Response(
        jsonEncode({
          'route': routeJson,
          'suggested_days': (decodedBody['days'] as num?)?.toInt() ?? 2,
          'order_method': 'requested',
          'cost_source': 'mapbox',
          'pace': decodedBody['pace'] ?? 'balanced',
          'warnings': const <String>[],
          'skipped_destination_ids': const <int>[],
          'days': const <dynamic>[],
        }),
        200,
        headers: const {'content-type': 'application/json; charset=utf-8'},
      );
    }

    if (rawRequest.method == 'POST' &&
        (normalizedPath == '/ai/chat' || normalizedPath == '/ai/chat/guest')) {
      if (onPostAiChat != null) {
        return onPostAiChat!(recorded);
      }
    }

    if (rawRequest.method == 'POST' &&
        (normalizedPath == '/planning/timeline' ||
            normalizedPath == '/planning/timeline/guest')) {
      if (onPostPlanningTimeline != null) {
        return onPostPlanningTimeline!(recorded);
      }
      return http.Response(
        jsonEncode({'detail': 'No timeline handler configured'}),
        404,
      );
    }

    if (rawRequest.method == 'POST' &&
        (normalizedPath == '/ai/itineraries/generate' ||
            normalizedPath == '/ai/itineraries/generate/guest')) {
      if (onPostAiItinerariesGenerate != null) {
        return onPostAiItinerariesGenerate!(recorded);
      }
    }

    if (rawRequest.method == 'POST' &&
        (normalizedPath == '/ai/trip-draft' ||
            normalizedPath == '/ai/trip-draft/guest')) {
      if (onPostAiTripDraft != null) {
        return onPostAiTripDraft!(recorded);
      }
      return http.Response(
        jsonEncode({
          'draft': {
            'reply_text': 'Here is a draft for your Davao Region trip.',
            'title': 'Davao Draft',
            'destination': 'Davao Region',
            'days_count': 1,
            'days': const <dynamic>[],
          },
        }),
        200,
      );
    }

    if (rawRequest.method == 'POST' &&
        normalizedPath == '/recommendations/top-places') {
      if (onPostTopPlaces != null) {
        return onPostTopPlaces!(recorded);
      }
      return http.Response(
        jsonEncode({
          'method': 'weighted_score',
          'items': const <dynamic>[],
          'warnings': const <String>[],
        }),
        200,
      );
    }

    if (rawRequest.method == 'GET' && normalizedPath == '/trips') {
      if (onGetTrips != null) {
        return onGetTrips!(recorded);
      }
      return http.Response('[]', 200);
    }

    if (rawRequest.method == 'POST' && normalizedPath == '/trips') {
      if (onPostTrips != null) {
        return onPostTrips!(recorded);
      }
      return http.Response(jsonEncode({'trip_id': 901}), 201);
    }

    if (rawRequest.method == 'GET' &&
        RegExp(r'^/trips/\d+$').hasMatch(normalizedPath)) {
      if (onGetTripById != null) {
        return onGetTripById!(recorded);
      }
      return http.Response('{}', 404);
    }

    if (rawRequest.method == 'PATCH' &&
        RegExp(r'^/trips/\d+$').hasMatch(normalizedPath)) {
      if (onPatchTrip != null) {
        return onPatchTrip!(recorded);
      }
      final id = int.parse(normalizedPath.split('/').last);
      return http.Response(
        jsonEncode({
          'trip_id': id,
          'owner_user_id': 1,
          'title': decodedBody['title'] ?? 'Davao Trip',
          'status': decodedBody['status'] ?? 'planned',
          'traveler_count': decodedBody['traveler_count'] ?? 2,
          'total_budget': decodedBody['total_budget'] ?? '5000.00',
          'estimated_total_cost':
              decodedBody['estimated_total_cost'] ?? '3500.00',
          'destinations': const <dynamic>[],
          'itinerary_days': const <dynamic>[],
        }),
        200,
        headers: const {'content-type': 'application/json; charset=utf-8'},
      );
    }

    if (rawRequest.method == 'GET' &&
        (normalizedPath == '/notifications' ||
            normalizedPath == '/notifications/unread-count' ||
            normalizedPath == '/trip-invitations' ||
            normalizedPath == '/auth/me')) {
      if (normalizedPath == '/notifications/unread-count') {
        return http.Response(jsonEncode({'unread_count': 0}), 200);
      }
      if (normalizedPath == '/auth/me') {
        return http.Response(
          jsonEncode({
            'user_id': 1,
            'full_name': 'Maria Santos',
            'email': 'maria@lakbay.test',
            'role': 'traveler',
          }),
          200,
        );
      }
      return http.Response('[]', 200);
    }

    if (RegExp(r'^/trips/\d+/(expenses|members|tasks)').hasMatch(normalizedPath)) {
      if (normalizedPath.endsWith('/expenses/summary')) {
        return http.Response(
          jsonEncode({
            'total_budget': 8000.0,
            'total_spent': 2500.0,
            'percent_used': 31.25,
            'budget_alert_level': 'ok',
          }),
          200,
        );
      }
      return http.Response('[]', 200);
    }

    if (RegExp(r'^/destinations/\d+/(accommodations|transportations)')
        .hasMatch(normalizedPath)) {
      return http.Response('[]', 200);
    }

    // Fail fast on any unmocked URL — never hit real network.
    return http.Response(
      jsonEncode({
        'detail': 'Unmocked E2E URL: ${rawRequest.method} $normalizedPath',
      }),
      500,
      headers: const {'content-type': 'application/json; charset=utf-8'},
    );
  });
}

List<int> _intList(Object? raw) {
  if (raw is! List) return const [];
  return raw.whereType<num>().map((n) => n.toInt()).toList();
}

/// Precision-5 polyline encoder matching [LakbayApiCatalogService.decodePolyline5].
String encodePolyline5(List<GeoPoint> points) {
  final buffer = StringBuffer();
  var prevLat = 0;
  var prevLng = 0;

  void writeSigned(int value) {
    var shifted = value < 0 ? ~(value << 1) : (value << 1);
    while (shifted >= 0x20) {
      buffer.writeCharCode((0x20 | (shifted & 0x1F)) + 63);
      shifted >>= 5;
    }
    buffer.writeCharCode(shifted + 63);
  }

  for (final pt in points) {
    final latE5 = (pt.lat * 1e5).round();
    final lngE5 = (pt.lng * 1e5).round();
    writeSigned(latE5 - prevLat);
    writeSigned(lngE5 - prevLng);
    prevLat = latE5;
    prevLng = lngE5;
  }
  return buffer.toString();
}

/// Initializes offline test prerequisites (`GoogleFonts` & `SharedPreferences`).
Future<void> initOfflineE2eEnv({
  Map<String, Object> extraPrefs = const {},
}) async {
  GoogleFonts.config.allowRuntimeFetching = false;
  SharedPreferences.setMockInitialValues(extraPrefs);
}

/// Seeds `'lakbay_traveler_state_v1'` in [SharedPreferences] offline.
Future<void> seedTravelerState({
  bool signedIn = true,
  List<ItineraryTrip> savedTrips = const [],
  bool showLiveTraffic = false,
  String preferredTravelMode = 'driving',
  String? activeMapStyleId,
  List<ChatSession> chatSessions = const [],
  String? activeChatId,
}) async {
  final state = <String, dynamic>{
    'hasCompletedOnboarding': true,
    'showLiveTraffic': showLiveTraffic,
    'preferredTravelMode': preferredTravelMode,
    'activeMapStyle': ?activeMapStyleId,
    if (signedIn)
      'authSession': const LakbayAuthSession(
        accessToken: 'e2e-traveler-token',
        refreshToken: 'e2e-refresh-token',
        userId: 1,
        fullName: 'Maria Santos',
        email: 'maria@lakbay.test',
        role: 'traveler',
      ).toJson(),
    if (savedTrips.isNotEmpty)
      'savedTrips': [for (final t in savedTrips) t.toJson()],
    if (chatSessions.isNotEmpty)
      'chatSessions': [for (final c in chatSessions) c.toJson()],
    'activeChatId': ?activeChatId,
  };
  await initOfflineE2eEnv(
    extraPrefs: {'lakbay_traveler_state_v1': jsonEncode(state)},
  );
}

/// Creates a [TravelRepository] wired to [E2eMockRouter] and deterministic GPS.
TravelRepository createE2eRepository({
  required E2eMockRouter router,
  GeoPoint? userLocation = davaoCityHallOrigin,
}) {
  return TravelRepository(
    apiCatalog: LakbayApiCatalogService(
      baseUrlOverride: 'https://api.lakbay.test/api/v1',
      client: router.client,
      retryDelayOverride: (_) async {},
    ),
    locationService: LocationService(
      customFetcher: () async => userLocation == null
          ? const LocationResult(granted: false, statusMessage: 'Declined')
          : LocationResult(
              granted: true,
              lat: userLocation.lat,
              lng: userLocation.lng,
              statusMessage: 'Mocked Davao GPS',
            ),
    ),
  );
}

/// Configures phone/desktop test viewport and resets it on tearDown.
void setTestViewport(WidgetTester tester, Size size, {double dpr = 1.0}) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = dpr;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

/// Safe bounded frame pump for screens containing [LakbayMapboxMap] or
/// indeterminate spinners (never calls `pumpAndSettle`).
Future<void> pumpBounded(
  WidgetTester tester, {
  int milliseconds = 350,
}) async {
  await tester.pump();
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 80)),
  );
  await tester.pump(Duration(milliseconds: milliseconds));
}

/// Wraps a widget under [LakbayTheme.lightTheme] for E2E screen tests.
Widget wrapE2eApp(Widget child, {bool disableAnimations = false}) {
  final app = MaterialApp(
    theme: LakbayTheme.lightTheme,
    home: child,
  );
  if (!disableAnimations) return app;
  return MediaQuery(
    data: const MediaQueryData(disableAnimations: true),
    child: app,
  );
}

/// Captures `PdfShare.share(...)` invocations offline via `PdfShare.override`.
List<({List<int> bytes, String name, String text})> capturePdfShares() {
  final captured = <({List<int> bytes, String name, String text})>[];
  PdfShare.override = (bytes, name, text) async {
    captured.add((bytes: bytes, name: name, text: text));
  };
  addTearDown(() => PdfShare.override = null);
  return captured;
}

/// Extracts decoded Unicode text, unmapped CID count, Type1 fallback flag, and
/// page count from generated PDF bytes (matching `timeline_pdf_test.dart`).
({String text, int unmappedCids, bool hasType1Fallback, int pageCount})
inspectPdfBytes(Uint8List bytes) {
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
        } catch (_) {}
      }
      objStreams[objId] = streamBytes;
    } else {
      final endObjIdx = segment.indexOf('endobj');
      objDicts[objId] = endObjIdx == -1
          ? segment
          : segment.substring(0, endObjIdx);
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
        for (final ref
            in RegExp(r'(\d+)\s+0\s+R').allMatches(multiContent.group(1)!)) {
          contentIds.add(int.parse(ref.group(1)!));
        }
      }
    }

    final words = <String>[];
    int? activeFontObjId;

    void decodeRun(String run) {
      final buf = StringBuffer();
      for (final part
          in RegExp(r'<([0-9A-Fa-f]+)>|\((?:\\.|[^\\)])*\)').allMatches(run)) {
        final token = part.group(0)!;
        if (token.startsWith('<')) {
          final hex = part.group(1)!;
          final cmap =
              activeFontObjId == null ? null : fontCmaps[activeFontObjId];
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

/// Verified Davao Region destination catalog fixture rows.
List<Map<String, dynamic>> davaoDestinationsCatalogJson({
  bool includeMediaFields = false,
}) {
  final base = <Map<String, dynamic>>[
    {
      'destination_id': 1,
      'name': "People's Park",
      'district': 'Poblacion District, Davao City',
      'category': 'Park',
      'lat': peoplesParkPoint.lat,
      'lng': peoplesParkPoint.lng,
      'island_group': 'mainland',
      'stay_duration_type': 'short',
      'entrance_fee': 'Free',
      'operating_hours': '05:00 AM - 10:00 PM',
      'description':
          'Urban rainforest park in central Davao City with iconic Durian Dome.',
      'image_url': 'https://cdn.lakbay.test/destinations/1/peoples_park.jpg',
    },
    {
      'destination_id': 2,
      'name': 'Philippine Eagle Center',
      'district': 'Baguio District, Davao City',
      'category': 'Wildlife',
      'lat': eagleCenterPoint.lat,
      'lng': eagleCenterPoint.lng,
      'island_group': 'mainland',
      'stay_duration_type': 'half_day',
      'entrance_fee': '₱150',
      'operating_hours': '08:00 AM - 05:00 PM',
      'description':
          'Conservation sanctuary for the critically endangered Philippine Eagle.',
      'image_url': 'https://cdn.lakbay.test/destinations/2/eagle_center.jpg',
    },
    {
      'destination_id': 3,
      'name': 'Eden Nature Park',
      'district': 'Toril, Davao City',
      'category': 'Nature Resort',
      'lat': edenNatureParkPoint.lat,
      'lng': edenNatureParkPoint.lng,
      'island_group': 'mainland',
      'stay_duration_type': 'half_day',
      'entrance_fee': '₱350',
      'overnight_fee': '₱3,800/night',
      'operating_hours': '08:00 AM - 05:00 PM',
      'description': 'Cool pine-forested mountain nature park in Toril.',
      'image_url': 'https://cdn.lakbay.test/destinations/3/eden_nature_park.jpg',
    },
    {
      'destination_id': 4,
      'name': 'Samal Island Beach Area',
      'district': 'Samal Island, Davao del Norte',
      'category': 'Beach',
      'lat': samalIslandPoint.lat,
      'lng': samalIslandPoint.lng,
      'island_group': 'samal',
      'stay_duration_type': 'full_day',
      'entrance_fee': '₱150',
      'overnight_fee': '₱2,500/night',
      'operating_hours': '06:00 AM - 08:00 PM',
      'description': 'White-sand coves across Pakiputan Strait via Sasa Wharf.',
      'image_url': 'https://cdn.lakbay.test/destinations/4/samal_beach.jpg',
    },
    {
      'destination_id': 5,
      'name': 'Mount Apo Trail Area',
      'district': 'Sta. Cruz / Kapatagan, Davao del Sur',
      'category': 'Mountain',
      'lat': mountApoPoint.lat,
      'lng': mountApoPoint.lng,
      'island_group': 'mainland',
      'stay_duration_type': 'multi_day',
      'entrance_fee': '₱1,500 permit',
      'operating_hours': '05:00 AM - 04:00 PM',
      'description': 'Highest peak in the Philippines with mossy cloud forest.',
      'image_url': 'https://cdn.lakbay.test/destinations/5/mount_apo.jpg',
    },
    {
      'destination_id': 14,
      'name': 'Museo Dabawenyo',
      'district': 'Mabini Street, Davao City',
      'category': 'Museum',
      'lat': museoDabawenyoPoint.lat,
      'lng': museoDabawenyoPoint.lng,
      'island_group': 'mainland',
      'stay_duration_type': 'short',
      'entrance_fee': 'Free',
      'operating_hours': '09:00 AM - 05:00 PM',
      'description': 'Heritage museum showcasing Davao history and indigenous culture.',
      'image_url': 'https://cdn.lakbay.test/destinations/14/museo_dabawenyo.jpg',
    },
  ];

  if (!includeMediaFields) return base;

  return [
    for (final row in base)
      {
        ...row,
        if (row['destination_id'] == 1) ...{
          'media_url': 'https://cdn.lakbay.test/destinations/1/park_loop.gif',
          'media_type': 'gif',
          'media_duration_seconds': null,
        } else if (row['destination_id'] == 4) ...{
          'media_url': 'https://cdn.lakbay.test/destinations/4/samal_wave.mp4',
          'media_type': 'video',
          'media_duration_seconds': 8.5,
        } else ...{
          'media_url': row['image_url'],
          'media_type': 'image',
          'media_duration_seconds': null,
        },
      },
  ];
}

/// Builds a mock `/routes/*` JSON response with optional live traffic & sea link.
Map<String, dynamic> buildMockRouteJson({
  required List<int> destinationIds,
  bool useLiveTraffic = false,
  String trafficStatus = 'live',
  int? delaySeconds = 180,
  bool includeSeaCrossing = false,
  bool isPartialEstimated = false,
  List<String> warnings = const [],
}) {
  final pts = <GeoPoint>[
    peoplesParkPoint,
    eagleCenterPoint,
    edenNatureParkPoint,
    if (includeSeaCrossing) sasaWharfPoint,
    if (includeSeaCrossing) babakWharfPoint,
    if (includeSeaCrossing) samalIslandPoint,
  ];
  final road1 = encodePolyline5([peoplesParkPoint, eagleCenterPoint]);
  final road2 = encodePolyline5([eagleCenterPoint, edenNatureParkPoint]);
  final sea = encodePolyline5([sasaWharfPoint, babakWharfPoint]);
  final road3 = encodePolyline5([babakWharfPoint, samalIslandPoint]);

  return {
    'route_provider': useLiveTraffic && trafficStatus == 'live'
        ? 'mapbox'
        : 'osrm',
    'is_estimated': false,
    'total_distance_km': includeSeaCrossing ? 78.4 : 46.2,
    'total_duration_minutes': includeSeaCrossing ? 135 : 82,
    'polyline': encodePolyline5(pts),
    'warnings': warnings,
    'stops': [
      for (final id in destinationIds) {'destination_id': id},
    ],
    'segments': [
      {
        'mode': 'road',
        'polyline': road1,
        'from_name': "People's Park",
        'to_name': 'Philippine Eagle Center',
        'is_estimated': false,
      },
      {
        'mode': 'road',
        'polyline': road2,
        'from_name': 'Philippine Eagle Center',
        'to_name': 'Eden Nature Park',
        'is_estimated': isPartialEstimated,
      },
      if (includeSeaCrossing) ...[
        {
          'mode': 'sea',
          'polyline': sea,
          'from_name': 'Sasa Wharf',
          'to_name': 'Babak Wharf',
          'is_estimated': false,
        },
        {
          'mode': 'road',
          'polyline': road3,
          'from_name': 'Babak Wharf',
          'to_name': 'Samal Island Beach Area',
          'is_estimated': false,
        },
      ],
    ],
    if (includeSeaCrossing)
      'sea_crossings': [
        {
          'vessel_type': 'roro_barge',
          'board_port': 'Sasa Wharf',
          'land_port': 'Babak Wharf',
          'board_lat': sasaWharfPoint.lat,
          'board_lng': sasaWharfPoint.lng,
          'land_lat': babakWharfPoint.lat,
          'land_lng': babakWharfPoint.lng,
          'crossing_minutes': 15,
          'typical_wait_minutes': 20,
          'allows_private_vehicle': true,
          'fare_passenger': 35.0,
          'fare_vehicle': 320.0,
          'verified': true,
        },
      ],
    if (useLiveTraffic)
      'traffic': {
        'status': trafficStatus,
        'provider': trafficStatus == 'live' ? 'mapbox' : null,
        'delay_seconds': trafficStatus == 'live' ? delaySeconds : null,
        'congestion_segments': trafficStatus == 'live'
            ? [
                {'level': 'moderate', 'distance_km': 4.2},
              ]
            : const <dynamic>[],
      },
  };
}

/// Canonical [SeaCrossingInfo] fixture for Sasa Wharf <-> Babak Wharf.
const SeaCrossingInfo sasaBabakSeaCrossing = SeaCrossingInfo(
  vesselType: 'roro_barge',
  boardPort: 'Sasa Wharf',
  landPort: 'Babak Wharf',
  boardLat: 7.1145,
  boardLng: 125.6562,
  landLat: 7.1258,
  landLng: 125.6881,
  crossingMinutes: 15,
  typicalWaitMinutes: 20,
  allowsPrivateVehicle: true,
  farePassenger: 35,
  fareVehicle: 320,
  verified: true,
);

/// Builds a 5-day, 10-stop Davao + Samal multimodal [ItineraryTrip] fixture
/// including non-consecutive hub revisit (`destinationId: 1` on Day 1 and Day 5).
ItineraryTrip buildFiveDayDavaoSamalTrip({
  String id = 'e2e_5day_davao_samal',
  int? backendTripId = 501,
  String backendStatus = 'planned',
  DateTime? startDate,
  DateTime? endDate,
  double? backendBudgetPhp = 15000,
  double? backendEstimatedCostPhp = 11200,
}) {
  return ItineraryTrip(
    id: id,
    title: '5-Day Davao & Samal Grand Loop',
    destination: 'Davao City & Samal Island',
    daysCount: 5,
    adults: 2,
    children: 0,
    centerLat: 7.0744,
    centerLng: 125.6096,
    heroAsset: 'assets/home_backdrops/01-samal-island.jpg',
    vibeTag: 'Nature & Island',
    overviewText:
        'Five days exploring Davao City heritage, Malagos highlands, Toril pines, and Samal Island coves.',
    bestMonths: 'Dec – May',
    avgTemp: '30°C • Sunny',
    startDate: startDate ?? DateTime(2026, 12, 1),
    endDate: endDate ?? DateTime(2026, 12, 5),
    expertName: 'Lakbay Planner',
    expertTip: 'Board the early RoRo barge at Sasa Wharf to beat the morning queue.',
    backendTripId: backendTripId,
    backendDestinationId: 1,
    backendDestinationIds: const [1, 14, 2, 3, 4, 1],
    backendStatus: backendStatus,
    backendBudgetPhp: backendBudgetPhp,
    backendEstimatedCostPhp: backendEstimatedCostPhp,
    pace: 'balanced',
    roundtrip: true,
    flights: const [],
    hotels: const [
      HotelOffer(
        id: 'hotel_davao_1',
        name: 'Marco Polo Davao',
        city: 'Davao City',
        stars: 4,
        pricePhp: 4500,
        chargingUnit: 'per_room_per_night',
        imageAsset: 'assets/home_backdrops/08-peoples-park.jpg',
        lat: 7.0725,
        lng: 125.6115,
      ),
    ],
    seaCrossings: const [sasaBabakSeaCrossing],
    routeSegments: const [
      RouteSegmentGeometry(
        mode: TransportMode.car,
        fromName: "People's Park",
        toName: 'Philippine Eagle Center',
        points: [peoplesParkPoint, eagleCenterPoint],
      ),
      RouteSegmentGeometry(
        mode: TransportMode.car,
        fromName: 'Philippine Eagle Center',
        toName: 'Eden Nature Park',
        points: [eagleCenterPoint, edenNatureParkPoint],
      ),
      RouteSegmentGeometry(
        mode: TransportMode.ferry,
        fromName: 'Sasa Wharf',
        toName: 'Babak Wharf',
        points: [sasaWharfPoint, babakWharfPoint],
      ),
      RouteSegmentGeometry(
        mode: TransportMode.car,
        fromName: 'Babak Wharf',
        toName: 'Samal Island Beach Area',
        points: [babakWharfPoint, samalIslandPoint],
      ),
    ],
    days: const [
      ItineraryDay(
        dayNumber: 1,
        cityTitle: 'Day 1 • Downtown Davao',
        summary: 'Urban park and heritage walk in Poblacion District.',
        lat: 7.0707,
        lng: 125.6096,
        apiDestinationId: 1,
        stops: [
          ItineraryStop(
            time: '08:30 AM',
            title: "People's Park",
            description: 'Morning rainforest walk and Durian Dome.',
            category: 'sight',
            costEstimateUsd: 0,
            lat: 7.0707,
            lng: 125.6096,
            destinationId: 1,
            islandGroup: 'mainland',
          ),
          ItineraryStop(
            time: '11:00 AM',
            title: 'Museo Dabawenyo',
            description: 'Explore Davao heritage galleries.',
            category: 'sight',
            costEstimateUsd: 0,
            lat: 7.07939,
            lng: 125.60449,
            destinationId: 14,
            islandGroup: 'mainland',
            travelFromPrevMinutes: 12,
            travelFromPrevKm: 1.8,
            travelFromPrevMode: TransportMode.car,
          ),
        ],
      ),
      ItineraryDay(
        dayNumber: 2,
        cityTitle: 'Day 2 • Malagos Wildlife',
        summary: 'Philippine Eagle sanctuary and orchid gardens.',
        lat: 7.1854,
        lng: 125.4169,
        apiDestinationId: 2,
        stops: [
          ItineraryStop(
            time: '08:30 AM',
            title: 'Philippine Eagle Center',
            description: 'Raptor conservation sanctuary in Baguio District.',
            category: 'nature',
            costEstimateUsd: 3.0,
            lat: 7.1854,
            lng: 125.4169,
            destinationId: 2,
            islandGroup: 'mainland',
            travelFromPrevMinutes: 48,
            travelFromPrevKm: 31.2,
            travelFromPrevMode: TransportMode.car,
          ),
          ItineraryStop(
            time: '01:30 PM',
            title: 'Malagos Chocolate Museo',
            description: 'Tree-to-bar Davao cacao tasting.',
            category: 'food',
            costEstimateUsd: 8.0,
            lat: 7.1890,
            lng: 125.4240,
            destinationId: 17,
            islandGroup: 'mainland',
            travelFromPrevMinutes: 8,
            travelFromPrevKm: 2.1,
            travelFromPrevMode: TransportMode.car,
          ),
        ],
      ),
      ItineraryDay(
        dayNumber: 3,
        cityTitle: 'Day 3 • Toril Highlands',
        summary: 'Cool pine canopy at Eden Nature Park.',
        lat: 7.02824,
        lng: 125.401755,
        apiDestinationId: 3,
        stops: [
          ItineraryStop(
            time: '09:00 AM',
            title: 'Eden Nature Park',
            description: 'Guided shuttle tour and mountain lunch.',
            category: 'nature',
            costEstimateUsd: 12.0,
            lat: 7.02824,
            lng: 125.401755,
            destinationId: 3,
            islandGroup: 'mainland',
            travelFromPrevMinutes: 52,
            travelFromPrevKm: 26.5,
            travelFromPrevMode: TransportMode.car,
          ),
          ItineraryStop(
            time: '03:30 PM',
            title: "Jack's Ridge Viewpoint",
            description: 'Sunset dining overlooking Davao Gulf.',
            category: 'food',
            costEstimateUsd: 15.0,
            lat: 7.0630,
            lng: 125.5880,
            destinationId: 15,
            islandGroup: 'mainland',
            travelFromPrevMinutes: 40,
            travelFromPrevKm: 22.0,
            travelFromPrevMode: TransportMode.car,
          ),
        ],
      ),
      ItineraryDay(
        dayNumber: 4,
        cityTitle: 'Day 4 • Samal Island Crossing',
        summary: 'Cross Pakiputan Strait via Sasa Wharf to Samal reefs.',
        lat: 7.0744,
        lng: 125.7087,
        apiDestinationId: 4,
        stops: [
          ItineraryStop(
            time: '08:00 AM',
            title: 'Samal Island Beach Area',
            description: 'Barge crossing and clear reef snorkeling.',
            category: 'nature',
            costEstimateUsd: 14.0,
            lat: 7.0744,
            lng: 125.7087,
            destinationId: 4,
            islandGroup: 'samal',
            travelFromPrevMinutes: 55,
            travelFromPrevKm: 18.2,
            travelFromPrevMode: TransportMode.ferry,
            isSeaCrossingFromPrev: true,
          ),
          ItineraryStop(
            time: '01:30 PM',
            title: 'Hagimit Falls',
            description: 'Cascading travertine pools in Samal.',
            category: 'nature',
            costEstimateUsd: 4.0,
            lat: 7.0812,
            lng: 125.7335,
            destinationId: 18,
            islandGroup: 'samal',
            travelFromPrevMinutes: 20,
            travelFromPrevKm: 7.4,
            travelFromPrevMode: TransportMode.car,
          ),
        ],
      ),
      ItineraryDay(
        dayNumber: 5,
        cityTitle: 'Day 5 • Return Hub & Souvenirs',
        summary: 'Ferry back to Davao City hub for departure.',
        lat: 7.0707,
        lng: 125.6096,
        apiDestinationId: 1,
        stops: [
          ItineraryStop(
            time: '09:30 AM',
            title: 'Sta. Ana Wharf Promenade',
            description: 'Morning baywalk stroll after crossing back.',
            category: 'sight',
            costEstimateUsd: 0,
            lat: 7.0740,
            lng: 125.6230,
            destinationId: 24,
            islandGroup: 'mainland',
            travelFromPrevMinutes: 45,
            travelFromPrevKm: 15.0,
            travelFromPrevMode: TransportMode.ferry,
            isSeaCrossingFromPrev: true,
          ),
          ItineraryStop(
            time: '02:00 PM',
            title: "People's Park",
            description: 'Final hub revisit for pasalubong and coffee.',
            category: 'sight',
            costEstimateUsd: 5.0,
            lat: 7.0707,
            lng: 125.6096,
            destinationId: 1,
            islandGroup: 'mainland',
            travelFromPrevMinutes: 10,
            travelFromPrevKm: 2.2,
            travelFromPrevMode: TransportMode.car,
          ),
        ],
      ),
    ],
  );
}

/// Builds a 14-day, 25-stop Davao Region Grand Loop [ItineraryTrip] fixture
/// for scale, chunking, hub-revisit, and multi-page PDF boundary tests.
ItineraryTrip buildFourteenDayDavaoGrandLoopTrip() {
  final stopsPerDay = <List<ItineraryStop>>[
    for (var d = 1; d <= 14; d++)
      [
        ItineraryStop(
          time: '09:00 AM',
          title: d == 1 || d == 14
              ? "People's Park Hub (Day $d)"
              : 'Davao Stop ${d * 2 - 1} — Santo Niño Ridge',
          description:
              'Explore local Davao landmarks, scenic overlooks, and community stalls on Day $d.',
          category: d.isEven ? 'nature' : 'sight',
          costEstimateUsd: 10.0,
          lat: 7.05 + (d * 0.01),
          lng: 125.55 + (d * 0.01),
          destinationId: d == 1 || d == 14 ? 1 : (100 + d * 2 - 1),
          islandGroup: d == 6 ? 'samal' : 'mainland',
          travelFromPrevMinutes: d == 1 ? null : 25,
          travelFromPrevKm: d == 1 ? null : 12.5,
          travelFromPrevMode: d == 6 ? TransportMode.ferry : TransportMode.car,
          isSeaCrossingFromPrev: d == 6,
        ),
        if (d <= 11)
          ItineraryStop(
            time: '02:00 PM',
            title: 'Davao Stop ${d * 2} — Coastal Cove',
            description: 'Afternoon scenic stop with ₱150 entrance and local snacks.',
            category: 'food',
            costEstimateUsd: 6.0,
            lat: 7.06 + (d * 0.01),
            lng: 125.57 + (d * 0.01),
            destinationId: 100 + d * 2,
            islandGroup: d == 6 ? 'samal' : 'mainland',
            travelFromPrevMinutes: 18,
            travelFromPrevKm: 7.5,
            travelFromPrevMode: TransportMode.car,
          ),
      ],
  ];

  final allIds = <int>[
    for (final dayStops in stopsPerDay)
      for (final stop in dayStops)
        if (stop.destinationId != null) stop.destinationId!,
  ];

  return ItineraryTrip(
    id: 'e2e_14day_25stop_davao',
    title: '14-Day Davao Region Grand Loop',
    destination: 'Davao Region',
    daysCount: 14,
    adults: 2,
    centerLat: 7.0744,
    centerLng: 125.6096,
    heroAsset: 'assets/home_backdrops/03-mount-apo.jpg',
    vibeTag: 'Grand Loop',
    overviewText:
        'Comprehensive 14-day, 25-stop circuit from Davao City to Samal Island, Mati, Tagum, and Mount Apo.',
    bestMonths: 'Dec – May',
    avgTemp: '29°C • Partly Cloudy',
    startDate: DateTime(2026, 12, 1),
    endDate: DateTime(2026, 12, 14),
    expertName: 'Lakbay Planner',
    expertTip: 'Pace your highlands and island transfers with buffer hours.',
    backendTripId: 1401,
    backendDestinationIds: allIds,
    backendBudgetPhp: 45000,
    backendEstimatedCostPhp: 32500,
    flights: const [],
    hotels: const [],
    seaCrossings: const [sasaBabakSeaCrossing],
    days: [
      for (var d = 1; d <= 14; d++)
        ItineraryDay(
          dayNumber: d,
          cityTitle: 'Day $d • Davao Region Circuit',
          summary: 'Day $d exploration across Davao Region.',
          lat: 7.05 + (d * 0.01),
          lng: 125.55 + (d * 0.01),
          apiDestinationId: stopsPerDay[d - 1].first.destinationId,
          stops: stopsPerDay[d - 1],
        ),
    ],
  );
}

/// Deterministic [TimelineData] fixture with Davao stops, ₱ costs, and checks.
TimelineData buildDavaoTimelineData({bool conflict = false}) {
  return TimelineData.fromJson({
    'days': [
      {
        'day': 1,
        'date': '2026-12-01',
        'items': [
          {
            'kind': 'depart',
            'day': 1,
            'starts_at': '08:00:00',
            'ends_at': '08:00:00',
            'duration_minutes': 0,
            'time_basis': 'confirmed',
            'duration_basis': 'recorded',
            'label': 'Leave Davao City Hall',
          },
          {
            'kind': 'visit',
            'day': 1,
            'starts_at': '08:30:00',
            'ends_at': '10:30:00',
            'duration_minutes': 120,
            'time_basis': 'estimated',
            'duration_basis': 'recorded',
            'label': "People's Park",
            'destination_id': 1,
            'costs': [
              {
                'label': 'Park Entry',
                'amount': '50.00',
                'status': 'known',
                'scope': 'per_person',
                'included_in': null,
              },
            ],
            'notes': ['Bring sun protection and water.'],
          },
          {
            'kind': 'visit',
            'day': 1,
            'starts_at': '11:30:00',
            'ends_at': '14:30:00',
            'duration_minutes': 180,
            'time_basis': 'estimated',
            'duration_basis': 'recorded',
            'label': 'Eden Nature Park',
            'destination_id': 3,
            'costs': [
              {
                'label': 'Day Tour',
                'amount': '350.00',
                'status': 'known',
                'scope': 'per_person',
                'included_in': null,
              },
            ],
          },
        ],
      },
      {
        'day': 2,
        'date': '2026-12-02',
        'items': [
          {
            'kind': 'visit',
            'day': 2,
            'starts_at': '09:00:00',
            'ends_at': '15:00:00',
            'duration_minutes': 360,
            'time_basis': 'provisional',
            'duration_basis': 'estimated',
            'label': 'Samal Island Beach Area',
            'destination_id': 4,
            'costs': [
              {
                'label': 'Barge Fare',
                'amount': '35.00',
                'status': 'known',
                'scope': 'per_person',
                'included_in': null,
              },
            ],
          },
        ],
      },
    ],
    'conflicts': conflict
        ? [
            {
              'code': 'does_not_fit_hours',
              'destination_id': 3,
              'day': 1,
              'message': 'Eden Nature Park closes at 5:00 PM.',
              'choices': ['change_time_window'],
            },
          ]
        : const <dynamic>[],
    'checks': [
      {
        'id': 'chronological_order',
        'status': 'passed',
        'message': 'All items are in chronological order.',
        'destination_ids': const <int>[],
      },
    ],
    'budget': {
      'known_total': '435.00',
      'estimated_total': '1200.00',
      'unknown': const <String>[],
      'unbased': const <String>[],
      'to_complete': const <String>[],
      'subtotal': '1635.00',
      'complete': true,
      'total_budget': '5000.00',
      'remaining': '3365.00',
      'fit': 'fits_known_costs',
      'notes': const <String>[],
    },
    'feasible': !conflict,
    'unverified': const <String>[],
    'assumptions': const ['Day starts at 8:00 AM from Davao City.'],
    'pins': const <dynamic>[],
  });
}
