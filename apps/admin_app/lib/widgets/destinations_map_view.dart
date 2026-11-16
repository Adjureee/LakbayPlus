import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../core/davao_region_boundaries.dart';
import '../core/map_tiles.dart';
import '../services/api_service.dart';
import 'add_place.dart';
import 'admin_widgets.dart';
import 'destination_photo_upload.dart';

/// All destinations on one map. Clicking a pin opens a side panel with the
/// photo, key details and route-endpoint status, and actions to view, edit or
/// move the pin.
class DestinationsMapView extends StatefulWidget {
  const DestinationsMapView({
    super.key,
    required this.records,
    required this.api,
    required this.onView,
    required this.onEdit,
    required this.onPinMoved,
    required this.onPhotoReplaced,
    required this.onCandidateQueued,
    this.initialSelectedId,
  });

  /// Called with the new review-queue candidate after "Add to review queue".
  final ValueChanged<Map<String, dynamic>> onCandidateQueued;

  /// Called with the saved record after "Replace photo" succeeds.
  final ValueChanged<Map<String, dynamic>> onPhotoReplaced;

  /// Destination to keep selected after the list reloads.
  final String? initialSelectedId;

  final List<Map<String, dynamic>> records;
  final ApiService api;
  final ValueChanged<Map<String, dynamic>> onView;
  final ValueChanged<Map<String, dynamic>> onEdit;

  /// Called with the saved record after "Move pin" succeeds.
  final ValueChanged<Map<String, dynamic>> onPinMoved;

  @override
  State<DestinationsMapView> createState() => _DestinationsMapViewState();
}

class _DestinationsMapViewState extends State<DestinationsMapView> {
  final _map = MapController();
  AdminMapStyle _style = AdminMapStyle.streets;
  late String? _selectedId = widget.initialSelectedId;
  bool _moving = false;

  /// A place being added (search result or dropped pin), and pin-drop mode.
  PlaceDraft? _draft;
  bool _dropping = false;
  LatLng? _movedTo;
  bool _saving = false;
  String? _error;

  /// Farther than this, a route endpoint probably belongs to an old pin.
  static const _endpointWarnMeters = 2000.0;

  Map<String, dynamic>? get _selected {
    for (final record in widget.records) {
      if (_id(record) == _selectedId) return record;
    }
    return null;
  }

  void _select(Map<String, dynamic> record) {
    if (_moving) return;
    setState(() {
      _selectedId = _id(record);
      _error = null;
      _draft = null;
      _dropping = false;
    });
  }

  void _showOsmResult(Map<String, dynamic> match) {
    final draft = PlaceDraft.fromOsm(match);
    setState(() {
      _draft = draft;
      _dropping = false;
      _selectedId = null;
    });
    _map.move(draft.point, math.max(_map.camera.zoom, 14));
  }

  void _clearDraft() => setState(() {
    _draft = null;
    _dropping = false;
  });

  void _startMove() => setState(() {
    _moving = true;
    _movedTo = null;
    _error = null;
  });

  void _cancelMove() => setState(() {
    _moving = false;
    _movedTo = null;
  });

