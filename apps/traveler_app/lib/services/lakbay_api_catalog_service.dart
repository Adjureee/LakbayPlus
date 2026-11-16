import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart' show MediaType;
import '../models/commute.dart';
import '../models/travel_models.dart';
import 'env_config.dart';

class LakbayApiException implements Exception {
  final int? statusCode;
  final String message;
  final String? code;
  final int? retryAfterSeconds;

  const LakbayApiException(
    this.message, {
    this.statusCode,
    this.code,
    this.retryAfterSeconds,
  });

  @override
  String toString() => message;
}

/// Google sign-in worked, but there is no Lakbay account for that email yet.
/// The app asks the traveler before creating one.
class GoogleAccountNotRegistered extends LakbayApiException {
  final String email;
  final String fullName;

  /// The Google token to send again once the traveler confirms.
  String idToken = '';

  GoogleAccountNotRegistered({required this.email, required this.fullName})
      : super(
          'No Lakbay account uses this Google email yet.',
          statusCode: 409,
          code: 'google_account_not_registered',
        );
}

sealed class AiItineraryResult {
  const AiItineraryResult();
}

class AiItinerarySuccess extends AiItineraryResult {
  final int? generationRunId;
  final List<Map<String, dynamic>> options;
  final Map<String, dynamic>? planningPreview;

  const AiItinerarySuccess({
    required this.generationRunId,
    required this.options,
    this.planningPreview,
  });
}

class AiItineraryFailure extends AiItineraryResult {
  final String code;
  final String message;
  final int? statusCode;
  final int? retryAfterSeconds;

  const AiItineraryFailure({
    required this.code,
    required this.message,
    this.statusCode,
    this.retryAfterSeconds,
  });

  String userFacingMessage() => switch (code) {
        'groq_rate_limit_exceeded' ||
        'groq_model_rate_limit_exceeded' =>
          retryAfterSeconds != null && retryAfterSeconds! > 0
              ? 'The AI is busy right now. Try again in ${retryAfterSeconds}s.'
              : 'The AI is busy right now. Please try again in a moment.',
        'planning_over_budget' =>
          'Your picks cost more than your budget. Raise the budget or remove a place.',
        'planning_selection_invalid' ||
        'planning_input_mismatch' =>
          message.isNotEmpty
              ? message
              : 'Please review your trip details and picks before generating.',
        'ai_user_rate_limit_exceeded' ||
        'ai_user_daily_limit_exceeded' =>
          message.isNotEmpty
              ? message
              : "You've reached today's AI limit. Please try again later.",
        'network_error' =>
          "Couldn't reach Lakbay AI. Check your connection and try again.",
        _ => "I couldn't draft that one. Try again.",
      };
}

/// Bridge connecting `apps/traveler_app` to the Lakbay+ FastAPI backend
/// (`destinations`, `accommodations`, `transportations`, `auth`, `trips`, `routes`,
/// `ai`, and `weather`) plus public live FX rates. Fails over cleanly offline.
class LakbayApiCatalogService {
  LakbayApiCatalogService({
    http.Client? client,
    this.baseUrlOverride,
    this.retryDelayOverride,
  }) : _client = client ?? http.Client();

  final http.Client _client;
  final String? baseUrlOverride;
  final Future<void> Function(Duration delay)? retryDelayOverride;

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

  /// Verified public-transport routes to a place (`GET /destinations/{id}/commute`).
  /// Returns null when the request fails, so the screen can say it could not
  /// check, and an empty list when no route has been verified yet.
  Future<List<CommuteRoute>?> fetchCommuteRoutes(int destinationId) async {
    final base = _base;
    if (base.isEmpty) return null;
    try {
      final res = await _client
          .get(Uri.parse('$base/destinations/$destinationId/commute'))
          .timeout(const Duration(seconds: 10));
      if (res.statusCode == 404) return const <CommuteRoute>[];
      if (res.statusCode != 200) return null;
      final decoded = jsonDecode(res.body);
      if (decoded is! Map<String, dynamic>) return null;
      return [
        for (final raw in (decoded['routes'] as List? ?? const []))
          if (raw is Map<String, dynamic>) CommuteRoute.fromJson(raw),
      ];
    } catch (_) {
      return null;
    }
  }

