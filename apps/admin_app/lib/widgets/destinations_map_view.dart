import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/davao_region_boundaries.dart';
import '../core/image_urls.dart';
import '../core/map_tiles.dart';
import '../core/polyline5.dart';
import '../services/api_service.dart';
import 'add_place.dart';
import 'admin_trail_editor_dialog.dart';
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
    this.onRouteAdjusted,
    this.initialSelectedId,
  });

  /// Called with the new review-queue candidate after "Add to review queue".
  final ValueChanged<Map<String, dynamic>> onCandidateQueued;

  /// Called with the saved record after "Replace photo" succeeds.
  final ValueChanged<Map<String, dynamic>> onPhotoReplaced;

  /// Called after endpoint or access-trail coordinates change.
  final ValueChanged<Map<String, dynamic>>? onRouteAdjusted;

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
  // null | 'pin' | 'endpoint' | 'origin'
  String? _moveTarget;
  bool get _moving => _moveTarget != null;

  /// A place being added (search result or dropped pin), and pin-drop mode.
  PlaceDraft? _draft;
  bool _dropping = false;
  LatLng? _movedTo;
  bool _saving = false;
  String? _error;

  String _originPreset = 'panabo';
  LatLng _previewOrigin = const LatLng(7.2990, 125.6740);
  String _previewOriginLabel = 'Panabo';
  String _travelMode = 'driving';
  bool _previewing = false;
  Map<String, dynamic>? _previewResult;
  String? _previewError;

  static const _originPresets = <String, ({String label, LatLng point})>{
    'panabo': (label: 'Panabo', point: LatLng(7.2990, 125.6740)),
    'davao': (label: 'Davao City Hall', point: LatLng(7.0644, 125.6088)),
    'airport': (label: 'Davao Airport', point: LatLng(7.1255, 125.6458)),
    'mati': (label: 'Mati City', point: LatLng(6.9551, 126.2166)),
  };

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
      _previewResult = null;
      _previewError = null;
    });
  }

  void _showOsmResult(Map<String, dynamic> match) {
    final draft = PlaceDraft.fromOsm(match);
    setState(() {
      _draft = draft;
      _dropping = false;
      _selectedId = null;
      _previewResult = null;
      _previewError = null;
    });
    _map.move(draft.point, math.max(_map.camera.zoom, 14));
  }

  void _clearDraft() => setState(() {
    _draft = null;
    _dropping = false;
  });

  void _startMove([String target = 'pin']) => setState(() {
    _moveTarget = target;
    _movedTo = null;
    _error = null;
  });

  void _cancelMove() => setState(() {
    _moveTarget = null;
    _movedTo = null;
  });

  Future<void> _saveMove() async {
    final record = _selected;
    final point = _movedTo;
    final target = _moveTarget;
    if (point == null || target == null) return;
    if (target == 'origin') {
      setState(() {
        _originPreset = 'custom';
        _previewOrigin = point;
        _previewOriginLabel = 'Custom Start';
        _moveTarget = null;
        _movedTo = null;
      });
      await _runPreview();
      return;
    }
    if (record == null) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    adminIsSaving.value = true;
    try {
      final lat = double.parse(point.latitude.toStringAsFixed(6));
      final lng = double.parse(point.longitude.toStringAsFixed(6));
      final Map<String, dynamic> patch;
      if (target == 'endpoint') {
        final routeReady = record['route_ready'] == true;
        final sourceUrl = _text(record, 'arrival_source_url');
        patch = {
          'arrival_lat': lat,
          'arrival_lng': lng,
          if (routeReady && sourceUrl.isNotEmpty) ...{
            'arrival_source_url': sourceUrl,
            'arrival_verified_at': DateTime.now().toUtc().toIso8601String(),
          },
        };
      } else {
        patch = {'lat': lat, 'lng': lng};
      }
      final saved = await widget.api.updateDestination(_id(record), patch);
      if (!mounted) return;
      setState(() {
        _moveTarget = null;
        _movedTo = null;
        _previewResult = null;
      });
      if (target == 'endpoint') {
        (widget.onRouteAdjusted ?? widget.onPinMoved)(saved);
      } else {
        widget.onPinMoved(saved);
      }
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

  Future<void> _editAccessTrail(Map<String, dynamic> record) async {
    final pin = _point(record);
    final end = _endpoint(record);
    final res = await showAdminTrailEditorDialog(
      context,
      title: 'Access road / trail for ${_text(record, 'name')}',
      subtitle:
          'Trace points from the road entrance / endpoint to the destination pin.',
      initialPolyline: _text(record, 'access_trail_polyline'),
      startPin: end,
      endPin: pin,
      startLabel: 'Route endpoint',
      endLabel: _text(record, 'name'),
    );
    if (res == null || !mounted) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    adminIsSaving.value = true;
    try {
      final saved = await widget.api.updateDestination(_id(record), {
        'access_trail_polyline': res.isEmpty ? null : res,
      });
      if (!mounted) return;
      setState(() => _previewResult = null);
      (widget.onRouteAdjusted ?? widget.onPinMoved)(saved);
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

  Future<void> _runPreview() async {
    final record = _selected;
    final destId = int.tryParse(_id(record));
    if (destId == null) return;
    setState(() {
      _previewing = true;
      _previewError = null;
    });
    try {
      final res = await widget.api.previewRoute(
        destinationIds: [destId],
        originLat: _previewOrigin.latitude,
        originLng: _previewOrigin.longitude,
        originLabel: _previewOriginLabel,
        travelMode: _travelMode,
      );
      if (!mounted) return;
      setState(() => _previewResult = res);
      final previewPts = _previewAllPoints(res);
      final fit = [
        _previewOrigin,
        ?_point(record!),
        ...previewPts,
      ];
      if (fit.length >= 2) {
        _map.fitCamera(
          CameraFit.coordinates(
            coordinates: fit,
            padding: const EdgeInsets.all(56),
            maxZoom: 15,
          ),
        );
      }
    } catch (error) {
      if (mounted) {
        setState(
          () => _previewError = error.toString().replaceFirst(
            RegExp(r'^Exception: '),
            '',
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _previewing = false);
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
                    PolylineLayer(polylines: _customTrailPolylines(selected)),
                    PolylineLayer(polylines: _previewPolylines()),
                    MarkerLayer(markers: _endpointMarkers(selected)),
                    MarkerLayer(markers: _destinationMarkers(context)),
                    if (_previewResult != null)
                      MarkerLayer(
                        markers: [
                          Marker(
                            point: _previewOrigin,
                            width: 34,
                            height: 34,
                            child: Tooltip(
                              message: 'Preview Start · $_previewOriginLabel',
                              child: const DecoratedBox(
                                decoration: BoxDecoration(
                                  color: Colors.white,
                                  shape: BoxShape.circle,
                                  boxShadow: [
                                    BoxShadow(blurRadius: 4, color: Colors.black26),
                                  ],
                                ),
                                child: Icon(
                                  Icons.trip_origin_rounded,
                                  size: 20,
                                  color: Color(0xFF20878E),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
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
                      target: _moveTarget!,
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
                  imageUrl: destinationPosterUrl(
                    record,
                    width: 56,
                    height: 56,
                    staticGif: true,
                  ),
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

  List<Polyline> _customTrailPolylines(Map<String, dynamic>? selected) {
    if (selected == null) return const [];
    final encoded = _text(selected, 'access_trail_polyline');
    if (encoded.isEmpty) return const [];
    final pts = decodePolyline5(encoded);
    if (pts.length < 2) return const [];
    return [
      Polyline(
        points: pts,
        strokeWidth: 4,
        color: const Color(0xFF20878E),
      ),
    ];
  }

  List<LatLng> _previewAllPoints(Map<String, dynamic> route) {
    final pts = <LatLng>[];
    final segments = (route['segments'] as List?)?.whereType<Map>() ?? const [];
    for (final seg in segments) {
      final poly = seg['polyline']?.toString() ?? '';
      if (poly.isNotEmpty) pts.addAll(decodePolyline5(poly));
    }
    if (pts.isEmpty) {
      final flat = route['polyline']?.toString() ?? '';
      if (flat.isNotEmpty) pts.addAll(decodePolyline5(flat));
    }
    return pts;
  }

  List<Polyline> _previewPolylines() {
    final route = _previewResult;
    if (route == null) return const [];
    final lines = <Polyline>[];
    final segments = (route['segments'] as List?)?.whereType<Map>() ?? const [];
    for (final seg in segments) {
      final poly = seg['polyline']?.toString() ?? '';
      if (poly.isEmpty) continue;
      final pts = decodePolyline5(poly);
      if (pts.length < 2) continue;
      final isSea = seg['mode'] == 'sea';
      final isEstimated = seg['is_estimated'] == true;
      lines.add(
        Polyline(
          points: pts,
          strokeWidth: isSea ? 3.5 : (isEstimated ? 3.0 : 4.5),
          color: isSea
              ? const Color(0xFF1D4ED8)
              : (isEstimated
                    ? const Color(0xFFD97706)
                    : const Color(0xFF20878E)),
          pattern: isSea
              ? StrokePattern.dashed(segments: const [10, 8])
              : (isEstimated
                    ? StrokePattern.dashed(segments: const [6, 6])
                    : const StrokePattern.solid()),
        ),
      );
    }
    if (lines.isEmpty) {
      final flat = route['polyline']?.toString() ?? '';
      if (flat.isNotEmpty) {
        final pts = decodePolyline5(flat);
        if (pts.length >= 2) {
          lines.add(
            Polyline(
              points: pts,
              strokeWidth: 4.5,
              color: const Color(0xFF20878E),
            ),
          );
        }
      }
    }
    return lines;
  }

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
    final gap = pin != null && end != null ? haversineMeters(pin, end) : null;
    final routeReady = record['route_ready'] == true;
    final islandGroup = _text(record, 'island_group');
    final accessTrail = _text(record, 'access_trail_polyline');
    final accessPts = accessTrail.isEmpty ? const <LatLng>[] : decodePolyline5(accessTrail);
    final imageUrl = destinationPosterUrl(record, width: 360, height: 150);
    final mediaUrl = _text(record, 'media_url');
    final mediaType = _text(record, 'media_type').toLowerCase();
    final mediaBadge = mediaUrl.isEmpty
        ? null
        : mediaType == 'gif'
        ? 'GIF'
        : mediaType == 'video'
        ? 'Video clip'
        : 'Media';
    return AdminPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (imageUrl != null)
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: Image.network(
                imageUrl,
                height: 150,
                width: double.infinity,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => const SizedBox.shrink(),
              ),
            ),
          if (imageUrl != null) const SizedBox(height: 12),
          if (mediaBadge != null) ...[
            Wrap(
              spacing: 8,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                AdminBadge(label: mediaBadge),
                if (Uri.tryParse(mediaUrl)?.hasAuthority == true)
                  TextButton.icon(
                    onPressed: () {
                      final uri = Uri.tryParse(mediaUrl);
                      if (uri != null) {
                        launchUrl(uri, mode: LaunchMode.externalApplication);
                      }
                    },
                    icon: const Icon(Icons.open_in_new, size: 15),
                    label: const Text('Open clip'),
                  ),
              ],
            ),
            const SizedBox(height: 8),
          ],
          Text(_text(record, 'name'), style: theme.textTheme.titleLarge),
          const SizedBox(height: 4),
          Text(
            [
              _text(record, 'district'),
              _text(record, 'category'),
              islandGroup.isEmpty ? 'Mainland' : islandGroup,
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
          const SizedBox(height: 6),
          Row(
            children: [
              Icon(
                Icons.route_outlined,
                size: 18,
                color: accessPts.length >= 2
                    ? const Color(0xFF20878E)
                    : theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  accessPts.length >= 2
                      ? 'Custom access trail: ${accessPts.length} pts · ${_distance(polylineLengthMeters(accessPts))}'
                      : 'No custom access trail',
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
                  label: Text(
                    _saving
                        ? 'Saving…'
                        : switch (_moveTarget) {
                            'endpoint' => 'Save endpoint',
                            'origin' => 'Preview from here',
                            _ => 'Save new pin',
                          },
                  ),
                ),
                OutlinedButton(
                  onPressed: _saving ? null : _cancelMove,
                  child: const Text('Cancel'),
                ),
                if (_movedTo != null && pin != null && _moveTarget == 'pin')
                  Text(
                    'Moves the pin ${_distance(haversineMeters(pin, _movedTo!))}.',
                    style: theme.textTheme.bodySmall,
                  ),
              ],
            )
          else ...[
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
                  onPressed: () => _startMove('pin'),
                  icon: const Icon(Icons.open_with_rounded),
                  label: const Text('Move pin'),
                ),
                OutlinedButton.icon(
                  onPressed: () => _startMove('endpoint'),
                  icon: const Icon(Icons.local_parking_outlined),
                  label: const Text('Set endpoint'),
                ),
                OutlinedButton.icon(
                  onPressed: _saving ? null : () => _editAccessTrail(record),
                  icon: const Icon(Icons.route_outlined),
                  label: const Text('Access trail'),
                ),
                ReplacePhotoButton(
                  api: widget.api,
                  destination: record,
                  onUploaded: widget.onPhotoReplaced,
                ),
                UploadMediaButton(
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
            const Divider(height: 24),
            _previewSection(theme),
          ],
        ],
      ),
    );
  }

  Widget _previewSection(ThemeData theme) {
    final result = _previewResult;
    final warnings = (result?['warnings'] as List?)?.cast<Object?>() ?? const [];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Test road trail preview',
          style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: DropdownButtonFormField<String>(
                key: ValueKey('origin-$_originPreset'),
                initialValue: _originPreset,
                isExpanded: true,
                isDense: true,
                decoration: const InputDecoration(labelText: 'Start from'),
                items: [
                  for (final entry in _originPresets.entries)
                    DropdownMenuItem(
                      value: entry.key,
                      child: Text(entry.value.label),
                    ),
                  if (_originPreset == 'custom')
                    const DropdownMenuItem(
                      value: 'custom',
                      child: Text('Custom map point'),
                    ),
                ],
                onChanged: (value) {
                  if (value == null) return;
                  final preset = _originPresets[value];
                  if (preset != null) {
                    setState(() {
                      _originPreset = value;
                      _previewOrigin = preset.point;
                      _previewOriginLabel = preset.label;
                    });
                  }
                },
              ),
            ),
            const SizedBox(width: 8),
            IconButton(
              tooltip: 'Pick start on map',
              onPressed: () => _startMove('origin'),
              icon: const Icon(Icons.my_location_outlined),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            SegmentedButton<String>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: 'driving', label: Text('Drive')),
                ButtonSegment(value: 'walking', label: Text('Walk')),
              ],
              selected: {_travelMode},
              onSelectionChanged: (v) => setState(() => _travelMode = v.first),
            ),
            FilledButton.tonalIcon(
              onPressed: _previewing ? null : _runPreview,
              icon: _previewing
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.play_arrow_rounded, size: 18),
              label: Text(_previewing ? 'Routing…' : 'Preview trail'),
            ),
            if (result != null)
              TextButton(
                onPressed: () => setState(() => _previewResult = null),
                child: const Text('Clear'),
              ),
          ],
        ),
        if (_previewError != null) ...[
          const SizedBox(height: 8),
          Text(
            _previewError!,
            style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error),
          ),
        ],
        if (result != null) ...[
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${result['total_distance_km'] ?? 0} km · '
                  '${result['total_duration_minutes'] ?? 0} min · '
                  '${result['route_provider'] ?? 'osrm'}'
                  '${result['is_estimated'] == true ? ' (estimated)' : ''}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                for (final w in warnings.take(3))
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      '• ${w.toString()}',
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

class _MoveBanner extends StatelessWidget {
  const _MoveBanner({
    required this.name,
    required this.target,
    required this.hasPoint,
  });

  final String name;
  final String target;
  final bool hasPoint;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final message = switch (target) {
      'endpoint' => hasPoint
          ? 'New road endpoint for $name placed. Save it in the panel, or click again to adjust.'
          : 'Click the map where the road endpoint / gate for $name should be.',
      'origin' => hasPoint
          ? 'Test start point placed. Click "Preview from here" in the panel.'
          : 'Click the map where your test route should start.',
      _ => hasPoint
          ? 'New pin for $name placed. Save it in the panel, or click again to adjust.'
          : 'Click the map where $name should be.',
    };
    return Material(
      color: scheme.tertiaryContainer,
      borderRadius: BorderRadius.circular(10),
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Text(
          message,
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
                  // A pin is at most 52 px: load a pin-sized rendition.
                  cloudinarySized(imageUrl!, width: 56, height: 56),
                  fit: BoxFit.cover,
                  // Non-Cloudinary images are at least decoded small.
                  cacheWidth: 112,
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

String _distance(double meters) => meters >= 1000
    ? '${(meters / 1000).toStringAsFixed(1)} km'
    : '${meters.round()} m';
