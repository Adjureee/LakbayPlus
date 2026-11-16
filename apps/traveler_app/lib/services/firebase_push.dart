import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';

import 'push_notification_service.dart';

/// Connects [PushNotificationService] to Firebase Cloud Messaging.
///
/// Needs `google-services.json` in `android/app/` (from the Firebase console).
/// Without it, or on a platform Firebase is not set up for, [create] returns a
/// plain service that does nothing: the app still checks for notifications
/// every minute while it is open.
class FirebasePush {
  FirebasePush._();

  static Future<PushNotificationService> create() async {
    if (kIsWeb) return PushNotificationService();
    try {
      await Firebase.initializeApp();
      final messaging = FirebaseMessaging.instance;
      return PushNotificationService(
        tokenFetcher: () => _requestPermissionAndToken(messaging),
        tokenRefreshStream: messaging.onTokenRefresh,
        foregroundMessageStream:
            FirebaseMessaging.onMessage.map((m) => _data(m)),
        openedMessageStream: _opened(messaging),
      );
    } catch (error) {
      debugPrint('Push notifications are off (Firebase not set up): $error');
      return PushNotificationService();
    }
  }

  /// Asks for the notification permission (Android 13+ shows a prompt) and
  /// returns this device's token, or null when the traveler said no.
  static Future<String?> _requestPermissionAndToken(
    FirebaseMessaging messaging,
  ) async {
    final settings = await messaging.requestPermission();
    if (settings.authorizationStatus == AuthorizationStatus.denied) {
      return null;
    }
    return messaging.getToken();
  }

  /// Taps on a notification: one that launched the app from closed, then any
  /// tapped while the app is in the background.
  static Stream<Map<String, dynamic>> _opened(FirebaseMessaging messaging) async* {
    final initial = await messaging.getInitialMessage();
    if (initial != null) yield _data(initial);
    yield* FirebaseMessaging.onMessageOpenedApp.map(_data);
  }

  static Map<String, dynamic> _data(RemoteMessage message) =>
      Map<String, dynamic>.from(message.data);
}
