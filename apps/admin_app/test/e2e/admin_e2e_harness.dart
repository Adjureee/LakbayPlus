import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lakbay_admin/services/api_service.dart';
import 'package:lakbay_admin/services/session_manager.dart';
import 'package:lakbay_admin/widgets/admin_widgets.dart';
import 'package:lakbay_admin/widgets/destination_photo_upload.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Initializes strictly offline, deterministic test state for Admin E2E tests.
Future<void> initAdminE2eEnvironment({
  Map<String, Object> initialPrefs = const {},
}) async {
  TestWidgetsFlutterBinding.ensureInitialized();
  GoogleFonts.config.allowRuntimeFetching = false;
  SharedPreferences.setMockInitialValues(initialPrefs);
  adminHasUnsavedChanges.value = false;
  adminIsSaving.value = false;
}

/// Seeds an authenticated Admin session into [SessionManager].
Future<void> seedAdminSession({
  String token = 'admin-access-token',
  String refreshToken = 'admin-refresh-token',
  String name = 'Lakbay Davao Admin',
  String email = 'admin@lakbay.test',
  String userId = '1',
}) => SessionManager.instance.saveSession(
  token: token,
  refreshToken: refreshToken,
  name: name,
  email: email,
  role: 'admin',
  userId: userId,
);

/// Seeds a non-admin (traveler/user) session into [SessionManager] for auth-gate tests.
Future<void> seedNonAdminSession({
  String role = 'traveler',
  String token = 'traveler-access-token',
  String refreshToken = 'traveler-refresh-token',
  String name = 'Traveler Account',
  String email = 'traveler@lakbay.test',
  String userId = '99',
}) => SessionManager.instance.saveSession(
  token: token,
  refreshToken: refreshToken,
  name: name,
  email: email,
  role: role,
  userId: userId,
);

/// Replaces [pickDestinationPhoto] for the duration of a test and restores it in tearDown.
void installPhotoPickerOverride(Future<PickedPhoto?> Function() picker) {
  final previous = pickDestinationPhoto;
  pickDestinationPhoto = picker;
  addTearDown(() => pickDestinationPhoto = previous);
}

/// Replaces [pickDestinationMedia] for the duration of a test and restores it in tearDown.
void installMediaPickerOverride(Future<PickedPhoto?> Function() picker) {
  final previous = pickDestinationMedia;
  pickDestinationMedia = picker;
  addTearDown(() => pickDestinationMedia = previous);
}

/// Sets a desktop viewport for wide Admin panels/tables and restores it on tearDown.
void setDesktopViewport(
  WidgetTester tester, {
  Size size = const Size(1280, 900),
}) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

/// Enters text into a [TextFormField] or [TextField] identified by its labelText.
Future<void> enterFieldByLabel(
  WidgetTester tester,
  String label,
  String value,
) async {
  var finder = find.widgetWithText(TextFormField, label);
  if (finder.evaluate().isEmpty) {
    finder = find.widgetWithText(TextField, label);
  }
  await tester.ensureVisible(finder);
  await tester.enterText(finder, value);
  await tester.pump();
}

/// Scrolls a widget into view and taps it cleanly.
Future<void> tapVisible(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
}

// ---------------------------------------------------------------------------
// Deterministic valid & adversarial binary media payloads (100% in-memory)
// ---------------------------------------------------------------------------

/// Minimal valid JPEG header + EOI bytes.
Uint8List validJpegBytes() => Uint8List.fromList(const [
  0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46, 0x00, 0x01,
  0x01, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0xFF, 0xD9,
]);

/// Valid 1x1 transparent PNG.
Uint8List validPngBytes() => Uint8List.fromList(const [
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
  0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
  0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
  0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41,
  0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00,
  0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
  0x42, 0x60, 0x82,
]);

/// Minimal valid RIFF/WEBP payload.
Uint8List validWebpBytes() => Uint8List.fromList([
  ...utf8.encode('RIFF'),
  0x1A, 0x00, 0x00, 0x00,
  ...utf8.encode('WEBP'),
  ...utf8.encode('VP8 '),
  0x0E, 0x00, 0x00, 0x00,
  0x10, 0x00, 0x00, 0x9D, 0x01, 0x2A, 0x01, 0x00, 0x01, 0x00, 0x00, 0x00,
]);

