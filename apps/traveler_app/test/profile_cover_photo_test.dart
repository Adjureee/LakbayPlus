import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lakbay_travel/models/travel_models.dart';
import 'package:lakbay_travel/screens/profile_screen.dart';
import 'package:lakbay_travel/services/lakbay_api_catalog_service.dart';
import 'package:lakbay_travel/services/travel_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _png = Uint8List.fromList(
  [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 0],
);

LakbayApiCatalogService _service(
  Future<http.Response> Function(http.BaseRequest) handler,
) =>
    LakbayApiCatalogService(
      baseUrlOverride: 'https://api.lakbay.test/api/v1',
      client: MockClient.streaming((request, body) async {
        await body.drain<void>();
        final res = await handler(request);
        return http.StreamedResponse(
          Stream.value(res.bodyBytes),
          res.statusCode,
          headers: res.headers,
          request: request,
        );
      }),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    GoogleFonts.config.allowRuntimeFetching = false;
    SharedPreferences.setMockInitialValues({});
  });

  group('cover photo service', () {
    test('uploads to /users/me/cover and returns the cover address', () async {
      http.BaseRequest? seen;
      final service = _service((request) async {
        seen = request;
        return http.Response(
          jsonEncode({
            'avatar_url': 'https://cdn.test/me.jpg',
            'cover_url': 'https://cdn.test/cover.jpg',
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      });

      final url = await service.uploadMyCover(
        'tok',
        fileBytes: _png,
        filename: 'cover.png',
      );

      // The cover address, not the profile photo's, comes back.
      expect(url, 'https://cdn.test/cover.jpg');
      expect(seen!.url.path, '/api/v1/users/me/cover');
      expect(seen!.headers['Authorization'], 'Bearer tok');
    });

    test('removing sends DELETE /users/me/cover', () async {
      http.BaseRequest? seen;
      final service = _service((request) async {
        seen = request;
        return http.Response(
          jsonEncode({'cover_url': null}),
          200,
          headers: {'content-type': 'application/json'},
        );
      });

      await service.removeMyCover('tok');

      expect(seen!.method, 'DELETE');
      expect(seen!.url.path, '/api/v1/users/me/cover');
    });

    test('a refusal carries the server reason', () async {
      final service = _service((_) async => http.Response(
            jsonEncode({
              'error': {
                'code': 'image_too_large',
                'message': 'Image must be 5 MB or smaller.',
              },
            }),
            413,
            headers: {'content-type': 'application/json'},
          ));

      expect(
        () => service.uploadMyCover('tok', fileBytes: _png, filename: 'x.png'),
        throwsA(
          isA<LakbayApiException>()
              .having((e) => e.message, 'message', contains('5 MB')),
        ),
      );
    });
  });

  group('cover photo model and repository', () {
    test('the cover address survives saving and loading the profile', () {
      const profile = UserProfile(
        firstName: 'A',
        coverUrl: 'https://cdn.test/c.jpg',
      );
      expect(
        UserProfile.fromJson(profile.toJson()).coverUrl,
        'https://cdn.test/c.jpg',
      );
      expect(UserProfile.fromJson(const {}).coverUrl, '');
    });

    test('signed out, nothing is sent and the traveler is asked to sign in', () async {
      var requests = 0;
      final repo = TravelRepository(
        apiCatalog: _service((_) async {
          requests++;
          return http.Response('{}', 200);
        }),
      );
      await repo.initialize();

      expect(
        await repo.uploadCoverPhoto(bytes: _png, filename: 'a.png'),
        contains('Sign in'),
      );
      expect(requests, 0);
    });
  });

  group('profile screen cover', () {
    Future<TravelRepository> pump(
      WidgetTester tester, {
      String coverUrl = '',
    }) async {
      SharedPreferences.setMockInitialValues({
        'lakbay_traveler_state_v1': jsonEncode({
          'hasCompletedOnboarding': true,
          'profile': {
            'firstName': 'Maria',
            'lastName': 'Santos',
            'coverUrl': coverUrl,
          },
        }),
      });
      final repo = TravelRepository(
        apiCatalog: LakbayApiCatalogService(baseUrlOverride: ''),
      );
      await tester.runAsync(() => repo.initialize());
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(400, 900);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(MaterialApp(home: ProfileScreen(repo: repo)));
      await tester.pump(const Duration(milliseconds: 300));
      return repo;
    }

    testWidgets('the default banner shows when no cover is set', (tester) async {
      await pump(tester);
      expect(find.byKey(const ValueKey('profile-cover-image')), findsNothing);
      expect(find.byKey(const ValueKey('change-cover-photo')), findsOneWidget);
    });

    testWidgets('a saved cover is the banner', (tester) async {
      await pump(tester, coverUrl: 'https://cdn.test/cover.jpg');
      expect(find.byKey(const ValueKey('profile-cover-image')), findsOneWidget);
    });

    testWidgets('a guest who taps the camera is asked to sign in', (tester) async {
      await pump(tester);
      await tester.tap(find.byKey(const ValueKey('change-cover-photo')));
      await tester.pump();
      expect(find.text('Sign in to add a cover photo.'), findsOneWidget);
    });

    testWidgets('the camera button is at least 48 dp', (tester) async {
      await pump(tester);
      final size = tester.getSize(find.byKey(const ValueKey('change-cover-photo')));
      expect(size.width, greaterThanOrEqualTo(48));
      expect(size.height, greaterThanOrEqualTo(48));
    });
  });
}
