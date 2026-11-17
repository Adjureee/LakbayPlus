import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../core/davao_region_boundaries.dart';
import '../core/map_tiles.dart';

/// Opens a Davao Region (Region XI) map dialog (Mapbox, or OpenStreetMap
/// without a token) where admins can click
/// anywhere to pick destination coordinates cleanly.
Future<LatLng?> showAdminMapPinPickerDialog(
  BuildContext context, {
  double? initialLat,
  double? initialLng,
  String title = 'Pick destination pin on Davao Region map',
}) {
  final startLat = initialLat ?? 7.0731;
  final startLng = initialLng ?? 125.6128;
  return showDialog<LatLng>(
    context: context,
    builder: (dialogContext) => _AdminMapPinPickerDialog(
      title: title,
      initialPoint: LatLng(startLat, startLng),
    ),
  );
}

class _AdminMapPinPickerDialog extends StatefulWidget {
  const _AdminMapPinPickerDialog({
    required this.title,
    required this.initialPoint,
  });

  final String title;
  final LatLng initialPoint;

  @override
  State<_AdminMapPinPickerDialog> createState() =>
      _AdminMapPinPickerDialogState();
}

class _AdminMapPinPickerDialogState extends State<_AdminMapPinPickerDialog> {
  late LatLng _selected = widget.initialPoint;
  final _mapController = MapController();
  // Satellite helps find the actual gate or parking area.
  AdminMapStyle _style = AdminMapStyle.streets;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final polygons = <Polygon>[
      for (final entry in DavaoRegionBoundaries.regionCoordinates.entries)
        for (final ring in entry.value)
          Polygon(
            points: ring,
            color:
                (DavaoRegionBoundaries.regionColors[entry.key] ??
                        theme.colorScheme.primary)
                    .withValues(alpha: 0.10),
            borderColor:
                (DavaoRegionBoundaries.regionColors[entry.key] ??
                        theme.colorScheme.primary)
                    .withValues(alpha: 0.55),
            borderStrokeWidth: 1.5,
          ),
    ];

    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760, maxHeight: 580),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(widget.title, style: theme.textTheme.titleLarge),
                        const SizedBox(height: 4),
                        Text(
                          'Tap anywhere on the map to move the pin. Region XI boundaries are highlighted.',
                          style: theme.textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: 'Close',
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: Stack(
                    children: [
                      FlutterMap(
                        mapController: _mapController,
                        options: MapOptions(
                          initialCenter: _selected,
                          initialZoom: 9.5,
                          onTap: (_, point) =>
                              setState(() => _selected = point),
                        ),
                        children: [
                          AdminMapTiles.tileLayer(_style),
                          PolygonLayer(polygons: polygons),
                          MarkerLayer(
                            markers: [
                              Marker(
                                point: _selected,
                                width: 44,
                                height: 44,
                                child: Icon(
                                  Icons.location_on_rounded,
                                  size: 40,
                                  color: theme.colorScheme.primary,
                                ),
                              ),
                            ],
                          ),
                          AdminMapTiles.attribution(),
                        ],
                      ),
                      Positioned(
                        top: 10,
                        right: 10,
                        child: AdminMapStyleSwitch(
                          style: _style,
                          onChanged: (value) => setState(() => _style = value),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'Selected: ${_selected.latitude.toStringAsFixed(6)}, ${_selected.longitude.toStringAsFixed(6)}',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Cancel'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    onPressed: () => Navigator.pop(context, _selected),
                    icon: const Icon(Icons.check),
                    label: const Text('Use coordinates'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