/// Valid 1x1 GIF89a image.
Uint8List validGif89aBytes() => Uint8List.fromList(const [
  0x47, 0x49, 0x46, 0x38, 0x39, 0x61, // GIF89a
  0x01, 0x00, 0x01, 0x00, 0x80, 0x00, 0x00,
  0xFF, 0xFF, 0xFF, 0x00, 0x00, 0x00,
  0x2C, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00,
  0x02, 0x02, 0x44, 0x01, 0x00, 0x3B,
]);

/// Valid minimal MP4 container with `ftyp` and `moov -> mvhd` (v0) encoding
/// [durationSeconds] so client duration validation can be tested deterministically.
Uint8List validMp4Bytes({double durationSeconds = 8.0}) {
  const timescale = 1000;
  final durationUnits = (durationSeconds * timescale).round();

  final ftyp = <int>[
    0x00, 0x00, 0x00, 0x14, // size = 20
    ...utf8.encode('ftyp'),
    ...utf8.encode('isom'),
    0x00, 0x00, 0x02, 0x00,
    ...utf8.encode('isom'),
  ];

  // mvhd v0 payload: 100 bytes total (8-byte header + 92 bytes body)
  final mvhd = Uint8List(100);
  final mvhdView = ByteData.sublistView(mvhd);
  mvhdView.setUint32(0, 100);
  mvhd.setRange(4, 8, utf8.encode('mvhd'));
  mvhd[8] = 0; // version 0
  mvhdView.setUint32(20, timescale); // start + 12 (8 + 12)
  mvhdView.setUint32(24, durationUnits); // start + 16 (8 + 16)

  final moov = Uint8List(8 + mvhd.length);
  final moovView = ByteData.sublistView(moov);
  moovView.setUint32(0, moov.length);
  moov.setRange(4, 8, utf8.encode('moov'));
  moov.setRange(8, moov.length, mvhd);

  return Uint8List.fromList([...ftyp, ...moov]);
}

/// Valid minimal WebM EBML header (`1A 45 DF A3`).
Uint8List validWebmBytes() => Uint8List.fromList([
  0x1A, 0x45, 0xDF, 0xA3, 0x9F, 0x42, 0x86, 0x81,
  0x01, 0x42, 0xF7, 0x81, 0x01, 0x42, 0xF2, 0x81,
  0x04, 0x42, 0xF3, 0x81, 0x08, 0x42, 0x82, 0x84,
  ...utf8.encode('webm'),
]);

/// Spoofed/corrupt payload (ZIP signature disguised as media).
Uint8List spoofedBytes() =>
    Uint8List.fromList([0x50, 0x4B, 0x03, 0x04, ...utf8.encode('not-media')]);

/// Empty 0-byte payload.
Uint8List emptyBytes() => Uint8List(0);

/// Oversized GIF89a buffer (`10 MB + 1 byte`) built in memory in <10ms.
Uint8List oversizedGifBytes() {
  final bytes = Uint8List(destinationMediaImageMaxBytes + 1);
  bytes.setRange(0, 6, const [0x47, 0x49, 0x46, 0x38, 0x39, 0x61]);
  return bytes;
}

/// Oversized MP4 buffer (`15 MB + 1 byte`) with valid `ftypisom` header.
Uint8List oversizedMp4Bytes() {
  final bytes = Uint8List(destinationMediaVideoMaxBytes + 1);
  final ftyp = validMp4Bytes(durationSeconds: 5.0);
  bytes.setRange(0, ftyp.length, ftyp);
  return bytes;
}

/// Oversized WebM buffer (`15 MB + 1 byte`) with valid EBML header.
Uint8List oversizedWebmBytes() {
  final bytes = Uint8List(destinationMediaVideoMaxBytes + 1);
  final webm = validWebmBytes();
  bytes.setRange(0, webm.length, webm);
  return bytes;
}

// ---------------------------------------------------------------------------
// Recorded request log & Stateful Offline MockAdminBackend
// ---------------------------------------------------------------------------

