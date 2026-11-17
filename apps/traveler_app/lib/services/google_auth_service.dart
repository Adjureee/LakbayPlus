import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';

import 'env_config.dart';
import 'lakbay_api_catalog_service.dart';

/// Wraps Google Sign-In (`google_sign_in` 7.x) for native Android/iOS and Web GIS
/// to retrieve a Google ID token ready for `POST /api/v1/auth/google`.
class GoogleAuthService {
  GoogleAuthService({this.customTokenFetcher});

  final Future<String?> Function()? customTokenFetcher;
  static bool _initialized = false;

  Future<void> signOut() async {
    if (customTokenFetcher != null || !_initialized) return;
    try {
      await GoogleSignIn.instance.signOut();
    } catch (_) {
      // Best-effort clear so the next login shows the account picker.
    }
  }

  Future<String?> requestGoogleIdToken() async {
    if (customTokenFetcher != null) {
      return customTokenFetcher!();
    }

    final clientId = EnvConfig.googleOAuthClientId.trim();
    if (clientId.isEmpty) {
      throw const LakbayApiException(
        'Google Sign-In needs GOOGLE_OAUTH_CLIENT_ID in .env (or use Email & Password below).',
      );
    }

    try {
      if (!_initialized) {
        await GoogleSignIn.instance.initialize(
          clientId: kIsWeb ? clientId : null,
          serverClientId: kIsWeb ? null : clientId,
        );
        _initialized = true;
      }

      if (GoogleSignIn.instance.supportsAuthenticate()) {
        // Clear any remembered Credential Manager selection so users can pick
        // a different Google account when switching accounts.
        await signOut();
        final account = await GoogleSignIn.instance.authenticate(
          scopeHint: const ['email', 'profile'],
        );
        final token = account.authentication.idToken;
        if (token == null || token.isEmpty) {
          throw const LakbayApiException(
            'Google did not return an ID token. Check GOOGLE_OAUTH_CLIENT_ID configuration.',
          );
        }
        return token;
      }

      // Web uses lightweight authentication / FedCM or stream events.
      final completer = Completer<String?>();
      late final StreamSubscription<GoogleSignInAuthenticationEvent> sub;
      sub = GoogleSignIn.instance.authenticationEvents.listen(
        (event) {
          if (event is GoogleSignInAuthenticationEventSignIn) {
            final token = event.user.authentication.idToken;
            if (!completer.isCompleted) completer.complete(token);
          }
        },
        onError: (Object err) {
          if (!completer.isCompleted) completer.completeError(err);
        },
      );

      try {
        final future = GoogleSignIn.instance.attemptLightweightAuthentication(
          reportAllExceptions: true,
        );
        if (future != null) {
          final acc = await future;
          final token = acc?.authentication.idToken;
          if (token != null && token.isNotEmpty) {
            return token;
          }
        }
        final streamedToken =
            await completer.future.timeout(const Duration(seconds: 12));
        if (streamedToken == null || streamedToken.isEmpty) {
          throw const LakbayApiException(
            'Google Sign-In was canceled or unavailable in this browser.',
          );
        }
        return streamedToken;
      } finally {
        await sub.cancel();
      }
    } on LakbayApiException {
      rethrow;
    } on GoogleSignInException catch (e) {
      if (e.code == GoogleSignInExceptionCode.canceled) {
        throw LakbayApiException(
          kIsWeb
              ? 'Google Sign-In was blocked or dismissed by the browser. Confirm GOOGLE_OAUTH_CLIENT_ID is your Web Client ID with this localhost origin authorized (or test on Android).'
              : 'Google Sign-In was canceled.',
        );
      }
      throw LakbayApiException(
        'Google Sign-In failed (${e.code.name})${e.description != null ? ': ${e.description}' : '.'}',
      );
    } on TimeoutException {
      throw const LakbayApiException(
        'Google Sign-In prompt timed out or was dismissed. Please allow popups or use Email & Password.',
      );
    } catch (e) {
      throw LakbayApiException('Google Sign-In failed: $e');
    }
  }
}
