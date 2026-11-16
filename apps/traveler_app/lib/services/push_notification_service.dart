import 'dart:async';

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;

/// Platform-safe push notification token & handler adapter for Firebase Cloud Messaging.
///
/// When `google-services.json` and the Firebase Messaging SDK are wired on Android/iOS,
/// set [tokenFetcher] / [platformResolver] (or [onTokenRefresh]) at app startup. In
/// unconfigured/dev/test builds this cleanly becomes a no-op alongside 60s polling.
class PushNotificationService {
  PushNotificationService({
    this.tokenFetcher,
    this.platformResolver,
    this.tokenRefreshStream,
    this.foregroundMessageStream,
    this.openedMessageStream,
  });

  final Future<String?> Function()? tokenFetcher;
  final String Function()? platformResolver;
  final Stream<String>? tokenRefreshStream;
  final Stream<Map<String, dynamic>>? foregroundMessageStream;
  final Stream<Map<String, dynamic>>? openedMessageStream;

  StreamSubscription<String>? _refreshSub;
  StreamSubscription<Map<String, dynamic>>? _foregroundSub;
  StreamSubscription<Map<String, dynamic>>? _openedSub;

  String? _lastRegisteredToken;
  String? get lastRegisteredToken => _lastRegisteredToken;

  String resolvePlatform() {
    if (platformResolver != null) return platformResolver!();
    if (kIsWeb) return 'web';
    return defaultTargetPlatform == TargetPlatform.iOS ? 'ios' : 'android';
  }

  Future<String?> fetchToken() async {
    if (tokenFetcher == null) return null;
    try {
      final token = (await tokenFetcher!())?.trim();
      if (token == null || token.isEmpty) return null;
      _lastRegisteredToken = token;
      return token;
    } catch (_) {
      return null;
    }
  }

  void listen({
    required Future<void> Function(String token) onToken,
    required void Function(Map<String, dynamic> data) onForegroundMessage,
    void Function(Map<String, dynamic> data)? onOpenedMessage,
  }) {
    _refreshSub?.cancel();
    _foregroundSub?.cancel();
    _openedSub?.cancel();

    _refreshSub = tokenRefreshStream?.listen((tok) {
      final trimmed = tok.trim();
      if (trimmed.isNotEmpty) {
        _lastRegisteredToken = trimmed;
        onToken(trimmed);
      }
    });
    _foregroundSub = foregroundMessageStream?.listen(onForegroundMessage);
    if (onOpenedMessage != null) {
      _openedSub = openedMessageStream?.listen(onOpenedMessage);
    }
  }

  void dispose() {
    _refreshSub?.cancel();
    _foregroundSub?.cancel();
    _openedSub?.cancel();
  }
}
