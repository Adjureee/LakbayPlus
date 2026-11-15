import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/travel_models.dart';
import 'env_config.dart';

class LakbayApiException implements Exception {
  final int? statusCode;
  final String message;

  const LakbayApiException(this.message, {this.statusCode});

  @override
  String toString() => message;
}

/// Bridge connecting `apps/traveler_app` to the Lakbay+ FastAPI backend
/// (`destinations`, `accommodations`, `transportations`, `auth`, `trips`, `routes`,
/// `ai`, and `weather`) plus public live FX rates. Fails over cleanly offline.
class LakbayApiCatalogService {
  LakbayApiCatalogService({http.Client? client, this.baseUrlOverride})
      : _client = client ?? http.Client();

  final http.Client _client;
  final String? baseUrlOverride;

  String get _base {
    final raw = baseUrlOverride ?? EnvConfig.lakbayApiBaseUrl;
    return raw.trim().replaceAll(RegExp(r'/+$'), '');
  }

  bool get isConfigured => _base.isNotEmpty;

  /// Fetches all active destinations across pages (`limit` per request).
  Future<List<ExploreTrip>> fetchActiveDestinations({int limit = 100}) {
    return fetchAllActiveDestinations(pageSize: limit);
  }

  Future<List<ExploreTrip>> fetchAllActiveDestinations({
    int pageSize = 100,
    int maxPages = 10,
  }) async {
    final base = _base;
    if (base.isEmpty) return const [];

    final collected = <ExploreTrip>[];
    final seenIds = <String>{};

    try {
      for (var page = 0; page < maxPages; page++) {
        final offset = page * pageSize;
        final uri = Uri.parse('$base/destinations?limit=$pageSize&offset=$offset');
        final res = await _client.get(uri).timeout(const Duration(seconds: 8));
        if (res.statusCode != 200) break;

        final decoded = jsonDecode(res.body);
        final List<dynamic> rows;
        if (decoded is List) {
          rows = decoded;
        } else if (decoded is Map && decoded['items'] is List) {
          rows = decoded['items'] as List<dynamic>;
        } else {
          break;
        }

        if (rows.isEmpty) break;
        for (final raw in rows) {
          if (raw is! Map) continue;
          final trip = _parseDestination(raw);
          if (trip == null || seenIds.contains(trip.id)) continue;
          seenIds.add(trip.id);
          collected.add(trip);
        }
        if (rows.length < pageSize) break;
      }
      return collected;
    } catch (_) {
      return collected;
    }
  }

  ExploreTrip? _parseDestination(Map raw) {
    final idStr = (raw['destination_id'] ?? raw['id'] ?? '').toString().trim();
    final destId = int.tryParse(idStr);
    final name = (raw['name'] ?? '').toString().trim();
    final lat = _toDouble(raw['lat'] ?? raw['latitude']);
    final lng = _toDouble(raw['lng'] ?? raw['longitude']);
    if (idStr.isEmpty || name.isEmpty || lat == null || lng == null) return null;

    final district = (raw['district'] ?? raw['location'] ?? '').toString().trim();
    final category = (raw['category'] ?? '').toString().trim();
    final imageUrl = (raw['image_url'] ?? '').toString().trim();
    final description = (raw['description'] ?? '').toString().trim();
    final activities = (raw['activities'] ?? '').toString().trim();
    final estimatedCostPhp = _toDouble(raw['estimated_cost']);
    final entranceFee = (raw['entrance_fee'] ?? '').toString().trim();
    final overnightFee = (raw['overnight_fee'] ?? '').toString().trim();
    final operatingHours = (raw['operating_hours'] ?? '').toString().trim();
    final bestTime = (raw['best_time_to_visit'] ?? '').toString().trim();
    final travelNotes = (raw['travel_notes'] ?? '').toString().trim();
    final stayDuration = (raw['stay_duration_type'] ?? '').toString().toLowerCase();

    final inferredDays = stayDuration.contains('overnight') ||
            stayDuration.contains('multi') ||
            overnightFee.isNotEmpty
        ? 3
        : 2;

    return ExploreTrip(
      locale: 'en',
      id: 'api_$idStr',
      title: district.isNotEmpty ? '$name — $district' : name,
      days: inferredDays,
      lat: lat,
      lng: lng,
      thumbnailUrl: imageUrl,
      tag: category.isNotEmpty ? category : 'Live Catalog',
      apiDestinationId: destId,
      description: description.isNotEmpty ? description : null,
      district: district.isNotEmpty ? district : null,
      activities: activities.isNotEmpty ? activities : null,
      estimatedCostPhp: estimatedCostPhp,
      entranceFee: entranceFee.isNotEmpty ? entranceFee : null,
      overnightFee: overnightFee.isNotEmpty ? overnightFee : null,
      operatingHours: operatingHours.isNotEmpty ? operatingHours : null,
      bestTimeToVisit: bestTime.isNotEmpty ? bestTime : null,
      travelNotes: travelNotes.isNotEmpty ? travelNotes : null,
    );
  }

