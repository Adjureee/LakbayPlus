import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lakbay_travel/models/travel_models.dart';
import 'package:lakbay_travel/services/lakbay_api_catalog_service.dart';
import 'package:lakbay_travel/services/travel_repository.dart';
import 'package:lakbay_travel/services/trip_pdf.dart';
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

/// The text the PDF draws. The builder writes one word per `[(word)]TJ`, so the
/// words are joined with spaces to read it as sentences again.
String _pdfText(Uint8List bytes) {
  final raw = latin1.decode(bytes, allowInvalid: true);
  final words = RegExp(r'\[\((.*?)\)\]TJ')
      .allMatches(raw)
      .map((m) => m.group(1)!.replaceAll(r'\(', '(').replaceAll(r'\)', ')'));
  return '%PDF-check ${words.join(' ')}';
}

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
      final text = _pdfText(bytes);

      expect(text, isNotEmpty);
      expect(text, contains('Samal Island'));
      expect(text, contains('Day 1'));
      expect(text, contains('Travelers: not set'));
      expect(text, contains('Start date: not set'));
      expect(text, contains('Nov 17, 2026'));
      for (final stop in trip.days.expand((d) => d.stops).take(2)) {
        expect(text, contains(stop.title.replaceAll(RegExp(r'[^\x20-\x7E]'), '')));
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
      expect(text, contains('Starts: Dec 5, 2026'));
    });
  });
}
