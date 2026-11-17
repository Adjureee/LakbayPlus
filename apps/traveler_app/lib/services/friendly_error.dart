import 'dart:async';

import 'lakbay_api_catalog_service.dart';

/// Turns an exception into one plain sentence a traveler can act on. Never
/// shows stack traces, class names or raw JSON.
String friendlyError(Object error) {
  final raw = error.toString();

  if (error is TimeoutException) {
    return 'Lakbay+ took too long to answer. Check your connection and try '
        'again.';
  }
  if (_looksOffline(raw)) {
    return 'No internet connection. Check your connection and try again.';
  }
  if (raw.startsWith('Google Sign-In failed')) {
    return "Google sign-in didn't finish. Try again, or use your email.";
  }

  if (error is LakbayApiException) {
    final code = error.statusCode;
    if (code == 429 || (code != null && code >= 500)) {
      return 'Lakbay+ is busy right now. Try again in a moment.';
    }
    if (_isHumanSentence(error.message)) return error.message;
    if (code == 401 || code == 403) {
      return "That didn't work. Check your details and try again.";
    }
  }

  return 'Something went wrong. Please try again.';
}

bool _looksOffline(String raw) {
  const markers = [
    'SocketException',
    'ClientException',
    'Failed host lookup',
    'Connection refused',
    'Connection closed',
    'Network is unreachable',
    'XMLHttpRequest error',
  ];
  return markers.any(raw.contains);
}

/// Server messages such as "We couldn't find that person." are fine to show;
/// anything that reads like code is not.
bool _isHumanSentence(String message) {
  final m = message.trim();
  if (m.isEmpty || m.length > 200) return false;
  const codeLike = ['Exception', 'Error:', '{', '}', '[', 'null', 'http'];
  return !codeLike.any(m.contains);
}
