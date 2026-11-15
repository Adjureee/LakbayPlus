import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lakbay_travel/models/travel_models.dart';
import 'package:lakbay_travel/services/lakbay_api_catalog_service.dart';
import 'package:lakbay_travel/services/location_service.dart';
import 'package:lakbay_travel/services/route_progress.dart';
import 'package:lakbay_travel/services/travel_repository.dart';
import 'package:lakbay_travel/widgets/lakbay_mapbox_widget.dart';
import 'package:shared_preferences/shared_preferences.dart';

// A straight road east from downtown Davao: about 1.1 km per 0.01° of longitude.
const _road = [
  GeoPoint(lat: 7.0700, lng: 125.6000),
  GeoPoint(lat: 7.0700, lng: 125.6100),
  GeoPoint(lat: 7.0700, lng: 125.6200),
];

LivePosition _fix(double lat, double lng, {double accuracy = 8}) => LivePosition(
      lat: lat,
      lng: lng,
      accuracyMeters: accuracy,
      headingDegrees: 90,
      timestamp: DateTime(2026, 11, 15, 9),
    );

void main() {
  group('projectOntoRoute', () {
    test('on the road: near-zero distance and correct remaining length', () {
      final p = projectOntoRoute(7.0700, 125.6050, _road)!;
      expect(p.distanceMeters, lessThan(1));
      expect(p.segmentIndex, 0);
      // 1.5 of 2 segments left, each ~1.1 km.
      expect(p.remainingMeters, closeTo(1655, 15));
    });

    test('100 m north of the road', () {
      final p = projectOntoRoute(7.0709, 125.6150, _road)!;
      expect(p.distanceMeters, closeTo(100, 3));
      expect(p.segmentIndex, 1);
    });

    test('needs at least two points', () {
      expect(projectOntoRoute(7.07, 125.6, const [GeoPoint(lat: 7.07, lng: 125.6)]),
          isNull);
    });
  });

  group('OffRouteDetector', () {
    final now = DateTime(2026, 11, 15, 9);

    test('needs three consecutive off-route fixes, then cools down', () {
      final detector = OffRouteDetector();
      bool off(int seconds) => detector.update(
            lat: 7.0720, lng: 125.6100, accuracyMeters: 10, route: _road,
            now: now.add(Duration(seconds: seconds)),
          );
      expect(off(0), isFalse);
      expect(off(4), isFalse);
      expect(off(8), isTrue);
      // Still off, but inside the 30 s cooldown.
      expect([off(12), off(16), off(20)], everyElement(isFalse));
      // Still off after the cooldown: reroute again right away, then wait again.
      expect([off(40), off(44)], [isTrue, isFalse]);
    });

    test('a fix back on the road resets the count', () {
      final detector = OffRouteDetector();
      bool update(double lat) => detector.update(
          lat: lat, lng: 125.61, accuracyMeters: 10, route: _road, now: now);
      update(7.0720);
      update(7.0720);
      update(7.0700);
      expect(update(7.0720), isFalse);
    });

    test('ignores inaccurate fixes and accuracy circles touching the road', () {
      final detector = OffRouteDetector();
      for (var i = 0; i < 5; i++) {
        expect(
            detector.update(
                lat: 7.0720, lng: 125.61, accuracyMeters: 150, route: _road, now: now),
            isFalse);
        expect(
            detector.update(
                lat: 7.0706, lng: 125.61, accuracyMeters: 80, route: _road, now: now),
            isFalse);
      }
    });
  });

  test('detectArrival finds the next unreached stop within the radius', () {
    const stops = [
      GeoPoint(lat: 7.0700, lng: 125.6000),
      GeoPoint(lat: 7.0700, lng: 125.6200),
    ];
    expect(detectArrival(lat: 7.0700, lng: 125.6001, stops: stops, reachedCount: 0), 0);
    expect(detectArrival(lat: 7.0700, lng: 125.6001, stops: stops, reachedCount: 1), isNull);
    expect(detectArrival(lat: 7.0701, lng: 125.6199, stops: stops, reachedCount: 1), 1);
  });

  test('formatDistanceMeters', () {
    expect(formatDistanceMeters(2430), '2.4 km');
    expect(formatDistanceMeters(347), '350 m');
  });

  group('TravelRepository live tracking', () {
    late StreamController<LivePosition> gps;
    late TravelRepository repo;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      gps = StreamController<LivePosition>.broadcast();
      repo = TravelRepository(
        apiCatalog: LakbayApiCatalogService(baseUrlOverride: ''),
        locationService: LocationService(customPositionStream: () => gps.stream),
      );
      await repo.initialize();
    });

    tearDown(() => gps.close());

    test('follows the stream and updates the routing origin', () async {
      expect(await repo.startLiveTracking(), isTrue);
      gps.add(_fix(7.0711, 125.6122));
      await Future<void>.delayed(Duration.zero);

      expect(repo.livePosition!.lat, 7.0711);
      expect(repo.userLat, 7.0711);
      expect(repo.userLng, 125.6122);
    });

    test('is reference counted and stops with the last client', () async {
      await repo.startLiveTracking();
      await repo.startLiveTracking();
      repo.stopLiveTracking();
      expect(repo.isLiveTracking, isTrue);
      repo.stopLiveTracking();
      expect(repo.isLiveTracking, isFalse);
      expect(repo.livePosition, isNull);
    });

    test('turning off location sharing stops tracking and ignores fixes', () async {
      await repo.startLiveTracking();
      repo.setLocationSharingEnabled(false);
      expect(repo.isLiveTracking, isFalse);
      expect(await repo.startLiveTracking(), isFalse);
    });
  });

  testWidgets('map draws the live dot and a follow button', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final repo = TravelRepository(
      apiCatalog: LakbayApiCatalogService(baseUrlOverride: ''),
    );
    await tester.runAsync(repo.initialize);
    var follow = false;

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: StatefulBuilder(
          builder: (context, setState) => SizedBox(
            width: 400,
            height: 500,
            child: LakbayMapboxMap(
              repo: repo,
              initialLat: 7.07,
              initialLng: 125.61,
              livePosition: _fix(7.0705, 125.6105, accuracy: 30),
              followUser: follow,
              onFollowUserChanged: (value) => setState(() => follow = value),
            ),
          ),
        ),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.byTooltip('Follow My Location'), findsOneWidget);
    await tester.tap(find.byTooltip('Follow My Location'));
    await tester.pump(const Duration(milliseconds: 600));
    expect(follow, isTrue);
    expect(find.byTooltip('Stop Following Me'), findsOneWidget);
  });
}