  Future<void> _saveMove() async {
    final record = _selected;
    final point = _movedTo;
    if (record == null || point == null) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    adminIsSaving.value = true;
    try {
      final saved = await widget.api.updateDestination(_id(record), {
        'lat': double.parse(point.latitude.toStringAsFixed(6)),
        'lng': double.parse(point.longitude.toStringAsFixed(6)),
      });
      if (!mounted) return;
      setState(() {
        _moving = false;
        _movedTo = null;
      });
      widget.onPinMoved(saved);
    } catch (error) {
      if (mounted) {
        setState(
          () => _error = error.toString().replaceFirst(
            RegExp(r'^Exception: '),
            '',
          ),
        );
      }
    } finally {
      adminIsSaving.value = false;
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final points = [for (final record in widget.records) ?_point(record)];
    final selected = _selected;
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 900;
        final map = SizedBox(
          height: wide ? 640 : 460,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: Stack(
              children: [
                FlutterMap(
                  mapController: _map,
                  options: MapOptions(
                    initialCameraFit: points.length >= 2
                        ? CameraFit.coordinates(
                            coordinates: points,
                            padding: const EdgeInsets.all(48),
                            maxZoom: 13,
                          )
                        : null,
                    initialCenter: points.isEmpty
                        ? const LatLng(7.0731, 125.6128)
                        : points.first,
                    initialZoom: 8.5,
                    onTap: (_, point) {
                      if (_moving) {
                        setState(() => _movedTo = point);
                      } else if (_dropping) {
                        setState(() {
                          _draft = PlaceDraft.pin(point);
                          _dropping = false;
                          _selectedId = null;
                        });
                      }
                    },
                  ),
                  children: [
                    AdminMapTiles.tileLayer(_style),
                    PolygonLayer(polygons: _regionPolygons(context)),
                    PolylineLayer(polylines: _endpointLines(selected)),
                    MarkerLayer(markers: _endpointMarkers(selected)),
                    MarkerLayer(markers: _destinationMarkers(context)),
                    if (_moving && _movedTo != null)
                      MarkerLayer(
                        markers: [
                          Marker(
                            point: _movedTo!,
                            width: 44,
                            height: 44,
                            alignment: Alignment.topCenter,
                            child: Icon(
                              Icons.location_on_rounded,
                              size: 42,
                              color: Theme.of(context).colorScheme.tertiary,
                            ),
                          ),
                        ],
                      ),
                    if (_draft != null)
                      MarkerLayer(
                        markers: [
                          Marker(
                            key: const ValueKey('new-place-pin'),
                            point: _draft!.point,
                            width: 44,
                            height: 44,
                            alignment: Alignment.topCenter,
                            child: const Icon(
                              Icons.add_location_alt_rounded,
                              size: 42,
                              color: Color(0xFF7B3FC4),
                            ),
                          ),
                        ],
                      ),
                    AdminMapTiles.attribution(),
                  ],
                ),
                if (!_moving && !_dropping)
                  Positioned(
                    top: 10,
                    left: 10,
                    right: AdminMapTiles.usesMapbox ? 230 : 10,
                    child: Align(
                      alignment: Alignment.topLeft,
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 560),
                        child: MapPlaceSearch(
                          api: widget.api,
                          center: () => _map.camera.center,
                          onSelected: _showOsmResult,
                          onDropPin: () => setState(() {
                            _dropping = true;
                            _draft = null;
                            _selectedId = null;
                          }),
                        ),
                      ),
                    ),
                  ),
                if (_dropping)
                  Positioned(
                    top: 10,
                    left: 10,
                    right: AdminMapTiles.usesMapbox ? 230 : 10,
                    child: Material(
                      color: const Color(0xFFEDE3F8),
                      borderRadius: BorderRadius.circular(10),
                      elevation: 2,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 4,
                        ),
                        child: Row(
                          children: [
                            const Expanded(
                              child: Text(
                                'Click the map where the new place is. '
                                'Switch to Satellite to find the exact spot.',
                              ),
                            ),
                            TextButton(
                              onPressed: _clearDraft,
                              child: const Text('Cancel'),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                Positioned(
                  top: 10,
                  right: 10,
                  child: AdminMapStyleSwitch(
                    style: _style,
                    onChanged: (value) => setState(() => _style = value),
                  ),
                ),
                if (_moving)
                  Positioned(
                    top: 10,
                    left: 10,
                    right: 160,
                    child: _MoveBanner(
                      name: _text(selected, 'name'),
                      hasPoint: _movedTo != null,
                    ),
                  ),
              ],
            ),
          ),
        );
        final panel = _draft != null
            ? AddPlacePanel(
                key: ValueKey(
                  'add-place-${_draft!.point.latitude}-${_draft!.point.longitude}',
                ),
                api: widget.api,
                draft: _draft!,
                onCancel: _clearDraft,
                onQueued: (saved) {
                  _clearDraft();
                  widget.onCandidateQueued(saved);
                },
              )
            : _panel(context, selected);
        if (!wide) {
          return Column(children: [map, const SizedBox(height: 16), panel]);
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: map),
            const SizedBox(width: 16),
            SizedBox(width: 340, child: panel),
          ],
        );
      },
    );
  }

  List<Polygon> _regionPolygons(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    return [
      for (final entry in DavaoRegionBoundaries.regionCoordinates.entries)
        for (final ring in entry.value)
          Polygon(
            points: ring,
            color: (DavaoRegionBoundaries.regionColors[entry.key] ?? primary)
                .withValues(alpha: 0.06),
            borderColor:
                (DavaoRegionBoundaries.regionColors[entry.key] ?? primary)
                    .withValues(alpha: 0.45),
            borderStrokeWidth: 1.2,
          ),
    ];
  }

  List<Marker> _destinationMarkers(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return [
      for (final record in widget.records)
        if (_point(record) case final point?)
          Marker(
            key: ValueKey('destination-pin-${_id(record)}'),
            point: point,
            width: _id(record) == _selectedId ? 52 : 38,
            height: _id(record) == _selectedId ? 52 : 38,
            child: Tooltip(
              message: _text(record, 'name'),
              child: GestureDetector(
                onTap: () => _select(record),
                child: _PhotoPin(
                  imageUrl: _imageUrl(record),
                  selected: _id(record) == _selectedId,
                  ringColor: _id(record) == _selectedId
                      ? scheme.tertiary
                      : scheme.primary,
                  dimmed: _moving && _id(record) == _selectedId,
                ),
              ),
            ),
          ),
    ];
  }

  /// Endpoint lines: every route-ready endpoint faintly, the selected one bold.
  List<Polyline> _endpointLines(Map<String, dynamic>? selected) => [
    for (final record in widget.records)
      if ((_point(record), _endpoint(record)) case (final pin?, final end?))
        if (_id(record) == _id(selected) || record['route_ready'] == true)
          Polyline(
            points: [pin, end],
            strokeWidth: _id(record) == _id(selected) ? 3 : 1.5,
            color: _id(record) == _id(selected)
                ? const Color(0xFFD66F29)
                : const Color(0x99D66F29),
            pattern: const StrokePattern.dotted(),
          ),
  ];

  List<Marker> _endpointMarkers(Map<String, dynamic>? selected) => [
    for (final record in widget.records)
      if (_endpoint(record) case final end?)
        if (_id(record) == _id(selected) || record['route_ready'] == true)
          Marker(
            point: end,
            width: 22,
            height: 22,
            child: Tooltip(
              message: 'Route endpoint · ${_text(record, 'name')}',
              child: const DecoratedBox(
                decoration: BoxDecoration(
                  color: Colors.white,
                  shape: BoxShape.circle,
                  boxShadow: [BoxShadow(blurRadius: 3, color: Colors.black26)],
                ),
                child: Icon(
                  Icons.local_parking_rounded,
                  size: 16,
                  color: Color(0xFFD66F29),
                ),
              ),
            ),
          ),
  ];

  Widget _panel(BuildContext context, Map<String, dynamic>? record) {
    final theme = Theme.of(context);
    if (record == null) {
      return AdminPanel(
        child: Text(
          'Click a pin to see the destination, its photo and its route endpoint.',
          style: theme.textTheme.bodyMedium,
        ),
      );
    }
    final pin = _point(record);
    final end = _endpoint(record);
    final gap = pin != null && end != null ? _meters(pin, end) : null;
    final routeReady = record['route_ready'] == true;
    final imageUrl = _imageUrl(record);
    return AdminPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (imageUrl != null)
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: Image.network(
                imageUrl,
                height: 160,
                width: double.infinity,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => const SizedBox.shrink(),
              ),
            ),
          if (imageUrl != null) const SizedBox(height: 12),
          Text(_text(record, 'name'), style: theme.textTheme.titleLarge),
          const SizedBox(height: 4),
          Text(
            [
              _text(record, 'district'),
              _text(record, 'category'),
            ].where((part) => part.isNotEmpty).join(' · '),
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          if (pin != null)
            SelectableText(
              'Pin: ${pin.latitude.toStringAsFixed(6)}, ${pin.longitude.toStringAsFixed(6)}',
              style: theme.textTheme.bodySmall,
            ),
          const SizedBox(height: 8),
          Row(
            children: [
              Icon(
                Icons.local_parking_rounded,
                size: 18,
                color: end == null
                    ? theme.colorScheme.onSurfaceVariant
                    : const Color(0xFFD66F29),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  end == null
                      ? 'No route endpoint: routes go to the pin.'
                      : '${routeReady ? 'Route-ready endpoint' : 'Endpoint stored, not used for routing'}'
                            '${gap == null ? '' : ' · ${_distance(gap)} from the pin'}',
                  style: theme.textTheme.bodySmall,
                ),
              ),
            ],
          ),
          if (gap != null && gap > _endpointWarnMeters) ...[
            const SizedBox(height: 6),
            Text(
              'The endpoint is far from the pin. Check it in the editor, or clear it if the pin moved.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          ],
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(
              _error!,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          ],
          const SizedBox(height: 16),
          if (_moving)
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  onPressed: _movedTo == null || _saving ? null : _saveMove,
                  icon: _saving
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.check),
                  label: Text(_saving ? 'Saving…' : 'Save new pin'),
                ),
                OutlinedButton(
                  onPressed: _saving ? null : _cancelMove,
                  child: const Text('Cancel'),
                ),
                if (_movedTo != null && pin != null)
                  Text(
                    'Moves the pin ${_distance(_meters(pin, _movedTo!))}.',
                    style: theme.textTheme.bodySmall,
                  ),
              ],
            )
          else
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  onPressed: () => widget.onEdit(record),
                  icon: const Icon(Icons.edit_outlined),
                  label: const Text('Edit'),
                ),
                OutlinedButton.icon(
                  onPressed: _startMove,
                  icon: const Icon(Icons.open_with_rounded),
                  label: const Text('Move pin'),
                ),
                ReplacePhotoButton(
                  api: widget.api,
                  destination: record,
                  onUploaded: widget.onPhotoReplaced,
                ),
                TextButton(
                  onPressed: () => widget.onView(record),
                  child: const Text('View details'),
                ),
              ],
            ),
        ],
      ),
    );
  }
}

