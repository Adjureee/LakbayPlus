import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:lakbay_admin/core/map_tiles.dart';
import 'package:lakbay_admin/widgets/admin_map_pin_picker.dart';

void main() {
  test('Mapbox tile URLs use the chosen style and the public token', () {
    expect(
      AdminMapTiles.urlTemplate(AdminMapStyle.streets, token: 'pk.abc'),
      'https://api.mapbox.com/styles/v1/mapbox/streets-v12'
      '/tiles/512/{z}/{x}/{y}@2x?access_token=pk.abc',
    );
    expect(
      AdminMapTiles.urlTemplate(AdminMapStyle.satellite, token: 'pk.abc'),
      contains('/mapbox/satellite-streets-v12/'),
    );
  });

  test('without a public token, OpenStreetMap tiles are used', () {
    // Tests run without --dart-define, so no token is configured.
    expect(AdminMapTiles.usesMapbox, isFalse);
    expect(
      AdminMapTiles.tileLayer(AdminMapStyle.satellite).urlTemplate,
      'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
    );
    expect(
      AdminMapTiles.urlTemplate(AdminMapStyle.streets, token: ''),
      contains('tile.openstreetmap.org'),
    );
  });

  testWidgets('pin picker shows attribution and hides Satellite without Mapbox',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showAdminMapPinPickerDialog(context),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.byType(RichAttributionWidget), findsOneWidget);
    expect(find.byType(SegmentedButton<AdminMapStyle>), findsNothing);
    expect(find.text('Use coordinates'), findsOneWidget);
  });
}