  /// Live preference groups and normalized categories from `GET /destinations/facets`.
  Future<({List<PreferenceGroup> groups, List<CategoryFacet> categories})>
      fetchDestinationFacets() async {
    final base = _base;
    if (base.isEmpty) {
      return (groups: const <PreferenceGroup>[], categories: const <CategoryFacet>[]);
    }
    try {
      final res = await _client
          .get(Uri.parse('$base/destinations/facets'))
          .timeout(const Duration(seconds: 8));
      if (res.statusCode != 200) {
        return (groups: const <PreferenceGroup>[], categories: const <CategoryFacet>[]);
      }
      final decoded = jsonDecode(res.body);
      if (decoded is! Map) {
        return (groups: const <PreferenceGroup>[], categories: const <CategoryFacet>[]);
      }
      final rawGroups = decoded['groups'];
      final groups = rawGroups is List
          ? rawGroups
              .whereType<Map<String, dynamic>>()
              .map(PreferenceGroup.fromJson)
              .where((g) => g.key.isNotEmpty && g.label.isNotEmpty)
              .toList()
          : const <PreferenceGroup>[];
      final rawCategories = decoded['categories'];
      final categories = rawCategories is List
          ? rawCategories
              .whereType<Map<String, dynamic>>()
              .map(CategoryFacet.fromJson)
              .where((c) => c.key.isNotEmpty && c.label.isNotEmpty)
              .toList()
          : const <CategoryFacet>[];
      return (groups: groups, categories: categories);
    } catch (_) {
      return (groups: const <PreferenceGroup>[], categories: const <CategoryFacet>[]);
    }
  }

  /// The preference groups travelers can choose, with live counts. Empty when
  /// the server cannot be reached, so callers keep what they already have.
  Future<List<PreferenceGroup>> fetchPreferenceGroups() async {
    final facets = await fetchDestinationFacets();
    return facets.groups;
  }

