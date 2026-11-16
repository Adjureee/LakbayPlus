import 'package:flutter/services.dart' show rootBundle;

/// Loads API keys and service settings from `.env` (bundled as an asset)
/// with `--dart-define` compile-time overrides.
class EnvConfig {
  EnvConfig._();

  static final Map<String, String> _values = {};
  static bool _loaded = false;

  static bool get isLoaded => _loaded;

  /// Seeds environment values cleanly inside unit/widget tests.
  static void seedForTesting(Map<String, String> values) {
    _values
      ..clear()
      ..addAll(values);
    _loaded = true;
  }

  /// Loads `.env` from the Flutter asset bundle. Safe to call multiple times.
  static Future<void> load({String assetPath = '.env'}) async {
    try {
      final raw = await rootBundle.loadString(assetPath);
      loadFromString(raw);
    } catch (_) {
      _loaded = true;
    }
  }

  /// Parses raw `.env` key=value lines into memory (also useful for unit tests).
  static void loadFromString(String raw) {
    _values.clear();
    for (final rawLine in raw.split(RegExp(r'\r?\n'))) {
      final line = rawLine.trim();
      if (line.isEmpty || line.startsWith('#')) continue;
      final eqIndex = line.indexOf('=');
      if (eqIndex <= 0) continue;
      final key = line.substring(0, eqIndex).trim();
      var value = line.substring(eqIndex + 1).trim();
      if ((value.startsWith('"') && value.endsWith('"')) ||
          (value.startsWith("'") && value.endsWith("'"))) {
        if (value.length >= 2) {
          value = value.substring(1, value.length - 1);
        }
      }
      if (key.isNotEmpty) {
        _values[key] = value;
      }
    }
    _loaded = true;
  }

  static String get(String key, {String fallback = ''}) {
    final v = _values[key];
    if (v != null && v.isNotEmpty) return v;
    return fallback;
  }

  // Compile-time --dart-define overrides take precedence if non-empty.
  static const String _defineMapbox =
      String.fromEnvironment('MAPBOX_ACCESS_TOKEN', defaultValue: '');
  static const String _defineCloudName =
      String.fromEnvironment('CLOUDINARY_CLOUD_NAME', defaultValue: '');
  static const String _definelakbayApiBaseUrl =
      String.fromEnvironment('LAKBAY_API_BASE_URL', defaultValue: '');
  static const String _defineGoogleClientId =
      String.fromEnvironment('GOOGLE_OAUTH_CLIENT_ID', defaultValue: '');

  static String get mapboxAccessToken =>
      _defineMapbox.isNotEmpty ? _defineMapbox : get('MAPBOX_ACCESS_TOKEN');

  // AI runs on the Lakbay backend (POST /ai/chat, /ai/chat/guest,
  // /ai/trip-draft). Never put an AI provider key in this file: .env is
  // bundled into the app and anyone can read it from the APK.

  // Cloudinary
  static String get cloudinaryCloudName => _defineCloudName.isNotEmpty
      ? _defineCloudName
      : get('CLOUDINARY_CLOUD_NAME');
  static String get cloudinaryUploadPreset => get('CLOUDINARY_UPLOAD_PRESET');

  // Optional OpenWeather & Lakbay+ Backend API
  static String get openWeatherApiKey => get('OPENWEATHER_API_KEY');
  static String get lakbayApiBaseUrl => _definelakbayApiBaseUrl.isNotEmpty
      ? _definelakbayApiBaseUrl
      : get('LAKBAY_API_BASE_URL');
  static String get googleOAuthClientId => _defineGoogleClientId.isNotEmpty
      ? _defineGoogleClientId
      : get('GOOGLE_OAUTH_CLIENT_ID');
  static bool get hasLakbayApi => lakbayApiBaseUrl.trim().isNotEmpty;
  static bool get hasGoogleOAuth => googleOAuthClientId.trim().isNotEmpty;

  /// The cloud name is public and only builds delivery URLs. Uploads go
  /// through the Lakbay API, which holds the Cloudinary key and secret; they
  /// must never be bundled into the app's `.env` asset.
  static bool get hasCloudinaryConfig => cloudinaryCloudName.trim().isNotEmpty;
}
