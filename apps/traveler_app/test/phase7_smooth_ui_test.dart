import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:lakbay_travel/main.dart';
import 'package:lakbay_travel/screens/explore_screen.dart';
import 'package:lakbay_travel/screens/memories_screen.dart';
import 'package:lakbay_travel/screens/my_trips_screen.dart';
import 'package:lakbay_travel/services/lakbay_api_catalog_service.dart';
import 'package:lakbay_travel/services/travel_repository.dart';
import 'package:lakbay_travel/widgets/lakbay_image.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    GoogleFonts.config.allowRuntimeFetching = false;
    SharedPreferences.setMockInitialValues({});
  });

  group('photos are asked for at the size they are shown', () {
    const full =
        'https://res.cloudinary.com/demo/image/upload/v1700000000/lakbay/places/eden.jpg';

    test('a Cloudinary upload gets a smaller, auto-quality copy', () {
      expect(
        LakbayImageSizing.sized(full, 480),
        'https://res.cloudinary.com/demo/image/upload/w_480,q_auto,f_auto/v1700000000/lakbay/places/eden.jpg',
      );
    });

    test('an address that is already transformed, or not Cloudinary, is left alone', () {
      const done =
          'https://res.cloudinary.com/demo/image/upload/w_300,c_fill/v1/x.jpg';
      expect(LakbayImageSizing.sized(done, 480), done);
      const other = 'https://example.com/image/upload/a.jpg';
      expect(LakbayImageSizing.sized(other, 480), other);
      expect(LakbayImageSizing.sized('', 480), '');
    });

    test('widths round up to a few shared sizes, never above the largest', () {
      expect(LakbayImageSizing.stepFor(100, 2), 240);
      expect(LakbayImageSizing.stepFor(180, 2), 360);
      expect(LakbayImageSizing.stepFor(360, 3), 1080);
      expect(LakbayImageSizing.stepFor(2000, 3), 1440);
    });
  });

  testWidgets('a tab is built the first time it is opened, and kept after', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(900, 2000);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    SharedPreferences.setMockInitialValues({
      'lakbay_traveler_state_v1':
          '{"hasCompletedOnboarding": true}',
    });
    final repo = TravelRepository(
      apiCatalog: LakbayApiCatalogService(baseUrlOverride: ''),
    );
    await tester.runAsync(() => repo.initialize());
    repo.setActiveNavIndex(0);

    // The app rebuilds its home when the repository changes; so does this.
    await tester.pumpWidget(
      ListenableBuilder(
        listenable: repo,
        builder: (_, _) =>
            MaterialApp(home: MainNavigationShell(repo: repo)),
      ),
    );
    await tester.pump();

    expect(find.byType(MyTripsScreen), findsOneWidget);
    expect(find.byType(ExploreScreen, skipOffstage: false), findsNothing);
    expect(find.byType(MemoriesScreen, skipOffstage: false), findsNothing);

    repo.setActiveNavIndex(1);
    await tester.pump();
    expect(find.byType(ExploreScreen), findsOneWidget);
    expect(find.byType(MemoriesScreen, skipOffstage: false), findsNothing);

    // Going back keeps the Discover tab alive for when the traveler returns.
    repo.setActiveNavIndex(0);
    await tester.pump();
    expect(find.byType(ExploreScreen, skipOffstage: false), findsOneWidget);
  });
}