class RecordedRequest {
  RecordedRequest({
    required this.method,
    required this.path,
    required this.queryParameters,
    required this.headers,
    required this.body,
    required this.bodyBytes,
  });

  final String method;
  final String path;
  final Map<String, String> queryParameters;
  final Map<String, String> headers;
  final String body;
  final Uint8List bodyBytes;

  Map<String, dynamic> get jsonBody =>
      body.isEmpty ? const {} : Map<String, dynamic>.from(jsonDecode(body) as Map);
}

class MockAdminBackend {
  MockAdminBackend({
    List<Map<String, dynamic>>? destinations,
    List<Map<String, dynamic>>? candidates,
    List<Map<String, dynamic>>? trips,
    Map<String, dynamic>? facets,
  }) : destinations = destinations ?? [],
       candidates = candidates ?? [],
       trips = trips ?? [],
       facets = facets ?? defaultDavaoFacets();

  static Map<String, dynamic> defaultDavaoFacets() => {
    'total_places': 3,
    'groups': [
      {
        'key': 'nature_attractions',
        'label': 'Nature',
        'description': 'Parks, waterfalls, peaks, and eco-reserves',
        'count': 2,
        'subtypes': [],
      },
      {
        'key': 'beaches_islands',
        'label': 'Beaches & Islands',
        'description': 'Coastal and island getaways',
        'count': 1,
        'subtypes': [],
      },
    ],
    'categories': [
      {
        'key': 'Nature',
        'label': 'Nature',
        'count': 1,
        'group': 'nature_attractions',
        'groups': ['nature_attractions'],
        'examples': [],
      },
      {
        'key': 'Waterfall',
        'label': 'Waterfall',
        'count': 1,
        'group': 'nature_attractions',
        'groups': ['nature_attractions'],
        'examples': [],
      },
      {
        'key': 'Beach',
        'label': 'Beach',
        'count': 1,
        'group': 'beaches_islands',
        'groups': ['beaches_islands'],
        'examples': [],
      },
    ],
  };

  final Map<String, dynamic> facets;
  final List<Map<String, dynamic>> destinations;
  final List<Map<String, dynamic>> candidates;
  final List<Map<String, dynamic>> trips;
  final Map<String, Map<String, dynamic>> hoursByDestId = {};
  final Map<String, Map<String, dynamic>> pricesByDestId = {};
  final Map<String, Map<String, dynamic>> activitiesByDestId = {};
  final Map<String, List<Map<String, dynamic>>> commutesByDestId = {};
  final List<RecordedRequest> requests = [];

  int _nextDestinationId = 100;
  int? tripsErrorStatusCode;
  String tripsErrorDetail = 'Database timeout while loading trips.';
  int? destinationsErrorStatusCode;
  bool requireAuthRefreshOnce = false;
  Future<http.Response> Function(RecordedRequest req)? onRefresh;

  /// Creates a fresh [ApiService] wired to this stateful mock backend.
  /// Always create a fresh instance per widget mount because screens like
  /// [TripsScreen] and [DestinationsScreen] close their [ApiService] in dispose().
  ApiService createApi({
    Future<String?> Function()? tokenProvider,
    String baseUrl = 'http://lakbay.test/api/v1',
  }) => ApiService(
    apiBaseUrl: baseUrl,
    tokenProvider: tokenProvider ?? () async => 'admin-token',
    client: MockClient(_handleRequest),
  );

  List<RecordedRequest> requestsTo(String pathSuffix, {String? method}) =>
      requests
          .where(
            (r) =>
                r.path.endsWith(pathSuffix) &&
                (method == null || r.method == method),
          )
          .toList();

