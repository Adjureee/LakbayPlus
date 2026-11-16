import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'env_config.dart';

enum LocationPermissionOutcome {
  granted,
  denied,
  deniedForever,
  serviceDisabled,
  error,
}

class LocationResult {
  final bool granted;
  final double? lat;
  final double? lng;
  final double? accuracyMeters;
  final String? resolvedLabel;
  final String statusMessage;
  final LocationPermissionOutcome? permissionOutcome;

  const LocationResult({
    required this.granted,
    this.lat,
    this.lng,
    this.accuracyMeters,
    this.resolvedLabel,
    required this.statusMessage,
    this.permissionOutcome,
  });

  LocationPermissionOutcome get effectiveOutcome =>
      permissionOutcome ??
      (granted ? LocationPermissionOutcome.granted : LocationPermissionOutcome.denied);

  bool get isPermanentlyDenied =>
      permissionOutcome == LocationPermissionOutcome.deniedForever;

  bool get isServiceDisabled =>
      permissionOutcome == LocationPermissionOutcome.serviceDisabled;
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

/// One place candidate returned by forward geocoding for manual origin search.
class PlaceSuggestion {
  final String label;
  final double lat;
  final double lng;

  const PlaceSuggestion({
    required this.label,
    required this.lat,
    required this.lng,
  });
}

/// Captures device or browser GPS coordinates with OS/Web permission prompts
/// and reverse-geocodes them into a human-readable city/region label.
class LocationService {
  LocationService({
    this.customFetcher,
    this.customPermissionChecker,
    this.customOpenAppSettings,
    this.customOpenLocationSettings,
    this.customPositionStream,
    this.customPlaceSearcher,
    this.customReverseGeocoder,
    http.Client? httpClient,
  }) : _httpClient = httpClient ?? http.Client();

  final Future<LocationResult> Function()? customFetcher;
  final Future<LocationPermissionOutcome> Function()? customPermissionChecker;
  final Future<bool> Function()? customOpenAppSettings;
  final Future<bool> Function()? customOpenLocationSettings;

  Future<LocationPermissionOutcome> checkPermissionOutcome() async {
    if (customPermissionChecker != null) {
      return customPermissionChecker!();
    }
    try {
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) return LocationPermissionOutcome.serviceDisabled;
      final permission = await Geolocator.checkPermission();
      return switch (permission) {
        LocationPermission.whileInUse ||
        LocationPermission.always =>
          LocationPermissionOutcome.granted,
        LocationPermission.deniedForever =>
          LocationPermissionOutcome.deniedForever,
        LocationPermission.denied ||
        LocationPermission.unableToDetermine =>
          LocationPermissionOutcome.denied,
      };
    } catch (_) {
      return LocationPermissionOutcome.error;
    }
  }

  Future<bool> openAppSettings() async {
    if (customOpenAppSettings != null) return customOpenAppSettings!();
    try {
      return await Geolocator.openAppSettings();
    } catch (_) {
      return false;
    }
  }

  Future<bool> openLocationSettings() async {
    if (customOpenLocationSettings != null) {
      return customOpenLocationSettings!();
    }
    try {
      return await Geolocator.openLocationSettings();
    } catch (_) {
      return false;
    }
  }

  /// Test hook replacing the device position stream.
  final Stream<LivePosition> Function()? customPositionStream;

  /// Test hook replacing forward geocoding search.
  final Future<List<PlaceSuggestion>> Function(String query)?
      customPlaceSearcher;

  /// Test hook replacing reverse geocoding.
  final Future<String> Function(double lat, double lng)? customReverseGeocoder;
  final http.Client _httpClient;

