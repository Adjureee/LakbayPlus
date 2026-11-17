import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lakbay_admin/services/api_service.dart';
import 'package:lakbay_admin/widgets/admin_widgets.dart';
import 'package:lakbay_admin/widgets/destination_photo_upload.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _jpeg = Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3, 4]);
const _newUrl =
    'https://res.cloudinary.com/demo/image/upload/lakbay/destinations/6/beach.jpg';
const _destination = <String, dynamic>{
  'destination_id': 6,
  'name': 'Dahican Beach',
};

Future<void> _pump(
  WidgetTester tester,
  ApiService api,
  ValueChanged<Map<String, dynamic>> onUploaded,
) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Center(
          child: ReplacePhotoButton(
            api: api,
            destination: _destination,
            onUploaded: onUploaded,
          ),
        ),
      ),
    ),
  );
}

void main() {
  final realPicker = pickDestinationPhoto;
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    adminIsSaving.value = false;
  });
  tearDown(() => pickDestinationPhoto = realPicker);

  test('detects image types the way the API does', () {
    expect(detectPhotoContentType(_jpeg), 'image/jpeg');
    expect(
      detectPhotoContentType(
        Uint8List.fromList([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]),
      ),
      'image/png',
    );
    expect(
      detectPhotoContentType(
        Uint8List.fromList(utf8.encode('RIFF1234WEBPVP8')),
      ),
      'image/webp',
    );
    expect(
      detectPhotoContentType(Uint8List.fromList(utf8.encode('hello'))),
      isNull,
    );
  });

  testWidgets('confirmed photo is uploaded as multipart with its type', (
    tester,
  ) async {
    final requests = <http.BaseRequest>[];
    String? sentBody;
    final api = ApiService(
      client: MockClient((request) async {
        requests.add(request);
        sentBody = latin1.decode(request.bodyBytes);
        return http.Response(
          jsonEncode({..._destination, 'image_url': _newUrl}),
          200,
        );
      }),
      tokenProvider: () async => 'test-access',
      apiBaseUrl: 'http://lakbay.test/api/v1',
    );
    addTearDown(api.close);
    pickDestinationPhoto = () async => PickedPhoto('beach.jpg', _jpeg);
    Map<String, dynamic>? uploaded;
    await _pump(tester, api, (saved) => uploaded = saved);

    await tester.tap(find.text('Replace photo'));
    await tester.pumpAndSettle();
    expect(find.text('Use this photo for Dahican Beach?'), findsOneWidget);
    await tester.tap(find.text('Upload photo'));
    await tester.pumpAndSettle();

    expect(requests, hasLength(1));
    expect(requests.single.method, 'POST');
    expect(requests.single.url.path, '/api/v1/destinations/6/image');
    expect(requests.single.headers['Authorization'], 'Bearer test-access');
    expect(sentBody, contains('name="file"; filename="beach.jpg"'));
    expect(sentBody, contains('content-type: image/jpeg'));
    expect(uploaded?['image_url'], _newUrl);
    expect(find.text('Photo updated for Dahican Beach.'), findsOneWidget);
    expect(adminIsSaving.value, isFalse);
  });

  testWidgets('cancel and non-image files never reach the API', (tester) async {
    var requests = 0;
    final api = ApiService(
      client: MockClient((_) async {
        requests++;
        return http.Response('{}', 200);
      }),
      tokenProvider: () async => 'test-access',
      apiBaseUrl: 'http://lakbay.test/api/v1',
    );
    addTearDown(api.close);
    await _pump(tester, api, (_) {});

    pickDestinationPhoto = () async => PickedPhoto('beach.jpg', _jpeg);
    await tester.tap(find.text('Replace photo'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    pickDestinationPhoto = () async =>
        PickedPhoto('notes.jpg', Uint8List.fromList(utf8.encode('text')));
    await tester.tap(find.text('Replace photo'));
    await tester.pumpAndSettle();
    expect(find.text('Choose a JPEG, PNG or WebP photo.'), findsOneWidget);

    expect(requests, 0);
  });
}