  Future<http.Response> _handleRequest(http.Request request) async {
    final bytes = Uint8List.fromList(request.bodyBytes);
    final body = latin1.decode(bytes);
    final rec = RecordedRequest(
      method: request.method,
      path: request.url.path,
      queryParameters: Map<String, String>.from(request.url.queryParameters),
      headers: Map<String, String>.from(request.headers),
      body: body,
      bodyBytes: bytes,
    );
    requests.add(rec);

    final path = request.url.path;

    // 1. Auth refresh
    if (path == '/api/v1/auth/refresh' && request.method == 'POST') {
      if (onRefresh != null) return onRefresh!(rec);
      return http.Response(
        jsonEncode({
          'user': {
            'user_id': 1,
            'full_name': 'Lakbay Admin',
            'email': 'admin@lakbay.test',
            'role': 'admin',
          },
          'tokens': {
            'access_token': 'rotated-admin-token',
            'refresh_token': 'rotated-refresh-token',
          },
        }),
        200,
      );
    }

    if (requireAuthRefreshOnce && path != '/api/v1/auth/refresh') {
      requireAuthRefreshOnce = false;
      return http.Response(jsonEncode({'detail': 'Token expired'}), 401);
    }

    // 2. Admin trips
    if (path == '/api/v1/admin/trips' && request.method == 'GET') {
      if (tripsErrorStatusCode != null) {
        return http.Response(
          jsonEncode({'detail': tripsErrorDetail}),
          tripsErrorStatusCode!,
        );
      }
      final status = request.url.queryParameters['status']?.trim();
      final search = (request.url.queryParameters['search'] ?? '').trim().toLowerCase();
      final limit = int.tryParse(request.url.queryParameters['limit'] ?? '') ?? 25;
      final offset = int.tryParse(request.url.queryParameters['offset'] ?? '') ?? 0;

      final matching = trips.where((t) {
        if (status != null && status.isNotEmpty && t['status'] != status) {
          return false;
        }
        if (search.isNotEmpty) {
          final hay = [
            t['title'],
            t['owner_name'],
            t['owner_email'],
          ].map((e) => (e ?? '').toString().toLowerCase()).join(' ');
          if (!hay.contains(search)) return false;
        }
        return true;
      }).toList();

      final paged = matching.skip(offset).take(limit).toList();
      return http.Response(
        jsonEncode({
          'total_trips': trips.length,
          'matching_trips': matching.length,
          'items': paged,
        }),
        200,
      );
    }

    // 3. Destination facets
    if (path == '/api/v1/destinations/facets' && request.method == 'GET') {
      return http.Response(jsonEncode(facets), 200);
    }

    // 4. Destinations list & create
    if (path == '/api/v1/destinations' && request.method == 'GET') {
      if (destinationsErrorStatusCode != null) {
        return http.Response(
          jsonEncode({'detail': 'Failed to load destinations'}),
          destinationsErrorStatusCode!,
        );
      }
      final limit = int.tryParse(request.url.queryParameters['limit'] ?? '') ?? 100;
      final offset = int.tryParse(request.url.queryParameters['offset'] ?? '') ?? 0;
      final active = destinations.where((d) => d['is_active'] != false).toList();
      final page = active.skip(offset).take(limit).toList();
      return http.Response(jsonEncode(page), 200);
    }

    if (path == '/api/v1/destinations' && request.method == 'POST') {
      final payload = jsonDecode(body) as Map<String, dynamic>;
      final newId = _nextDestinationId++;
      final created = <String, dynamic>{
        'destination_id': newId,
        'is_active': true,
        'created_at': '2026-11-27T04:00:00Z',
        ...payload,
      };
      destinations.add(created);
      return http.Response(jsonEncode(created), 201);
    }

    // 5. Destination photo (/image) & media (/media)
    final imageMatch = RegExp(r'^/api/v1/destinations/(\d+)/image$').firstMatch(path);
    if (imageMatch != null && request.method == 'POST') {
      final id = imageMatch.group(1)!;
      final idx = destinations.indexWhere((d) => d['destination_id'].toString() == id);
      if (idx < 0) return http.Response(jsonEncode({'detail': 'Not found'}), 404);
      final filename = _extractFilename(body) ?? 'photo.jpg';
      final url =
          'https://res.cloudinary.com/demo/image/upload/lakbay/destinations/$id/$filename';
      final updated = <String, dynamic>{...destinations[idx], 'image_url': url};
      destinations[idx] = updated;
      return http.Response(jsonEncode(updated), 200);
    }

    final mediaMatch = RegExp(r'^/api/v1/destinations/(\d+)/media$').firstMatch(path);
    if (mediaMatch != null && request.method == 'POST') {
      final id = mediaMatch.group(1)!;
      final idx = destinations.indexWhere((d) => d['destination_id'].toString() == id);
      if (idx < 0) return http.Response(jsonEncode({'detail': 'Not found'}), 404);
      final filename = _extractFilename(body) ?? 'clip.mp4';
      final contentType = _extractMultipartContentType(body) ?? 'image/jpeg';
      final lower = filename.toLowerCase();
      final isVideo = contentType.startsWith('video/') ||
          lower.endsWith('.mp4') ||
          lower.endsWith('.webm');
      final isGif = contentType == 'image/gif' || lower.endsWith('.gif');
      final mediaType = isVideo ? 'video' : (isGif ? 'gif' : 'image');
      final resourceFolder = isVideo ? 'video' : 'image';
      final mediaUrl =
          'https://res.cloudinary.com/demo/$resourceFolder/upload/lakbay/destinations/$id/$filename';
      final updated = <String, dynamic>{
        ...destinations[idx],
        'media_url': mediaUrl,
        'media_type': mediaType,
        'media_public_id': 'lakbay/destinations/$id/$filename',
        if (isVideo) 'media_duration_seconds': 8.0 else 'media_duration_seconds': null,
      };
      if (!isVideo && !isGif) {
        updated['image_url'] = mediaUrl;
      }
      destinations[idx] = updated;
      return http.Response(jsonEncode(updated), 200);
    }

    // 6. Destination sub-sections (hours, prices, activities, commute)
    final subMatch = RegExp(
      r'^/api/v1/destinations/(\d+)/(hours|prices|activities)$',
    ).firstMatch(path);
    if (subMatch != null) {
      final id = subMatch.group(1)!;
      final section = subMatch.group(2)!;
      if (request.method == 'GET') {
        final data = switch (section) {
          'hours' => hoursByDestId[id] ?? {'destination_id': int.parse(id), 'weekly': [], 'exceptions': []},
          'prices' => pricesByDestId[id] ?? {'destination_id': int.parse(id), 'prices': []},
          'activities' => activitiesByDestId[id] ?? {'destination_id': int.parse(id), 'activities': []},
          _ => const {},
        };
        return http.Response(jsonEncode(data), 200);
      }
      if (request.method == 'PUT') {
        final payload = Map<String, dynamic>.from(jsonDecode(body) as Map);
        final saved = <String, dynamic>{
          'destination_id': int.parse(id),
          ...payload,
          'data_quality': 'supported',
        };
        if (section == 'hours') hoursByDestId[id] = saved;
        if (section == 'prices') pricesByDestId[id] = saved;
        if (section == 'activities') activitiesByDestId[id] = saved;
        return http.Response(jsonEncode(saved), 200);
      }
    }

    final commuteMatch = RegExp(
      r'^/api/v1/admin/destinations/(\d+)/commute$',
    ).firstMatch(path);
    if (commuteMatch != null && request.method == 'GET') {
      final id = commuteMatch.group(1)!;
      return http.Response(
        jsonEncode({
          'destination_id': int.parse(id),
          'routes': commutesByDestId[id] ?? [],
        }),
        200,
      );
    }

    // 7. Destination PATCH & DELETE
    final destMatch = RegExp(r'^/api/v1/destinations/(\d+)$').firstMatch(path);
    if (destMatch != null) {
      final id = destMatch.group(1)!;
      final idx = destinations.indexWhere((d) => d['destination_id'].toString() == id);
      if (idx < 0) return http.Response(jsonEncode({'detail': 'Not found'}), 404);
      if (request.method == 'PATCH') {
        final patch = jsonDecode(body) as Map<String, dynamic>;
        final updated = <String, dynamic>{...destinations[idx], ...patch};
        destinations[idx] = updated;
        return http.Response(jsonEncode(updated), 200);
      }
      if (request.method == 'DELETE') {
        destinations[idx] = {...destinations[idx], 'is_active': false};
        return http.Response(jsonEncode(destinations[idx]), 200);
      }
    }

    // 8. Destination candidates
    if (path == '/api/v1/admin/destination-candidates' && request.method == 'GET') {
      final reviewStatus = request.url.queryParameters['review_status'] ?? 'staged';
      final query = (request.url.queryParameters['q'] ?? '').trim().toLowerCase();
      final limit = int.tryParse(request.url.queryParameters['limit'] ?? '') ?? 50;
      final offset = int.tryParse(request.url.queryParameters['offset'] ?? '') ?? 0;
      final filtered = candidates.where((c) {
        if ((c['review_status'] ?? 'staged') != reviewStatus) return false;
        if (query.isNotEmpty) {
          final hay = [
            c['name'],
            c['district'],
            c['location'],
            c['category'],
            c['osm_id'],
          ].map((e) => (e ?? '').toString().toLowerCase()).join(' ');
          if (!hay.contains(query)) return false;
        }
        return true;
      }).toList();
      return http.Response(
        jsonEncode(filtered.skip(offset).take(limit).toList()),
        200,
      );
    }

    final candPatch = RegExp(
      r'^/api/v1/admin/destination-candidates/(\d+)$',
    ).firstMatch(path);
    if (candPatch != null && request.method == 'PATCH') {
      final id = int.parse(candPatch.group(1)!);
      final idx = candidates.indexWhere((c) => c['candidate_id'] == id);
      if (idx < 0) return http.Response(jsonEncode({'detail': 'Not found'}), 404);
      final patch = jsonDecode(body) as Map<String, dynamic>;
      final updated = <String, dynamic>{...candidates[idx], ...patch};
      candidates[idx] = updated;
      return http.Response(jsonEncode(updated), 200);
    }

    final candPublish = RegExp(
      r'^/api/v1/admin/destination-candidates/(\d+)/publish$',
    ).firstMatch(path);
    if (candPublish != null && request.method == 'POST') {
      final id = int.parse(candPublish.group(1)!);
      final idx = candidates.indexWhere((c) => c['candidate_id'] == id);
      if (idx < 0) return http.Response(jsonEncode({'detail': 'Not found'}), 404);
      final cand = candidates[idx];
      final newDestId = _nextDestinationId++;
      final publishedDest = <String, dynamic>{
        'destination_id': newDestId,
        'name': cand['name'],
        'lat': cand['lat'],
        'lng': cand['lng'],
        'district': cand['district'],
        'category': cand['category'],
        'vibes': cand['vibes'],
        'island_group': cand['island_group'],
        'description': cand['description'],
        'location': cand['location'],
        'activities': cand['activities'],
        'estimated_cost': cand['estimated_cost']?.toString(),
        'entrance_fee': cand['entrance_fee'],
        'overnight_fee': cand['overnight_fee'],
        'operating_hours': cand['operating_hours'],
        'is_active': true,
      };
      destinations.add(publishedDest);
      final updatedCand = <String, dynamic>{
        ...cand,
        'review_status': 'published',
        'destination_id': newDestId,
      };
      candidates[idx] = updatedCand;
      return http.Response(jsonEncode(updatedCand), 200);
    }

    final candReject = RegExp(
      r'^/api/v1/admin/destination-candidates/(\d+)/reject$',
    ).firstMatch(path);
    if (candReject != null && request.method == 'POST') {
      final id = int.parse(candReject.group(1)!);
      final idx = candidates.indexWhere((c) => c['candidate_id'] == id);
      if (idx < 0) return http.Response(jsonEncode({'detail': 'Not found'}), 404);
      final payload = jsonDecode(body) as Map<String, dynamic>;
      final updatedCand = <String, dynamic>{
        ...candidates[idx],
        'review_status': 'rejected',
        'review_notes': payload['reason'],
      };
      candidates[idx] = updatedCand;
      return http.Response(jsonEncode(updatedCand), 200);
    }

    return http.Response(jsonEncode({'detail': 'Unhandled route: $path'}), 404);
  }