  Future<bool> hasGrantedPermission() async {
    if (customPermissionChecker != null) {
      return (await customPermissionChecker!()) ==
          LocationPermissionOutcome.granted;
    }
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
          permissionOutcome: LocationPermissionOutcome.serviceDisabled,
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
          permissionOutcome: LocationPermissionOutcome.denied,
          statusMessage: 'Location permission was declined.',
        );
      }

      if (permission == LocationPermission.deniedForever) {
        return const LocationResult(
          granted: false,
          permissionOutcome: LocationPermissionOutcome.deniedForever,
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
          permissionOutcome: LocationPermissionOutcome.error,
          statusMessage: 'Unable to determine your current location right now.',
        );
      }

      final label = await reverseGeocode(position.latitude, position.longitude);
      return LocationResult(
        granted: true,
        permissionOutcome: LocationPermissionOutcome.granted,
        lat: position.latitude,
        lng: position.longitude,
        accuracyMeters: position.accuracy,
        resolvedLabel: label,
        statusMessage: 'Location detected: $label',
      );
    } catch (_) {
      return const LocationResult(
        granted: false,
        permissionOutcome: LocationPermissionOutcome.error,
        statusMessage: 'Unable to determine your current location right now.',
      );
    }
  }

  Future<String> reverseGeocode(double lat, double lng) async {
    if (customReverseGeocoder != null) {
      return customReverseGeocoder!(lat, lng);
    }
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

  /// Searches for starting places by name via Mapbox Geocoding or Nominatim.
  Future<List<PlaceSuggestion>> searchPlaces(String query) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return const [];
    if (customPlaceSearcher != null) {
      return customPlaceSearcher!(trimmed);
    }
    final encoded = Uri.encodeQueryComponent(trimmed);
    final mapboxToken = EnvConfig.mapboxAccessToken.trim();
    if (mapboxToken.isNotEmpty) {
      try {
        final uri = Uri.parse(
          'https://api.mapbox.com/geocoding/v5/mapbox.places/$encoded.json'
          '?types=place,locality,neighborhood,poi,address&limit=5&access_token=$mapboxToken',
        );
        final res =
            await _httpClient.get(uri).timeout(const Duration(seconds: 6));
        if (res.statusCode == 200) {
          final decoded = jsonDecode(res.body);
          if (decoded is Map<String, dynamic>) {
            final features = decoded['features'] as List<dynamic>? ?? const [];
            final results = <PlaceSuggestion>[];
            for (final raw in features) {
              if (raw is! Map) continue;
              final center = raw['center'] as List<dynamic>?;
              final label = (raw['place_name'] ?? raw['text'] ?? '').toString().trim();
              if (center != null && center.length >= 2 && label.isNotEmpty) {
                final lng = (center[0] as num?)?.toDouble();
                final lat = (center[1] as num?)?.toDouble();
                if (lat != null && lng != null) {
                  results.add(PlaceSuggestion(label: label, lat: lat, lng: lng));
                }
              }
            }
            if (results.isNotEmpty) return results;
          }
        }
      } catch (_) {}
    }

    try {
      final uri = Uri.parse(
        'https://nominatim.openstreetmap.org/search'
        '?format=jsonv2&q=$encoded&limit=5',
      );
      final res =
          await _httpClient.get(uri).timeout(const Duration(seconds: 6));
      if (res.statusCode == 200) {
        final decoded = jsonDecode(res.body);
        if (decoded is List) {
          final results = <PlaceSuggestion>[];
          for (final raw in decoded) {
            if (raw is! Map) continue;
            final label = (raw['display_name'] ?? '').toString().trim();
            final lat = double.tryParse((raw['lat'] ?? '').toString());
            final lng = double.tryParse((raw['lon'] ?? '').toString());
            if (lat != null && lng != null && label.isNotEmpty) {
              // Trim long Nominatim tails to the first 3 comma segments for readability.
              final shortLabel = label.split(',').take(3).map((s) => s.trim()).join(', ');
              results.add(PlaceSuggestion(label: shortLabel, lat: lat, lng: lng));
            }
          }
          return results;
        }
      }
    } catch (_) {}

    return const [];
  }
}
