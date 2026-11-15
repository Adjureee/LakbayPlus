import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'env_config.dart';

class LocationResult {
  final bool granted;
  final double? lat;
  final double? lng;
  final double? accuracyMeters;
  final String? resolvedLabel;
  final String statusMessage;

  const LocationResult({
    required this.granted,
    this.lat,
    this.lng,
    this.accuracyMeters,
    this.resolvedLabel,
    required this.statusMessage,
  });
}

/// One live GPS fix from the position stream.
class LivePosition {
  final double lat;
  final double lng;
  final double accuracyMeters;

  /// Direction of travel in degrees from north, or null when unknown
  /// (standing still, or the platform does not report it).
  final double? headingDegrees;
  final double? speedMetersPerSecond;
  final DateTime timestamp;

  const LivePosition({
    required this.lat,
    required this.lng,
    required this.accuracyMeters,
    this.headingDegrees,
    this.speedMetersPerSecond,
    required this.timestamp,
  });

  factory LivePosition.fromPosition(Position position) {
    final moving = position.speed > 0.8; // ~3 km/h; heading is noise below it
    return LivePosition(
      lat: position.latitude,
      lng: position.longitude,
      accuracyMeters: position.accuracy,
      headingDegrees:
          moving && position.heading >= 0 ? position.heading : null,
      speedMetersPerSecond: position.speed >= 0 ? position.speed : null,
      timestamp: position.timestamp,
    );
  }
}

/// Captures device or browser GPS coordinates with OS/Web permission prompts
/// and reverse-geocodes them into a human-readable city/region label.
class LocationService {
  LocationService({
    this.customFetcher,
    this.customPositionStream,
    http.Client? httpClient,
  }) : _httpClient = httpClient ?? http.Client();

  final Future<LocationResult> Function()? customFetcher;

  /// Test hook replacing the device position stream.
  final Stream<LivePosition> Function()? customPositionStream;
  final http.Client _httpClient;

  Future<bool> hasGrantedPermission() async {
    if (customFetcher != null) return false;
    try {
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) return false;
      final permission = await Geolocator.checkPermission();
      return permission == LocationPermission.whileInUse ||
          permission == LocationPermission.always;
    } catch (_) {
      return false;
    }
  }

  /// Asks for location permission if needed; true when the stream may start.
  Future<bool> ensurePermission() async {
    if (customPositionStream != null) return true;
    try {
      if (!await Geolocator.isLocationServiceEnabled()) return false;
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      return permission == LocationPermission.whileInUse ||
          permission == LocationPermission.always;
    } catch (_) {
      return false;
    }
  }

  /// Continuous GPS fixes while the app is in the foreground. A fix arrives
  /// after moving about [distanceFilterMeters] (or every few seconds on
  /// Android). Call [ensurePermission] first.
  Stream<LivePosition> watchPosition({
    int distanceFilterMeters = 10,
    bool navigation = false,
  }) {
    if (customPositionStream != null) return customPositionStream!();
    final accuracy =
        navigation ? LocationAccuracy.bestForNavigation : LocationAccuracy.high;
    final LocationSettings settings;
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      settings = AndroidSettings(
        accuracy: accuracy,
        distanceFilter: distanceFilterMeters,
        intervalDuration: const Duration(seconds: 4),
      );
    } else if (!kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.iOS ||
            defaultTargetPlatform == TargetPlatform.macOS)) {
      settings = AppleSettings(
        accuracy: accuracy,
        distanceFilter: distanceFilterMeters,
        activityType: ActivityType.automotiveNavigation,
        pauseLocationUpdatesAutomatically: true,
      );
    } else {
      settings = LocationSettings(
        accuracy: accuracy,
        distanceFilter: distanceFilterMeters,
      );
    }
    return Geolocator.getPositionStream(locationSettings: settings)
        .map(LivePosition.fromPosition);
  }

  Future<LocationResult> captureCurrentLocation() async {
    if (customFetcher != null) {
      return customFetcher!();
    }

    try {
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        return const LocationResult(
          granted: false,
          statusMessage: 'Location services are turned off on this device.',
        );
      }

      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }

      if (permission == LocationPermission.denied) {
        return const LocationResult(
          granted: false,
          statusMessage: 'Location permission was declined.',
        );
      }

      if (permission == LocationPermission.deniedForever) {
        return const LocationResult(
          granted: false,
          statusMessage:
              'Location permission is blocked in browser or system settings.',
        );
      }

      Position? position;
      try {
        position = await Geolocator.getCurrentPosition(
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.medium,
            timeLimit: Duration(seconds: 12),
          ),
        );
      } catch (_) {
        position = await Geolocator.getLastKnownPosition();
      }
      if (position == null) {
        return const LocationResult(
          granted: false,
          statusMessage: 'Unable to determine your current location right now.',
        );
      }

      final label = await reverseGeocode(position.latitude, position.longitude);
      return LocationResult(
        granted: true,
        lat: position.latitude,
        lng: position.longitude,
        accuracyMeters: position.accuracy,
        resolvedLabel: label,
        statusMessage: 'Location detected: $label',
      );
    } catch (_) {
      return const LocationResult(
        granted: false,
        statusMessage: 'Unable to determine your current location right now.',
      );
    }
  }

  Future<String> reverseGeocode(double lat, double lng) async {
    final mapboxToken = EnvConfig.mapboxAccessToken.trim();
    if (mapboxToken.isNotEmpty) {
      try {
        final uri = Uri.parse(
          'https://api.mapbox.com/geocoding/v5/mapbox.places/$lng,$lat.json'
          '?types=place,locality,region&limit=1&access_token=$mapboxToken',
        );
        final res =
            await _httpClient.get(uri).timeout(const Duration(seconds: 5));
        if (res.statusCode == 200) {
          final decoded = jsonDecode(res.body);
          if (decoded is Map<String, dynamic>) {
            final features = decoded['features'] as List<dynamic>? ?? const [];
            if (features.isNotEmpty && features.first is Map) {
              final placeName =
                  (features.first as Map)['place_name']?.toString().trim() ??
                      '';
              if (placeName.isNotEmpty) return placeName;
            }
          }
        }
      } catch (_) {}
    }

    try {
      final uri = Uri.parse(
        'https://nominatim.openstreetmap.org/reverse'
        '?format=jsonv2&lat=${lat.toStringAsFixed(5)}&lon=${lng.toStringAsFixed(5)}&zoom=10',
      );
      final res =
          await _httpClient.get(uri).timeout(const Duration(seconds: 5));
      if (res.statusCode == 200) {
        final decoded = jsonDecode(res.body);
        if (decoded is Map<String, dynamic>) {
          final addr = decoded['address'] as Map<String, dynamic>? ?? const {};
          final city = (addr['city'] ??
                  addr['town'] ??
                  addr['municipality'] ??
                  addr['village'] ??
                  '')
              .toString()
              .trim();
          final country = (addr['country'] ?? '').toString().trim();
          if (city.isNotEmpty && country.isNotEmpty) {
            return '$city, $country';
          }
          if (city.isNotEmpty) return city;
        }
      }
    } catch (_) {}

    return '${lat.toStringAsFixed(3)}°, ${lng.toStringAsFixed(3)}°';
  }
}
