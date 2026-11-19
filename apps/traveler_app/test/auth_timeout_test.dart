import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lakbay_travel/services/lakbay_api_catalog_service.dart';

/// A server that never answers, like one that is still waking up.
LakbayApiCatalogService _silentServer() => LakbayApiCatalogService(
      baseUrlOverride: 'https://api.lakbay.test/api/v1',
      client: MockClient((_) => Completer<http.Response>().future),
    );

void main() {
  test('signing in waits for a slow server, then says so in words', () {
    fakeAsync((async) {
      Object? error;
      _silentServer()
          .googleLogin(idToken: 'token')
          .then<void>((_) {}).catchError((Object e) => error = e);

      // Past the usual 12 seconds it is still waiting, not giving up.
      async.elapse(const Duration(seconds: 13));
      expect(error, isNull);

      async.elapse(const Duration(seconds: 40));
      expect(error, isA<LakbayApiException>());
      expect((error! as LakbayApiException).message, contains('taking too long'));
    });
  });

  test('refreshing a session still gives up after 12 seconds', () {
    fakeAsync((async) {
      Object? error;
      _silentServer()
          .refreshSession('refresh')
          .then<void>((_) {}).catchError((Object e) => error = e);

      async.elapse(const Duration(seconds: 13));
      expect(error, isA<TimeoutException>());
    });
  });
}