  /// Fetches up to [limit] ranked places in a catalog category without calling AI.
  Future<List<TopPlaceRecommendation>> browsePlacesByCategory({
    String? category,
    String? province,
    double? userLat,
    double? userLng,
    int limit = 5,
  }) async {
    final base = _base;
    if (base.isEmpty) return const [];
    try {
      final params = <String, String>{
        'limit': limit.clamp(1, 5).toString(),
        if (category != null && category.trim().isNotEmpty)
          'category': category.trim(),
        if (province != null && province.trim().isNotEmpty)
          'province': province.trim(),
        if (userLat != null && userLng != null) 'lat': userLat.toString(),
        if (userLat != null && userLng != null) 'lng': userLng.toString(),
      };
      final uri =
          Uri.parse('$base/destinations/browse').replace(queryParameters: params);
      final res = await _client.get(uri).timeout(const Duration(seconds: 10));
      if (res.statusCode != 200) return const [];
      final decoded = jsonDecode(res.body);
      if (decoded is! List) return const [];
      return decoded
          .whereType<Map<String, dynamic>>()
          .map(TopPlaceRecommendation.fromJson)
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
    final trail = (raw['access_trail_polyline'] ?? '').toString().trim();
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
      accessTrailPolyline: trail.isNotEmpty ? trail : null,
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
            final name = (raw['name'] ?? '').toString().trim();
            if (name.isEmpty) continue;
            final price = _toDouble(raw['price']);
            final roomType = (raw['room_type'] ?? '').toString().trim();
            final unit = (raw['charging_unit'] ?? '').toString().trim();
            hotels.add(
              HotelOffer(
                id: 'acc_${accId ?? hotels.length + 1}',
                name: name,
                city: city,
                // Only what the catalog says: no rating, stars, unit or
                // capacity is made up, and no price means "not listed".
                pricePhp: (price != null && price > 0) ? price : null,
                chargingUnit: unit.isEmpty ? null : unit,
                capacity: (raw['capacity'] as num?)?.toInt(),
                facilities: [if (roomType.isNotEmpty) roomType],
                sourceLabel: 'Lakbay catalog',
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

  Future<LakbayAuthSession> googleLogin({
    required String idToken,
    bool confirmNewAccount = false,
  }) async {
    return _postAuth(
      path: '/auth/google',
      body: {
        'id_token': idToken,
        // Only sent when the traveler confirmed, so an older server that does
        // not know the field behaves as before.
        if (confirmNewAccount) 'confirm_new_account': true,
      },
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
      final error = decoded is Map ? decoded['error'] : null;
      if (res.statusCode == 409 &&
          error is Map &&
          error['code'] == 'google_account_not_registered') {
        final details = error['details'];
        throw GoogleAccountNotRegistered(
          email: details is Map ? (details['email'] ?? '').toString() : '',
          fullName: details is Map ? (details['full_name'] ?? '').toString() : '',
        );
      }
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
    String language = 'auto',
    bool isOnboarding = false,
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
        'language': language,
        if (isOnboarding) 'is_onboarding': true,
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
    String language = 'auto',
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
        'language': language,
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

  Future<AiItineraryResult> generateAiItineraries(
    String? accessToken, {
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
    String language = 'auto',
    void Function(int waitSeconds)? onRateLimitRetry,
    Future<void> Function(Duration delay)? retryDelay,
  }) async {
    final base = _base;
    if (base.isEmpty || destinationIds.isEmpty) {
      return const AiItineraryFailure(
        code: 'not_configured',
        message: 'Pick at least one destination first.',
      );
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
        'language': language,
        'planning_state': ?planningState,
        'input_revision': inputRevision,
        'strict_budget_filter': strictBudgetFilter,
      });

      Future<http.Response> sendOnce() => _postAuthedOrGuest(
            accessToken: accessToken,
            authedPath: '/ai/itineraries/generate',
            guestPath: '/ai/itineraries/generate/guest',
            encodedBody: encodedPayload,
            timeout: const Duration(seconds: 45),
          );

      var res = await sendOnce();
      var decoded = _tryDecodeJson(res.body);
      var errorCode = _extractErrorCode(decoded);

      if (res.statusCode == 429 &&
          (errorCode == 'groq_rate_limit_exceeded' ||
              errorCode == 'groq_model_rate_limit_exceeded' ||
              errorCode == null)) {
        final retryAfter =
            _extractRetryAfterSeconds(decoded, res.headers) ?? 3;
        final waitSeconds = retryAfter.clamp(1, 10);
        onRateLimitRetry?.call(waitSeconds);
        await (retryDelay ?? retryDelayOverride ?? Future<void>.delayed)(
          Duration(seconds: waitSeconds),
        );
        res = await sendOnce();
        decoded = _tryDecodeJson(res.body);
        errorCode = _extractErrorCode(decoded);
      }

      if (res.statusCode < 200 || res.statusCode >= 300) {
        return AiItineraryFailure(
          code: errorCode ??
              (res.statusCode == 429
                  ? 'groq_rate_limit_exceeded'
                  : 'ai_generation_failed'),
          message: _extractErrorMessage(decoded, res.statusCode),
          statusCode: res.statusCode,
          retryAfterSeconds: _extractRetryAfterSeconds(decoded, res.headers),
        );
      }

      if (decoded is! Map<String, dynamic>) {
        return const AiItineraryFailure(
          code: 'ai_generation_failed',
          message: 'Unexpected itinerary response.',
        );
      }
      final options = (decoded['options'] as List<dynamic>? ?? const [])
          .whereType<Map<String, dynamic>>()
          .toList();
      if (options.isEmpty) {
        return const AiItineraryFailure(
          code: 'ai_generation_failed',
          message: "I couldn't draft that one. Try again.",
        );
      }
      return AiItinerarySuccess(
        generationRunId:
            (decoded['selected_generation_run_id'] as num?)?.toInt(),
        options: options,
        planningPreview: decoded['planning_preview'] is Map<String, dynamic>
            ? decoded['planning_preview'] as Map<String, dynamic>
            : null,
      );
    } catch (_) {
      return const AiItineraryFailure(
        code: 'network_error',
        message: "Couldn't reach Lakbay AI. Check your connection and try again.",
      );
    }
  }

  /// Calls `POST /planning/draft` to build a deterministic itinerary from the
  /// catalog without using any AI model (available to guests and signed-in).
  Future<({
    List<Map<String, dynamic>> options,
    String sourceLabel,
    Map<String, dynamic>? planningPreview,
  })?> buildPlanningDraft(
    String? accessToken, {
    Map<String, dynamic>? planningState,
    int inputRevision = 0,
    String? city,
    String? query,
    int maxPlaces = 5,
    int optionCount = 2,
  }) async {
    final base = _base;
    if (base.isEmpty) return null;
    try {
      final encodedPayload = jsonEncode({
        'input_revision': inputRevision,
        'state': planningState ?? const <String, dynamic>{},
        if (city != null && city.trim().isNotEmpty) 'city': city.trim(),
        if (query != null && query.trim().isNotEmpty) 'query': query.trim(),
        'max_places': maxPlaces.clamp(1, 10),
        'option_count': optionCount.clamp(1, 2),
      });
      final token = (accessToken ?? '').trim();
      Future<http.Response> sendReq(String? tok) => _client
          .post(
            Uri.parse('$base/planning/draft'),
            headers: {
              if (tok != null && tok.isNotEmpty) 'Authorization': 'Bearer $tok',
              'Content-Type': 'application/json',
            },
            body: encodedPayload,
          )
          .timeout(const Duration(seconds: 25));

      var res = token.isEmpty
          ? await sendReq(null)
          : await _sendAuthorized(token, sendReq);
      if (token.isNotEmpty && res.statusCode == 401) {
        res = await sendReq(null);
      }
      if (res.statusCode < 200 || res.statusCode >= 300) return null;
      final decoded = _tryDecodeJson(res.body);
      if (decoded is! Map<String, dynamic>) return null;
      final options = (decoded['options'] as List<dynamic>? ?? const [])
          .whereType<Map<String, dynamic>>()
          .toList();
      if (options.isEmpty) return null;
      return (
        options: options,
        sourceLabel: (decoded['source_label'] ??
                "Built from Lakbay's catalog, without AI")
            .toString(),
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
      final main = (cond['main'] ?? '').toString();
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

  /// The server's forecast (up to 5 days ahead), or an empty list when it is
  /// not available. Nothing is guessed for days beyond it.
  Future<List<({DateTime date, int tempC, int wmoCode, String condition})>>
      getWeatherForecast(
    String accessToken, {
    required double lat,
    required double lng,
  }) async {
    final base = _base;
    if (base.isEmpty || accessToken.isEmpty) return const [];
    try {
      final res = await _sendAuthorized(
        accessToken,
        (tok) => _client
            .get(
              Uri.parse('$base/weather/forecast?lat=$lat&lng=$lng&days=5'),
              headers: _authHeaders(tok, json: false),
            )
            .timeout(const Duration(seconds: 8)),
      );
      if (res.statusCode != 200) return const [];
      final decoded = jsonDecode(res.body);
      final days = decoded is Map ? decoded['days'] : null;
      if (days is! List) return const [];
      final result =
          <({DateTime date, int tempC, int wmoCode, String condition})>[];
      for (final raw in days) {
        if (raw is! Map) continue;
        final date = DateTime.tryParse((raw['date'] ?? '').toString());
        final temp = ((raw['temp_avg_c'] ?? raw['temp_max_c']) as num?)?.round();
        if (date == null || temp == null) continue;
        final cond = raw['condition'] is Map ? raw['condition'] as Map : const {};
        result.add((
          date: DateTime(date.year, date.month, date.day),
          tempC: temp,
          wmoCode: _openWeatherCodeToWmo((cond['code'] as num?)?.toInt()),
          condition: (cond['main'] ?? '').toString(),
        ));
      }
      return result;
    } catch (_) {
      return const [];
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

  static String? _extractErrorCode(dynamic decoded) {
    if (decoded is Map) {
      final err = decoded['error'];
      if (err is Map && err['code'] != null) {
        return err['code'].toString();
      }
      if (decoded['code'] != null) {
        return decoded['code'].toString();
      }
    }
    return null;
  }

  static int? _extractRetryAfterSeconds(
    dynamic decoded,
    Map<String, String> headers,
  ) {
    if (decoded is Map) {
      final err = decoded['error'];
      final details = err is Map ? err['details'] : null;
      if (details is Map && details['retry_after_seconds'] != null) {
        final v = (details['retry_after_seconds'] as num?)?.toInt();
        if (v != null && v > 0) return v;
      }
    }
    for (final entry in headers.entries) {
      if (entry.key.toLowerCase() == 'retry-after') {
        final v = int.tryParse(entry.value.trim());
        if (v != null && v > 0) return v;
      }
    }
    return null;
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
            .patch(
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
            .patch(
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

  Future<bool> registerDevicePushToken(
    String accessToken, {
    required String deviceToken,
    String platform = 'android',
  }) async {
    final base = _base;
    if (base.isEmpty || accessToken.isEmpty || deviceToken.trim().isEmpty) {
      return false;
    }
    try {
      final res = await _sendAuthorized(
        accessToken,
        (tok) => _client
            .post(
              Uri.parse('$base/notifications/device-tokens'),
              headers: _authHeaders(tok),
              body: jsonEncode({
                'device_token': deviceToken.trim(),
                'platform': platform,
              }),
            )
            .timeout(const Duration(seconds: 8)),
      );
      return res.statusCode >= 200 && res.statusCode < 300;
    } catch (_) {
      return false;
    }
  }

  Future<bool> unregisterDevicePushToken(
    String accessToken, {
    required String deviceToken,
  }) async {
    final base = _base;
    if (base.isEmpty || accessToken.isEmpty || deviceToken.trim().isEmpty) {
      return false;
    }
    try {
      final res = await _sendAuthorized(
        accessToken,
        (tok) => _client
            .delete(
              Uri.parse('$base/notifications/device-tokens').replace(
                queryParameters: {'device_token': deviceToken.trim()},
              ),
              headers: _authHeaders(tok, json: false),
            )
            .timeout(const Duration(seconds: 8)),
      );
      return res.statusCode >= 200 && res.statusCode < 300;
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

  /// The signed-in traveler's username, or null when it cannot be loaded.
  Future<String?> fetchMyUsername(String accessToken) async =>
      (await fetchMyAccount(accessToken))?.username;

  /// Username and profile photo from the server, or null when unavailable.
  Future<({String? username, String? avatarUrl})?> fetchMyAccount(
    String accessToken,
  ) async {
    final base = _base;
    if (base.isEmpty || accessToken.isEmpty) return null;
    try {
      final res = await _sendAuthorized(
        accessToken,
        (tok) => _client
            .get(
              Uri.parse('$base/users/me'),
              headers: _authHeaders(tok, json: false),
            )
            .timeout(const Duration(seconds: 8)),
      );
      if (res.statusCode != 200) return null;
      final decoded = _tryDecodeJson(res.body);
      if (decoded is! Map<String, dynamic>) return null;
      String? clean(Object? v) {
        final text = v?.toString().trim();
        return (text == null || text.isEmpty) ? null : text;
      }

      return (
        username: clean(decoded['username']),
        avatarUrl: clean(decoded['avatar_url']),
      );
    } catch (_) {
      return null;
    }
  }

  /// Uploads the traveler's profile photo (`POST /users/me/avatar`) and returns
  /// the saved photo address. Throws a [LakbayApiException] with the server's
  /// reason (too large, wrong type, too many uploads) when it is refused.
  Future<String> uploadMyAvatar(
    String accessToken, {
    Uint8List? fileBytes,
    String? filePath,
    String? filename,
    Duration timeout = const Duration(seconds: 60),
  }) async {
    final base = _base;
    if (base.isEmpty || accessToken.isEmpty) {
      throw const LakbayApiException("You're not connected to Lakbay.");
    }
    if (fileBytes == null && (filePath == null || filePath.trim().isEmpty)) {
      throw const LakbayApiException('No photo file was selected.');
    }
    final meta = _inferImageUploadMeta(
      bytes: fileBytes,
      rawFilename: filename ?? filePath,
    );
    http.Response res;
    try {
      res = await _sendAuthorized(accessToken, (tok) async {
        final req = http.MultipartRequest('POST', Uri.parse('$base/users/me/avatar'));
        req.headers['Authorization'] = 'Bearer $tok';
        req.files.add(
          fileBytes != null
              ? http.MultipartFile.fromBytes(
                  'file', fileBytes,
                  filename: meta.filename, contentType: meta.mediaType,
                )
              : await http.MultipartFile.fromPath(
                  'file', filePath!,
                  filename: meta.filename, contentType: meta.mediaType,
                ),
        );
        return http.Response.fromStream(await _client.send(req).timeout(timeout));
      });
    } on TimeoutException {
      throw const LakbayApiException(
        'The upload took too long. Check your connection and try again.',
      );
    } on LakbayApiException {
      rethrow;
    } catch (_) {
      throw const LakbayApiException(
        "Couldn't reach Lakbay. Check your connection and try again.",
      );
    }
    final decoded = _tryDecodeJson(res.body);
    if (res.statusCode >= 200 && res.statusCode < 300 && decoded is Map) {
      final url = (decoded['avatar_url'] ?? '').toString().trim();
      if (url.isNotEmpty) return url;
      throw const LakbayApiException('The server did not return the new photo.');
    }
    throw LakbayApiException(
      _extractErrorMessage(decoded, res.statusCode),
      statusCode: res.statusCode,
    );
  }

  /// Changes the username. Returns the saved (normalised) username; throws a
  /// [LakbayApiException] carrying the server's message when it is refused
  /// (for example "That username is already taken.").
  Future<String> updateMyUsername(String accessToken, String username) async {
    final base = _base;
    if (base.isEmpty || accessToken.isEmpty) {
      throw const LakbayApiException("You're not connected to Lakbay.");
    }
    final res = await _sendAuthorized(
      accessToken,
      (tok) => _client
          .patch(
            Uri.parse('$base/users/me'),
            headers: _authHeaders(tok),
            body: jsonEncode({'username': username.trim()}),
          )
          .timeout(const Duration(seconds: 10)),
    );
    final decoded = _tryDecodeJson(res.body);
    if (res.statusCode >= 200 && res.statusCode < 300 && decoded is Map) {
      return (decoded['username'] ?? username).toString();
    }
    throw LakbayApiException(
      res.statusCode == 422
          ? 'Use 3 to 30 letters, numbers, dots or underscores.'
          : _extractErrorMessage(decoded, res.statusCode),
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

  Future<bool> resendTripInvitation(
    String accessToken,
    int tripId,
    int tripMemberId,
  ) async {
    final base = _base;
    if (base.isEmpty || accessToken.isEmpty) return false;
    try {
      final res = await _sendAuthorized(
        accessToken,
        (tok) => _client
            .post(
              Uri.parse('$base/trips/$tripId/members/$tripMemberId/resend'),
              headers: _authHeaders(tok, json: false),
            )
            .timeout(const Duration(seconds: 8)),
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

  static ({MediaType mediaType, String filename}) _inferImageUploadMeta({
    Uint8List? bytes,
    String? rawFilename,
  }) {
    var ext = 'jpg';
    var subtype = 'jpeg';
    if (bytes != null && bytes.length >= 12) {
      if (bytes[0] == 0x89 &&
          bytes[1] == 0x50 &&
          bytes[2] == 0x4E &&
          bytes[3] == 0x47) {
        ext = 'png';
        subtype = 'png';
      } else if (bytes[0] == 0x52 &&
          bytes[1] == 0x49 &&
          bytes[2] == 0x46 &&
          bytes[3] == 0x46 &&
          bytes[8] == 0x57 &&
          bytes[9] == 0x45 &&
          bytes[10] == 0x42 &&
          bytes[11] == 0x50) {
        ext = 'webp';
        subtype = 'webp';
      }
    } else if (rawFilename != null) {
      final lower = rawFilename.toLowerCase();
      if (lower.endsWith('.png')) {
        ext = 'png';
        subtype = 'png';
      } else if (lower.endsWith('.webp')) {
        ext = 'webp';
        subtype = 'webp';
      }
    }
    final cleanedName = (rawFilename ?? '').trim().isNotEmpty
        ? rawFilename!.trim().split(RegExp(r'[/\\]')).last
        : 'memory.$ext';
    final hasKnownExt = RegExp(r'\.(jpe?g|png|webp)$', caseSensitive: false)
        .hasMatch(cleanedName);
    return (
      mediaType: MediaType('image', subtype),
      filename: hasKnownExt ? cleanedName : '$cleanedName.$ext',
    );
  }

  Future<({String imageUrl, String? publicId})?> uploadTripMemoryPhoto(
    String accessToken,
    int tripId, {
    Uint8List? fileBytes,
    String? filename,
    String? filePath,
    void Function(String status)? onProgress,
    Duration? timeoutOverride,
  }) async {
    final base = _base;
    if (base.isEmpty || accessToken.isEmpty) return null;
    if (fileBytes == null && (filePath == null || filePath.trim().isEmpty)) {
      throw const LakbayApiException('No photo file was selected.');
    }

    final meta = _inferImageUploadMeta(
      bytes: fileBytes,
      rawFilename: filename ?? filePath,
    );
    final timeout = timeoutOverride ?? const Duration(seconds: 60);

    for (var attempt = 0; attempt < 2; attempt++) {
      onProgress?.call(
        attempt == 0 ? 'Uploading photo…' : 'Retrying photo upload…',
      );
      final req = http.MultipartRequest(
        'POST',
        Uri.parse('$base/trips/$tripId/memories/upload'),
      );
      req.headers['Authorization'] = 'Bearer $accessToken';
      if (fileBytes != null) {
        req.files.add(
          http.MultipartFile.fromBytes(
            'file',
            fileBytes,
            filename: meta.filename,
            contentType: meta.mediaType,
          ),
        );
      } else {
        req.files.add(
          await http.MultipartFile.fromPath(
            'file',
            filePath!,
            filename: meta.filename,
            contentType: meta.mediaType,
          ),
        );
      }

      try {
        final streamed = await _client.send(req).timeout(timeout);
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
        final code = decoded is Map && decoded['error'] is Map
            ? (decoded['error'] as Map)['code']?.toString()
            : null;
        final isRetryable = streamed.statusCode >= 500 && attempt == 0;
        if (!isRetryable) {
          throw LakbayApiException(
            _extractErrorMessage(decoded, streamed.statusCode),
            statusCode: streamed.statusCode,
            code: code,
          );
        }
      } on LakbayApiException {
        rethrow;
      } catch (e) {
        if (attempt == 1) {
          throw LakbayApiException(
            e is TimeoutException
                ? 'Photo upload timed out. Saved to your outbox so you can retry.'
                : 'Network error while uploading photo.',
            code: 'network_error',
          );
        }
      }
    }
    return null;
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
        .timeout(const Duration(seconds: 20));
    final decoded = _tryDecodeJson(res.body);
    if (res.statusCode == 200 || res.statusCode == 201) {
      if (decoded is Map<String, dynamic>) {
        return TripMemoryItem.fromJson(decoded);
      }
      return null;
    }
    final code = decoded is Map && decoded['error'] is Map
        ? (decoded['error'] as Map)['code']?.toString()
        : null;
    throw LakbayApiException(
      _extractErrorMessage(decoded, res.statusCode),
      statusCode: res.statusCode,
      code: code,
    );
  }

  Future<({bool confirmed, int? likeCount})> likeTripMemory(
    String accessToken,
    int tripId,
    int memoryId,
  ) async {
    final base = _base;
    if (base.isEmpty || accessToken.isEmpty) {
      return (confirmed: false, likeCount: null);
    }
    try {
      final res = await _client
          .post(
            Uri.parse('$base/trips/$tripId/memories/$memoryId/likes'),
            headers: _authHeaders(accessToken, json: false),
          )
          .timeout(const Duration(seconds: 10));
      if (res.statusCode == 200 || res.statusCode == 201) {
        final decoded = _tryDecodeJson(res.body);
        if (decoded is Map<String, dynamic> &&
            decoded.containsKey('like_count')) {
          return (
            confirmed: true,
            likeCount: (decoded['like_count'] as num?)?.toInt(),
          );
        }
        return (confirmed: true, likeCount: null);
      }
      return (confirmed: false, likeCount: null);
    } catch (_) {
      return (confirmed: false, likeCount: null);
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
