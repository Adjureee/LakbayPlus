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

  group('Tier 3 — Pairwise Cross-Feature Admin Interactions', () {
    testWidgets(
      'Candidate review -> save -> publish -> open in DestinationsScreen -> DestinationEditor enrich hours/prices/attribution + GIF media -> visible in DestinationsScreen',
      (tester) async {
        setDesktopViewport(tester);
        final backend = MockAdminBackend(
          candidates: [
            davaoCandidate(
              candidateId: 71,
              name: 'Tagbaobo Falls',
              district: 'Kaputian, Samal Island',
              category: 'Waterfall',
            ),
          ],
        );

        // 1. Review, edit, save, and publish candidate
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: DestinationCandidatesScreen(api: backend.createApi()),
            ),
          ),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.text('Tagbaobo Falls'));
        await tester.pumpAndSettle();

        await enterFieldByLabel(
          tester,
          'Description',
          'Hidden forest waterfall on Samal Island.',
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
          'https://samalcity.gov.ph/tagbaobo',
        );
        await tapVisible(
          tester,
          find.widgetWithText(CheckboxListTile, 'I checked this access evidence'),
        );
        await tester.pumpAndSettle();

        await tapVisible(tester, find.widgetWithText(FilledButton, 'Save review'));
        await tester.pumpAndSettle();
        await tapVisible(
          tester,
          find.widgetWithText(OutlinedButton, 'Publish destination'),
        );
        await tester.pumpAndSettle();
        expect(backend.destinations, hasLength(1));

        // 2. Open published destination in DestinationsScreen -> DestinationEditor
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(body: DestinationsScreen(api: backend.createApi())),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('Tagbaobo Falls'), findsOneWidget);

        await tapVisible(tester, find.widgetWithText(TextButton, 'View').first);
        await tester.pumpAndSettle();
        await tapVisible(
          tester,
          find.widgetWithText(FilledButton, 'Edit destination'),
        );
        await tester.pumpAndSettle();

        // 3. Enrich attribution, hours, prices, and upload GIF media
        await enterFieldByLabel(
          tester,
          'Photo / media credit',
          'Samal Tourism Office',
        );
        await enterFieldByLabel(tester, 'License', 'CC-BY-4.0');
        await tapVisible(
          tester,
          find.widgetWithText(FilledButton, 'Save destination'),
        );
        await tester.pumpAndSettle();

        // Back in DestinationsScreen detail after save; re-open editor for sub-sections & media
        expect(find.text('Destination saved.'), findsOneWidget);
        expect(find.text('Samal Tourism Office'), findsOneWidget);
        await tapVisible(
          tester,
          find.widgetWithText(FilledButton, 'Edit destination'),
        );
        await tester.pumpAndSettle();

        final destId = backend.destinations.single['destination_id'];
        await enterFieldByLabel(
          tester,
          'Where these hours came from (web address)',
          'https://samalcity.gov.ph/tagbaobo-hours',
        );
        await tapVisible(tester, find.byKey(const ValueKey('hours-save')));
        await tester.pumpAndSettle();
        expect(find.text('Hours saved.'), findsOneWidget);

        await tapVisible(tester, find.byKey(const ValueKey('prices-add')));
        await tester.pump();
        await tester.enterText(
          find.byKey(const ValueKey('price-amount-0')),
          '50',
        );
        await enterFieldByLabel(
          tester,
          'Where these prices came from (web address)',
          'https://samalcity.gov.ph/tagbaobo-fees',
        );
        await tapVisible(tester, find.byKey(const ValueKey('prices-save')));
        await tester.pumpAndSettle();
        expect(find.text('Prices saved.'), findsOneWidget);

        installMediaPickerOverride(
          () async => PickedPhoto('tagbaobo.gif', validGif89aBytes()),
        );
        await tapVisible(tester, find.text('Upload GIF / video'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Upload media'));
        await tester.pumpAndSettle();

        expect(backend.requestsTo('/destinations/$destId/media'), hasLength(1));
        expect(find.text('Media updated for Tagbaobo Falls.'), findsOneWidget);

        // Return to DestinationsScreen detail and verify updated media & attribution
        await tapVisible(
          tester,
          find.widgetWithText(TextButton, 'Back to destination'),
        );
        await tester.pumpAndSettle();

        // Re-mount DestinationsScreen to reflect fresh backend state cleanly
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

        expect(find.text('Tagbaobo Falls'), findsOneWidget);
        expect(find.text('Samal Tourism Office'), findsOneWidget);
        expect(
          find.byWidgetPredicate((w) => w is AdminBadge && w.label == 'GIF'),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'TripsScreen combined completed status filter + search + pagination + completed_at & Completed badge + Clear search & reset',
      (tester) async {
        setDesktopViewport(tester);
        final trips = <Map<String, dynamic>>[
          davaoTrip(tripId: 1, title: 'Davao Ongoing Trip', status: 'ongoing'),
          davaoTrip(tripId: 2, title: 'Davao Planned Trip', status: 'planned'),
          for (var i = 1; i <= 26; i++)
            davaoTrip(
              tripId: 100 + i,
              title: i == 26
                  ? 'Samal Sunset Finale'
                  : 'Davao Completed Loop #$i',
              status: 'completed',
              startDate: '2026-11-10',
              endDate: '2026-11-12',
              completedAt: '2026-11-25T15:00:00Z',
            ),
        ];
        final backend = MockAdminBackend(trips: trips);

        await tester.pumpWidget(
          MaterialApp(home: Scaffold(body: TripsScreen(api: backend.createApi()))),
        );
        await tester.pumpAndSettle();

        expect(find.text('Total trips: 28'), findsOneWidget);

        // 1. Filter by Completed (26 completed trips -> pagination appears)
        await tester.tap(find.byType(DropdownButton<String>));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Completed').last);
        await tester.pumpAndSettle();

        expect(find.text('Showing: 25 of 26'), findsOneWidget);
        await tapVisible(tester, find.widgetWithText(OutlinedButton, 'Next'));
        await tester.pumpAndSettle();
        expect(find.text('Showing: 1 of 26'), findsOneWidget);
        expect(find.text('Samal Sunset Finale'), findsOneWidget);

        // 2. Search 'Samal' while status=completed is active -> resets offset=0
        await enterFieldByLabel(tester, 'Search trips', 'Samal');
        await tester.pump(const Duration(milliseconds: 400));
        await tester.pumpAndSettle();

        final combinedReq = backend.requestsTo('/admin/trips').last;
        expect(combinedReq.queryParameters['status'], 'completed');
        expect(combinedReq.queryParameters['search'], 'Samal');
        expect(combinedReq.queryParameters['offset'], '0');
        expect(find.text('Showing: 1 of 1'), findsOneWidget);

        // M4 assertion: capitalized Completed badge + completed_at timestamp
        expect(
          find.byWidgetPredicate(
            (w) => w is AdminBadge && w.label == 'Completed',
          ),
          findsOneWidget,
        );
        expect(find.textContaining('2026-11-25'), findsOneWidget);

        // 3. Clear search & reset status filter -> restores all 28 trips
        await tester.tap(find.byTooltip('Clear search'));
        await tester.pumpAndSettle();
        expect(find.text('Showing: 25 of 26'), findsOneWidget);

        await tester.tap(find.byType(DropdownButton<String>));
        await tester.pumpAndSettle();
        await tester.tap(find.text('All statuses').last);
        await tester.pumpAndSettle();

        expect(find.text('Showing: 25 of 28'), findsOneWidget);
        expect(find.text('Davao Ongoing Trip'), findsOneWidget);
      },
    );

    testWidgets(
      'DestinationEditor unsaved edits + photo replacement preserves dirty state without false PATCH + sub-section save',
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

        // 1. Make an unsaved text edit
        await enterFieldByLabel(
          tester,
          'Description',
          'Updated highland eco-park overview.',
        );
        expect(adminHasUnsavedChanges.value, isTrue);

        // 2. Replace photo while form is dirty -> uploads /image, does NOT trigger PATCH or clear description dirty state
        installPhotoPickerOverride(
          () async => PickedPhoto('eden-new.png', validPngBytes()),
        );
        await tapVisible(tester, find.text('Replace photo'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Upload photo'));
        await tester.pumpAndSettle();

        expect(backend.requestsTo('/destinations/12/image'), hasLength(1));
        expect(backend.requestsTo('/destinations/12', method: 'PATCH'), isEmpty);
        expect(adminHasUnsavedChanges.value, isTrue);
        expect(find.text('Unsaved changes'), findsOneWidget);

        // 3. Save HoursSection independently -> only PUT /hours fires
        await tapVisible(tester, find.byKey(const ValueKey('hours-24')));
        await tester.pump();
        await tapVisible(tester, find.byKey(const ValueKey('hours-save')));
        await tester.pumpAndSettle();

        expect(backend.requestsTo('/destinations/12/hours', method: 'PUT'), hasLength(1));
        expect(backend.requestsTo('/destinations/12', method: 'PATCH'), isEmpty);

        // 4. Save main form -> sends delta PATCH with ONLY description (not image_url)
        await tapVisible(
          tester,
          find.widgetWithText(FilledButton, 'Save destination'),
        );
        await tester.pumpAndSettle();

        final patches = backend.requestsTo('/destinations/12', method: 'PATCH');
        expect(patches, hasLength(1));
        expect(patches.single.jsonBody, {
          'description': 'Updated highland eco-park overview.',
        });
        expect(adminHasUnsavedChanges.value, isFalse);
      },
    );
  });
}