  /// Pulls live admin-maintained accommodations and transportation rates for a
  /// synced backend destination (`/destinations/{id}/accommodations` & `/transportations`).
  Future<({List<HotelOffer> hotels, List<AdminTransportRate> transports})>
      fetchDestinationMarketRates(
    int destinationId, {
    String city = 'Davao Region',
    String fallbackImageAsset = 'assets/home_backdrops/04-thoddoo.jpg',
    String? remoteImageUrl,
    double lat = 7.0731,
    double lng = 125.6128,
    double phpPerUsd = 57.0,
  }) async {
    final base = _base;
    if (base.isEmpty) {
      return (hotels: const <HotelOffer>[], transports: const <AdminTransportRate>[]);
    }

    try {
      final results = await Future.wait([
        _client
            .get(Uri.parse('$base/destinations/$destinationId/accommodations'))
            .timeout(const Duration(seconds: 8)),
        _client
            .get(Uri.parse('$base/destinations/$destinationId/transportations'))
            .timeout(const Duration(seconds: 8)),
      ]);

      final hotels = <HotelOffer>[];
      final accRes = results[0];
      if (accRes.statusCode == 200) {
        final decoded = jsonDecode(accRes.body);
        if (decoded is List) {
          for (final raw in decoded) {
            if (raw is! Map) continue;
            if (raw['is_available'] == false) continue;
            final accId = (raw['accommodation_id'] as num?)?.toInt();
            final pricePhp = _toDouble(raw['price']) ?? 0;
            final priceUsd =
                (pricePhp / phpPerUsd).round().clamp(12, 2500);
            final roomType = (raw['room_type'] ?? 'Standard Room').toString();
            final chargingUnit = (raw['charging_unit'] ?? 'per_room_per_night')
                .toString()
                .replaceAll('_', ' ');
            final capacity = (raw['capacity'] as num?)?.toInt() ?? 2;
            hotels.add(
              HotelOffer(
                id: 'acc_${accId ?? hotels.length + 1}',
                name: (raw['name'] ?? 'Partner Stay').toString(),
                city: city,
                rating: 9.2,
                stars: pricePhp >= 6000 ? 5 : 4,
                pricePerNightUsd: priceUsd,
                facilities: [
                  roomType,
                  'Capacity: $capacity',
                  chargingUnit,
                ],
                partnerName: 'Admin Verified Rate',
                imageAsset: fallbackImageAsset,
                remoteImageUrl: remoteImageUrl,
                lat: lat,
                lng: lng,
                apiAccommodationId: accId,
              ),
            );
          }
        }
      }

      final transports = <AdminTransportRate>[];
      final trRes = results[1];
      if (trRes.statusCode == 200) {
        final decoded = jsonDecode(trRes.body);
        if (decoded is List) {
          for (final raw in decoded) {
            if (raw is! Map<String, dynamic>) continue;
            if (raw['is_available'] == false) continue;
            transports.add(AdminTransportRate.fromApi(raw));
          }
        }
      }

      return (hotels: hotels, transports: transports);
    } catch (_) {
      return (hotels: const <HotelOffer>[], transports: const <AdminTransportRate>[]);
    }
  }

  Future<LakbayAuthSession> login({
    required String email,
    required String password,
  }) async {
    return _postAuth(
      path: '/auth/login',
      body: {'email': email.trim(), 'password': password},
    );
  }

  Future<LakbayAuthSession> register({
    required String fullName,
    required String email,
    required String password,
    String? confirmPassword,
  }) async {
    return _postAuth(
      path: '/auth/register',
      body: {
        'full_name': fullName.trim(),
        'email': email.trim(),
        'password': password,
        'confirm_password': confirmPassword ?? password,
      },
    );
  }

