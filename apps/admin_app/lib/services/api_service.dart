import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';
import 'session_manager.dart';
import 'validation_message.dart';

/// One file sent as `multipart/form-data` under the `file` field.
class UploadFile {
  final List<int> bytes;
  final String filename;
  final String contentType;
  const UploadFile({
    required this.bytes,
    required this.filename,
    required this.contentType,
  });
}

class ApiException implements Exception {
  final String message;
  final int? statusCode;
  const ApiException(this.message, {this.statusCode});
  @override
  String toString() => message;
}

/// Client for the versioned Lakbay+ API. No sample data is substituted.
class ApiService {
  static const String baseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'http://127.0.0.1:8000/api/v1',
  );
  final http.Client _client;
  final Future<String?> Function() _tokenProvider;
  final String _base;
  static Future<bool>? _refreshing;

  ApiService({
    http.Client? client,
    Future<String?> Function()? tokenProvider,
    String? apiBaseUrl,
  }) : _client = client ?? http.Client(),
       _tokenProvider = tokenProvider ?? SessionManager.instance.getToken,
       _base = (apiBaseUrl ?? baseUrl).replaceFirst(RegExp(r'/+$'), '');

  Future<dynamic> _request(
    String method,
    String path, {
    Map<String, dynamic>? data,
    UploadFile? file,
    bool authenticated = true,
    bool retryOnUnauthorized = true,
  }) async {
    final headers = <String, String>{'Accept': 'application/json'};
    if (data != null) headers['Content-Type'] = 'application/json';
    if (authenticated) {
      final token = await _tokenProvider();
      if (token != null && token.isNotEmpty) {
        headers['Authorization'] = 'Bearer $token';
      }
    }
    final uri = Uri.parse('$_base$path');
    try {
      final body = data == null ? null : jsonEncode(data);
      final request = file != null
          ? _sendMultipart(method, uri, headers, file)
          : switch (method) {
        'GET' => _client.get(uri, headers: headers),
        'POST' => _client.post(uri, headers: headers, body: body),
        'PATCH' => _client.patch(uri, headers: headers, body: body),
        'DELETE' => _client.delete(uri, headers: headers),
        _ => throw ArgumentError('Unsupported request method'),
      };
      // Photo uploads go on to Cloudinary from the API, so allow longer.
      final response = await request.timeout(
        Duration(seconds: file != null ? 60 : 20),
      );
      if (response.statusCode == 401 && authenticated && retryOnUnauthorized) {
        final refreshed = await _refreshAccess();
        if (refreshed) {
          return await _request(
            method,
            path,
            data: data,
            file: file,
            authenticated: true,
            retryOnUnauthorized: false,
          );
        }
      }
      dynamic decoded;
      if (response.body.isNotEmpty) {
        try {
          decoded = jsonDecode(response.body);
        } on FormatException {
          if (response.statusCode >= 200 && response.statusCode < 300) {
            throw const ApiException(
              'The server returned an unreadable response. Please try again.',
            );
          }
        }
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        final defaultMessage = switch (response.statusCode) {
          401 => 'Your session has expired. Please sign in again.',
          403 => 'Your account does not have permission for this action.',
          404 => 'This record is no longer available.',
          _ => 'The request could not be completed. Please try again.',
        };
        String message = defaultMessage;
        if (decoded is Map) {
          final detail =
              decoded['detail'] ??
              decoded['message'] ??
              (decoded['error'] is Map ? decoded['error']['message'] : null);
          if (detail is String && detail.isNotEmpty) message = detail;
          if (detail is List) {
            message = validationMessage(detail) ?? message;
          }
          final error = decoded['error'];
          final details = error is Map ? error['details'] : null;
          if (details is List) {
            message = validationMessage(details) ?? message;
          }
        }
        throw ApiException(message, statusCode: response.statusCode);
      }
      return decoded;
    } on ApiException {
      rethrow;
    } on TimeoutException {
      throw const ApiException(
        'The server took too long to respond. Please try again.',
      );
    } on http.ClientException {
      throw const ApiException(
        'Unable to reach Lakbay API. Check the connection and try again.',
      );
    }
  }

  Future<http.Response> _sendMultipart(
    String method,
    Uri uri,
    Map<String, String> headers,
    UploadFile file,
  ) async {
    final request = http.MultipartRequest(method, uri)
      ..headers.addAll(headers)
      ..files.add(
        http.MultipartFile.fromBytes(
          'file',
          file.bytes,
          filename: file.filename,
          contentType: MediaType.parse(file.contentType),
        ),
      );
    return http.Response.fromStream(await _client.send(request));
  }

  Map<String, dynamic> _object(dynamic value) {
    if (value is Map) return Map<String, dynamic>.from(value);
    throw const ApiException('The server returned an unexpected record.');
  }

  List<dynamic> _list(dynamic value) {
    if (value is List) return value;
    throw const ApiException('The server returned an unexpected list.');
  }

  Future<Map<String, dynamic>> login(String email, String password) async {
    final response = _object(
      await _request(
        'POST',
        '/auth/login',
        authenticated: false,
        data: {'email': email, 'password': password},
      ),
    );
    return _sessionResponse(response);
  }

  Map<String, dynamic> _sessionResponse(Map<String, dynamic> response) {
    final user = _object(response['user']);
    final tokens = _object(response['tokens']);
    if ((tokens['access_token'] ?? '').toString().isEmpty) {
      throw const ApiException('Sign-in did not return a valid session.');
    }
    return {...user, ...tokens, 'name': user['full_name']};
  }

  Future<bool> _refreshAccess() async {
    final existing = _refreshing;
    if (existing != null) return existing;
    final pending = _rotateSession();
    _refreshing = pending;
    try {
      return await pending;
    } finally {
      if (identical(_refreshing, pending)) _refreshing = null;
    }
  }

  Future<bool> _rotateSession() async {
    final session = SessionManager.instance;
    final refreshToken = await session.getRefreshToken();
    if (refreshToken == null || refreshToken.isEmpty) return false;
    try {
      final result = _sessionResponse(
        _object(
          await _request(
            'POST',
            '/auth/refresh',
            authenticated: false,
            retryOnUnauthorized: false,
            data: {'refresh_token': refreshToken},
          ),
        ),
      );
      if (result['role'] != 'admin') return false;
      return await session.saveRefreshedSession(
        expectedRefreshToken: refreshToken,
        token: result['access_token'].toString(),
        refreshToken: result['refresh_token']?.toString(),
        name: (result['full_name'] ?? '').toString(),
        email: result['email'].toString(),
        role: result['role'].toString(),
        userId: result['user_id'].toString(),
      );
    } on ApiException {
      return false;
    }
  }

  Future<void> logout() async {
    final refreshToken = await SessionManager.instance.getRefreshToken();
    try {
      if (refreshToken != null && refreshToken.isNotEmpty) {
        await _request(
          'POST',
          '/auth/logout',
          data: {'refresh_token': refreshToken},
          retryOnUnauthorized: false,
        );
      }
    } finally {
      await SessionManager.instance.clearSession();
    }
  }

  Future<Map<String, dynamic>> getCurrentUser() async =>
      _object(await _request('GET', '/users/me'));
  Future<Map<String, dynamic>> updateOwnProfile(
    Map<String, dynamic> data,
  ) async => _object(await _request('PATCH', '/users/me', data: data));

  Future<List<dynamic>> getDestinations() async {
    final records = <dynamic>[];
    var offset = 0;
    while (true) {
      final page = _list(
        await _request(
          'GET',
          '/destinations?limit=100&offset=$offset',
          authenticated: false,
        ),
      );
      records.addAll(page);
      if (page.length < 100) return records;
      offset += page.length;
    }
  }

  /// Lists review candidates. A non-empty [query] searches the whole queue on the
  /// server (name, district, location, area, tag, category, notes, OSM id).
  Future<List<dynamic>> getDestinationCandidates({
    String reviewStatus = 'staged',
    int limit = 50,
    int offset = 0,
    String query = '',
  }) async {
    final search = query.trim();
    return _list(
      await _request(
        'GET',
        '/admin/destination-candidates?review_status=${Uri.encodeQueryComponent(reviewStatus)}&limit=$limit&offset=$offset${search.isEmpty ? '' : '&q=${Uri.encodeQueryComponent(search)}'}',
      ),
    );
  }

  Future<Map<String, dynamic>> updateDestinationCandidate(
    int id,
    Map<String, dynamic> data,
  ) async => _object(
    await _request('PATCH', '/admin/destination-candidates/$id', data: data),
  );

  Future<Map<String, dynamic>> rejectDestinationCandidate(
    int id,
    String reason,
  ) async => _object(
    await _request(
      'POST',
      '/admin/destination-candidates/$id/reject',
      data: {'reason': reason},
    ),
  );

  /// OpenStreetMap places whose name matches, around a point (up to 50 km).
  Future<List<dynamic>> searchOsmPlaces({
    required String name,
    required double lat,
    required double lng,
    int radiusM = 30000,
  }) async {
    final params = Uri(
      queryParameters: {
        'name': name.trim(),
        'lat': lat.toStringAsFixed(6),
        'lng': lng.toStringAsFixed(6),
        'radius_m': '$radiusM',
      },
    ).query;
    return _list(
      await _request('GET', '/admin/destination-candidates/osm/search?$params'),
    );
  }

  /// Destinations and staged candidates near a point, for duplicate warnings.
  Future<Map<String, dynamic>> nearbyPlaces({
    required double lat,
    required double lng,
    int radiusM = 500,
  }) async => _object(
    await _request(
      'GET',
      '/admin/destination-candidates/nearby?lat=${lat.toStringAsFixed(6)}'
          '&lng=${lng.toStringAsFixed(6)}&radius_m=$radiusM',
    ),
  );

  /// Queue an OpenStreetMap place for review.
  Future<Map<String, dynamic>> stageOsmCandidate(
    Map<String, dynamic> data,
  ) async => _object(
    await _request('POST', '/admin/destination-candidates', data: data),
  );

  /// Queue a pin dropped on the admin map (no OpenStreetMap object).
  Future<Map<String, dynamic>> stageManualCandidate(
    Map<String, dynamic> data,
  ) async => _object(
    await _request('POST', '/admin/destination-candidates/manual', data: data),
  );

  Future<Map<String, dynamic>> publishDestinationCandidate(int id) async =>
      _object(
        await _request('POST', '/admin/destination-candidates/$id/publish'),
      );

  Future<Map<String, dynamic>> createDestination(
    Map<String, dynamic> data,
  ) async => _object(await _request('POST', '/destinations', data: data));
  Future<Map<String, dynamic>> updateDestination(
    String id,
    Map<String, dynamic> data,
  ) async => _object(
    await _request(
      'PATCH',
      '/destinations/${Uri.encodeComponent(id)}',
      data: data,
    ),
  );
  /// Uploads a new destination photo; the API stores it in Cloudinary and
  /// returns the destination with its new `image_url`.
  Future<Map<String, dynamic>> uploadDestinationPhoto(
    String id,
    UploadFile photo,
  ) async => _object(
    await _request(
      'POST',
      '/destinations/${Uri.encodeComponent(id)}/image',
      file: photo,
    ),
  );
  Future<bool> deleteDestination(String id) async {
    await _request('DELETE', '/destinations/${Uri.encodeComponent(id)}');
    return true;
  }

  Future<List<dynamic>> _rates(String type, String? destinationId) async {
    if (destinationId == null || destinationId.isEmpty) {
      throw const ApiException('Choose a destination to view its rates.');
    }
    return _list(
      await _request(
        'GET',
        '/destinations/${Uri.encodeComponent(destinationId)}/$type',
        authenticated: false,
      ),
    );
  }

  Future<List<dynamic>> getAccommodationRates({String? destinationId}) =>
      _rates('accommodations', destinationId);
  Future<List<dynamic>> getTransportRates({String? destinationId}) =>
      _rates('transportations', destinationId);
  Future<Map<String, dynamic>> _createRate(
    String type,
    Map<String, dynamic> data,
  ) async {
    final payload = Map<String, dynamic>.from(data);
    final destinationId = payload.remove('destination_id')?.toString();
    if (destinationId == null || destinationId.isEmpty) {
      throw const ApiException('Choose a destination for this rate.');
    }
    return _object(
      await _request(
        'POST',
        '/destinations/${Uri.encodeComponent(destinationId)}/$type',
        data: payload,
      ),
    );
  }

  Map<String, dynamic> _rateUpdate(Map<String, dynamic> data) =>
      Map<String, dynamic>.from(data)..remove('destination_id');
  Future<Map<String, dynamic>> createAccommodationRate(
    Map<String, dynamic> data,
  ) => _createRate('accommodations', data);
  Future<Map<String, dynamic>> createTransportRate(Map<String, dynamic> data) =>
      _createRate('transportations', data);
  Future<Map<String, dynamic>> updateAccommodationRate(
    String id,
    Map<String, dynamic> data,
  ) async => _object(
    await _request(
      'PATCH',
      '/accommodations/${Uri.encodeComponent(id)}',
      data: _rateUpdate(data),
    ),
  );
  Future<Map<String, dynamic>> updateTransportRate(
    String id,
    Map<String, dynamic> data,
  ) async => _object(
    await _request(
      'PATCH',
      '/transportations/${Uri.encodeComponent(id)}',
      data: _rateUpdate(data),
    ),
  );
  Future<bool> deleteAccommodationRate(String id) async {
    await _request('DELETE', '/accommodations/${Uri.encodeComponent(id)}');
    return true;
  }

  Future<bool> deleteTransportRate(String id) async {
    await _request('DELETE', '/transportations/${Uri.encodeComponent(id)}');
    return true;
  }

  Future<Map<String, dynamic>> getAdminUsers({
    String query = '',
    int limit = 50,
    int offset = 0,
  }) async {
    final search = query.trim();
    return _object(
      await _request(
        'GET',
        '/admin/users?limit=$limit&offset=$offset${search.isEmpty ? '' : '&search=${Uri.encodeQueryComponent(search)}'}',
      ),
    );
  }

  Future<Map<String, dynamic>> updateAdminUserStatus(
    int userId, {
    required bool isActive,
  }) async => _object(
    await _request(
      'PATCH',
      '/admin/users/$userId',
      data: {'is_active': isActive},
    ),
  );

  Future<Map<String, dynamic>> getAdminTrips({
    String query = '',
    String? status,
    int limit = 50,
    int offset = 0,
  }) async {
    final search = query.trim();
    final statusParam =
        status == null || status.isEmpty || status == 'all'
            ? ''
            : '&status=${Uri.encodeQueryComponent(status)}';
    final queryParam = search.isEmpty
        ? ''
        : '&search=${Uri.encodeQueryComponent(search)}';
    return _object(
      await _request(
        'GET',
        '/admin/trips?limit=$limit&offset=$offset$statusParam$queryParam',
      ),
    );
  }

  Future<Map<String, dynamic>> getAdminReviews({
    String query = '',
    String status = 'active',
    int limit = 50,
    int offset = 0,
  }) async {
    final search = query.trim();
    final queryParam = search.isEmpty
        ? ''
        : '&search=${Uri.encodeQueryComponent(search)}';
    return _object(
      await _request(
        'GET',
        '/admin/reviews?status=${Uri.encodeQueryComponent(status)}&limit=$limit&offset=$offset$queryParam',
      ),
    );
  }

  Future<Map<String, dynamic>> archiveAdminReview(int reviewId) async =>
      _object(await _request('DELETE', '/admin/reviews/$reviewId'));

  Future<Map<String, dynamic>> getAppAssessmentSummary({
    int windowDays = 30,
  }) async => _object(
    await _request(
      'GET',
      '/evaluation/app-assessments/summary?window_days=$windowDays',
    ),
  );

  /// Previews a traveler route so admins can inspect road/sea geometry and gaps.
  Future<Map<String, dynamic>> previewRoute({
    required List<int> destinationIds,
    double? originLat,
    double? originLng,
    String? originLabel,
    String travelMode = 'driving',
  }) async => _object(
    await _request(
      'POST',
      '/routes/preview',
      data: {
        'destination_ids': destinationIds,
        'travel_mode': travelMode,
        if (originLat != null && originLng != null)
          'origin': {
            'label': (originLabel ?? '').trim().isEmpty
                ? 'Admin Test Start'
                : originLabel!.trim(),
            'lat': originLat,
            'lng': originLng,
          },
      },
    ),
  );

  Future<List<dynamic>> getSeaPorts({bool includeInactive = true}) async =>
      _list(
        await _request(
          'GET',
          '/admin/sea-ports?include_inactive=$includeInactive',
        ),
      );

  Future<Map<String, dynamic>> createSeaPort(Map<String, dynamic> data) async =>
      _object(await _request('POST', '/admin/sea-ports', data: data));

  Future<Map<String, dynamic>> updateSeaPort(
    int portId,
    Map<String, dynamic> data,
  ) async =>
      _object(await _request('PATCH', '/admin/sea-ports/$portId', data: data));

  Future<List<dynamic>> getSeaLinks({bool includeInactive = true}) async =>
      _list(
        await _request(
          'GET',
          '/admin/sea-links?include_inactive=$includeInactive',
        ),
      );

  Future<Map<String, dynamic>> createSeaLink(Map<String, dynamic> data) async =>
      _object(await _request('POST', '/admin/sea-links', data: data));

  Future<Map<String, dynamic>> updateSeaLink(
    int linkId,
    Map<String, dynamic> data,
  ) async =>
      _object(await _request('PATCH', '/admin/sea-links/$linkId', data: data));

  void close() => _client.close();
}
