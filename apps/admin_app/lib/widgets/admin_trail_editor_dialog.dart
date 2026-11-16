import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../core/davao_region_boundaries.dart';
import '../core/map_tiles.dart';
import '../core/polyline5.dart';

/// Opens a Davao Region interactive map dialog for tracing or editing a
/// multi-point road access trail or boat crossing track (`polyline5`).
///
/// Returns `null` if cancelled, `""` if the trail was cleared, or a non-empty
/// precision-5 encoded polyline string when saved with at least two waypoints.
Future<String?> showAdminTrailEditorDialog(
  BuildContext context, {
  required String title,
  required String subtitle,
  String? initialPolyline,
  LatLng? startPin,
  LatLng? endPin,
  String? startLabel,
  String? endLabel,
  Color lineColor = const Color(0xFF20878E),
}) {
  final decoded = (initialPolyline != null && initialPolyline.trim().isNotEmpty)
      ? decodePolyline5(initialPolyline.trim())
      : <LatLng>[];
  return showDialog<String>(
    context: context,
    builder: (dialogContext) => _AdminTrailEditorDialog(
      title: title,
      subtitle: subtitle,
      initialPoints: decoded,
      startPin: startPin,
      endPin: endPin,
      startLabel: startLabel,
      endLabel: endLabel,
      lineColor: lineColor,
    ),
  );
}

class _AdminTrailEditorDialog extends StatefulWidget {
  const _AdminTrailEditorDialog({
    required this.title,
    required this.subtitle,
    required this.initialPoints,
    required this.startPin,
    required this.endPin,
    required this.startLabel,
    required this.endLabel,
    required this.lineColor,
  });

  final String title;
  final String subtitle;
  final List<LatLng> initialPoints;
  final LatLng? startPin;
  final LatLng? endPin;
  final String? startLabel;
  final String? endLabel;
  final Color lineColor;

  @override
  State<_AdminTrailEditorDialog> createState() =>
      _AdminTrailEditorDialogState();
}

class _AdminTrailEditorDialogState extends State<_AdminTrailEditorDialog> {
  late final List<LatLng> _points = List<LatLng>.from(widget.initialPoints);
  final _mapController = MapController();
  AdminMapStyle _style = AdminMapStyle.streets;

  LatLng get _initialCenter {
    if (_points.isNotEmpty) return _points.first;
    if (widget.startPin != null && widget.endPin != null) {
      return LatLng(
        (widget.startPin!.latitude + widget.endPin!.latitude) / 2,
        (widget.startPin!.longitude + widget.endPin!.longitude) / 2,
      );
    }
    return widget.startPin ??
        widget.endPin ??
        const LatLng(7.0731, 125.6128);
  }

  List<LatLng> get _fitCoords => [
    ..._points,
    if (widget.startPin != null) widget.startPin!,
    if (widget.endPin != null) widget.endPin!,
  ];

  void _addPoint(LatLng pt) => setState(() => _points.add(pt));

  void _undo() {
    if (_points.isEmpty) return;
    setState(() => _points.removeLast());
  }

