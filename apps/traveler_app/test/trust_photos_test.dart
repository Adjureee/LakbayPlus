import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lakbay_travel/core/place_kinds.dart';
import 'package:lakbay_travel/models/travel_models.dart';
import 'package:lakbay_travel/services/travel_repository.dart';
import 'package:lakbay_travel/widgets/lakbay_image.dart';
import 'package:lakbay_travel/widgets/place_photo_placeholder.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// F3 (docs/FLAGSHIP_UX_PLAN.md): a card never shows a photo of a different
/// place, and a travel time says where it starts.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('placeKindFor reads the free-text catalog category', () {
    test('picks the kind a traveler would picture', () {
      expect(placeKindFor('Eco-Agritourism Beach Resort'), PlaceKind.beach);
      expect(placeKindFor('Coastal Park'), PlaceKind.beach);
      expect(placeKindFor('waterfall'), PlaceKind.water);
      expect(placeKindFor('Eco-Tourism Park'), PlaceKind.nature);
      expect(placeKindFor('sea of clouds viewpoint'), PlaceKind.mountain);
      expect(placeKindFor('Cultural and Historical Landmark'), PlaceKind.culture);
      expect(placeKindFor('museum'), PlaceKind.culture);
      expect(placeKindFor('Garden / Eco-Park'), PlaceKind.nature);
      expect(placeKindFor('Cafe/ Restaurant'), PlaceKind.stay);
      expect(placeKindFor('resort'), PlaceKind.stay);
    });

    test('unknown or missing categories get the plain pin', () {
      expect(placeKindFor(null), PlaceKind.other);
      expect(placeKindFor(''), PlaceKind.other);
      expect(placeKindFor('Sports Complex'), PlaceKind.other);
    });
  });

  group('ownPhotoAssetFor', () {
    test('matches only a place that is the photo\'s own subject', () {
      for (final name in [
        'Aliwagwag Falls — Cateel',
        'Samal Island Beach Area',
        'Eden Nature Park',
        "People's Park",
      ]) {
        final asset = ownPhotoAssetFor(name);
        expect(asset, startsWith('assets/home_backdrops/'), reason: name);
        expect(File(asset).existsSync(), isTrue, reason: '$name -> $asset');
      }
    });

    test('other places get no photo, not the closest region\'s', () {
      // These used to get Eden's, Aliwagwag's, Samal's or People's Park's photo.
      for (final name in [
        'Huyong-huyong Nature Park',
        'Pyalitan Falls',
        'Dahican Surf Resort',
        'Pearl Farm Beach Resort',
        'Museo Panabo',
        'Digos City Eco Park and Arboretum',
      ]) {
        expect(ownPhotoAssetFor(name), isEmpty, reason: name);
      }
    });

    test('an Explore place without its own photo has no asset', () {
      const place = ExploreTrip(
        locale: 'en',
        id: 'api_99',
        title: 'Panabo Mangrove Forest Park',
        district: 'Davao del Norte',
        lat: 7.3,
        lng: 125.7,
        thumbnailUrl: '',
      );
      expect(place.localAssetPath, isEmpty);
    });
  });

  group('LakbayNetworkOrAssetImage', () {
    Future<void> show(WidgetTester tester, Widget child) => tester.pumpWidget(
          MaterialApp(home: Scaffold(body: Center(child: child))),
        );

    testWidgets('no photo shows the placeholder, not another place',
        (tester) async {
      await show(
        tester,
        const LakbayNetworkOrAssetImage(
          networkUrl: null,
          assetPath: '',
          category: 'waterfall',
          width: 300,
          height: 200,
        ),
      );
      expect(find.byType(PlacePhotoPlaceholder), findsOneWidget);
      expect(find.byType(Image), findsNothing);
      expect(find.byIcon(Icons.water_rounded), findsOneWidget);
      expect(find.text('Photo coming soon'), findsOneWidget);
    });

    testWidgets('a small thumbnail shows only the icon', (tester) async {
      await show(
        tester,
        const LakbayNetworkOrAssetImage(
          networkUrl: null,
          assetPath: '',
          category: 'museum',
          width: 60,
          height: 60,
        ),
      );
      expect(find.byIcon(Icons.account_balance_rounded), findsOneWidget);
      expect(find.text('Photo coming soon'), findsNothing);
    });

    testWidgets('a place with its own bundled photo shows that photo',
        (tester) async {
      await show(
        tester,
        LakbayNetworkOrAssetImage(
          networkUrl: null,
          assetPath: ownPhotoAssetFor('Aliwagwag Falls'),
          width: 300,
          height: 200,
        ),
      );
      expect(find.byType(Image), findsOneWidget);
      expect(find.byType(PlacePhotoPlaceholder), findsNothing);
    });

    testWidgets('a missing asset file falls back to the placeholder',
        (tester) async {
      await show(
        tester,
        const LakbayNetworkOrAssetImage(
          networkUrl: null,
          assetPath: 'assets/home_backdrops/does-not-exist.jpg',
          width: 300,
          height: 200,
        ),
      );
      await tester.pump();
      expect(find.byType(PlacePhotoPlaceholder), findsOneWidget);
    });
  });

  group('travel time names where it starts', () {
    test('with a start set', () {
      SharedPreferences.setMockInitialValues({});
      final repo = TravelRepository();
      repo.setManualOrigin(
        label: 'Tubaon, Tarragona, Davao Oriental',
        lat: 6.9,
        lng: 126.4,
      );
      expect(repo.originShortName, 'Tubaon');
      expect(repo.travelTimeLabel(34), '~34 min from Tubaon');
    });

    test('with no start it stays a bare estimate', () {
      SharedPreferences.setMockInitialValues({});
      final repo = TravelRepository();
      expect(repo.originShortName, isEmpty);
      expect(repo.travelTimeLabel(34), '~34 min');
    });
  });
}
