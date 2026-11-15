import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lakbay_travel/models/travel_models.dart';
import 'package:lakbay_travel/services/lakbay_api_catalog_service.dart';
import 'package:lakbay_travel/services/travel_repository.dart';
import 'package:lakbay_travel/widgets/lakbay_mapbox_widget.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Davao City downtown -> Samal Island: a straight line between them crosses the gulf.
const _davaoCity = GeoPoint(lat: 7.0707, lng: 125.6096, label: 'Davao City');
const _samal = GeoPoint(lat: 7.0742, lng: 125.7089, label: 'Samal Island');

Iterable<Image> _vehicleSprites(WidgetTester tester) => tester
    .widgetList<Image>(find.byType(Image))
    .where((img) =>
        img.image is AssetImage &&
        (img.image as AssetImage).assetName.startsWith('assets/map_sprites/'));

Future<TravelRepository> _repo(WidgetTester tester) async {
  SharedPreferences.setMockInitialValues({});
  final repo = TravelRepository(
    apiCatalog: LakbayApiCatalogService(baseUrlOverride: ''),
  );
  await tester.runAsync(repo.initialize);
  return repo;
}

Widget _map(TravelRepository repo, {List<GeoPoint> road = const []}) {
  return MaterialApp(
    home: Scaffold(
      body: SizedBox(
        width: 400,
        height: 500,
        child: LakbayMapboxMap(
          repo: repo,
          initialLat: 7.07,
          initialLng: 125.66,
          initialZoom: 10,
          routePoints: const [_davaoCity, _samal],
          roadGeometry: road,
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('pier route: road solid, sea crossing gets a boat, no notice',
      (tester) async {
    final repo = await _repo(tester);
    await tester.pumpWidget(_segmentMap(repo, const [
      RouteSegmentGeometry(
          mode: TransportMode.car, points: [_davaoCity, _sasa],
          fromName: 'Davao City', toName: 'Sasa'),
      RouteSegmentGeometry(
          mode: TransportMode.ferry, points: [_sasa, _babak],
          fromName: 'Sasa', toName: 'Babak'),
      RouteSegmentGeometry(
          mode: TransportMode.car, points: [_babak, _samal],
          fromName: 'Babak', toName: 'Samal'),
    ]));
    await tester.pump(const Duration(milliseconds: 100));

    expect(_vehicleSprites(tester), isNotEmpty);
    expect(find.textContaining('unavailable'), findsNothing);
  });

  testWidgets('pier route with an estimated road part: no vehicle at all',
      (tester) async {
    final repo = await _repo(tester);
    await tester.pumpWidget(_segmentMap(repo, const [
      RouteSegmentGeometry(
          mode: TransportMode.car, points: [_davaoCity, _sasa],
          fromName: 'Davao City', toName: 'Sasa'),
      RouteSegmentGeometry(
          mode: TransportMode.ferry, points: [_sasa, _babak],
          fromName: 'Sasa', toName: 'Babak'),
      RouteSegmentGeometry(
          mode: TransportMode.car, points: [_babak, _samal],
          fromName: 'Babak', toName: 'Samal', isEstimated: true),
    ]));
    await tester.pump(const Duration(milliseconds: 100));

    expect(_vehicleSprites(tester), isEmpty);
    expect(find.textContaining('Part of this road route is unavailable'),
        findsOneWidget);
  });

  test('sea segments and crossings are parsed from the route response',
      () async {
    String encode(List<List<double>> pts) {
      // Minimal polyline5 encoder for the test fixture.
      final out = StringBuffer();
      var prevLat = 0, prevLng = 0;
      for (final p in pts) {
        final lat = (p[0] * 1e5).round(), lng = (p[1] * 1e5).round();
        for (var delta in [lat - prevLat, lng - prevLng]) {
          var v = delta < 0 ? ~(delta << 1) : delta << 1;
          while (v >= 0x20) {
            out.writeCharCode((0x20 | (v & 0x1f)) + 63);
            v >>= 5;
          }
          out.writeCharCode(v + 63);
        }
        prevLat = lat;
        prevLng = lng;
      }
      return out.toString();
    }

    final client = MockClient((request) async => http.Response(
          jsonEncode({
            'route_provider': 'mapbox+sea_links',
            'is_estimated': false,
            'total_distance_km': '12.40',
            'total_duration_minutes': 55,
            'polyline': encode([[7.0707, 125.6096], [7.1236, 125.6655], [7.1180, 125.6880]]),
            'stops': [],
            'segments': [
              {'order': 1, 'mode': 'road', 'from_name': 'A', 'to_name': 'Sasa',
               'polyline': encode([[7.0707, 125.6096], [7.1236, 125.6655]]), 'is_estimated': false},
              {'order': 2, 'mode': 'sea', 'from_name': 'Sasa', 'to_name': 'Babak',
               'polyline': encode([[7.1236, 125.6655], [7.1180, 125.6880]]), 'is_estimated': false},
            ],
            'sea_crossings': [
              {'vessel_type': 'roro_barge', 'board_port': 'Sasa', 'land_port': 'Babak',
               'board_lat': 7.1236, 'board_lng': 125.6655, 'land_lat': 7.118, 'land_lng': 125.688,
               'crossing_minutes': 15, 'typical_wait_minutes': 20,
               'allows_private_vehicle': true, 'fare_vehicle': '180.00', 'verified': false},
            ],
          }),
          200,
        ));
    final api = LakbayApiCatalogService(
      baseUrlOverride: 'https://api.example.test/api/v1',
      client: client,
    );

    final result = await api.previewRoute('token', destinationIds: const [1, 2]);

    expect(result!.segments.map((s) => s.mode),
        [TransportMode.car, TransportMode.ferry]);
    expect(result.segments[1].points.first.lat, closeTo(7.1236, 1e-5));
    final crossing = result.seaCrossings.single;
    expect(crossing.vesselLabel, 'RoRo barge');
    expect(crossing.fareVehicle, 180.0);
    expect(crossing.verified, isFalse);
  });

  testWidgets('no road geometry: no vehicle sprite, unrouted notice shown',
      (tester) async {
    final repo = await _repo(tester);
    await tester.pumpWidget(_map(repo));
    await tester.pump(const Duration(milliseconds: 100));

    expect(_vehicleSprites(tester), isEmpty);
    expect(find.textContaining('Road route unavailable'), findsOneWidget);
  });

  testWidgets('road geometry: vehicle sprite follows the road, no notice',
      (tester) async {
    final repo = await _repo(tester);
    await tester.pumpWidget(_map(repo, road: const [
      _davaoCity,
      GeoPoint(lat: 7.0900, lng: 125.6300),
      GeoPoint(lat: 7.1000, lng: 125.6500),
    ]));
    await tester.pump(const Duration(milliseconds: 100));

    expect(_vehicleSprites(tester), isNotEmpty);
    expect(find.textContaining('Road route unavailable'), findsNothing);
  });

  test('estimated backend route yields no geometry even with stop list',
      () async {
    final client = MockClient((request) async {
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      expect(body['origin'], {'label': 'My location', 'lat': 7.0, 'lng': 125.6});
      expect(body.containsKey('preserve_first_destination'), isFalse);
      return http.Response(
        jsonEncode({
          'route_provider': 'haversine',
          'is_estimated': true,
          'total_distance_km': '11.2',
          'total_duration_minutes': 20,
          'polyline': null,
          'stops': [
            {'name': 'Davao City', 'lat': 7.0707, 'lng': 125.6096},
            {'destination_id': 4, 'name': 'Samal', 'lat': 7.0742, 'lng': 125.7089},
          ],
          'warnings': ['OSRM was unavailable'],
        }),
        200,
      );
    });
    final api = LakbayApiCatalogService(
      baseUrlOverride: 'https://api.example.test/api/v1',
      client: client,
    );

    final result = await api.optimizeRoute(
      'token',
      destinationIds: const [4, 5],
      origin: const GeoPoint(lat: 7.0, lng: 125.6),
    );

    expect(result, isNotNull);
    expect(result!.isEstimated, isTrue);
    expect(result.geometryPoints, isEmpty);
    expect(result.orderedDestinationIds, [4]);
  });
}

Widget _segmentMap(TravelRepository repo, List<RouteSegmentGeometry> segments) {
  return MaterialApp(
    home: Scaffold(
      body: SizedBox(
        width: 400,
        height: 500,
        child: LakbayMapboxMap(
          repo: repo,
          initialLat: 7.10,
          initialLng: 125.66,
          initialZoom: 10,
          routePoints: const [_davaoCity, _samal],
          routeSegments: segments,
        ),
      ),
    ),
  );
}

const _sasa = GeoPoint(lat: 7.1236, lng: 125.6655);
const _babak = GeoPoint(lat: 7.1180, lng: 125.6880);