  Future<LakbayAuthSession> googleLogin({required String idToken}) async {
    return _postAuth(
      path: '/auth/google',
      body: {'id_token': idToken},
    );
  }

  Future<LakbayAuthSession> refreshSession(String refreshToken) async {
    return _postAuth(
      path: '/auth/refresh',
      body: {'refresh_token': refreshToken},
    );
  }

  Future<void> logout(String refreshToken) async {
    final base = _base;
    if (base.isEmpty || refreshToken.isEmpty) return;
    try {
      await _client
          .post(
            Uri.parse('$base/auth/logout'),
            headers: const {'Content-Type': 'application/json'},
            body: jsonEncode({'refresh_token': refreshToken}),
          )
          .timeout(const Duration(seconds: 6));
    } catch (_) {
      // Local logout still succeeds cleanly offline.
    }
  }

  Future<LakbayAuthSession> _postAuth({
    required String path,
    required Map<String, dynamic> body,
  }) async {
    final base = _base;
    if (base.isEmpty) {
      throw const LakbayApiException(
        'LAKBAY_API_BASE_URL is not configured for backend sign-in.',
      );
    }
    final res = await _client
        .post(
          Uri.parse('$base$path'),
          headers: const {'Content-Type': 'application/json'},
          body: jsonEncode(body),
        )
        .timeout(const Duration(seconds: 12));

    final decoded = _tryDecodeJson(res.body);
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw LakbayApiException(
        _extractErrorMessage(decoded, res.statusCode),
        statusCode: res.statusCode,
      );
    }
    if (decoded is! Map<String, dynamic>) {
      throw const LakbayApiException('Unexpected authentication response.');
    }
    final user = decoded['user'] as Map<String, dynamic>? ?? const {};
    final tokens = decoded['tokens'] as Map<String, dynamic>? ?? const {};
    return LakbayAuthSession(
      accessToken: (tokens['access_token'] ?? '').toString(),
      refreshToken: (tokens['refresh_token'] ?? '').toString(),
      userId: (user['user_id'] as num?)?.toInt() ?? 0,
      fullName: (user['full_name'] ?? '').toString(),
      email: (user['email'] ?? '').toString(),
      role: (user['role'] ?? 'traveler').toString(),
    );
  }

  Future<List<Map<String, dynamic>>> getMyTrips(String accessToken) async {
    final base = _base;
    if (base.isEmpty || accessToken.isEmpty) return const [];
    try {
      final res = await _client
          .get(
            Uri.parse('$base/trips'),
            headers: {'Authorization': 'Bearer $accessToken'},
          )
          .timeout(const Duration(seconds: 10));
      if (res.statusCode != 200) return const [];
      final decoded = jsonDecode(res.body);
      if (decoded is List) {
        return decoded.whereType<Map<String, dynamic>>().toList();
      }
      return const [];
    } catch (_) {
      return const [];
    }
  }

  Future<int?> createTrip(
    String accessToken, {
    required String title,
    String? description,
    int travelerCount = 2,
    required double totalBudgetPhp,
    required double estimatedTotalCostPhp,
    required List<int> destinationIds,
    String? notes,
    Map<String, dynamic>? itineraryDays,
  }) async {
    final base = _base;
    if (base.isEmpty || accessToken.isEmpty || destinationIds.isEmpty) {
      return null;
    }
    try {
      final payload = <String, dynamic>{
        'title': title.length >= 2 ? title : 'Davao Trip',
        if (description != null && description.isNotEmpty)
          'description': description,
        'traveler_count': travelerCount.clamp(1, 100),
        'total_budget': totalBudgetPhp.toStringAsFixed(2),
        'estimated_total_cost': estimatedTotalCostPhp.toStringAsFixed(2),
        'destination_ids': destinationIds.toSet().toList(),
        if (notes != null && notes.isNotEmpty) 'notes': notes,
        'itinerary_days': ?itineraryDays,
      };
      final res = await _client
          .post(
            Uri.parse('$base/trips'),
            headers: {
              'Authorization': 'Bearer $accessToken',
              'Content-Type': 'application/json',
            },
            body: jsonEncode(payload),
          )
          .timeout(const Duration(seconds: 12));
      if (res.statusCode < 200 || res.statusCode >= 300) return null;
      final decoded = _tryDecodeJson(res.body);
      if (decoded is Map<String, dynamic>) {
        return (decoded['trip_id'] as num?)?.toInt();
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  Future<BackendRouteResult?> previewRoute(
    String accessToken, {
    required List<int> destinationIds,
    String travelMode = 'driving',
  }) {
    return _fetchRoute(
      path: '/routes/preview',
      accessToken: accessToken,
      body: {
        'destination_ids': destinationIds.toSet().toList(),
        'travel_mode': travelMode,
      },
    );
  }

  Future<BackendRouteResult?> optimizeRoute(
    String accessToken, {
    required List<int> destinationIds,
    String travelMode = 'driving',
  }) {
    return _fetchRoute(
      path: '/routes/optimize',
      accessToken: accessToken,
      body: {
        'destination_ids': destinationIds.toSet().toList(),
        'travel_mode': travelMode,
        'preserve_first_destination': true,
      },
    );
  }

  Future<BackendRouteResult?> _fetchRoute({
    required String path,
    required String accessToken,
    required Map<String, dynamic> body,
  }) async {
    final base = _base;
    final destIds = body['destination_ids'] as List<dynamic>? ?? const [];
    if (base.isEmpty || accessToken.isEmpty || destIds.isEmpty) return null;
    try {
      final res = await _client
          .post(
            Uri.parse('$base$path'),
            headers: {
              'Authorization': 'Bearer $accessToken',
              'Content-Type': 'application/json',
            },
            body: jsonEncode(body),
          )
          .timeout(const Duration(seconds: 12));
      if (res.statusCode < 200 || res.statusCode >= 300) return null;
      final decoded = jsonDecode(res.body);
      if (decoded is! Map<String, dynamic>) return null;

      final encodedPolyline = decoded['polyline']?.toString() ?? '';
      final stops = (decoded['stops'] as List<dynamic>? ?? const [])
          .whereType<Map<String, dynamic>>()
          .toList();
      final decodedPts = encodedPolyline.isNotEmpty
          ? decodePolyline5(encodedPolyline)
          : stops
              .map(
                (s) => GeoPoint(
                  lat: _toDouble(s['lat']) ?? 7.0731,
                  lng: _toDouble(s['lng']) ?? 125.6128,
                  label: s['name']?.toString(),
                ),
              )
              .toList();

      return BackendRouteResult(
        routeProvider: (decoded['route_provider'] ?? 'osrm').toString(),
        isEstimated: decoded['is_estimated'] == true,
        totalDistanceKm: _toDouble(decoded['total_distance_km']) ?? 0,
        totalDurationMinutes:
            (decoded['total_duration_minutes'] as num?)?.toInt() ?? 0,
        geometryPoints: decodedPts,
        warnings: (decoded['warnings'] as List<dynamic>? ?? const [])
            .map((e) => e.toString())
            .toList(),
        orderedDestinationIds: stops
            .map((s) => (s['destination_id'] as num?)?.toInt())
            .whereType<int>()
            .toList(),
      );
    } catch (_) {
      return null;
    }
  }

  Future<({String replyText, String modelId, List<Map<String, dynamic>> results})?>
      aiChat(
    String accessToken, {
    required String message,
    List<Map<String, String>> history = const [],
  }) async {
    final base = _base;
    if (base.isEmpty || accessToken.isEmpty) return null;
    try {
      final res = await _client
          .post(
            Uri.parse('$base/ai/chat'),
            headers: {
              'Authorization': 'Bearer $accessToken',
              'Content-Type': 'application/json',
            },
            body: jsonEncode({
              'message': message,
              'history': history,
              'use_rag': true,
            }),
          )
          .timeout(const Duration(seconds: 25));
      if (res.statusCode < 200 || res.statusCode >= 300) return null;
      final decoded = jsonDecode(res.body);
      if (decoded is! Map<String, dynamic>) return null;
      final reply = (decoded['chat_response'] ?? '').toString().trim();
      if (reply.isEmpty) return null;
      return (
        replyText: reply,
        modelId: (decoded['model_id'] ?? 'lakbay-api').toString(),
        results: (decoded['results'] as List<dynamic>? ?? const [])
            .whereType<Map<String, dynamic>>()
            .toList(),
      );
    } catch (_) {
      return null;
    }
  }

  Future<({int tempC, int wmoCode, String condition})?> getCurrentWeather(
    String accessToken, {
    required double lat,
    required double lng,
  }) async {
    final base = _base;
    if (base.isEmpty || accessToken.isEmpty) return null;
    try {
      final res = await _client
          .get(
            Uri.parse('$base/weather/current?lat=$lat&lng=$lng'),
            headers: {'Authorization': 'Bearer $accessToken'},
          )
          .timeout(const Duration(seconds: 8));
      if (res.statusCode != 200) return null;
      final decoded = jsonDecode(res.body);
      if (decoded is! Map<String, dynamic>) return null;
      final temp = (decoded['temp_c'] as num?)?.round();
      final cond = decoded['condition'] as Map<String, dynamic>? ?? const {};
      final owCode = (cond['code'] as num?)?.toInt();
      final main = (cond['main'] ?? 'Partly Cloudy').toString();
      if (temp == null) return null;
      return (
        tempC: temp,
        wmoCode: _openWeatherCodeToWmo(owCode),
        condition: main,
      );
    } catch (_) {
      return null;
    }
  }

  /// Fetches live USD FX rates for PHP, EUR, GBP, AUD, and JPY from Open ER-API.
  Future<Map<String, double>?> fetchLiveUsdRates() async {
    try {
      final res = await _client
          .get(Uri.parse('https://open.er-api.com/v6/latest/USD'))
          .timeout(const Duration(seconds: 6));
      if (res.statusCode != 200) return null;
      final decoded = jsonDecode(res.body);
      if (decoded is! Map<String, dynamic>) return null;
      final rates = decoded['rates'] as Map<String, dynamic>? ?? const {};
      const supported = ['PHP', 'USD', 'EUR', 'GBP', 'AUD', 'JPY'];
      final parsed = <String, double>{};
      for (final code in supported) {
        final v = _toDouble(rates[code]);
        if (v != null && v > 0) parsed[code] = v;
      }
      return parsed.containsKey('PHP') ? parsed : null;
    } catch (_) {
      return null;
    }
  }

  /// Decodes Google / OSRM precision-5 encoded polyline strings into coordinates.
  static List<GeoPoint> decodePolyline5(String encoded) {
    final points = <GeoPoint>[];
    var index = 0;
    var lat = 0;
    var lng = 0;

    while (index < encoded.length) {
      var shift = 0;
      var result = 0;
      int byte;
      do {
        if (index >= encoded.length) return points;
        byte = encoded.codeUnitAt(index++) - 63;
        result |= (byte & 0x1f) << shift;
        shift += 5;
      } while (byte >= 0x20);
      final dLat = (result & 1) != 0 ? ~(result >> 1) : (result >> 1);
      lat += dLat;

      shift = 0;
      result = 0;
      do {
        if (index >= encoded.length) return points;
        byte = encoded.codeUnitAt(index++) - 63;
        result |= (byte & 0x1f) << shift;
        shift += 5;
      } while (byte >= 0x20);
      final dLng = (result & 1) != 0 ? ~(result >> 1) : (result >> 1);
      lng += dLng;

      points.add(GeoPoint(lat: lat / 1e5, lng: lng / 1e5));
    }
    return points;
  }

  static int _openWeatherCodeToWmo(int? code) {
    if (code == null) return 2;
    if (code == 800) return 0;
    if (code == 801) return 1;
    if (code == 802) return 2;
    if (code >= 803) return 3;
    if (code >= 200 && code < 600) return 80;
    return 2;
  }

  static dynamic _tryDecodeJson(String body) {
    if (body.trim().isEmpty) return null;
    try {
      return jsonDecode(body);
    } on FormatException {
      return null;
    }
  }

  static String _extractErrorMessage(dynamic decoded, int statusCode) {
    if (decoded is Map) {
      final err = decoded['error'];
      if (err is Map && err['message'] != null) {
        return err['message'].toString();
      }
      if (decoded['detail'] != null) {
        return decoded['detail'].toString();
      }
      if (decoded['message'] != null) {
        return decoded['message'].toString();
      }
    }
    return 'Request failed with status $statusCode.';
  }

  static double? _toDouble(dynamic value) {
    if (value is num) return value.toDouble();
    if (value is String) return double.tryParse(value);
    return null;
  }
}
