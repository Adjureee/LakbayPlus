import 'package:firebase_analytics/firebase_analytics.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'analytics_service.dart';

/// Connects [AnalyticsService] to Firebase Analytics and Crashlytics.
///
/// Uses the same `google-services.json` as push notifications. Without it, on
/// the web, or on a platform Firebase is not set up for, [create] returns a
/// service that does nothing and the app behaves as before.
///
/// Both collections start switched off in the Android manifest and stay off
/// until the traveler explicitly opts in (never in a debug build), so a
/// traveler who has not opted in is never counted and development does not
/// pollute the numbers.
class FirebaseAnalyticsSetup {
  FirebaseAnalyticsSetup._();

  static Future<AnalyticsService> create() async {
    if (kIsWeb) return AnalyticsService();
    try {
      await Firebase.initializeApp();
      final analytics = FirebaseAnalytics.instance;
      final crashlytics = FirebaseCrashlytics.instance;
      if (!kDebugMode) {
        // Keep the console crash dump while developing; report in release.
        FlutterError.onError = crashlytics.recordFlutterFatalError;
        PlatformDispatcher.instance.onError = (error, stack) {
          crashlytics.recordError(error, stack, fatal: true);
          return true;
        };
      }
      final service = AnalyticsService(
        sender: (name, parameters) =>
            analytics.logEvent(name: name, parameters: parameters),
        collectionSwitch: (enabled) async {
          final on = enabled && !kDebugMode;
          await analytics.setAnalyticsCollectionEnabled(on);
          await crashlytics.setCrashlyticsCollectionEnabled(on);
        },
        prefs: await SharedPreferences.getInstance(),
      );
      await service.start();
      return service;
    } catch (error) {
      debugPrint('Usage and crash reports are off (Firebase not set up): $error');
      return AnalyticsService();
    }
  }
}