class _MoveBanner extends StatelessWidget {
  const _MoveBanner({required this.name, required this.hasPoint});

  final String name;
  final bool hasPoint;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.tertiaryContainer,
      borderRadius: BorderRadius.circular(10),
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Text(
          hasPoint
              ? 'New pin for $name placed. Save it in the panel, or click again to adjust.'
              : 'Click the map where $name should be.',
          style: TextStyle(color: scheme.onTertiaryContainer),
        ),
      ),
    );
  }
}

class _PhotoPin extends StatelessWidget {
  const _PhotoPin({
    required this.imageUrl,
    required this.selected,
    required this.ringColor,
    required this.dimmed,
  });

  final String? imageUrl;
  final bool selected;
  final Color ringColor;
  final bool dimmed;

  @override
  Widget build(BuildContext context) {
    final placeholder = ColoredBox(
      color: ringColor.withValues(alpha: 0.18),
      child: Icon(Icons.place_rounded, color: ringColor, size: 18),
    );
    return Opacity(
      opacity: dimmed ? 0.45 : 1,
      child: DecoratedBox(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: ringColor, width: selected ? 3.5 : 2.5),
          boxShadow: const [BoxShadow(blurRadius: 4, color: Colors.black26)],
        ),
        child: ClipOval(
          child: imageUrl == null
              ? placeholder
              : Image.network(
                  imageUrl!,
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) => placeholder,
                ),
        ),
      ),
    );
  }
}

