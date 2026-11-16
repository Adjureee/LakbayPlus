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

  /// Optional callback invoked when a bearer-authenticated request receives
  /// 401 Unauthorized, returning a refreshed access token for one retry.
  Future<String?> Function()? onUnauthorizedRefresh;

  Future<http.Response> _sendAuthorized(
    String accessToken,
    Future<http.Response> Function(String token) send,
  ) async {
    final first = await send(accessToken);
    if (first.statusCode != 401 || onUnauthorizedRefresh == null) {
      return first;
    }
    final nextToken = (await onUnauthorizedRefresh!() ?? '').trim();
    if (nextToken.isEmpty || nextToken == accessToken) {
      return first;
    }
    return send(nextToken);
  }

  /// Sends a POST request with bearer auth (and 401 refresh retry) when
  /// signed in, or directly to [guestPath] when signed out or if 401 persists.
  Future<http.Response> _postAuthedOrGuest({
    required String? accessToken,
    required String authedPath,
    required String guestPath,
    required String encodedBody,
    required Duration timeout,
  }) async {
    Future<http.Response> postGuest() => _client
        .post(
          Uri.parse('$_base$guestPath'),
          headers: const {'Content-Type': 'application/json'},
          body: encodedBody,
        )
        .timeout(timeout);

    final token = (accessToken ?? '').trim();
    if (token.isEmpty) return postGuest();
    final res = await _sendAuthorized(
      token,
      (tok) => _client
          .post(
            Uri.parse('$_base$authedPath'),
            headers: _authHeaders(tok),
            body: encodedBody,
          )
          .timeout(timeout),
    );
    return res.statusCode == 401 ? postGuest() : res;
  }

  String get _base {
    final raw = baseUrlOverride ?? EnvConfig.lakbayApiBaseUrl;
    return raw.trim().replaceAll(RegExp(r'/+$'), '');
  }

  bool get isConfigured => _base.isNotEmpty;

  /// The preference groups travelers can choose, with live counts. Empty when
  /// the server cannot be reached, so callers keep what they already have.
  Future<List<PreferenceGroup>> fetchPreferenceGroups() async {
    final base = _base;
    if (base.isEmpty) return const [];
    try {
      final res = await _client
          .get(Uri.parse('$base/destinations/facets'))
          .timeout(const Duration(seconds: 8));
      if (res.statusCode != 200) return const [];
      final decoded = jsonDecode(res.body);
      final groups = decoded is Map ? decoded['groups'] : null;
      if (groups is! List) return const [];
      return groups
          .whereType<Map<String, dynamic>>()
          .map(PreferenceGroup.fromJson)
          .where((g) => g.key.isNotEmpty && g.label.isNotEmpty)
          .toList();
    } catch (_) {
      return const [];
    }
  }

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
    final whatToBring = (raw['what_to_bring'] ?? '').toString().trim();
    final stayDurationRaw =
        (raw['stay_duration_type'] ?? '').toString().trim().toLowerCase();
    final islandGroupRaw =
        (raw['island_group'] ?? '').toString().trim().toLowerCase();
    final stayDuration = normalizeStayDurationType(
      stayDurationRaw,
      category: category,
      overnightFee: overnightFee,
    );

    return ExploreTrip(
      locale: 'en',
      id: 'api_$idStr',
      title: name,
      days: 1,
      lat: lat,
      lng: lng,
      thumbnailUrl: imageUrl,
      tag: category.isNotEmpty ? category : 'Place',
      apiDestinationId: destId,
      islandGroup: islandGroupRaw.isNotEmpty ? islandGroupRaw : null,
      stayDurationType: stayDuration,
      description: description.isNotEmpty ? description : null,
      district: district.isNotEmpty ? district : null,
      activities: activities.isNotEmpty ? activities : null,
      estimatedCostPhp: estimatedCostPhp,
      entranceFee: entranceFee.isNotEmpty ? entranceFee : null,
      overnightFee: overnightFee.isNotEmpty ? overnightFee : null,
      operatingHours: operatingHours.isNotEmpty ? operatingHours : null,
      bestTimeToVisit: bestTime.isNotEmpty ? bestTime : null,
      travelNotes: travelNotes.isNotEmpty ? travelNotes : null,
      whatToBring: whatToBring.isNotEmpty ? whatToBring : null,
    );
  }

  /// Pulls live admin-maintained accommodations and transportation rates for a
  /// synced backend destination (`/destinations/{id}/accommodations` & `/transportations`).
  Future<({List<HotelOffer> hotels, List<AdminTransportRate> transports})>
      fetchDestinationMarketRates(
    int destinationId, {
    String city = 'Davao Region',
    String fallbackImageAsset = 'assets/home_backdrops/01-samal-island.jpg',
    String? remoteImageUrl,
    // Where the trip is: hotels without their own pin are shown here.
    required double lat,
    required double lng,
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
      final res = await _sendAuthorized(
        accessToken,
        (tok) => _client
            .get(
              Uri.parse('$base/trips'),
              headers: {'Authorization': 'Bearer $tok'},
            )
            .timeout(const Duration(seconds: 10)),
      );
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
    List<Map<String, dynamic>>? itineraryDays,
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
        if (itineraryDays != null && itineraryDays.isNotEmpty)
          'itinerary_days': itineraryDays,
      };
      final encodedPayload = jsonEncode(payload);
      final res = await _sendAuthorized(
        accessToken,
        (tok) => _client
            .post(
              Uri.parse('$base/trips'),
              headers: _authHeaders(tok),
              body: encodedPayload,
            )
            .timeout(const Duration(seconds: 12)),
      );
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

  Future<Map<String, dynamic>?> getTripDetail(
    String accessToken,
    int tripId,
  ) async {
    final base = _base;
    if (base.isEmpty || accessToken.isEmpty) return null;
    try {
      final res = await _sendAuthorized(
        accessToken,
        (tok) => _client
            .get(
              Uri.parse('$base/trips/$tripId'),
              headers: _authHeaders(tok, json: false),
            )
            .timeout(const Duration(seconds: 10)),
      );
      if (res.statusCode != 200) return null;
      final decoded = _tryDecodeJson(res.body);
      return decoded is Map<String, dynamic> ? decoded : null;
    } catch (_) {
      return null;
    }
  }

  Future<bool> updateTrip(
    String accessToken,
    int tripId, {
    String? title,
    String? description,
    int? travelerCount,
    double? totalBudgetPhp,
    double? estimatedTotalCostPhp,
    String? status,
    String? notes,
  }) async {
    final base = _base;
    if (base.isEmpty || accessToken.isEmpty) return false;
    final payload = <String, dynamic>{
      if (title != null && title.trim().length >= 2) 'title': title.trim(),
      'description': ?description,
      if (travelerCount != null) 'traveler_count': travelerCount.clamp(1, 100),
      if (totalBudgetPhp != null)
        'total_budget': totalBudgetPhp.toStringAsFixed(2),
      if (estimatedTotalCostPhp != null)
        'estimated_total_cost': estimatedTotalCostPhp.toStringAsFixed(2),
      'status': ?status,
      'notes': ?notes,
    };
    if (payload.isEmpty) return true;
    try {
      final encodedPayload = jsonEncode(payload);
      final res = await _sendAuthorized(
        accessToken,
        (tok) => _client
            .patch(
              Uri.parse('$base/trips/$tripId'),
              headers: _authHeaders(tok),
              body: encodedPayload,
            )
            .timeout(const Duration(seconds: 10)),
      );
      return res.statusCode >= 200 && res.statusCode < 300;
    } catch (_) {
      return false;
    }
  }

  Future<bool> deleteTrip(String accessToken, int tripId) async {
    final base = _base;
    if (base.isEmpty || accessToken.isEmpty) return false;
    try {
      final res = await _sendAuthorized(
        accessToken,
        (tok) => _client
            .delete(
              Uri.parse('$base/trips/$tripId'),
              headers: _authHeaders(tok, json: false),
            )
            .timeout(const Duration(seconds: 10)),
      );
      return res.statusCode >= 200 && res.statusCode < 300;
    } catch (_) {
      return false;
    }
  }

  Future<int?> createTripFromAiOption(
    String accessToken, {
    required int generationRunId,
    required int optionNumber,
    String? notes,
  }) async {
    final base = _base;
    if (base.isEmpty || accessToken.isEmpty) return null;
    try {
      final encodedPayload = jsonEncode({
        'generation_run_id': generationRunId,
        'option_number': optionNumber,
        if (notes != null && notes.isNotEmpty) 'notes': notes,
      });
      final res = await _sendAuthorized(
        accessToken,
        (tok) => _client
            .post(
              Uri.parse('$base/trips/from-ai-option'),
              headers: _authHeaders(tok),
              body: encodedPayload,
            )
            .timeout(const Duration(seconds: 12)),
      );
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

  /// [origin] is where the traveler starts (usually their GPS position); the
  /// route then begins there instead of at the first stop.
  Future<BackendRouteResult?> previewRoute(
    String accessToken, {
    required List<int> destinationIds,
    String travelMode = 'driving',
    GeoPoint? origin,
  }) {
    return _fetchRoute(
      path: '/routes/preview',
      accessToken: accessToken,
      body: {
        'destination_ids': destinationIds.toSet().toList(),
        'travel_mode': travelMode,
        if (origin != null) 'origin': _routeOrigin(origin),
      },
    );
  }

  Future<BackendRouteResult?> optimizeRoute(
    String accessToken, {
    required List<int> destinationIds,
    String travelMode = 'driving',
    GeoPoint? origin,
  }) {
    return _fetchRoute(
      path: '/routes/optimize',
      accessToken: accessToken,
      body: {
        'destination_ids': destinationIds.toSet().toList(),
        'travel_mode': travelMode,
        // With an origin, the origin is the fixed start and every stop may move.
        if (origin != null)
          'origin': _routeOrigin(origin)
        else
          'preserve_first_destination': true,
      },
    );
  }

  static Map<String, dynamic> _routeOrigin(GeoPoint origin) => {
        'label': (origin.label ?? '').trim().isEmpty
            ? 'My location'
            : origin.label!.trim(),
        'lat': origin.lat,
        'lng': origin.lng,
      };

  /// Plans an adaptive multi-day itinerary via `/routes/plan` or `/routes/plan/guest`.
  Future<BackendRoutePlanResult?> planRoute(
    String? accessToken, {
    required List<int> destinationIds,
    required int days,
    String pace = 'balanced',
    String travelMode = 'driving',
    GeoPoint? origin,
    bool returnToOrigin = false,
    bool preserveFirstDestination = false,
    int? lockedFirstDestinationId,
    List<int>? mustVisitDestinationIds,
    bool pruneOptionalToFit = false,
  }) async {
    final base = _base;
    final uniqueIds = destinationIds.toSet().toList();
    if (base.isEmpty || uniqueIds.isEmpty) return null;
    try {
      final encodedPayload = jsonEncode({
        'destination_ids': uniqueIds,
        'travel_mode': travelMode,
        'days': days.clamp(1, 14),
        'pace': pace,
        if (origin != null) 'origin': _routeOrigin(origin),
        'return_to_origin': origin != null && returnToOrigin,
        'preserve_first_destination': preserveFirstDestination,
        'locked_first_destination_id': ?lockedFirstDestinationId,
        if (mustVisitDestinationIds != null)
          'must_visit_destination_ids': mustVisitDestinationIds.toSet().toList(),
        'prune_optional_to_fit': pruneOptionalToFit,
      });
      final res = await _postAuthedOrGuest(
        accessToken: accessToken,
        authedPath: '/routes/plan',
        guestPath: '/routes/plan/guest',
        encodedBody: encodedPayload,
        timeout: _routeRequestTimeout,
      );
      if (res.statusCode < 200 || res.statusCode >= 300) return null;
      final decoded = jsonDecode(res.body);
      if (decoded is! Map<String, dynamic>) return null;
      final routeMap = decoded['route'];
      if (routeMap is! Map<String, dynamic>) return null;
      final parsedRoute = _parseRouteResult(routeMap);
      final rawSavings =
          decoded['savings_vs_input'] as Map<String, dynamic>? ?? const {};
      final suggestedDays =
          (decoded['suggested_days'] as num?)?.toInt() ?? days.clamp(1, 14);
      final orderMethod =
          (decoded['order_method'] ?? 'requested').toString();
      final costSource =
          (decoded['cost_source'] ?? parsedRoute.routeProvider).toString();
      final parsedPace = (decoded['pace'] ?? pace).toString();

      final rawDays = (decoded['days'] as List<dynamic>? ?? const [])
          .whereType<Map<String, dynamic>>();
      final parsedDays = <BackendRoutePlanDay>[];
      for (final dayMap in rawDays) {
        final rawStops = (dayMap['stops'] as List<dynamic>? ?? const [])
            .whereType<Map<String, dynamic>>();
        // A stop without coordinates is dropped, not placed at a made-up spot.
        final stops = rawStops
            .where((s) => _toDouble(s['lat']) != null && _toDouble(s['lng']) != null)
            .map(
              (s) => BackendRoutePlanStop(
                destinationId: (s['destination_id'] as num?)?.toInt(),
                name: s['name']?.toString() ?? 'Stop',
                lat: _toDouble(s['lat'])!,
                lng: _toDouble(s['lng'])!,
                islandGroup: s['island_group']?.toString(),
                stayDurationType:
                    s['stay_duration_type']?.toString() ?? 'half_day',
                visitHours: _toDouble(s['visit_hours']) ?? 4.0,
              ),
            )
            .toList();
        parsedDays.add(
          BackendRoutePlanDay(
            dayNumber: (dayMap['day_number'] as num?)?.toInt() ??
                (parsedDays.length + 1),
            stops: stops,
            visitHours: _toDouble(dayMap['visit_hours']) ?? 0,
            transitHours: _toDouble(dayMap['transit_hours']) ?? 0,
            totalHours: _toDouble(dayMap['total_hours']) ?? 0,
            isContinuationDay: dayMap['is_continuation_day'] == true,
            continuationOfName: dayMap['continuation_of_name']?.toString(),
            isOverloaded: dayMap['is_overloaded'] == true,
            overloadWarning: dayMap['overload_warning']?.toString(),
          ),
        );
      }

      return BackendRoutePlanResult(
        summary: RoutePlanOptimizationSummary(
          orderMethod: orderMethod,
          costSource: costSource,
          baselineDistanceKm:
              _toDouble(rawSavings['baseline_distance_km']) ?? 0,
          optimizedDistanceKm:
              _toDouble(rawSavings['optimized_distance_km']) ??
                  parsedRoute.totalDistanceKm,
          distanceSavedKm: _toDouble(rawSavings['distance_saved_km']) ?? 0,
          distanceSavedPercent:
              _toDouble(rawSavings['distance_saved_percent']) ?? 0,
          baselineTransitMinutes:
              _toDouble(rawSavings['baseline_transit_minutes']) ?? 0,
          optimizedTransitMinutes:
              _toDouble(rawSavings['optimized_transit_minutes']) ??
                  parsedRoute.totalDurationMinutes.toDouble(),
          minutesSaved: _toDouble(rawSavings['minutes_saved']) ?? 0,
          pace: parsedPace,
          suggestedDays: suggestedDays,
          roundtrip: origin != null && returnToOrigin,
        ),
        warnings: (decoded['warnings'] as List<dynamic>? ?? const [])
            .map((e) => e.toString())
            .toList(),
        skippedDestinationIds:
            (decoded['skipped_destination_ids'] as List<dynamic>? ?? const [])
                .whereType<num>()
                .map((n) => n.toInt())
                .toList(),
        days: parsedDays,
        route: parsedRoute,
      );
    } catch (_) {
      return null;
    }
  }

  static const Duration _routeRequestTimeout = Duration(seconds: 30);

  Future<BackendRouteResult?> _fetchRoute({
    required String path,
    required String accessToken,
    required Map<String, dynamic> body,
  }) async {
    final base = _base;
    final destIds = body['destination_ids'] as List<dynamic>? ?? const [];
    if (base.isEmpty || accessToken.isEmpty || destIds.isEmpty) return null;
    try {
      final encodedBody = jsonEncode(body);
      final res = await _sendAuthorized(
        accessToken,
        (tok) => _client
            .post(
              Uri.parse('$base$path'),
              headers: _authHeaders(tok),
              body: encodedBody,
            )
            // Long mountain routes and a Render cold start can exceed 12 s.
            .timeout(_routeRequestTimeout),
      );
      if (res.statusCode < 200 || res.statusCode >= 300) return null;
      final decoded = jsonDecode(res.body);
      if (decoded is! Map<String, dynamic>) return null;
      return _parseRouteResult(decoded);
    } catch (_) {
      return null;
    }
  }

  static BackendRouteResult _parseRouteResult(Map<String, dynamic> decoded) {
    final encodedPolyline = decoded['polyline']?.toString() ?? '';
    final stops = (decoded['stops'] as List<dynamic>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .toList();
    // Only provider road geometry counts as a route. Estimated responses
    // (Haversine) have no polyline; joining their stops would draw a line
    // straight across the sea, so leave the geometry empty instead.
    final decodedPts =
        encodedPolyline.isNotEmpty && decoded['is_estimated'] != true
            ? decodePolyline5(encodedPolyline)
            : const <GeoPoint>[];

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
      segments: _parseRouteSegments(decoded['segments']),
      seaCrossings: _parseSeaCrossings(decoded['sea_crossings']),
    );
  }

  static List<RouteSegmentGeometry> _parseRouteSegments(Object? raw) {
    if (raw is! List) return const [];
    final segments = <RouteSegmentGeometry>[];
    for (final item in raw.whereType<Map<String, dynamic>>()) {
      final encoded = item['polyline']?.toString() ?? '';
      if (encoded.isEmpty) continue;
      final points = decodePolyline5(encoded);
      if (points.length < 2) continue;
      segments.add(RouteSegmentGeometry(
        mode: item['mode'] == 'sea' ? TransportMode.ferry : TransportMode.car,
        points: points,
        fromName: item['from_name']?.toString() ?? '',
        toName: item['to_name']?.toString() ?? '',
        isEstimated: item['is_estimated'] == true,
      ));
    }
    return segments;
  }

  static List<SeaCrossingInfo> _parseSeaCrossings(Object? raw) {
    if (raw is! List) return const [];
    return raw
        .whereType<Map<String, dynamic>>()
        .map((item) => SeaCrossingInfo(
              vesselType: item['vessel_type']?.toString() ?? '',
              boardPort: item['board_port']?.toString() ?? 'Pier',
              landPort: item['land_port']?.toString() ?? 'Pier',
              boardLat: _toDouble(item['board_lat']) ?? 0,
              boardLng: _toDouble(item['board_lng']) ?? 0,
              landLat: _toDouble(item['land_lat']) ?? 0,
              landLng: _toDouble(item['land_lng']) ?? 0,
              crossingMinutes: (item['crossing_minutes'] as num?)?.toInt() ?? 0,
              typicalWaitMinutes:
                  (item['typical_wait_minutes'] as num?)?.toInt() ?? 0,
              allowsPrivateVehicle: item['allows_private_vehicle'] == true,
              scheduleText: item['schedule_text']?.toString(),
              farePassenger: _toDouble(item['fare_passenger']),
              fareVehicle: _toDouble(item['fare_vehicle']),
              verified: item['verified'] == true,
            ))
        .toList();
  }

  Future<({
    String replyText,
    String modelId,
    List<Map<String, dynamic>> results,
    List<Map<String, dynamic>> retrievedContext,
    Map<String, dynamic>? planning,
  })?> aiChat(
    String? accessToken, {
    required String message,
    List<Map<String, String>> history = const [],
    Map<String, dynamic>? planningState,
    int inputRevision = 0,
    String modelRole = 'default',
  }) async {
    final base = _base;
    if (base.isEmpty) return null;
    // Signed out or expired-token fallback: rate-limited guest endpoint.
    try {
      final payload = <String, dynamic>{
        'message': message,
        'history': history,
        'use_rag': true,
        'model_role': modelRole,
        'planning_state': ?planningState,
        if (planningState != null) 'input_revision': inputRevision,
      };
      final res = await _postAuthedOrGuest(
        accessToken: accessToken,
        authedPath: '/ai/chat',
        guestPath: '/ai/chat/guest',
        encodedBody: jsonEncode(payload),
        timeout: const Duration(seconds: 28),
      );
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
        retrievedContext:
            (decoded['retrieved_context'] as List<dynamic>? ?? const [])
                .whereType<Map<String, dynamic>>()
                .toList(),
        planning: decoded['planning'] is Map<String, dynamic>
            ? decoded['planning'] as Map<String, dynamic>
            : null,
      );
    } catch (_) {
      return null;
    }
  }

  /// Quick structured trip draft from the backend (guest or signed in).
  /// Returns the draft JSON plus the model that wrote it, or null on failure.
  Future<({Map<String, dynamic> draft, String modelId, String provider})?>
      aiTripDraft({
    String? accessToken,
    required String message,
    List<Map<String, String>> history = const [],
    String? currentLocation,
    double? userLat,
    double? userLng,
    List<String> preferredVibes = const [],
    bool strictBudget = false,
    int defaultDays = 3,
  }) async {
    final base = _base;
    if (base.isEmpty) return null;
    final token = (accessToken ?? '').trim();
    try {
      final encodedPayload = jsonEncode({
        'message': message,
        'history': history,
        'current_location': ?currentLocation,
        if (userLat != null && userLng != null) 'user_lat': userLat,
        if (userLat != null && userLng != null) 'user_lng': userLng,
        'preferred_vibes': preferredVibes.take(10).toList(),
        'strict_budget': strictBudget,
        'default_days': defaultDays.clamp(1, 14),
      });
      Future<http.Response> sendReq(String? tok) => _client
          .post(
            Uri.parse('$base/ai/trip-draft'),
            headers: {
              if (tok != null && tok.isNotEmpty) 'Authorization': 'Bearer $tok',
              'Content-Type': 'application/json',
            },
            body: encodedPayload,
          )
          .timeout(const Duration(seconds: 45));

      var res = token.isEmpty
          ? await sendReq(null)
          : await _sendAuthorized(token, sendReq);
      if (token.isNotEmpty && res.statusCode == 401) {
        res = await sendReq(null);
      }
      if (res.statusCode < 200 || res.statusCode >= 300) return null;
      final decoded = _tryDecodeJson(res.body);
      if (decoded is! Map<String, dynamic>) return null;
      final draft = decoded['draft'];
      if (draft is! Map<String, dynamic>) return null;
      return (
        draft: draft,
        modelId: (decoded['model_id'] ?? 'lakbay-api').toString(),
        provider: (decoded['provider'] ?? 'lakbay-api').toString(),
      );
    } catch (_) {
      return null;
    }
  }

  Future<({
    int? generationRunId,
    List<Map<String, dynamic>> options,
    Map<String, dynamic>? planningPreview,
  })?> generateAiItineraries(
    String accessToken, {
    required double totalBudgetPhp,
    required int travelerCount,
    required int dayCount,
    required List<int> destinationIds,
    List<int> accommodationIds = const [],
    List<int> transportationIds = const [],
    List<String> interests = const [],
    Map<String, dynamic>? planningState,
    int inputRevision = 0,
    String? travelStyle,
    String? specialRequirements,
    bool strictBudgetFilter = false,
  }) async {
    final base = _base;
    if (base.isEmpty || accessToken.isEmpty || destinationIds.isEmpty) {
      return null;
    }
    try {
      final encodedPayload = jsonEncode({
        'total_budget': totalBudgetPhp.clamp(100, 9999999).toStringAsFixed(2),
        'traveler_count': travelerCount.clamp(1, 100),
        'day_count': dayCount.clamp(1, 30),
        'destination_ids': destinationIds.toSet().take(10).toList(),
        if (accommodationIds.isNotEmpty)
          'accommodation_ids': accommodationIds.toSet().toList(),
        if (transportationIds.isNotEmpty)
          'transportation_ids': transportationIds.toSet().toList(),
        if (interests.isNotEmpty) 'interests': interests.take(15).toList(),
        if (travelStyle != null && travelStyle.isNotEmpty)
          'travel_style': travelStyle,
        if (specialRequirements != null && specialRequirements.isNotEmpty)
          'special_requirements': specialRequirements,
        'planning_state': ?planningState,
        'input_revision': inputRevision,
        'strict_budget_filter': strictBudgetFilter,
      });
      final res = await _sendAuthorized(
        accessToken,
        (tok) => _client
            .post(
              Uri.parse('$base/ai/itineraries/generate'),
              headers: _authHeaders(tok),
              body: encodedPayload,
            )
            .timeout(const Duration(seconds: 45)),
      );
      if (res.statusCode < 200 || res.statusCode >= 300) return null;
      final decoded = _tryDecodeJson(res.body);
      if (decoded is! Map<String, dynamic>) return null;
      return (
        generationRunId:
            (decoded['selected_generation_run_id'] as num?)?.toInt(),
        options: (decoded['options'] as List<dynamic>? ?? const [])
            .whereType<Map<String, dynamic>>()
            .toList(),
        planningPreview: decoded['planning_preview'] is Map<String, dynamic>
            ? decoded['planning_preview'] as Map<String, dynamic>
            : null,
      );
    } catch (_) {
      return null;
    }
  }

  Future<({
    String status,
    List<PlanningFeedbackFinding> findings,
    Map<String, dynamic>? preview,
  })?> evaluatePlanningFeedback(
    String accessToken, {
    required Map<String, dynamic> state,
    bool? travelingWithChildren,
    int inputRevision = 0,
  }) async {
    final base = _base;
    if (base.isEmpty || accessToken.isEmpty) return null;
    try {
      final encodedPayload = jsonEncode({
        'input_revision': inputRevision,
        'state': state,
        'traveling_with_children': ?travelingWithChildren,
      });
      final res = await _sendAuthorized(
        accessToken,
        (tok) => _client
            .post(
              Uri.parse('$base/planning/feedback'),
              headers: _authHeaders(tok),
              body: encodedPayload,
            )
            .timeout(const Duration(seconds: 12)),
      );
      if (res.statusCode < 200 || res.statusCode >= 300) return null;
      final decoded = _tryDecodeJson(res.body);
      if (decoded is! Map<String, dynamic>) return null;
      final findings = (decoded['findings'] as List<dynamic>? ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(PlanningFeedbackFinding.fromJson)
          .toList();
      return (
        status: (decoded['status'] ?? 'needs_review').toString(),
        findings: findings,
        preview: decoded['preview'] is Map<String, dynamic>
            ? decoded['preview'] as Map<String, dynamic>
            : null,
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
      final res = await _sendAuthorized(
        accessToken,
        (tok) => _client
            .get(
              Uri.parse('$base/weather/current?lat=$lat&lng=$lng'),
              headers: _authHeaders(tok, json: false),
            )
            .timeout(const Duration(seconds: 8)),
      );
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

  Map<String, String> _authHeaders(String accessToken, {bool json = true}) => {
        'Authorization': 'Bearer $accessToken',
        if (json) 'Content-Type': 'application/json',
      };

  // ── Notifications ──────────────────────────────────────────────────────────

  Future<List<AppNotificationItem>> fetchNotifications(
    String accessToken, {
    bool unreadOnly = false,
  }) async {
    final base = _base;
    if (base.isEmpty || accessToken.isEmpty) return const [];
    try {
      final res = await _sendAuthorized(
        accessToken,
        (tok) => _client
            .get(
              Uri.parse('$base/notifications?unread_only=$unreadOnly&limit=50'),
              headers: _authHeaders(tok, json: false),
            )
            .timeout(const Duration(seconds: 8)),
      );
      if (res.statusCode != 200) return const [];
      final decoded = _tryDecodeJson(res.body);
      if (decoded is! List) return const [];
      return decoded
          .whereType<Map<String, dynamic>>()
          .map(AppNotificationItem.fromJson)
          .toList();
    } catch (_) {
      return const [];
    }
  }

  Future<int> getUnreadNotificationCount(String accessToken) async {
    final base = _base;
    if (base.isEmpty || accessToken.isEmpty) return 0;
    try {
      final res = await _sendAuthorized(
        accessToken,
        (tok) => _client
            .get(
              Uri.parse('$base/notifications/unread-count'),
              headers: _authHeaders(tok, json: false),
            )
            .timeout(const Duration(seconds: 6)),
      );
      if (res.statusCode != 200) return 0;
      final decoded = _tryDecodeJson(res.body);
      if (decoded is Map<String, dynamic>) {
        return (decoded['unread_count'] as num?)?.toInt() ?? 0;
      }
      return 0;
    } catch (_) {
      return 0;
    }
  }

  Future<bool> markNotificationRead(
    String accessToken,
    int notificationId,
  ) async {
    final base = _base;
    if (base.isEmpty || accessToken.isEmpty) return false;
    try {
      final res = await _sendAuthorized(
        accessToken,
        (tok) => _client
            .post(
              Uri.parse('$base/notifications/$notificationId/read'),
              headers: _authHeaders(tok, json: false),
            )
            .timeout(const Duration(seconds: 6)),
      );
      return res.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  Future<bool> markAllNotificationsRead(String accessToken) async {
    final base = _base;
    if (base.isEmpty || accessToken.isEmpty) return false;
    try {
      final res = await _sendAuthorized(
        accessToken,
        (tok) => _client
            .post(
              Uri.parse('$base/notifications/read-all'),
              headers: _authHeaders(tok, json: false),
            )
            .timeout(const Duration(seconds: 6)),
      );
      return res.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  // ── Trip Collaboration (Members & Tasks) ───────────────────────────────────

  Future<List<TripMemberItem>> listTripMembers(
    String accessToken,
    int tripId,
  ) async {
    final base = _base;
    if (base.isEmpty || accessToken.isEmpty) return const [];
    try {
      final res = await _client
          .get(
            Uri.parse('$base/trips/$tripId/members'),
            headers: _authHeaders(accessToken, json: false),
          )
          .timeout(const Duration(seconds: 8));
      if (res.statusCode != 200) return const [];
      final decoded = _tryDecodeJson(res.body);
      if (decoded is! List) return const [];
      return decoded
          .whereType<Map<String, dynamic>>()
          .map(TripMemberItem.fromJson)
          .toList();
    } catch (_) {
      return const [];
    }
  }

  Future<TripMemberItem?> addTripMember(
    String accessToken,
    int tripId, {
    String? email,
    String? username,
    String role = 'member',
  }) async {
    final base = _base;
    if (base.isEmpty || accessToken.isEmpty) return null;
    assert((email == null) != (username == null),
        'Invite by email or by username, not both.');
    // The server sends an invitation (status "invited"); the person joins
    // when they accept.
    final res = await _client
        .post(
          Uri.parse('$base/trips/$tripId/members'),
          headers: _authHeaders(accessToken),
          body: jsonEncode({
            if (email != null) 'email': email.trim(),
            if (username != null) 'username': username.trim(),
            'role': role,
          }),
        )
        .timeout(const Duration(seconds: 10));
    final decoded = _tryDecodeJson(res.body);
    if (res.statusCode == 200 || res.statusCode == 201) {
      if (decoded is Map<String, dynamic>) {
        return TripMemberItem.fromJson(decoded);
      }
      return null;
    }
    throw LakbayApiException(
      _extractErrorMessage(decoded, res.statusCode),
      statusCode: res.statusCode,
    );
  }

  /// Travelers matching the start of a username or name (no emails).
  Future<List<UserSearchItem>> searchUsers(String accessToken, String query) async {
    final base = _base;
    if (base.isEmpty || accessToken.isEmpty || query.trim().length < 2) {
      return const [];
    }
    try {
      final res = await _sendAuthorized(
        accessToken,
        (tok) => _client
            .get(
              Uri.parse('$base/users/search').replace(
                queryParameters: {'q': query.trim()},
              ),
              headers: _authHeaders(tok, json: false),
            )
            .timeout(const Duration(seconds: 8)),
      );
      if (res.statusCode != 200) return const [];
      final decoded = _tryDecodeJson(res.body);
      if (decoded is! List) return const [];
      return decoded
          .whereType<Map<String, dynamic>>()
          .map(UserSearchItem.fromJson)
          .toList();
    } catch (_) {
      return const [];
    }
  }

  Future<List<TripInvitationItem>> listTripInvitations(String accessToken) async {
    final base = _base;
    if (base.isEmpty || accessToken.isEmpty) return const [];
    try {
      final res = await _sendAuthorized(
        accessToken,
        (tok) => _client
            .get(
              Uri.parse('$base/trips/invitations'),
              headers: _authHeaders(tok, json: false),
            )
            .timeout(const Duration(seconds: 8)),
      );
      if (res.statusCode != 200) return const [];
      final decoded = _tryDecodeJson(res.body);
      if (decoded is! List) return const [];
      return decoded
          .whereType<Map<String, dynamic>>()
          .map(TripInvitationItem.fromJson)
          .toList();
    } catch (_) {
      return const [];
    }
  }

  /// Accepts or declines an invitation. True when the server confirmed it.
  Future<bool> answerTripInvitation(
    String accessToken,
    int tripId, {
    required bool accept,
  }) async {
    final base = _base;
    if (base.isEmpty || accessToken.isEmpty) return false;
    try {
      final res = await _sendAuthorized(
        accessToken,
        (tok) => _client
            .post(
              Uri.parse(
                '$base/trips/$tripId/invitation/${accept ? 'accept' : 'decline'}',
              ),
              headers: _authHeaders(tok, json: false),
            )
            .timeout(const Duration(seconds: 10)),
      );
      return res.statusCode >= 200 && res.statusCode < 300;
    } catch (_) {
      return false;
    }
  }

  Future<bool> removeTripMember(
    String accessToken,
    int tripId,
    int tripMemberId,
  ) async {
    final base = _base;
    if (base.isEmpty || accessToken.isEmpty) return false;
    try {
      final res = await _client
          .delete(
            Uri.parse('$base/trips/$tripId/members/$tripMemberId'),
            headers: _authHeaders(accessToken, json: false),
          )
          .timeout(const Duration(seconds: 8));
      return res.statusCode >= 200 && res.statusCode < 300;
    } catch (_) {
      return false;
    }
  }

  Future<List<TripTaskItem>> listTripTasks(
    String accessToken,
    int tripId,
  ) async {
    final base = _base;
    if (base.isEmpty || accessToken.isEmpty) return const [];
    try {
      final res = await _client
          .get(
            Uri.parse('$base/trips/$tripId/tasks'),
            headers: _authHeaders(accessToken, json: false),
          )
          .timeout(const Duration(seconds: 8));
      if (res.statusCode != 200) return const [];
      final decoded = _tryDecodeJson(res.body);
      if (decoded is! List) return const [];
      return decoded
          .whereType<Map<String, dynamic>>()
          .map(TripTaskItem.fromJson)
          .toList();
    } catch (_) {
      return const [];
    }
  }

  Future<TripTaskItem?> createTripTask(
    String accessToken,
    int tripId, {
    required String title,
    String? description,
    int? assignedTripMemberId,
    DateTime? dueDate,
  }) async {
    final base = _base;
    if (base.isEmpty || accessToken.isEmpty) return null;
    final res = await _client
        .post(
          Uri.parse('$base/trips/$tripId/tasks'),
          headers: _authHeaders(accessToken),
          body: jsonEncode({
            'title': title.trim(),
            if (description != null && description.trim().isNotEmpty)
              'description': description.trim(),
            'assigned_trip_member_id': ?assignedTripMemberId,
            if (dueDate != null)
              'due_date': dueDate.toIso8601String().split('T').first,
          }),
        )
        .timeout(const Duration(seconds: 10));
    final decoded = _tryDecodeJson(res.body);
    if (res.statusCode == 200 || res.statusCode == 201) {
      if (decoded is Map<String, dynamic>) {
        return TripTaskItem.fromJson(decoded);
      }
      return null;
    }
    throw LakbayApiException(
      _extractErrorMessage(decoded, res.statusCode),
      statusCode: res.statusCode,
    );
  }

  Future<TripTaskItem?> updateTripTaskStatus(
    String accessToken,
    int tripId,
    int taskId, {
    required String status,
  }) async {
    final base = _base;
    if (base.isEmpty || accessToken.isEmpty) return null;
    try {
      final res = await _client
          .patch(
            Uri.parse('$base/trips/$tripId/tasks/$taskId'),
            headers: _authHeaders(accessToken),
            body: jsonEncode({'status': status}),
          )
          .timeout(const Duration(seconds: 8));
      if (res.statusCode == 200) {
        final decoded = _tryDecodeJson(res.body);
        if (decoded is Map<String, dynamic>) {
          return TripTaskItem.fromJson(decoded);
        }
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  // ── Expenses & Budget Tracking ─────────────────────────────────────────────

  Future<List<TripExpenseItem>> listTripExpenses(
    String accessToken,
    int tripId,
  ) async {
    final base = _base;
    if (base.isEmpty || accessToken.isEmpty) return const [];
    try {
      final res = await _client
          .get(
            Uri.parse('$base/trips/$tripId/expenses'),
            headers: _authHeaders(accessToken, json: false),
          )
          .timeout(const Duration(seconds: 8));
      if (res.statusCode != 200) return const [];
      final decoded = _tryDecodeJson(res.body);
      if (decoded is! List) return const [];
      return decoded
          .whereType<Map<String, dynamic>>()
          .map(TripExpenseItem.fromJson)
          .toList();
    } catch (_) {
      return const [];
    }
  }

  Future<TripExpenseSummary?> getTripExpenseSummary(
    String accessToken,
    int tripId, {
    int? adultCount,
    int childCount = 0,
  }) async {
    final base = _base;
    if (base.isEmpty || accessToken.isEmpty) return null;
    try {
      final qp = <String, String>{
        if (adultCount != null) 'adult_count': '$adultCount',
        'child_count': '$childCount',
      };
      final uri = Uri.parse('$base/trips/$tripId/expenses/summary')
          .replace(queryParameters: qp);
      final res = await _client
          .get(uri, headers: _authHeaders(accessToken, json: false))
          .timeout(const Duration(seconds: 8));
      if (res.statusCode != 200) return null;
      final decoded = _tryDecodeJson(res.body);
      if (decoded is Map<String, dynamic>) {
        return TripExpenseSummary.fromJson(decoded);
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  Future<TripExpenseItem?> createTripExpense(
    String accessToken,
    int tripId, {
    required String title,
    required String category,
    required double amount,
    required int paidByTripMemberId,
    String? notes,
  }) async {
    final base = _base;
    if (base.isEmpty || accessToken.isEmpty) return null;
    final res = await _client
        .post(
          Uri.parse('$base/trips/$tripId/expenses'),
          headers: _authHeaders(accessToken),
          body: jsonEncode({
            'title': title.trim(),
            'category': category,
            'amount': amount.toStringAsFixed(2),
            'paid_by_trip_member_id': paidByTripMemberId,
            if (notes != null && notes.trim().isNotEmpty) 'notes': notes.trim(),
          }),
        )
        .timeout(const Duration(seconds: 10));
    final decoded = _tryDecodeJson(res.body);
    if (res.statusCode == 200 || res.statusCode == 201) {
      if (decoded is Map<String, dynamic>) {
        return TripExpenseItem.fromJson(decoded);
      }
      return null;
    }
    throw LakbayApiException(
      _extractErrorMessage(decoded, res.statusCode),
      statusCode: res.statusCode,
    );
  }

  Future<bool> voidTripExpense(
    String accessToken,
    int tripId,
    int expenseId,
  ) async {
    final base = _base;
    if (base.isEmpty || accessToken.isEmpty) return false;
    try {
      final res = await _client
          .delete(
            Uri.parse('$base/trips/$tripId/expenses/$expenseId'),
            headers: _authHeaders(accessToken, json: false),
          )
          .timeout(const Duration(seconds: 8));
      return res.statusCode >= 200 && res.statusCode < 300;
    } catch (_) {
      return false;
    }
  }

  // ── Trip Memories (Replaced Bookings) ──────────────────────────────────────

  Future<List<TripMemoryItem>> listTripMemories(
    String accessToken,
    int tripId,
  ) async {
    final base = _base;
    if (base.isEmpty || accessToken.isEmpty) return const [];
    try {
      final res = await _client
          .get(
            Uri.parse('$base/trips/$tripId/memories'),
            headers: _authHeaders(accessToken, json: false),
          )
          .timeout(const Duration(seconds: 8));
      if (res.statusCode != 200) return const [];
      final decoded = _tryDecodeJson(res.body);
      if (decoded is! List) return const [];
      return decoded
          .whereType<Map<String, dynamic>>()
          .map(TripMemoryItem.fromJson)
          .toList();
    } catch (_) {
      return const [];
    }
  }

  Future<({String imageUrl, String? publicId})?> uploadTripMemoryPhoto(
    String accessToken,
    int tripId, {
    required String filePath,
  }) async {
    final base = _base;
    if (base.isEmpty || accessToken.isEmpty) return null;
    final req = http.MultipartRequest(
      'POST',
      Uri.parse('$base/trips/$tripId/memories/upload'),
    );
    req.headers['Authorization'] = 'Bearer $accessToken';
    req.files.add(await http.MultipartFile.fromPath('file', filePath));
    final streamed = await _client.send(req).timeout(const Duration(seconds: 30));
    final body = await streamed.stream.bytesToString();
    final decoded = _tryDecodeJson(body);
    if (streamed.statusCode == 200 || streamed.statusCode == 201) {
      if (decoded is Map<String, dynamic>) {
        return (
          imageUrl: (decoded['image_url'] ?? '').toString(),
          publicId: decoded['cloudinary_public_id']?.toString(),
        );
      }
      return null;
    }
    throw LakbayApiException(
      _extractErrorMessage(decoded, streamed.statusCode),
      statusCode: streamed.statusCode,
    );
  }

  Future<TripMemoryItem?> createTripMemory(
    String accessToken,
    int tripId, {
    required String imageUrl,
    String? cloudinaryPublicId,
    int? destinationId,
    String? caption,
    String? locationTag,
  }) async {
    final base = _base;
    if (base.isEmpty || accessToken.isEmpty) return null;
    final res = await _client
        .post(
          Uri.parse('$base/trips/$tripId/memories'),
          headers: _authHeaders(accessToken),
          body: jsonEncode({
            'image_url': imageUrl,
            'cloudinary_public_id': ?cloudinaryPublicId,
            'destination_id': ?destinationId,
            if (caption != null && caption.trim().isNotEmpty)
              'caption': caption.trim(),
            if (locationTag != null && locationTag.trim().isNotEmpty)
              'location_tag': locationTag.trim(),
          }),
        )
        .timeout(const Duration(seconds: 10));
    final decoded = _tryDecodeJson(res.body);
    if (res.statusCode == 200 || res.statusCode == 201) {
      if (decoded is Map<String, dynamic>) {
        return TripMemoryItem.fromJson(decoded);
      }
      return null;
    }
    throw LakbayApiException(
      _extractErrorMessage(decoded, res.statusCode),
      statusCode: res.statusCode,
    );
  }

  Future<bool> likeTripMemory(
    String accessToken,
    int tripId,
    int memoryId,
  ) async {
    final base = _base;
    if (base.isEmpty || accessToken.isEmpty) return false;
    try {
      final res = await _client
          .post(
            Uri.parse('$base/trips/$tripId/memories/$memoryId/likes'),
            headers: _authHeaders(accessToken, json: false),
          )
          .timeout(const Duration(seconds: 6));
      return res.statusCode == 200 || res.statusCode == 201;
    } catch (_) {
      return false;
    }
  }

  Future<bool> deleteTripMemory(
    String accessToken,
    int tripId,
    int memoryId,
  ) async {
    final base = _base;
    if (base.isEmpty || accessToken.isEmpty) return false;
    try {
      final res = await _client
          .delete(
            Uri.parse('$base/trips/$tripId/memories/$memoryId'),
            headers: _authHeaders(accessToken, json: false),
          )
          .timeout(const Duration(seconds: 8));
      return res.statusCode >= 200 && res.statusCode < 300;
    } catch (_) {
      return false;
    }
  }

  // ── Reports, Reviews & ISO/IEC 25010 App Assessment ────────────────────────

  Future<List<int>?> downloadTripReportPdf(
    String accessToken,
    int tripId,
  ) async {
    final base = _base;
    if (base.isEmpty || accessToken.isEmpty) return null;
    try {
      final res = await _client
          .get(
            Uri.parse('$base/trips/$tripId/reports/pdf'),
            headers: _authHeaders(accessToken, json: false),
          )
          .timeout(const Duration(seconds: 20));
      if (res.statusCode == 200 && res.bodyBytes.isNotEmpty) {
        return res.bodyBytes;
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  Future<List<TripReviewItem>> listTripReviews(
    String accessToken,
    int tripId,
  ) async {
    final base = _base;
    if (base.isEmpty || accessToken.isEmpty) return const [];
    try {
      final res = await _client
          .get(
            Uri.parse('$base/trips/$tripId/reviews'),
            headers: _authHeaders(accessToken, json: false),
          )
          .timeout(const Duration(seconds: 8));
      if (res.statusCode != 200) return const [];
      final decoded = _tryDecodeJson(res.body);
      if (decoded is! List) return const [];
      return decoded
          .whereType<Map<String, dynamic>>()
          .map(TripReviewItem.fromJson)
          .toList();
    } catch (_) {
      return const [];
    }
  }

  Future<TripReviewItem?> submitTripReview(
    String accessToken,
    int tripId, {
    int? destinationId,
    required int postTripRating,
    required int accuracyRating,
    required int routeEfficiencyRating,
    required int budgetAdherenceRating,
    required int overallExperienceRating,
    String? comments,
  }) async {
    final base = _base;
    if (base.isEmpty || accessToken.isEmpty) return null;
    final res = await _client
        .post(
          Uri.parse('$base/trips/$tripId/reviews'),
          headers: _authHeaders(accessToken),
          body: jsonEncode({
            'destination_id': ?destinationId,
            'post_trip_rating': postTripRating,
            'accuracy_rating': accuracyRating,
            'route_efficiency_rating': routeEfficiencyRating,
            'budget_adherence_rating': budgetAdherenceRating,
            'overall_experience_rating': overallExperienceRating,
            if (comments != null && comments.trim().isNotEmpty)
              'comments': comments.trim(),
          }),
        )
        .timeout(const Duration(seconds: 10));
    final decoded = _tryDecodeJson(res.body);
    if (res.statusCode == 200 || res.statusCode == 201) {
      if (decoded is Map<String, dynamic>) {
        return TripReviewItem.fromJson(decoded);
      }
      return null;
    }
    throw LakbayApiException(
      _extractErrorMessage(decoded, res.statusCode),
      statusCode: res.statusCode,
    );
  }

  Future<AppAssessmentData?> submitAppAssessment(
    String accessToken,
    int tripId, {
    required int functionalSuitabilityRating,
    required int informationAccuracyRating,
    required int performanceRating,
    required int interactionRating,
    required int reliabilityRating,
    required int sharingClarityRating,
    String? comment,
  }) async {
    final base = _base;
    if (base.isEmpty || accessToken.isEmpty) return null;
    final res = await _client
        .post(
          Uri.parse('$base/trips/$tripId/app-assessment'),
          headers: _authHeaders(accessToken),
          body: jsonEncode({
            'functional_suitability_rating': functionalSuitabilityRating,
            'information_accuracy_rating': informationAccuracyRating,
            'performance_rating': performanceRating,
            'interaction_rating': interactionRating,
            'reliability_rating': reliabilityRating,
            'sharing_clarity_rating': sharingClarityRating,
            if (comment != null && comment.trim().isNotEmpty)
              'comment': comment.trim(),
            'app_version': '1.0.0',
          }),
        )
        .timeout(const Duration(seconds: 10));
    final decoded = _tryDecodeJson(res.body);
    if (res.statusCode == 200 || res.statusCode == 201) {
      if (decoded is Map<String, dynamic>) {
        return AppAssessmentData.fromJson(decoded);
      }
      return null;
    }
    throw LakbayApiException(
      _extractErrorMessage(decoded, res.statusCode),
      statusCode: res.statusCode,
    );
  }

  // ── Personalized Top-5 Recommendations (weighted SAW by default) ──────────

  Future<TopPlacesResult?> fetchTopPlaces(
    String accessToken, {
    List<String> interests = const [],
    String travelMode = 'driving',
    double? totalBudgetPhp,
    int? adultCount,
    List<int> childAges = const [],
    int? dayCount,
    double? originLat,
    double? originLng,
    String rankingMethod = 'simple_additive_weighting',
    // The server caps this at 5 (its MAX_SUGGESTIONS).
    int? limit,
    // Fill the list with clearly labelled near matches when fewer fit exactly.
    bool fillToLimit = true,
  }) async {
    final base = _base;
    if (base.isEmpty || accessToken.isEmpty) return null;
    try {
      final res = await _client
          .post(
            Uri.parse('$base/recommendations/top-places'),
            headers: _authHeaders(accessToken),
            body: jsonEncode({
              if (interests.isNotEmpty) 'interests': interests,
              'travel_mode': travelMode,
              if (totalBudgetPhp != null && totalBudgetPhp > 0)
                'total_budget': totalBudgetPhp.toStringAsFixed(2),
              'adult_count': ?adultCount,
              if (childAges.isNotEmpty) 'child_ages': childAges,
              'day_count': ?dayCount,
              if (originLat != null && originLng != null)
                'origin': {'lat': originLat, 'lng': originLng},
              'ranking_method': rankingMethod,
              'limit': ?limit,
              'fill_to_limit': fillToLimit,
              'save_preference': false,
            }),
          )
          .timeout(const Duration(seconds: 15));
      if (res.statusCode != 200 && res.statusCode != 201) return null;
      final decoded = _tryDecodeJson(res.body);
      if (decoded is Map<String, dynamic>) {
        return TopPlacesResult.fromJson(decoded);
      }
      return null;
    } catch (_) {
      return null;
    }
  }
}