  void _seedFromPins() {
    if (widget.startPin == null || widget.endPin == null) return;
    setState(() {
      _points
        ..clear()
        ..add(widget.startPin!)
        ..add(widget.endPin!);
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final coords = _fitCoords;
    final polygons = <Polygon>[
      for (final entry in DavaoRegionBoundaries.regionCoordinates.entries)
        for (final ring in entry.value)
          Polygon(
            points: ring,
            color:
                (DavaoRegionBoundaries.regionColors[entry.key] ??
                        theme.colorScheme.primary)
                    .withValues(alpha: 0.08),
            borderColor:
                (DavaoRegionBoundaries.regionColors[entry.key] ??
                        theme.colorScheme.primary)
                    .withValues(alpha: 0.45),
            borderStrokeWidth: 1.2,
          ),
    ];

    final distanceMeters = polylineLengthMeters(_points);
    final canSave = _points.isEmpty || _points.length >= 2;

    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 880, maxHeight: 650),
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
                        Text(widget.subtitle, style: theme.textTheme.bodySmall),
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
              Wrap(
                spacing: 8,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  OutlinedButton.icon(
                    onPressed: _points.isEmpty ? null : _undo,
                    icon: const Icon(Icons.undo_rounded, size: 18),
                    label: const Text('Undo point'),
                  ),
                  if (widget.startPin != null && widget.endPin != null)
                    OutlinedButton.icon(
                      onPressed: _seedFromPins,
                      icon: const Icon(Icons.timeline_rounded, size: 18),
                      label: const Text('Start -> End straight line'),
                    ),
                  TextButton.icon(
                    onPressed: _points.isEmpty
                        ? null
                        : () => setState(_points.clear),
                    icon: const Icon(Icons.delete_outline, size: 18),
                    label: const Text('Clear trail'),
                  ),
                  Text(
                    _points.isEmpty
                        ? 'Click along the road/channel to add waypoints.'
                        : '${_points.length} point${_points.length == 1 ? '' : 's'} · ${formatDistanceMeters(distanceMeters)}',
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
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
                          initialCameraFit: coords.length >= 2
                              ? CameraFit.coordinates(
                                  coordinates: coords,
                                  padding: const EdgeInsets.all(64),
                                  maxZoom: 16,
                                )
                              : null,
                          initialCenter: _initialCenter,
                          initialZoom: 14,
                          onTap: (_, point) => _addPoint(point),
                        ),
                        children: [
                          AdminMapTiles.tileLayer(_style),
                          PolygonLayer(polygons: polygons),
                          if (widget.startPin != null &&
                              widget.endPin != null &&
                              _points.isEmpty)
                            PolylineLayer(
                              polylines: [
                                Polyline(
                                  points: [widget.startPin!, widget.endPin!],
                                  strokeWidth: 2.5,
                                  color: widget.lineColor.withValues(alpha: 0.45),
                                  pattern: const StrokePattern.dotted(),
                                ),
                              ],
                            ),
                          if (_points.length >= 2)
                            PolylineLayer(
                              polylines: [
                                Polyline(
                                  points: _points,
                                  strokeWidth: 4.5,
                                  color: widget.lineColor,
                                ),
                              ],
                            ),
                          MarkerLayer(
                            markers: [
                              if (widget.startPin != null)
                                _referenceMarker(
                                  point: widget.startPin!,
                                  color: const Color(0xFFD66F29),
                                  icon: Icons.local_parking_rounded,
                                  tooltip: widget.startLabel ?? 'Start / Gate',
                                ),
                              if (widget.endPin != null)
                                _referenceMarker(
                                  point: widget.endPin!,
                                  color: const Color(0xFF20878E),
                                  icon: Icons.place_rounded,
                                  tooltip: widget.endLabel ?? 'Destination Pin',
                                ),
                              for (var i = 0; i < _points.length; i++)
                                Marker(
                                  point: _points[i],
                                  width: 24,
                                  height: 24,
                                  child: Tooltip(
                                    message: 'Waypoint ${i + 1} (tap to remove)',
                                    child: GestureDetector(
                                      onTap: () =>
                                          setState(() => _points.removeAt(i)),
                                      child: DecoratedBox(
                                        decoration: BoxDecoration(
                                          color: i == 0
                                              ? const Color(0xFFD66F29)
                                              : widget.lineColor,
                                          shape: BoxShape.circle,
                                          border: Border.all(
                                            color: Colors.white,
                                            width: 2,
                                          ),
                                          boxShadow: const [
                                            BoxShadow(
                                              blurRadius: 3,
                                              color: Colors.black26,
                                            ),
                                          ],
                                        ),
                                        child: Center(
                                          child: Text(
                                            '${i + 1}',
                                            style: const TextStyle(
                                              color: Colors.white,
                                              fontSize: 10,
                                              fontWeight: FontWeight.w700,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
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
                      _points.length == 1
                          ? 'Add at least one more point (or clear to revert).'
                          : 'Tap anywhere on the map to append points; tap a numbered dot to delete it.',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: _points.length == 1
                            ? theme.colorScheme.error
                            : null,
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Cancel'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    onPressed: !canSave
                        ? null
                        : () => Navigator.pop(
                            context,
                            _points.isEmpty ? '' : encodePolyline5(_points),
                          ),
                    icon: const Icon(Icons.check),
                    label: Text(_points.isEmpty ? 'Clear & Save' : 'Use trail'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Marker _referenceMarker({
    required LatLng point,
    required Color color,
    required IconData icon,
    required String tooltip,
  }) => Marker(
    point: point,
    width: 30,
    height: 30,
    child: Tooltip(
      message: tooltip,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Colors.white,
          shape: BoxShape.circle,
          border: Border.all(color: color, width: 2.5),
          boxShadow: const [BoxShadow(blurRadius: 4, color: Colors.black26)],
        ),
        child: Icon(icon, size: 17, color: color),
      ),
    ),
  );
}