  String? _extractFilename(String multipartBody) {
    final match = RegExp(r'filename="([^"]+)"').firstMatch(multipartBody);
    return match?.group(1);
  }

  String? _extractMultipartContentType(String multipartBody) {
    final match = RegExp(
      r'content-type:\s*([^\r\n;]+)',
      caseSensitive: false,
    ).firstMatch(multipartBody);
    return match?.group(1)?.trim().toLowerCase();
  }
}

/// Realistic Davao destination builder for test seeding.
Map<String, dynamic> davaoDestination({
  int id = 12,
  String name = 'Eden Nature Park',
  String district = 'Toril, Davao City',
  String category = 'Nature',
  double lat = 7.0188,
  double lng = 125.4321,
  String? description = 'Mountain eco-park on the slopes of Mount Talomo.',
  String? location = 'Barangay Eden, Toril, Davao City',
  String? operatingHours = '8:00 AM - 5:00 PM',
  String? entranceFee = 'PHP 220 / person',
  String? imageUrl =
      'https://res.cloudinary.com/demo/image/upload/lakbay/destinations/12/eden.jpg',
  String? mediaUrl,
  String? mediaType,
  double? mediaDurationSeconds,
  String? imageCredit,
  String? imageLicense,
  String? imageSourceUrl,
}) => {
  'destination_id': id,
  'name': name,
  'district': district,
  'category': category,
  'lat': lat,
  'lng': lng,
  'description': description,
  'location': location,
  'operating_hours': operatingHours,
  'entrance_fee': entranceFee,
  'image_url': imageUrl,
  'media_url': ?mediaUrl,
  'media_type': ?mediaType,
  'media_duration_seconds': ?mediaDurationSeconds,
  'image_credit': ?imageCredit,
  'image_license': ?imageLicense,
  'image_source_url': ?imageSourceUrl,
  'is_active': true,
};

