import 'dart:convert';
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

/// Captures device or browser GPS coordinates with OS/Web permission prompts
/// and reverse-geocodes them into a human-readable city/region label.
class LocationService {
  LocationService({
    this.customFetcher,
    http.Client? httpClient,
  }) : _httpClient = httpClient ?? http.Client();

  final Future<LocationResult> Function()? customFetcher;
  final http.Client _httpClient;

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

      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.medium,
          timeLimit: Duration(seconds: 12),
        ),
      );

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
