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
final _gif89 = Uint8List.fromList(utf8.encode('GIF89a\x01\x00\x01\x00\x00\x00\x00;'));
final _gif87 = Uint8List.fromList(utf8.encode('GIF87a\x01\x00\x01\x00\x00\x00\x00;'));
final _webm = Uint8List.fromList([0x1A, 0x45, 0xDF, 0xA3, 0x9F, 0x42, 0x86, 0x81]);
const _newUrl =
    'https://res.cloudinary.com/demo/image/upload/lakbay/destinations/6/beach.jpg';
const _newVideoUrl =
    'https://res.cloudinary.com/demo/video/upload/v1/lakbay/destinations/6/beach.mp4';

Uint8List _mp4WithDuration(double seconds, {int timescale = 1000}) {
  final durationUnits = (seconds * timescale).round();
  final mvhd = ByteData(108);
  mvhd.setUint32(0, 108);
  mvhd.setUint8(4, 0x6D); // m
  mvhd.setUint8(5, 0x76); // v
  mvhd.setUint8(6, 0x68); // h
  mvhd.setUint8(7, 0x64); // d
  mvhd.setUint32(8 + 12, timescale);
  mvhd.setUint32(8 + 16, durationUnits);
  final moovHeader = ByteData(8);
  moovHeader.setUint32(0, 8 + mvhd.lengthInBytes);
  moovHeader.setUint8(4, 0x6D); // m
  moovHeader.setUint8(5, 0x6F); // o
  moovHeader.setUint8(6, 0x6F); // o
  moovHeader.setUint8(7, 0x76); // v
  return Uint8List.fromList([
    0, 0, 0, 24, 0x66, 0x74, 0x79, 0x70, 0x6D, 0x70, 0x34, 0x32,
    0, 0, 0, 0, 0x6D, 0x70, 0x34, 0x32, 0x69, 0x73, 0x6F, 0x6D,
    ...moovHeader.buffer.asUint8List(),
    ...mvhd.buffer.asUint8List(),
  ]);
}
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
  final realMediaPicker = pickDestinationMedia;
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    adminIsSaving.value = false;
  });
  tearDown(() {
    pickDestinationPhoto = realPicker;
    pickDestinationMedia = realMediaPicker;
  });

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

  test('detectMediaContentType and parseMp4DurationSeconds validate media formats', () {
    expect(detectMediaContentType(_jpeg), 'image/jpeg');
    expect(detectMediaContentType(_gif89), 'image/gif');
    expect(detectMediaContentType(_gif87), 'image/gif');
    expect(detectMediaContentType(_mp4WithDuration(9.5)), 'video/mp4');
    expect(detectMediaContentType(_webm), 'video/webm');
    expect(detectMediaContentType(Uint8List.fromList(utf8.encode('plain'))), isNull);

    expect(parseMp4DurationSeconds(_mp4WithDuration(12.25)), closeTo(12.25, 0.01));
    expect(parseMp4DurationSeconds(_mp4WithDuration(18.5)), closeTo(18.5, 0.01));
    expect(parseMp4DurationSeconds(Uint8List.fromList([0, 0, 0, 12, 0x66, 0x74, 0x79, 0x70, 0, 0, 0, 0])), isNull);
  });

  testWidgets('UploadMediaButton rejects >15s MP4 and >10 MB GIF before calling API', (
    tester,
  ) async {
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

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: UploadMediaButton(
              api: api,
              destination: _destination,
              onUploaded: (_) {},
            ),
          ),
        ),
      ),
    );

    // >15s MP4 rejected locally
    pickDestinationMedia = () async => PickedPhoto('long.mp4', _mp4WithDuration(18.0));
    await tester.tap(find.text('Upload GIF / video'));
    await tester.pumpAndSettle();
    expect(find.textContaining('must be 15 seconds or shorter'), findsOneWidget);

    // >10 MB GIF rejected locally
    final hugeGif = Uint8List(destinationMediaImageMaxBytes + 1);
    hugeGif.setRange(0, _gif89.length, _gif89);
    pickDestinationMedia = () async => PickedPhoto('huge.gif', hugeGif);
    await tester.tap(find.text('Upload GIF / video'));
    await tester.pumpAndSettle();
    expect(find.textContaining('The limit is 10 MB.'), findsOneWidget);

    expect(requests, 0);
  });

  testWidgets('UploadMediaButton shows Video Clip Preview Card and posts to /media', (
    tester,
  ) async {
    final requests = <http.BaseRequest>[];
    String? sentBody;
    final api = ApiService(
      client: MockClient((request) async {
        requests.add(request);
        sentBody = latin1.decode(request.bodyBytes);
        return http.Response(
          jsonEncode({
            ..._destination,
            'media_url': _newVideoUrl,
            'media_type': 'video',
            'media_duration_seconds': 9.5,
          }),
          200,
        );
      }),
      tokenProvider: () async => 'test-access',
      apiBaseUrl: 'http://lakbay.test/api/v1',
    );
    addTearDown(api.close);

    Map<String, dynamic>? uploaded;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: UploadMediaButton(
              api: api,
              destination: _destination,
              onUploaded: (saved) => uploaded = saved,
            ),
          ),
        ),
      ),
    );

    pickDestinationMedia = () async => PickedPhoto('clip.mp4', _mp4WithDuration(9.5));
    await tester.tap(find.text('Upload GIF / video'));
    await tester.pumpAndSettle();

    expect(find.text('Upload video clip for Dahican Beach?'), findsOneWidget);
    expect(find.text('MP4'), findsOneWidget);
    expect(find.textContaining('9.5s'), findsWidgets);
    await tester.tap(find.text('Upload media'));
    await tester.pumpAndSettle();

    expect(requests, hasLength(1));
    expect(requests.single.method, 'POST');
    expect(requests.single.url.path, '/api/v1/destinations/6/media');
    expect(sentBody, contains('name="file"; filename="clip.mp4"'));
    expect(sentBody, contains('content-type: video/mp4'));
    expect(uploaded?['media_url'], _newVideoUrl);
    expect(uploaded?['media_type'], 'video');
    expect(find.text('Media updated for Dahican Beach.'), findsOneWidget);
    expect(adminIsSaving.value, isFalse);
  });
}
