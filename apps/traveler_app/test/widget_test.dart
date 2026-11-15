import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:lakbay_travel/main.dart';
import 'package:lakbay_travel/models/travel_models.dart';
import 'package:lakbay_travel/services/cloudinary_service.dart';
import 'package:lakbay_travel/services/env_config.dart';
import 'package:lakbay_travel/services/lakbay_ai_service.dart';
import 'package:lakbay_travel/services/mapbox_service.dart';
import 'package:lakbay_travel/services/travel_repository.dart';
import 'package:lakbay_travel/theme/lakbay_theme.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('Lakbay+ app launches with brand wordmark',
      (WidgetTester tester) async {
    await tester.pumpWidget(const LakbayTravelApp());
    expect(find.byType(LakbayBrandWordmark), findsWidgets);
    expect(find.textContaining('Lakbay'), findsWidgets);
  });

  test('MapboxService computes Davao bounds, Bezier animation, and URLs', () {
    final mapbox = MapboxService();
    expect(mapbox.hasValidToken, isFalse);

    mapbox.setCustomToken('pk.eyJ1Ijoic29sYXJhIiwiYSI6ImRlbW8ifQ.signature');
    expect(mapbox.hasValidToken, isTrue);

    final (cLat, cLng) = MapboxService.clampToDavaoRegion(14.5995, 120.9842);
    expect(
        cLat,
        inInclusiveRange(
            MapboxService.davaoMinLat, MapboxService.davaoMaxLat));
    expect(
        cLng,
        inInclusiveRange(
            MapboxService.davaoMinLng, MapboxService.davaoMaxLng));

    const waypoints = [
      GeoPoint(
          lat: 7.0644,
          lng: 125.6088,
          label: 'D1',
          legMode: TransportMode.flight),
      GeoPoint(
          lat: 6.9255, lng: 126.2772, label: 'D2', legMode: TransportMode.car),
    ];
    final staticUrl = mapbox.buildStaticRouteImageUrl(
      waypoints: waypoints,
      centerLat: 7.00,
      centerLng: 125.90,
    );
    expect(staticUrl, isNotNull);
    expect(staticUrl,
        contains('api.mapbox.com/styles/v1/mapbox/outdoors-v12/static/'));

    final distKm = MapboxService.calculateRouteDistanceKm(waypoints);
    expect(distKm, greaterThan(60));

    final pt = MapboxService.evaluateQuadraticBezier(
      const Offset(0, 0),
      const Offset(50, -30),
      const Offset(100, 0),
      0.5,
    );
    expect(pt.dx, closeTo(50, 0.01));
  });

  test('TravelRepository defaults to PHP currency and Davao Region datasets are valid', () {
    final repo = TravelRepository();
    expect(repo.currency, equals('PHP'));
    expect(repo.formatPrice(100), equals('₱5,700'));

    final davaoTrip = repo.generateCustomTrip(
      destination: 'Samal Island & Talikud Reefs',
      daysCount: 4,
      vibe: 'Island Hopping',
    );
    expect(davaoTrip.days.length, equals(4));
    expect(davaoTrip.centerLat, inInclusiveRange(5.2, 8.15));
    expect(davaoTrip.centerLng, inInclusiveRange(124.95, 126.85));

    final shortList = jsonDecode(
      File('assets/data/short_descriptions.json').readAsStringSync(),
    ) as List<dynamic>;
    final longList = jsonDecode(
      File('assets/data/descriptions.json').readAsStringSync(),
    ) as List<dynamic>;
    final sections = jsonDecode(
      File('assets/data/discovery_sections.json').readAsStringSync(),
    ) as Map<String, dynamic>;
    final csvLines = File('assets/data/explore_trips.csv').readAsLinesSync();

    expect(shortList.length, equals(24));
    expect(longList.length, equals(24));
    expect((sections['locales']['en']['sections'] as List).length, equals(6));
    expect(csvLines.length, equals(21)); // header + 20 Davao Region trips
  });

  test('EnvConfig parses API keys and ignores AI keys & configures CloudinaryService', () {
    EnvConfig.loadFromString('''
MAPBOX_ACCESS_TOKEN=pk.test_mapbox_123
GROQ_API_KEY=gsk_test_groq_123
GROQ_MODEL_DEFAULT=openai/gpt-oss-120b
GROQ_MODEL_FALLBACK=qwen/qwen3-32b
FALLBACK_LLM_API_KEY=AIza_test_gemini
FALLBACK_LLM_MODEL=gemini-2.5-flash,gemini-2.5-flash-lite
CLOUDINARY_CLOUD_NAME=lakbay_cloud
CLOUDINARY_UPLOAD_PRESET=lakbay_unsigned
''');

    expect(EnvConfig.mapboxAccessToken, equals('pk.test_mapbox_123'));
    expect(EnvConfig.hasCloudinaryConfig, isTrue);

    // AI keys in .env are ignored: AI runs only on the Lakbay backend, so an
    // app without a backend URL has no AI even if a key was left in .env.
    expect(LakbayAiService().isConfigured, isFalse);

    final cloudinary = CloudinaryService();
    expect(cloudinary.isConfigured, isTrue);
    expect(
      cloudinary.buildImageUrl('davao/samal', width: 800, height: 600),
      equals(
        'https://res.cloudinary.com/lakbay_cloud/image/upload/f_auto,q_auto,w_800,h_600,c_fill/davao/samal',
      ),
    );
  });
}
