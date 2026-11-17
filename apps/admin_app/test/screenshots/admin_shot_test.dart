// Renders admin screens at desktop size with mock API data and saves PNGs.
// Skipped unless SHOTS_DIR is set:
//
//   SHOTS_DIR=/path/to/out flutter test test/screenshots
@Tags(['screenshots'])
library;

import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lakbay_admin/core/theme/app_theme.dart';
import 'package:lakbay_admin/screens/dashboard_screen.dart';
import 'package:lakbay_admin/screens/login_screen.dart';
import 'package:lakbay_admin/services/api_service.dart';
import 'package:lakbay_admin/widgets/app_shell.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _outDir = Platform.environment['SHOTS_DIR'];

Future<void> _loadIconFont() async {
  final root = Platform.environment['FLUTTER_ROOT'];
  if (root == null) return;
  final file = File(
    '$root/bin/cache/artifacts/material_fonts/materialicons-regular.otf',
  );
  if (!file.existsSync()) return;
  final loader = FontLoader('MaterialIcons')
    ..addFont(Future.value(ByteData.sublistView(file.readAsBytesSync())));
  await loader.load();
}

Future<void> _shot(WidgetTester tester, GlobalKey key, String name) async {
  for (var i = 0; i < 4; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 120)),
    );
    await tester.pump(const Duration(milliseconds: 300));
  }
  final boundary =
      key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    File('$_outDir/$name.png').writeAsBytesSync(data!.buffer.asUint8List());
  });
}

ApiService _mockApi() => ApiService(
  tokenProvider: () async => 'shot-token',
  client: MockClient((request) async {
    final path = request.url.path;
    Object body;
    if (path.endsWith('/destinations')) {
      body = [
        for (final name in ['Samal Island', 'Mt. Apo', 'Eden Nature Park'])
          {'destination_id': name.length, 'name': name, 'is_active': true},
      ];
    } else if (path.contains('/admin/users')) {
      body = {'total_users': 24, 'items': []};
    } else if (path.contains('/admin/trips')) {
      body = {'total_trips': 31, 'matching_trips': 31, 'items': []};
    } else if (path.contains('/admin/reviews')) {
      body = {'total_reviews': 9, 'matching_reviews': 9, 'items': []};
    } else if (path.contains('/admin/destination-candidates')) {
      body = [
        {'name': 'Hagimit Falls', 'district': 'Samal', 'category': 'Waterfall'},
        {'name': 'Dahican Beach', 'district': 'Mati', 'category': 'Beach'},
      ];
    } else {
      body = <String, dynamic>{};
    }
    return http.Response(jsonEncode(body), 200);
  }),
);

void main() {
  testWidgets('admin screens', skip: _outDir == null, (tester) async {
    SharedPreferences.setMockInitialValues({});
    debugDisableShadows = false;
    await tester.runAsync(_loadIconFont);
    tester.view
      ..physicalSize = const Size(1440, 900)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final key = GlobalKey();

    await tester.pumpWidget(
      RepaintBoundary(
        key: key,
        child: MaterialApp(theme: AppTheme.darkTheme, home: const LoginScreen()),
      ),
    );
    await _shot(tester, key, 'admin_01_login');

    for (final (theme, name) in [
      (AppTheme.darkTheme, 'admin_02_dashboard_dark'),
      (AppTheme.lightTheme, 'admin_03_dashboard_light'),
    ]) {
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(
        RepaintBoundary(
          key: key,
          child: MaterialApp(
            theme: theme,
            initialRoute: '/dashboard',
            onGenerateRoute: (settings) => MaterialPageRoute<void>(
              settings: settings,
              builder: (_) => AppShell(child: DashboardScreen(api: _mockApi())),
            ),
          ),
        ),
      );
      await _shot(tester, key, name);
    }
    await tester.pumpWidget(const SizedBox());
    debugDisableShadows = true;
  });
}
