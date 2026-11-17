import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:lakbay_travel/main.dart';
import 'package:lakbay_travel/services/lakbay_api_catalog_service.dart';
import 'package:lakbay_travel/services/travel_repository.dart';
import 'package:lakbay_travel/theme/lakbay_theme.dart';
import 'package:lakbay_travel/widgets/brand/lakbay_ai_avatar.dart';
import 'package:lakbay_travel/widgets/brand/lakbay_compass_mark.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    GoogleFonts.config.allowRuntimeFetching = false;
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('the logo file is bundled and has the proportions the code assumes', (
    tester,
  ) async {
    final data = await rootBundle.load(LakbayCompassMark.asset);
    expect(data.lengthInBytes, greaterThan(1000));
    final codec = await tester.runAsync(
      () => ui.instantiateImageCodec(data.buffer.asUint8List()),
    );
    final frame = await tester.runAsync(() => codec!.getNextFrame());
    final image = frame!.image;
    expect(image.width / image.height, closeTo(LakbayCompassMark.aspect, 0.02));
  });

  testWidgets('the mark draws the logo, wider than tall', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: Center(child: LakbayCompassMark(size: 40))),
    );
    final box = tester.getSize(find.byKey(const ValueKey('lakbay-logo')));
    expect(box.height, 40);
    expect(box.width, closeTo(40 * LakbayCompassMark.aspect, 0.5));
  });

  testWidgets('on a dark background the logo sits on a white badge', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          backgroundColor: Colors.black,
          body: Center(
            child: LakbayCompassMark(size: 40, primaryColor: Colors.white),
          ),
        ),
      ),
    );
    final badge = tester.widget<DecoratedBox>(
      find.ancestor(
        of: find.byKey(const ValueKey('lakbay-logo')),
        matching: find.byType(DecoratedBox),
      ).first,
    );
    expect((badge.decoration as BoxDecoration).color, Colors.white);
  });

  testWidgets('the AI avatar shows the logo inside its circle', (tester) async {
    for (final diameter in [34.0, 46.0]) {
      await tester.pumpWidget(
        MaterialApp(home: Center(child: LakbayAiAvatar(diameter: diameter))),
      );
      final logo = tester.getSize(find.byKey(const ValueKey('lakbay-logo')));
      expect(logo.width, lessThan(diameter), reason: 'width at $diameter');
      expect(find.byKey(const ValueKey('lakbay-ai-avatar')), findsOneWidget);
    }
  });

  testWidgets('the wordmark shows the logo and keeps the name', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: Center(child: LakbayBrandWordmark(fontSize: 24))),
    );
    expect(find.byKey(const ValueKey('lakbay-logo')), findsOneWidget);
    expect(find.textContaining('Lakbay'), findsOneWidget);
  });

  testWidgets('the centre Chat tab button shows the logo, not the old star', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(400, 800);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    SharedPreferences.setMockInitialValues({
      'lakbay_traveler_state_v1': '{"hasCompletedOnboarding": true}',
    });
    final repo = TravelRepository(
      apiCatalog: LakbayApiCatalogService(baseUrlOverride: ''),
    );
    await tester.runAsync(() => repo.initialize());
    repo.setActiveNavIndex(0);
    await tester.pumpWidget(
      ListenableBuilder(
        listenable: repo,
        builder: (_, _) => MaterialApp(home: MainNavigationShell(repo: repo)),
      ),
    );
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(const ValueKey('lakbay-logo')), findsWidgets);
    expect(tester.takeException(), isNull);
  });
}