String _id(Map<String, dynamic>? record) =>
    record?['destination_id']?.toString() ?? '';

String _text(Map<String, dynamic>? record, String key) =>
    record?[key]?.toString().trim() ?? '';

double? _num(Object? value) =>
    value is num ? value.toDouble() : double.tryParse(value?.toString() ?? '');

LatLng? _point(Map<String, dynamic> record) {
  final lat = _num(record['lat']), lng = _num(record['lng']);
  return lat == null || lng == null ? null : LatLng(lat, lng);
}

LatLng? _endpoint(Map<String, dynamic> record) {
  final lat = _num(record['arrival_lat']), lng = _num(record['arrival_lng']);
  return lat == null || lng == null ? null : LatLng(lat, lng);
}

String? _imageUrl(Map<String, dynamic> record) {
  final uri = Uri.tryParse(_text(record, 'image_url'));
  if (uri == null || uri.host.isEmpty) return null;
  return uri.scheme == 'https' || uri.scheme == 'http' ? uri.toString() : null;
}

double _meters(LatLng a, LatLng b) {
  double rad(double degrees) => degrees * math.pi / 180;
  final h =
      math.pow(math.sin(rad(b.latitude - a.latitude) / 2), 2) +
      math.cos(rad(a.latitude)) *
          math.cos(rad(b.latitude)) *
          math.pow(math.sin(rad(b.longitude - a.longitude) / 2), 2);
  return 2 * 6371000 * math.asin(math.sqrt(h));
}

String _distance(double meters) => meters >= 1000
    ? '${(meters / 1000).toStringAsFixed(1)} km'
    : '${meters.round()} m';
