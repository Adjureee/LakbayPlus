import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:url_launcher/url_launcher.dart';

/// Base-map styles the admin can switch between.
enum AdminMapStyle {
  streets('Streets', 'streets-v12'),
  satellite('Satellite', 'satellite-streets-v12');

  const AdminMapStyle(this.label, this.mapboxStyleId);

  final String label;
  final String mapboxStyleId;
}

/// Tile source for every admin map.
///
/// Uses Mapbox when a **public** token is supplied at build time:
/// `flutter run -d chrome --dart-define=MAPBOX_PUBLIC_TOKEN=pk....`
/// The admin site is a web build, so the token is visible to anyone who opens
/// it: restrict it to the admin site's URL in the Mapbox account. A secret
/// (`sk.`) token is ignored. Without a token, OpenStreetMap tiles are used.
class AdminMapTiles {
  AdminMapTiles._();

  static const String _rawToken = String.fromEnvironment('MAPBOX_PUBLIC_TOKEN');

  /// The token, only if it is a public one.
  static String get mapboxToken =>
      _rawToken.trim().startsWith('pk.') ? _rawToken.trim() : '';

  static bool get usesMapbox => mapboxToken.isNotEmpty;

  static String urlTemplate(AdminMapStyle style, {String? token}) {
    final key = token ?? mapboxToken;
    if (key.isEmpty) return 'https://tile.openstreetmap.org/{z}/{x}/{y}.png';
    return 'https://api.mapbox.com/styles/v1/mapbox/${style.mapboxStyleId}'
        '/tiles/512/{z}/{x}/{y}@2x?access_token=$key';
  }

  static TileLayer tileLayer(AdminMapStyle style) {
    if (!usesMapbox) {
      return TileLayer(
        urlTemplate: urlTemplate(style),
        userAgentPackageName: 'com.lakbay.plus.lakbay_admin',
      );
    }
    // Mapbox style tiles are 512 px; offset the zoom so labels stay readable.
    return TileLayer(
      urlTemplate: urlTemplate(style),
      tileDimension: 512,
      zoomOffset: -1,
      maxNativeZoom: 22,
      userAgentPackageName: 'com.lakbay.plus.lakbay_admin',
    );
  }

  /// Attribution each provider requires on every map.
  static Widget attribution() => RichAttributionWidget(
    showFlutterMapAttribution: false,
    attributions: [
      if (usesMapbox) ...[
        TextSourceAttribution(
          'Mapbox',
          onTap: () => _open('https://www.mapbox.com/about/maps/'),
        ),
        TextSourceAttribution(
          'OpenStreetMap contributors',
          onTap: () => _open('https://www.openstreetmap.org/copyright'),
        ),
        TextSourceAttribution(
          'Improve this map',
          prependCopyright: false,
          onTap: () => _open('https://apps.mapbox.com/feedback/'),
        ),
      ] else
        TextSourceAttribution(
          'OpenStreetMap contributors',
          onTap: () => _open('https://www.openstreetmap.org/copyright'),
        ),
    ],
  );

  static Future<void> _open(String url) =>
      launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
}

/// Streets / Satellite switch shown over a map. Satellite only exists with
/// Mapbox, so the switch is hidden on OpenStreetMap tiles.
class AdminMapStyleSwitch extends StatelessWidget {
  const AdminMapStyleSwitch({
    super.key,
    required this.style,
    required this.onChanged,
  });

  final AdminMapStyle style;
  final ValueChanged<AdminMapStyle> onChanged;

  @override
  Widget build(BuildContext context) {
    if (!AdminMapTiles.usesMapbox) return const SizedBox.shrink();
    return Material(
      color: Theme.of(context).colorScheme.surface.withValues(alpha: 0.95),
      borderRadius: BorderRadius.circular(10),
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: SegmentedButton<AdminMapStyle>(
          showSelectedIcon: false,
          style: const ButtonStyle(visualDensity: VisualDensity.compact),
          segments: [
            for (final value in AdminMapStyle.values)
              ButtonSegment(value: value, label: Text(value.label)),
          ],
          selected: {style},
          onSelectionChanged: (selection) => onChanged(selection.first),
        ),
      ),
    );
  }
}
