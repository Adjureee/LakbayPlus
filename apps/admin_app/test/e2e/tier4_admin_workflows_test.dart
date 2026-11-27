import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lakbay_admin/main.dart';
import 'package:lakbay_admin/screens/destination_candidates_screen.dart';
import 'package:lakbay_admin/screens/destinations_screen.dart';
import 'package:lakbay_admin/screens/login_screen.dart';
import 'package:lakbay_admin/screens/trips_screen.dart';
import 'package:lakbay_admin/widgets/admin_widgets.dart';
import 'package:lakbay_admin/widgets/destination_photo_upload.dart';

import 'admin_e2e_harness.dart';

void main() {
  setUp(() async {
    await initAdminE2eEnvironment();
  });

  group('Tier 4 — Real-World Davao Admin Workflows', () {
    testWidgets(
      'Workflow 1: Davao Region OSM Candidate Curation, Attribution, Structured Sub-sections & MP4 Media Upload',
      (tester) async {
        setDesktopViewport(tester);
        final backend = MockAdminBackend(
          candidates: [
            davaoCandidate(
              candidateId: 88,
              name: 'Hagimit Falls',
              district: 'Island Garden City of Samal',
              category: 'Waterfall',
              islandGroup: 'samal',
              regionStatus: 'inside',
            ),
          ],
        );

        // Step 1: Curate staged OSM candidate in DestinationCandidatesScreen
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: DestinationCandidatesScreen(api: backend.createApi()),
            ),
          ),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.text('Hagimit Falls'));
        await tester.pumpAndSettle();

        await enterFieldByLabel(
          tester,
          'Visitor purpose',
          'Multi-tiered freshwater falls and swimming lagoons in Samal.',
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
          'https://samalcity.gov.ph/tourism/hagimit-falls',
        );
        await tapVisible(
          tester,
          find.widgetWithText(CheckboxListTile, 'I checked this access evidence'),
        );
        await tester.pumpAndSettle();

        await tapVisible(tester, find.widgetWithText(FilledButton, 'Save review'));
        await tester.pumpAndSettle();
        expect(find.text('Candidate review saved.'), findsOneWidget);

        await tapVisible(
          tester,
          find.widgetWithText(OutlinedButton, 'Publish destination'),
        );
        await tester.pumpAndSettle();
        expect(find.text('Destination published.'), findsOneWidget);
        expect(backend.destinations, hasLength(1));

        // Step 2: Open published destination in DestinationsScreen -> edit & enrich
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(body: DestinationsScreen(api: backend.createApi())),
          ),
        );
        await tester.pumpAndSettle();

        await tapVisible(tester, find.widgetWithText(TextButton, 'View').first);
        await tester.pumpAndSettle();
        await tapVisible(
          tester,
          find.widgetWithText(FilledButton, 'Edit destination'),
        );
        await tester.pumpAndSettle();

        await enterFieldByLabel(
          tester,
          'Photo / media credit',
          'IGACOS Tourism Office',
        );
        await enterFieldByLabel(tester, 'License', 'CC-BY-4.0');
        await enterFieldByLabel(
          tester,
          'Attribution source URL',
          'https://samalcity.gov.ph/media/hagimit',
        );
        await tapVisible(
          tester,
          find.widgetWithText(FilledButton, 'Save destination'),
        );
        await tester.pumpAndSettle();
        expect(find.text('Destination saved.'), findsOneWidget);

        // Step 3: Enrich verified Hours, Prices, Activities, Poster & MP4 clip
        await tapVisible(
          tester,
          find.widgetWithText(FilledButton, 'Edit destination'),
        );
        await tester.pumpAndSettle();

        final destId = backend.destinations.single['destination_id'];

        await enterFieldByLabel(
          tester,
          'Where these hours came from (web address)',
          'https://samalcity.gov.ph/hagimit-hours',
        );
        await tapVisible(tester, find.byKey(const ValueKey('hours-verified-today')));
        await tester.pump();
        await tapVisible(tester, find.byKey(const ValueKey('hours-save')));
        await tester.pumpAndSettle();
        expect(find.text('Hours saved.'), findsOneWidget);

        await tapVisible(tester, find.byKey(const ValueKey('prices-add')));
        await tester.pump();
        await tester.enterText(
          find.byKey(const ValueKey('price-amount-0')),
          '40',
        );
        await enterFieldByLabel(
          tester,
          'Where these prices came from (web address)',
          'https://samalcity.gov.ph/hagimit-rates',
        );
        await tapVisible(tester, find.byKey(const ValueKey('prices-verified-today')));
        await tester.pump();
        await tapVisible(tester, find.byKey(const ValueKey('prices-save')));
        await tester.pumpAndSettle();
        expect(find.text('Prices saved.'), findsOneWidget);

        await tapVisible(tester, find.byKey(const ValueKey('activities-add')));
        await tester.pump();
        await tester.ensureVisible(find.byKey(const ValueKey('activity-name-0')));
        await tester.enterText(
          find.byKey(const ValueKey('activity-name-0')),
          'Waterfall Swimming',
        );
        await tapVisible(tester, find.byKey(const ValueKey('activities-save')));
        await tester.pumpAndSettle();
        expect(find.text('Activities saved.'), findsOneWidget);

        // Upload static JPEG poster
        installPhotoPickerOverride(
          () async => PickedPhoto('hagimit-poster.jpg', validJpegBytes()),
        );
        await tapVisible(tester, find.text('Replace photo'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Upload photo'));
        await tester.pumpAndSettle();
        expect(find.text('Photo updated for Hagimit Falls.'), findsOneWidget);

        // Upload short 8s MP4 clip preserving static poster
        installMediaPickerOverride(
          () async => PickedPhoto(
            'hagimit-clip.mp4',
            validMp4Bytes(durationSeconds: 8.0),
          ),
        );
        await tapVisible(tester, find.text('Upload GIF / video'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Upload media'));
        await tester.pumpAndSettle();
        expect(find.text('Media updated for Hagimit Falls.'), findsOneWidget);

        // Verify persisted state in DestinationsScreen detail view
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: DestinationsScreen(
                key: const ValueKey('destinations-remount'),
                api: backend.createApi(),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tapVisible(tester, find.widgetWithText(TextButton, 'View').first);
        await tester.pumpAndSettle();

        expect(find.text('Hagimit Falls'), findsOneWidget);
        expect(find.text('IGACOS Tourism Office'), findsOneWidget);
        expect(find.text('CC-BY-4.0'), findsOneWidget);
        expect(
          find.byWidgetPredicate(
            (w) => w is AdminBadge && w.label == 'Video (8.0s)',
          ),
          findsOneWidget,
        );
        expect(
          backend.destinations.single['image_url'],
          contains('hagimit-poster.jpg'),
        );
        expect(
          backend.destinations.single['media_url'],
          contains('hagimit-clip.mp4'),
        );
        expect(backend.requestsTo('/destinations/$destId/media'), hasLength(1));
      },
    );

    testWidgets(
      'Workflow 2: Admin Trip Audit Across Active, Completed, Archived Davao Trips with Error Recovery & Non-Admin Session Guard',
      (tester) async {
        setDesktopViewport(tester);

        // Step 1: Verify traveler session cannot enter /trips
        await seedNonAdminSession(role: 'traveler');
        await tester.pumpWidget(const LakbayAdminApp(initialRoute: '/trips'));
        await tester.pumpAndSettle();
        expect(find.byType(LoginScreen), findsOneWidget);
        expect(find.byType(TripsScreen), findsNothing);

        // Step 2: Admin signs in and audits Davao Region trips
        await seedAdminSession();
        final backend = MockAdminBackend(
          trips: [
            davaoTrip(
              tripId: 201,
              title: 'Samal Island Weekend',
              status: 'completed',
              ownerName: 'Carla Mendoza',
              ownerEmail: 'carla@lakbay.test',
              travelerCount: 2,
              totalBudget: 8500,
              estimatedTotalCost: 7200,
              startDate: '2026-11-21',
              endDate: '2026-11-23',
              completedAt: '2026-11-25T16:45:00Z',
              destinationNames: const ['Hagimit Falls', 'Talikud Island'],
            ),
            davaoTrip(
              tripId: 202,
              title: 'Mt. Apo Day Hike',
              status: 'ongoing',
              ownerName: 'Miguel Tan',
              ownerEmail: 'miguel@lakbay.test',
              travelerCount: 4,
              totalBudget: 12000,
              estimatedTotalCost: 9800,
              startDate: '2026-11-26',
              endDate: '2026-11-27',
              destinationNames: const ['Mount Apo', 'Eden Nature Park'],
            ),
            davaoTrip(
              tripId: 203,
              title: 'Davao City Heritage Tour',
              status: 'planned',
              ownerName: 'Liza Bautista',
              ownerEmail: 'liza@lakbay.test',
              travelerCount: 3,
              totalBudget: 4500,
              estimatedTotalCost: 3900,
              startDate: '2026-12-05',
              endDate: '2026-12-06',
              destinationNames: const ['People\'s Park', 'Davao Museum'],
            ),
            davaoTrip(
              tripId: 204,
              title: 'Mati Dahican Surf Retreat',
              status: 'archived',
              ownerName: 'Rafael Ong',
              ownerEmail: 'rafael@lakbay.test',
              travelerCount: 2,
              totalBudget: 9000,
              estimatedTotalCost: 8300,
              startDate: '2026-10-02',
              endDate: '2026-10-04',
              destinationNames: const ['Dahican Beach'],
            ),
          ],
        )..tripsErrorStatusCode = 503;

        await tester.pumpWidget(
          MaterialApp(home: Scaffold(body: TripsScreen(api: backend.createApi()))),
        );
        await tester.pumpAndSettle();

        // Transient 503 -> Retry recovery
        expect(find.text('Could not load trips'), findsOneWidget);
        backend.tripsErrorStatusCode = null;
        await tester.tap(find.widgetWithText(OutlinedButton, 'Retry'));
        await tester.pumpAndSettle();

        expect(find.text('Total trips: 4'), findsOneWidget);
        expect(find.text('Showing: 4 of 4'), findsOneWidget);
        expect(find.text('Samal Island Weekend'), findsOneWidget);
        expect(find.text('Mt. Apo Day Hike'), findsOneWidget);
        expect(find.text('Davao City Heritage Tour'), findsOneWidget);
        expect(find.text('Mati Dahican Surf Retreat'), findsOneWidget);

        // Filter completed + search 'Samal' -> M4 badge & completed_at check
        await tester.tap(find.byType(DropdownButton<String>));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Completed').last);
        await tester.pumpAndSettle();

        await enterFieldByLabel(tester, 'Search trips', 'Samal');
        await tester.pump(const Duration(milliseconds: 400));
        await tester.pumpAndSettle();

        expect(find.text('Showing: 1 of 1'), findsOneWidget);
        expect(find.text('Samal Island Weekend'), findsOneWidget);
        expect(
          find.byWidgetPredicate(
            (w) => w is AdminBadge && w.label == 'Completed',
          ),
          findsOneWidget,
        );
        expect(find.textContaining('2026-11-25'), findsOneWidget);

        // Clear search & reset filter
        await tester.tap(find.byTooltip('Clear search'));
        await tester.pumpAndSettle();
        await tester.tap(find.byType(DropdownButton<String>));
        await tester.pumpAndSettle();
        await tester.tap(find.text('All statuses').last);
        await tester.pumpAndSettle();

        expect(find.text('Showing: 4 of 4'), findsOneWidget);
      },
    );
  });
}