/// Realistic Davao staged OSM candidate builder for test seeding.
Map<String, dynamic> davaoCandidate({
  int candidateId = 41,
  String name = 'Hagimit Falls',
  double lat = 7.0681,
  double lng = 125.7364,
  String district = 'Island Garden City of Samal',
  String category = 'Waterfall',
  String islandGroup = 'samal',
  String regionStatus = 'inside',
  String reviewStatus = 'staged',
  String source = 'osm',
  String osmType = 'node',
  int osmId = 538858577,
}) => {
  'candidate_id': candidateId,
  'source': source,
  'osm_type': osmType,
  'osm_id': osmId,
  'osm_url': 'https://www.openstreetmap.org/$osmType/$osmId',
  'source_area': 'Davao del Norte',
  'source_tag': 'waterway=waterfall',
  'suggested_category': category,
  'name': name,
  'lat': lat,
  'lng': lng,
  'district': district,
  'category': category,
  'vibes': 'refreshing, nature',
  'island_group': islandGroup,
  'visitor_purpose': 'Cascading limestone pools for day swimming.',
  'description': 'Multi-tiered waterfall in Penaplata, Samal Island.',
  'location': 'Brgy. Cawag, Island Garden City of Samal',
  'activities': 'Swimming, cliff jumping, picnic',
  'estimated_cost': 350,
  'entrance_fee': 'PHP 40 / person',
  'operating_hours': '6:00 AM - 5:00 PM',
  'region_status': regionStatus,
  'review_status': reviewStatus,
};

/// Realistic Davao traveler trip builder for Admin TripsScreen tests.
Map<String, dynamic> davaoTrip({
  int tripId = 101,
  String title = 'Samal Island Weekend',
  String status = 'planned',
  String ownerName = 'Maria Santos',
  String ownerEmail = 'maria@lakbay.test',
  int travelerCount = 2,
  num totalBudget = 8500,
  num estimatedTotalCost = 6400,
  String? startDate = '2026-11-20',
  String? endDate = '2026-11-22',
  String? completedAt,
  List<String> destinationNames = const ['Hagimit Falls', 'Talikud Island'],
}) => {
  'trip_id': tripId,
  'title': title,
  'status': status,
  'owner_user_id': 7,
  'owner_name': ownerName,
  'owner_email': ownerEmail,
  'traveler_count': travelerCount,
  'total_budget': totalBudget,
  'estimated_total_cost': estimatedTotalCost,
  'start_date': ?startDate,
  'end_date': ?endDate,
  'completed_at': completedAt,
  'destination_names': destinationNames,
  'created_at': '2026-11-15T08:00:00Z',
};
