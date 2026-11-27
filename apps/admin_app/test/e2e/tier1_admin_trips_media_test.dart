import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lakbay_admin/screens/destination_candidates_screen.dart';
import 'package:lakbay_admin/screens/destination_editor.dart';
import 'package:lakbay_admin/screens/destinations_screen.dart';
import 'package:lakbay_admin/screens/trips_screen.dart';
import 'package:lakbay_admin/widgets/admin_widgets.dart';
import 'package:lakbay_admin/widgets/destination_photo_upload.dart';

import 'admin_e2e_harness.dart';

void main() {
  setUp(() async {
    await initAdminE2eEnvironment();
  });

  group('Tier 1 — F6 Admin Trip Completion Lifecycle (R6)', () {
    testWidgets(
      'TripsScreen lists planned, ongoing, completed, and archived trips with summary badges, owner, budget/est cost, dates, and stops',
      (tester) async {
        setDesktopViewport(tester);
        final backend = MockAdminBackend(
          trips: [
            davaoTrip(
              tripId: 1,
              title: 'Davao City Heritage Walk',
              status: 'planned',
              ownerName: 'Maria Santos',
              ownerEmail: 'maria@lakbay.test',
              travelerCount: 2,
              totalBudget: 6000,
              estimatedTotalCost: 4200,
              startDate: '2026-12-01',
              endDate: '2026-12-02',
              destinationNames: const ['People\'s Park', 'Davao Museum'],
            ),
            davaoTrip(
              tripId: 2,
              title: 'Mt. Apo Highlands Trek',
              status: 'ongoing',
              ownerName: 'Juan Dela Cruz',
              ownerEmail: 'juan@lakbay.test',
              travelerCount: 4,
              totalBudget: 14000,
              estimatedTotalCost: 11800,
              startDate: '2026-11-26',
              endDate: '2026-11-28',
              destinationNames: const ['Eden Nature Park', 'Mount Apo'],
            ),
            davaoTrip(
              tripId: 3,
              title: 'Samal Island Weekend',
              status: 'completed',
              ownerName: 'Ana Reyes',
              ownerEmail: 'ana@lakbay.test',
              travelerCount: 3,
              totalBudget: 9500,
              estimatedTotalCost: 8100,
              startDate: '2026-11-20',
              endDate: '2026-11-22',
              completedAt: '2026-11-25T14:30:00Z',
              destinationNames: const ['Hagimit Falls', 'Talikud Island'],
            ),
            davaoTrip(
              tripId: 4,
              title: 'Mati Dahican Surf Camp',
              status: 'archived',
              ownerName: 'Carlo Lim',
              ownerEmail: 'carlo@lakbay.test',
              travelerCount: 1,
              totalBudget: 5000,
              estimatedTotalCost: 4500,
              startDate: '2026-10-10',
              endDate: '2026-10-12',
              destinationNames: const ['Dahican Beach'],
            ),
          ],
        );

        await tester.pumpWidget(
          MaterialApp(home: Scaffold(body: TripsScreen(api: backend.createApi()))),
        );
        await tester.pumpAndSettle();

        expect(find.text('Total trips: 4'), findsOneWidget);
        expect(find.text('Showing: 4 of 4'), findsOneWidget);

        expect(find.text('Davao City Heritage Walk'), findsOneWidget);
        expect(find.text('Mt. Apo Highlands Trek'), findsOneWidget);
        expect(find.text('Samal Island Weekend'), findsOneWidget);
        expect(find.text('Mati Dahican Surf Camp'), findsOneWidget);

        expect(find.text('Owner: Maria Santos (maria@lakbay.test)'), findsOneWidget);
        expect(find.text('Owner: Ana Reyes (ana@lakbay.test)'), findsOneWidget);
        expect(find.textContaining('Budget: PHP 9500 • Est. Cost: PHP 8100'), findsOneWidget);
        expect(find.textContaining('2026-11-20 to 2026-11-22'), findsOneWidget);
        expect(find.text('Stops: Hagimit Falls → Talikud Island'), findsOneWidget);
      },
    );

    testWidgets(
      'Filtering by completed status dropdown sends status=completed query param and renders completed trips',
      (tester) async {
        setDesktopViewport(tester);
        final backend = MockAdminBackend(
          trips: [
            davaoTrip(tripId: 1, title: 'Planned Trip', status: 'planned'),
            davaoTrip(
              tripId: 2,
              title: 'Completed Samal Getaway',
              status: 'completed',
              completedAt: '2026-11-25T10:00:00Z',
            ),
          ],
        );

        await tester.pumpWidget(
          MaterialApp(home: Scaffold(body: TripsScreen(api: backend.createApi()))),
        );
        await tester.pumpAndSettle();

        expect(find.text('Planned Trip'), findsOneWidget);
        expect(find.text('Completed Samal Getaway'), findsOneWidget);

        await tester.tap(find.byType(DropdownButton<String>));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Completed').last);
        await tester.pumpAndSettle();

        final tripRequests = backend.requestsTo('/admin/trips', method: 'GET');
        expect(tripRequests.last.queryParameters['status'], 'completed');
        expect(find.text('Completed Samal Getaway'), findsOneWidget);
        expect(find.text('Planned Trip'), findsNothing);
        expect(find.text('Showing: 1 of 1'), findsOneWidget);
      },
    );

    testWidgets(
      'Completed trip displays completed_at timestamp and capitalized Completed status badge (M4)',
      (tester) async {
        setDesktopViewport(tester);
        final backend = MockAdminBackend(
          trips: [
            davaoTrip(
              tripId: 33,
              title: 'Eden & Malagos Completed Tour',
              status: 'completed',
              startDate: '2026-11-18',
              endDate: '2026-11-19',
              completedAt: '2026-11-25T14:30:00Z',
            ),
          ],
        );

        await tester.pumpWidget(
          MaterialApp(home: Scaffold(body: TripsScreen(api: backend.createApi()))),
        );
        await tester.pumpAndSettle();

        // M4 contract: status badge is capitalized 'Completed' and completed_at is rendered.
        expect(
          find.byWidgetPredicate(
            (widget) => widget is AdminBadge && widget.label == 'Completed',
          ),
          findsOneWidget,
        );
        expect(find.textContaining('2026-11-25'), findsOneWidget);
      },
    );

    testWidgets(
      'Search query uses 350ms debounce and Clear search resets query and offset',
      (tester) async {
        setDesktopViewport(tester);
        final backend = MockAdminBackend(
          trips: [
            davaoTrip(
              tripId: 1,
              title: 'Samal Coastal Hopping',
              ownerName: 'Elena Cruz',
            ),
            davaoTrip(
              tripId: 2,
              title: 'Toril Highland Retreat',
              ownerName: 'Marco Diaz',
            ),
          ],
        );

        await tester.pumpWidget(
          MaterialApp(home: Scaffold(body: TripsScreen(api: backend.createApi()))),
        );
        await tester.pumpAndSettle();
        expect(backend.requestsTo('/admin/trips'), hasLength(1));

        await enterFieldByLabel(tester, 'Search trips', 'Samal');
        // Before 350ms debounce fires, no new request should be issued.
        await tester.pump(const Duration(milliseconds: 200));
        expect(backend.requestsTo('/admin/trips'), hasLength(1));

        await tester.pump(const Duration(milliseconds: 200));
        await tester.pumpAndSettle();

        final searchReq = backend.requestsTo('/admin/trips').last;
        expect(searchReq.queryParameters['search'], 'Samal');
        expect(searchReq.queryParameters['offset'], '0');
        expect(find.text('Samal Coastal Hopping'), findsOneWidget);
        expect(find.text('Toril Highland Retreat'), findsNothing);

        await tester.tap(find.byTooltip('Clear search'));
        await tester.pumpAndSettle();

        final resetReq = backend.requestsTo('/admin/trips').last;
        expect(resetReq.queryParameters.containsKey('search'), isFalse);
        expect(resetReq.queryParameters['offset'], '0');
        expect(find.text('Samal Coastal Hopping'), findsOneWidget);
        expect(find.text('Toril Highland Retreat'), findsOneWidget);
      },
    );

    testWidgets(
      'Pagination renders Next and Previous when matching_trips > 25 and fetches offset=25 and offset=0',
      (tester) async {
        setDesktopViewport(tester);
        final backend = MockAdminBackend(
          trips: [
            for (var i = 1; i <= 30; i++)
              davaoTrip(tripId: i, title: 'Davao Trip #$i'),
          ],
        );

        await tester.pumpWidget(
          MaterialApp(home: Scaffold(body: TripsScreen(api: backend.createApi()))),
        );
        await tester.pumpAndSettle();

        expect(find.text('Total trips: 30'), findsOneWidget);
        expect(find.text('Showing: 25 of 30'), findsOneWidget);

        final prevBefore = tester.widget<OutlinedButton>(
          find.widgetWithText(OutlinedButton, 'Previous'),
        );
        final nextBefore = tester.widget<OutlinedButton>(
          find.widgetWithText(OutlinedButton, 'Next'),
        );
        expect(prevBefore.onPressed, isNull);
        expect(nextBefore.onPressed, isNotNull);

        await tapVisible(tester, find.widgetWithText(OutlinedButton, 'Next'));
        await tester.pumpAndSettle();

        expect(
          backend.requestsTo('/admin/trips').last.queryParameters['offset'],
          '25',
        );
        expect(find.text('Showing: 5 of 30'), findsOneWidget);
        expect(find.text('Davao Trip #26'), findsOneWidget);

        await tapVisible(tester, find.widgetWithText(OutlinedButton, 'Previous'));
        await tester.pumpAndSettle();

        expect(
          backend.requestsTo('/admin/trips').last.queryParameters['offset'],
          '0',
        );
        expect(find.text('Showing: 25 of 30'), findsOneWidget);
      },
    );
  });

  group('Tier 1 — F7 Admin Destinations, Media & Candidates (R7)', () {
    testWidgets(
      'DestinationsScreen lists Davao destinations, searches/filters by category, and opens detail view',
      (tester) async {
        setDesktopViewport(tester);
        final backend = MockAdminBackend(
          destinations: [
            davaoDestination(
              id: 1,
              name: 'Eden Nature Park',
              category: 'Nature',
              location: 'Barangay Eden, Toril, Davao City',
            ),
            davaoDestination(
              id: 2,
              name: 'Hagimit Falls',
              district: 'Samal Island',
              category: 'Waterfall',
              location: 'Brgy. Cawag, Island Garden City of Samal',
            ),
            davaoDestination(
              id: 3,
              name: 'Dahican Beach',
              district: 'Mati',
              category: 'Beach',
              location: 'Dahican, City of Mati, Davao Oriental',
            ),
          ],
        );

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(body: DestinationsScreen(api: backend.createApi())),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('3 of 3 active destinations'), findsOneWidget);
        expect(find.text('Eden Nature Park'), findsOneWidget);
        expect(find.text('Hagimit Falls'), findsOneWidget);

        // Filter by Category dropdown
        await tapVisible(tester, find.byType(DropdownButtonFormField<String>));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Waterfall').last);
        await tester.pumpAndSettle();

        expect(find.text('1 of 3 active destinations'), findsOneWidget);
        expect(find.text('Hagimit Falls'), findsOneWidget);
        expect(find.text('Eden Nature Park'), findsNothing);

        // Reset filters and search
        await tapVisible(tester, find.widgetWithText(TextButton, 'Reset filters'));
        await tester.pumpAndSettle();
        expect(find.text('3 of 3 active destinations'), findsOneWidget);

        await enterFieldByLabel(tester, 'Search destinations', 'Eden');
        await tester.pumpAndSettle();
        expect(find.text('1 of 3 active destinations'), findsOneWidget);

        // Open detail view
        await tapVisible(tester, find.widgetWithText(TextButton, 'View').first);
        await tester.pumpAndSettle();

        expect(find.text('Back to destinations'), findsOneWidget);
        expect(find.text('Edit destination'), findsOneWidget);
        expect(find.text('Replace photo'), findsOneWidget);
        expect(find.text('Upload GIF / video'), findsOneWidget);
      },
    );

    testWidgets(
      'DestinationEditor creates a new Davao destination (POST /destinations) with required fields, coordinates, hours, fee, and description',
      (tester) async {
        setDesktopViewport(tester);
        final backend = MockAdminBackend();
        Map<String, dynamic>? saved;

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: DestinationEditor(
                api: backend.createApi(),
                destination: null,
                onSaved: (record) => saved = record,
                onCancel: () {},
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        await enterFieldByLabel(
          tester,
          'Destination name *',
          'Malagos Garden Resort',
        );
        await enterFieldByLabel(tester, 'District', 'Baguio District');
        await enterFieldByLabel(
          tester,
          'Description',
          'Botanical sanctuary, bird show, and chocolate museum in Davao City.',
        );
        await enterFieldByLabel(
          tester,
          'Location / address',
          'Calinan-Baguio Rd, Davao City',
        );
        await enterFieldByLabel(tester, 'Latitude *', '7.1865');
        await enterFieldByLabel(tester, 'Longitude *', '125.4321');
        await enterFieldByLabel(tester, 'Operating hours', '8:00 AM - 5:00 PM');
        await enterFieldByLabel(tester, 'Entrance fee', 'PHP 250 / person');

        await tapVisible(
          tester,
          find.widgetWithText(FilledButton, 'Save destination'),
        );
        await tester.pumpAndSettle();

        final posts = backend.requestsTo('/destinations', method: 'POST');
        expect(posts, hasLength(1));
        final payload = posts.single.jsonBody;
        expect(payload['name'], 'Malagos Garden Resort');
        expect(payload['district'], 'Baguio District');
        expect(payload['lat'], 7.1865);
        expect(payload['lng'], 125.4321);
        expect(payload['operating_hours'], '8:00 AM - 5:00 PM');
        expect(payload['entrance_fee'], 'PHP 250 / person');
        expect(
          payload['description'],
          'Botanical sanctuary, bird show, and chocolate museum in Davao City.',
        );
        expect(saved?['name'], 'Malagos Garden Resort');
      },
    );

    testWidgets(
      'DestinationEditor edits existing Davao destination with verified HoursSection, PricesSection, ActivitiesSection, and source attribution',
      (tester) async {
        setDesktopViewport(tester);
        final backend = MockAdminBackend(
          destinations: [davaoDestination(id: 12, name: 'Eden Nature Park')],
        );

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: DestinationEditor(
                api: backend.createApi(),
                destination: backend.destinations.single,
                onSaved: (_) {},
                onCancel: () {},
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        // Attribution fields + route endpoint source link on main editor
        await enterFieldByLabel(
          tester,
          'Photo / media credit',
          'City Tourism Operations Office',
        );
        await enterFieldByLabel(tester, 'License', 'CC-BY-4.0');
        await enterFieldByLabel(
          tester,
          'Attribution source URL',
          'https://tourism.davaocity.gov.ph/eden-photo',
        );
        await enterFieldByLabel(tester, 'Endpoint latitude', '7.0185');
        await enterFieldByLabel(tester, 'Endpoint longitude', '125.4320');
        await enterFieldByLabel(
          tester,
          'Source link',
          'https://www.openstreetmap.org/node/538858577',
        );

        await tapVisible(
          tester,
          find.widgetWithText(FilledButton, 'Save destination'),
        );
        await tester.pumpAndSettle();

        final patches = backend.requestsTo('/destinations/12', method: 'PATCH');
        expect(patches, hasLength(1));
        final patchBody = patches.single.jsonBody;
        expect(patchBody['image_credit'], 'City Tourism Operations Office');
        expect(patchBody['image_license'], 'CC-BY-4.0');
        expect(
          patchBody['image_source_url'],
          'https://tourism.davaocity.gov.ph/eden-photo',
        );
        expect(
          patchBody['arrival_source_url'],
          'https://www.openstreetmap.org/node/538858577',
        );

        // HoursSection verification & save
        await enterFieldByLabel(
          tester,
          'Where these hours came from (web address)',
          'https://edennaturepark.com.ph/hours',
        );
        await tapVisible(tester, find.byKey(const ValueKey('hours-verified-today')));
        await tester.pump();
        await tapVisible(tester, find.byKey(const ValueKey('hours-save')));
        await tester.pumpAndSettle();

        final hoursPut = backend.requestsTo('/destinations/12/hours', method: 'PUT');
        expect(hoursPut, hasLength(1));
        expect(
          hoursPut.single.jsonBody['hours_source_url'],
          'https://edennaturepark.com.ph/hours',
        );
        expect(find.text('Hours saved.'), findsOneWidget);

        // PricesSection verification & save
        await tapVisible(tester, find.byKey(const ValueKey('prices-add')));
        await tester.pump();
        await tester.enterText(
          find.byKey(const ValueKey('price-amount-0')),
          '220',
        );
        await enterFieldByLabel(
          tester,
          'Where these prices came from (web address)',
          'https://edennaturepark.com.ph/rates',
        );
        await tapVisible(tester, find.byKey(const ValueKey('prices-verified-today')));
        await tester.pump();
        await tapVisible(tester, find.byKey(const ValueKey('prices-save')));
        await tester.pumpAndSettle();

        final pricesPut = backend.requestsTo('/destinations/12/prices', method: 'PUT');
        expect(pricesPut, hasLength(1));
        expect(
          pricesPut.single.jsonBody['fees_source_url'],
          'https://edennaturepark.com.ph/rates',
        );
        expect(find.text('Prices saved.'), findsOneWidget);

        // ActivitiesSection verification & save
        await tapVisible(tester, find.byKey(const ValueKey('activities-add')));
        await tester.pump();
        await tester.ensureVisible(find.byKey(const ValueKey('activity-name-0')));
        await tester.enterText(
          find.byKey(const ValueKey('activity-name-0')),
          'Skycycle Trail',
        );
        await tapVisible(tester, find.byKey(const ValueKey('activities-save')));
        await tester.pumpAndSettle();

        final actPut = backend.requestsTo(
          '/destinations/12/activities',
          method: 'PUT',
        );
        expect(actPut, hasLength(1));
        expect(
          (actPut.single.jsonBody['activities'] as List).single['name'],
          'Skycycle Trail',
        );
        expect(find.text('Activities saved.'), findsOneWidget);
      },
    );

    testWidgets(
      'ReplacePhotoButton uploads valid JPEG, PNG, and WebP photos to /destinations/{id}/image without leaving form dirty',
      (tester) async {
        setDesktopViewport(tester);
        final backend = MockAdminBackend(
          destinations: [davaoDestination(id: 12, name: 'Eden Nature Park')],
        );

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: DestinationEditor(
                api: backend.createApi(),
                destination: backend.destinations.single,
                onSaved: (_) {},
                onCancel: () {},
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        final samples = <({String filename, String contentType, Uint8List bytes})>[
          (
            filename: 'eden.jpg',
            contentType: 'image/jpeg',
            bytes: validJpegBytes(),
          ),
          (
            filename: 'eden.png',
            contentType: 'image/png',
            bytes: validPngBytes(),
          ),
          (
            filename: 'eden.webp',
            contentType: 'image/webp',
            bytes: validWebpBytes(),
          ),
        ];

        for (final sample in samples) {
          installPhotoPickerOverride(
            () async => PickedPhoto(sample.filename, sample.bytes),
          );
          await tapVisible(tester, find.text('Replace photo'));
          await tester.pumpAndSettle();
          expect(
            find.text('Use this photo for Eden Nature Park?'),
            findsOneWidget,
          );
          await tester.tap(find.text('Upload photo'));
          await tester.pumpAndSettle();

          final lastReq = backend.requestsTo('/destinations/12/image').last;
          expect(lastReq.method, 'POST');
          expect(
            lastReq.body,
            contains('name="file"; filename="${sample.filename}"'),
          );
          expect(
            lastReq.body.toLowerCase(),
            contains('content-type: ${sample.contentType}'),
          );
          expect(adminHasUnsavedChanges.value, isFalse);
          expect(find.text('No unsaved changes'), findsOneWidget);
        }

        expect(backend.requestsTo('/destinations/12/image'), hasLength(3));
      },
    );

    testWidgets(
      'UploadMediaButton accepts valid GIF (GIF89a <=10 MB) and MP4 (ftyp <=15 MB, <=15s) and uploads to /destinations/{id}/media (M5)',
      (tester) async {
        setDesktopViewport(tester);
        expect(detectMediaContentType(validGif89aBytes()), 'image/gif');
        expect(detectMediaContentType(validMp4Bytes(durationSeconds: 8)), 'video/mp4');
        expect(detectMediaContentType(validWebmBytes()), 'video/webm');

        final backend = MockAdminBackend(
          destinations: [davaoDestination(id: 12, name: 'Eden Nature Park')],
        );

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: DestinationEditor(
                api: backend.createApi(),
                destination: backend.destinations.single,
                onSaved: (_) {},
                onCancel: () {},
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        // 1. Valid GIF89a upload
        installMediaPickerOverride(
          () async => PickedPhoto('eden-loop.gif', validGif89aBytes()),
        );
        await tapVisible(tester, find.text('Upload GIF / video'));
        await tester.pumpAndSettle();
        expect(find.text('Upload GIF for Eden Nature Park?'), findsOneWidget);
        await tester.tap(find.text('Upload media'));
        await tester.pumpAndSettle();

        var mediaReqs = backend.requestsTo('/destinations/12/media');
        expect(mediaReqs, hasLength(1));
        expect(mediaReqs.last.body, contains('name="file"; filename="eden-loop.gif"'));
        expect(mediaReqs.last.body.toLowerCase(), contains('content-type: image/gif'));
        expect(find.text('Attached media clip'), findsOneWidget);
        expect(
          find.byWidgetPredicate((w) => w is AdminBadge && w.label == 'GIF'),
          findsOneWidget,
        );
        expect(adminHasUnsavedChanges.value, isFalse);

        // 2. Valid <=15s MP4 upload
        installMediaPickerOverride(
          () async => PickedPhoto(
            'eden-drone.mp4',
            validMp4Bytes(durationSeconds: 8.0),
          ),
        );
        await tapVisible(tester, find.text('Upload GIF / video'));
        await tester.pumpAndSettle();
        expect(
          find.text('Upload video clip for Eden Nature Park?'),
          findsOneWidget,
        );
        await tester.tap(find.text('Upload media'));
        await tester.pumpAndSettle();

        mediaReqs = backend.requestsTo('/destinations/12/media');
        expect(mediaReqs, hasLength(2));
        expect(mediaReqs.last.body, contains('name="file"; filename="eden-drone.mp4"'));
        expect(mediaReqs.last.body.toLowerCase(), contains('content-type: video/mp4'));
        expect(
          find.byWidgetPredicate(
            (w) => w is AdminBadge && w.label == 'Video (8.0s)',
          ),
          findsOneWidget,
        );
        expect(adminHasUnsavedChanges.value, isFalse);
      },
    );

    testWidgets(
      'DestinationCandidatesScreen reviews staged Davao OSM candidate, saves edits (PATCH), and publishes (POST .../publish)',
      (tester) async {
        setDesktopViewport(tester);
        final backend = MockAdminBackend(
          candidates: [davaoCandidate(candidateId: 41, name: 'Hagimit Falls')],
        );

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: DestinationCandidatesScreen(api: backend.createApi()),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('Hagimit Falls'), findsOneWidget);
        await tester.tap(find.text('Hagimit Falls'));
        await tester.pumpAndSettle();

        await enterFieldByLabel(
          tester,
          'Description',
          'Verified Samal waterfall with clear pools and shaded cottages.',
        );
        await tapVisible(
          tester,
          find.byWidgetPredicate((w) => w is DropdownButtonFormField<String?>).last,
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Public').last);
        await tester.pumpAndSettle();
        await enterFieldByLabel(
          tester,
          'Visitor access source URL',
          'https://samalcity.gov.ph/hagimit',
        );
        await tapVisible(
          tester,
          find.widgetWithText(CheckboxListTile, 'I checked this access evidence'),
        );
        await tester.pumpAndSettle();

        // Publish button disabled while dirty
        final publishWhileDirty = tester.widget<OutlinedButton>(
          find.widgetWithText(OutlinedButton, 'Publish destination'),
        );
        expect(publishWhileDirty.onPressed, isNull);
        expect(find.text('Save changes before publishing.'), findsOneWidget);

        await tapVisible(tester, find.widgetWithText(FilledButton, 'Save review'));
        await tester.pumpAndSettle();

        final patches = backend.requestsTo(
          '/admin/destination-candidates/41',
          method: 'PATCH',
        );
        expect(patches, hasLength(1));
        expect(patches.single.jsonBody['access_policy'], 'public');
        expect(
          patches.single.jsonBody['access_source_url'],
          'https://samalcity.gov.ph/hagimit',
        );
        expect(patches.single.jsonBody['access_verified_at'], isNotNull);
        expect(find.text('Candidate review saved.'), findsOneWidget);

        await tapVisible(
          tester,
          find.widgetWithText(OutlinedButton, 'Publish destination'),
        );
        await tester.pumpAndSettle();

        final publishes = backend.requestsTo(
          '/admin/destination-candidates/41/publish',
          method: 'POST',
        );
        expect(publishes, hasLength(1));
        expect(find.text('Destination published.'), findsOneWidget);
        expect(backend.destinations, hasLength(1));
      },
    );
  });
}
