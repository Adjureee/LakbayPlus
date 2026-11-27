import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:lakbay_admin/main.dart';
import 'package:lakbay_admin/screens/destination_candidates_screen.dart';
import 'package:lakbay_admin/screens/destination_editor.dart';
import 'package:lakbay_admin/screens/login_screen.dart';
import 'package:lakbay_admin/screens/trips_screen.dart';
import 'package:lakbay_admin/services/api_service.dart';
import 'package:lakbay_admin/services/session_manager.dart';
import 'package:lakbay_admin/widgets/admin_widgets.dart';
import 'package:lakbay_admin/widgets/destination_photo_upload.dart';

import 'admin_e2e_harness.dart';

void main() {
  setUp(() async {
    await initAdminE2eEnvironment();
  });

  group('Tier 2 — F6 Admin Trip Boundaries & Auth Guard (R6)', () {
    testWidgets('Empty trip directory renders No trips found', (tester) async {
      setDesktopViewport(tester);
      final backend = MockAdminBackend(trips: const []);

      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: TripsScreen(api: backend.createApi()))),
      );
      await tester.pumpAndSettle();

      expect(find.text('Total trips: 0'), findsOneWidget);
      expect(find.text('Showing: 0 of 0'), findsOneWidget);
      expect(find.text('No trips found'), findsOneWidget);
    });

    testWidgets(
      'Older completed trip with completed_at null renders cleanly without crashing or showing literal null',
      (tester) async {
        setDesktopViewport(tester);
        final backend = MockAdminBackend(
          trips: [
            davaoTrip(
              tripId: 77,
              title: 'Legacy Samal Day Trip',
              status: 'completed',
              startDate: null,
              endDate: null,
              completedAt: null,
              destinationNames: const [],
            ),
          ],
        );

        await tester.pumpWidget(
          MaterialApp(home: Scaffold(body: TripsScreen(api: backend.createApi()))),
        );
        await tester.pumpAndSettle();

        expect(find.text('Legacy Samal Day Trip'), findsOneWidget);
        expect(find.textContaining('null'), findsNothing);
      },
    );

    testWidgets(
      'Status filter reset from completed to all omits status query param and restores all trips',
      (tester) async {
        setDesktopViewport(tester);
        final backend = MockAdminBackend(
          trips: [
            davaoTrip(tripId: 1, title: 'Active Trip', status: 'planned'),
            davaoTrip(
              tripId: 2,
              title: 'Finished Trip',
              status: 'completed',
              completedAt: '2026-11-25T12:00:00Z',
            ),
          ],
        );

        await tester.pumpWidget(
          MaterialApp(home: Scaffold(body: TripsScreen(api: backend.createApi()))),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.byType(DropdownButton<String>));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Completed').last);
        await tester.pumpAndSettle();
        expect(find.text('Active Trip'), findsNothing);
        expect(
          backend.requestsTo('/admin/trips').last.queryParameters['status'],
          'completed',
        );

        await tester.tap(find.byType(DropdownButton<String>));
        await tester.pumpAndSettle();
        await tester.tap(find.text('All statuses').last);
        await tester.pumpAndSettle();

        final resetReq = backend.requestsTo('/admin/trips').last;
        expect(resetReq.queryParameters.containsKey('status'), isFalse);
        expect(find.text('Active Trip'), findsOneWidget);
        expect(find.text('Finished Trip'), findsOneWidget);
      },
    );

    testWidgets(
      'API 500 error shows Could not load trips and Retry recovers cleanly on 200',
      (tester) async {
        setDesktopViewport(tester);
        final backend = MockAdminBackend(
          trips: [davaoTrip(tripId: 9, title: 'Davao Recovery Trip')],
        )..tripsErrorStatusCode = 500;

        await tester.pumpWidget(
          MaterialApp(home: Scaffold(body: TripsScreen(api: backend.createApi()))),
        );
        await tester.pumpAndSettle();

        expect(find.text('Could not load trips'), findsOneWidget);
        expect(find.widgetWithText(OutlinedButton, 'Retry'), findsOneWidget);

        backend.tripsErrorStatusCode = null;
        await tester.tap(find.widgetWithText(OutlinedButton, 'Retry'));
        await tester.pumpAndSettle();

        expect(find.text('Could not load trips'), findsNothing);
        expect(find.text('Davao Recovery Trip'), findsOneWidget);
      },
    );

    testWidgets(
      'Non-admin session is rejected across SessionManager, _AdminSessionGate, and ApiService 401 refresh',
      (tester) async {
        setDesktopViewport(tester);

        // 1. SessionManager.isLoggedIn returns false for traveler/user roles.
        await seedNonAdminSession(role: 'traveler');
        expect(await SessionManager.instance.isLoggedIn(), isFalse);

        await seedNonAdminSession(role: 'user');
        expect(await SessionManager.instance.isLoggedIn(), isFalse);

        // 2. _AdminSessionGate renders LoginScreen instead of TripsScreen on /trips.
        await tester.pumpWidget(const LakbayAdminApp(initialRoute: '/trips'));
        await tester.pumpAndSettle();
        expect(find.byType(LoginScreen), findsOneWidget);
        expect(find.byType(TripsScreen), findsNothing);

        // 3. ApiService 401 refresh with non-admin role rejects token rotation.
        final backend = MockAdminBackend()
          ..requireAuthRefreshOnce = true
          ..onRefresh = (_) async => http.Response(
            jsonEncode({
              'user': {
                'user_id': 99,
                'full_name': 'Traveler User',
                'email': 'traveler@lakbay.test',
                'role': 'traveler',
              },
              'tokens': {
                'access_token': 'new-traveler-token',
                'refresh_token': 'new-traveler-refresh',
              },
            }),
            200,
          );

        final api = backend.createApi(tokenProvider: SessionManager.instance.getToken);
        addTearDown(api.close);

        await expectLater(
          api.getAdminTrips(),
          throwsA(
            isA<ApiException>().having((e) => e.statusCode, 'statusCode', 401),
          ),
        );
        expect(await SessionManager.instance.isLoggedIn(), isFalse);
      },
    );
  });

  group('Tier 2 — F7 Media Validation, Editor & Candidate Boundaries (R7)', () {
    testWidgets(
      'GIF > 10 MB is rejected client-side before upload with 0 HTTP requests and 10 MB error message (M5)',
      (tester) async {
        setDesktopViewport(tester);
        final backend = MockAdminBackend(
          destinations: [davaoDestination(id: 12, name: 'Eden Nature Park')],
        );
        final api = backend.createApi();
        addTearDown(api.close);

        installMediaPickerOverride(
          () async => PickedPhoto('huge-loop.gif', oversizedGifBytes()),
        );

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: UploadMediaButton(
                api: api,
                destination: backend.destinations.single,
                onUploaded: (_) {},
              ),
            ),
          ),
        );

        await tester.tap(find.text('Upload GIF / video'));
        await tester.pumpAndSettle();

        expect(backend.requestsTo('/destinations/12/media'), isEmpty);
        expect(backend.requests, isEmpty);
        expect(find.textContaining('10 MB'), findsOneWidget);
      },
    );

    testWidgets(
      'MP4 and WebM > 15 MB and MP4 > 15s are rejected client-side before upload with 0 HTTP requests (M5)',
      (tester) async {
        setDesktopViewport(tester);
        final backend = MockAdminBackend(
          destinations: [davaoDestination(id: 12, name: 'Eden Nature Park')],
        );
        final api = backend.createApi();
        addTearDown(api.close);

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: UploadMediaButton(
                api: api,
                destination: backend.destinations.single,
                onUploaded: (_) {},
              ),
            ),
          ),
        );

        // 1. Oversized MP4 (> 15 MB)
        installMediaPickerOverride(
          () async => PickedPhoto('huge.mp4', oversizedMp4Bytes()),
        );
        await tester.tap(find.text('Upload GIF / video'));
        await tester.pumpAndSettle();
        expect(find.textContaining('15 MB'), findsOneWidget);

        // 2. Oversized WebM (> 15 MB)
        installMediaPickerOverride(
          () async => PickedPhoto('huge.webm', oversizedWebmBytes()),
        );
        await tester.tap(find.text('Upload GIF / video'));
        await tester.pumpAndSettle();
        expect(find.textContaining('15 MB'), findsOneWidget);

        // 3. Over-duration MP4 (> 15s)
        installMediaPickerOverride(
          () async => PickedPhoto(
            'too-long.mp4',
            validMp4Bytes(durationSeconds: 18.5),
          ),
        );
        await tester.tap(find.text('Upload GIF / video'));
        await tester.pumpAndSettle();
        expect(
          find.textContaining('15 seconds or shorter'),
          findsOneWidget,
        );

        expect(backend.requests, isEmpty);
      },
    );

    testWidgets(
      'Spoofed extension and invalid magic bytes are rejected before upload with 0 HTTP requests',
      (tester) async {
        setDesktopViewport(tester);
        final backend = MockAdminBackend(
          destinations: [davaoDestination(id: 12, name: 'Eden Nature Park')],
        );
        final api = backend.createApi();
        addTearDown(api.close);

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Column(
                children: [
                  ReplacePhotoButton(
                    api: api,
                    destination: backend.destinations.single,
                    onUploaded: (_) {},
                  ),
                  UploadMediaButton(
                    api: api,
                    destination: backend.destinations.single,
                    onUploaded: (_) {},
                  ),
                ],
              ),
            ),
          ),
        );

        installPhotoPickerOverride(
          () async => PickedPhoto('spoofed.jpg', spoofedBytes()),
        );
        await tester.tap(find.text('Replace photo'));
        await tester.pumpAndSettle();
        expect(find.text('Choose a JPEG, PNG or WebP photo.'), findsOneWidget);

        installMediaPickerOverride(
          () async => PickedPhoto('spoofed.gif', spoofedBytes()),
        );
        await tester.tap(find.text('Upload GIF / video'));
        await tester.pumpAndSettle();
        expect(
          find.text('Choose a JPEG, PNG, WebP, GIF, MP4, or WebM file.'),
          findsOneWidget,
        );

        installMediaPickerOverride(
          () async => PickedPhoto('fake.mp4', spoofedBytes()),
        );
        await tester.tap(find.text('Upload GIF / video'));
        await tester.pumpAndSettle();

        expect(backend.requests, isEmpty);
      },
    );

    testWidgets(
      'Empty 0-byte file is rejected before upload with 0 HTTP requests',
      (tester) async {
        setDesktopViewport(tester);
        final backend = MockAdminBackend(
          destinations: [davaoDestination(id: 12, name: 'Eden Nature Park')],
        );
        final api = backend.createApi();
        addTearDown(api.close);

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Column(
                children: [
                  ReplacePhotoButton(
                    api: api,
                    destination: backend.destinations.single,
                    onUploaded: (_) {},
                  ),
                  UploadMediaButton(
                    api: api,
                    destination: backend.destinations.single,
                    onUploaded: (_) {},
                  ),
                ],
              ),
            ),
          ),
        );

        installPhotoPickerOverride(
          () async => PickedPhoto('empty.jpg', emptyBytes()),
        );
        await tester.tap(find.text('Replace photo'));
        await tester.pumpAndSettle();
        expect(find.text('Choose a JPEG, PNG or WebP photo.'), findsOneWidget);

        installMediaPickerOverride(
          () async => PickedPhoto('empty.mp4', emptyBytes()),
        );
        await tester.tap(find.text('Upload GIF / video'));
        await tester.pumpAndSettle();
        expect(
          find.text('Choose a JPEG, PNG, WebP, GIF, MP4, or WebM file.'),
          findsOneWidget,
        );

        expect(backend.requests, isEmpty);
      },
    );

    testWidgets(
      'DestinationEditor unsaved-changes guard and optional fields remain null without placeholder fabrication',
      (tester) async {
        setDesktopViewport(tester);
        final backend = MockAdminBackend();
        var cancelled = 0;

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: DestinationEditor(
                api: backend.createApi(),
                destination: null,
                onSaved: (_) {},
                onCancel: () => cancelled++,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        // Enter minimal required fields only, test Keep editing, then Save.
        await enterFieldByLabel(
          tester,
          'Destination name *',
          'Mount Apo Trailhead',
        );
        expect(adminHasUnsavedChanges.value, isTrue);

        await tapVisible(tester, find.widgetWithText(OutlinedButton, 'Cancel'));
        await tester.pumpAndSettle();
        expect(find.text('Discard changes?'), findsOneWidget);
        await tester.tap(find.text('Keep editing'));
        await tester.pumpAndSettle();
        expect(cancelled, 0);
        expect(adminHasUnsavedChanges.value, isTrue);

        await enterFieldByLabel(tester, 'Latitude *', '6.9875');
        await enterFieldByLabel(tester, 'Longitude *', '125.2708');
        await tapVisible(
          tester,
          find.widgetWithText(FilledButton, 'Save destination'),
        );
        await tester.pumpAndSettle();

        final posts = backend.requestsTo('/destinations', method: 'POST');
        expect(posts, hasLength(1));
        final body = posts.single.jsonBody;
        expect(body['name'], 'Mount Apo Trailhead');
        expect(body['entrance_fee'], isNull);
        expect(body['overnight_fee'], isNull);
        expect(body['operating_hours'], isNull);
        expect(body['estimated_cost'], isNull);
        expect(adminHasUnsavedChanges.value, isFalse);

        // Now verify Discard changes path on a dirty form
        await enterFieldByLabel(tester, 'District', 'Digos');
        await tapVisible(tester, find.widgetWithText(OutlinedButton, 'Cancel'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Discard changes'));
        await tester.pumpAndSettle();

        expect(cancelled, 1);
        expect(adminHasUnsavedChanges.value, isFalse);
      },
    );

    testWidgets(
      'Candidate rejection validates minimum 5-char reason and displays outside-Region-XI warning banner',
      (tester) async {
        setDesktopViewport(tester);
        final backend = MockAdminBackend(
          candidates: [
            davaoCandidate(
              candidateId: 55,
              name: 'Far Boundary Peak',
              lat: 8.5,
              lng: 124.9,
              regionStatus: 'outside',
            ),
          ],
        );

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: DestinationCandidatesScreen(api: backend.createApi()),
            ),
          ),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.text('Far Boundary Peak'));
        await tester.pumpAndSettle();

        expect(
          find.text('Outside the Davao Region (Region XI): this cannot be published.'),
          findsOneWidget,
        );

        // Reject with < 5 chars -> client validation error, 0 reject requests
        await tapVisible(
          tester,
          find.widgetWithText(TextButton, 'Reject candidate'),
        );
        await tester.pumpAndSettle();
        await tester.enterText(
          find.widgetWithText(TextField, 'Reason for rejection'),
          'nope',
        );
        await tester.tap(find.widgetWithText(FilledButton, 'Reject'));
        await tester.pumpAndSettle();

        expect(
          find.text('Give a reason of at least five characters.'),
          findsOneWidget,
        );
        expect(
          backend.requestsTo('/admin/destination-candidates/55/reject'),
          isEmpty,
        );

        // Reject with >= 5 chars -> POST .../reject succeeds
        await tapVisible(
          tester,
          find.widgetWithText(TextButton, 'Reject candidate'),
        );
        await tester.pumpAndSettle();
        await tester.enterText(
          find.widgetWithText(TextField, 'Reason for rejection'),
          'Outside Davao Region XI boundary',
        );
        await tester.tap(find.widgetWithText(FilledButton, 'Reject'));
        await tester.pumpAndSettle();

        final rejects = backend.requestsTo(
          '/admin/destination-candidates/55/reject',
          method: 'POST',
        );
        expect(rejects, hasLength(1));
        expect(
          rejects.single.jsonBody['reason'],
          'Outside Davao Region XI boundary',
        );
        expect(find.text('Candidate rejected.'), findsOneWidget);
      },
    );
  });
}
