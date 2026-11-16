import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../core/davao_region_boundaries.dart';
import '../core/map_tiles.dart';
import '../core/polyline5.dart';
import '../services/api_service.dart';
import '../widgets/admin_map_pin_picker.dart';
import '../widgets/admin_trail_editor_dialog.dart';
import '../widgets/admin_widgets.dart';

/// Manage RoRo/ferry piers (`sea_ports`) and boat tracks (`sea_links`).
class SeaLinksScreen extends StatefulWidget {
  const SeaLinksScreen({super.key, this.api});

  final ApiService? api;

  @override
  State<SeaLinksScreen> createState() => _SeaLinksScreenState();
}

class _SeaLinksScreenState extends State<SeaLinksScreen>
    with SingleTickerProviderStateMixin {
  late final ApiService _api = widget.api ?? ApiService();
  late final TabController _tabs = TabController(length: 2, vsync: this);
  final _map = MapController();

  AdminMapStyle _style = AdminMapStyle.streets;
  List<Map<String, dynamic>> _ports = const [];
  List<Map<String, dynamic>> _links = const [];
  bool _loading = true;
  bool _saving = false;
  String? _error;

  int? _selectedPortId;
  int? _selectedLinkId;
  bool _movingPort = false;
  LatLng? _movedPortPoint;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  @override
  void dispose() {
    _tabs.dispose();
    _api.close();
    if (_saving) adminIsSaving.value = false;
    super.dispose();
  }

  Future<void> _reload() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final results = await Future.wait([
        _api.getSeaPorts(),
        _api.getSeaLinks(),
      ]);
      if (!mounted) return;
      setState(() {
        _ports = results[0]
            .whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList();
        _links = results[1]
            .whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList();
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error.toString().replaceFirst(RegExp(r'^Exception: '), '');
        _loading = false;
      });
    }
  }

  Map<String, dynamic>? get _selectedPort {
    for (final p in _ports) {
      if ((p['port_id'] as num?)?.toInt() == _selectedPortId) return p;
    }
    return null;
  }

  Future<void> _saveMovedPort() async {
    final port = _selectedPort;
    final pt = _movedPortPoint;
    if (port == null || pt == null) return;
    final portId = (port['port_id'] as num).toInt();
    setState(() => _saving = true);
    adminIsSaving.value = true;
    try {
      await _api.updateSeaPort(portId, {
        'lat': double.parse(pt.latitude.toStringAsFixed(6)),
        'lng': double.parse(pt.longitude.toStringAsFixed(6)),
      });
      if (!mounted) return;
      setState(() {
        _movingPort = false;
        _movedPortPoint = null;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Updated boarding gate for ${port['name']}.')),
      );
      await _reload();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(error.toString())),
        );
      }
    } finally {
      adminIsSaving.value = false;
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _editBoatTrack(Map<String, dynamic> link) async {
    final fromPt = _latLng(link['from_lat'], link['from_lng']);
    final toPt = _latLng(link['to_lat'], link['to_lng']);
    final linkId = (link['link_id'] as num).toInt();
    final res = await showAdminTrailEditorDialog(
      context,
      title: 'Boat track: ${link['from_port_name']} -> ${link['to_port_name']}',
      subtitle:
          'Plot the ferry/barge marine track between piers, or clear to use direct pier-to-pier.',
      initialPolyline: link['geometry_polyline']?.toString(),
      startPin: fromPt,
      endPin: toPt,
      startLabel: link['from_port_name']?.toString() ?? 'Departure pier',
      endLabel: link['to_port_name']?.toString() ?? 'Arrival pier',
      lineColor: const Color(0xFF1D4ED8),
    );
    if (res == null || !mounted) return;
    setState(() => _saving = true);
    adminIsSaving.value = true;
    try {
      await _api.updateSeaLink(linkId, {
        'geometry_polyline': res.isEmpty ? null : res,
      });
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Updated boat crossing track.')),
      );
      await _reload();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(error.toString())),
        );
      }
    } finally {
      adminIsSaving.value = false;
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _openPortDialog([Map<String, dynamic>? existing]) async {
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => _SeaPortDialog(api: _api, port: existing),
    );
    if (saved == true && mounted) {
      await _reload();
    }
  }

  Future<void> _openLinkDialog([Map<String, dynamic>? existing]) async {
    if (_ports.length < 2) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Add at least two piers before creating a boat link.')),
      );
      return;
    }
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => _SeaLinkDialog(api: _api, ports: _ports, link: existing),
    );
    if (saved == true && mounted) {
      await _reload();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AdminPage(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AdminPageHeader(
            title: 'Sea Ports & Trails',
            description:
                'Adjust pier boarding gates and boat crossing polylines used when routes cross between islands.',
            action: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: _loading ? null : _reload,
                  icon: const Icon(Icons.refresh, size: 18),
                  label: const Text('Refresh'),
                ),
                FilledButton.icon(
                  onPressed: _saving ? null : () => _openPortDialog(),
                  icon: const Icon(Icons.add),
                  label: const Text('Add pier'),
                ),
                FilledButton.tonalIcon(
                  onPressed: _saving ? null : () => _openLinkDialog(),
                  icon: const Icon(Icons.directions_boat_outlined),
                  label: const Text('Add boat link'),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          if (_loading)
            const AdminPanel(
              child: Padding(
                padding: EdgeInsets.all(40),
                child: Center(child: CircularProgressIndicator()),
              ),
            )
          else if (_error != null)
            AdminMessage(
              icon: Icons.cloud_off_outlined,
              title: 'Could not load sea ports & links',
              message: _error!,
              isError: true,
              action: OutlinedButton.icon(
                onPressed: _reload,
                icon: const Icon(Icons.refresh),
                label: const Text('Retry'),
              ),
            )
          else
            LayoutBuilder(
              builder: (context, constraints) {
                final wide = constraints.maxWidth >= 940;
                final mapWidget = _buildMap(theme, wide ? 600 : 420);
                final sidePanel = _buildPanel(theme);
                if (!wide) {
                  return Column(
                    children: [
                      mapWidget,
                      const SizedBox(height: 16),
                      sidePanel,
                    ],
                  );
                }
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(flex: 6, child: mapWidget),
                    const SizedBox(width: 16),
                    Expanded(flex: 5, child: sidePanel),
                  ],
                );
              },
            ),
        ],
      ),
    );
  }

  Widget _buildMap(ThemeData theme, double height) {
    final portPts = [
      for (final p in _ports) ?_latLng(p['lat'], p['lng']),
    ];
    final selectedPort = _selectedPort;
    return SizedBox(
      height: height,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Stack(
          children: [
            FlutterMap(
              mapController: _map,
              options: MapOptions(
                initialCameraFit: portPts.length >= 2
                    ? CameraFit.coordinates(
                        coordinates: portPts,
                        padding: const EdgeInsets.all(64),
                        maxZoom: 13,
                      )
                    : null,
                initialCenter: portPts.isEmpty
                    ? const LatLng(7.095, 125.665)
                    : portPts.first,
                initialZoom: 11.5,
                onTap: (_, pt) {
                  if (_movingPort) setState(() => _movedPortPoint = pt);
                },
              ),
              children: [
                AdminMapTiles.tileLayer(_style),
                PolygonLayer(
                  polygons: [
                    for (final entry in DavaoRegionBoundaries.regionCoordinates.entries)
                      for (final ring in entry.value)
                        Polygon(
                          points: ring,
                          color: (DavaoRegionBoundaries.regionColors[entry.key] ??
                                  theme.colorScheme.primary)
                              .withValues(alpha: 0.06),
                          borderColor:
                              (DavaoRegionBoundaries.regionColors[entry.key] ??
                                      theme.colorScheme.primary)
                                  .withValues(alpha: 0.45),
                          borderStrokeWidth: 1.2,
                        ),
                  ],
                ),
                PolylineLayer(polylines: _linkPolylines()),
                MarkerLayer(markers: _portMarkers(theme)),
                if (_movingPort && _movedPortPoint != null)
                  MarkerLayer(
                    markers: [
                      Marker(
                        point: _movedPortPoint!,
                        width: 40,
                        height: 40,
                        child: Icon(
                          Icons.anchor_rounded,
                          size: 32,
                          color: theme.colorScheme.tertiary,
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
            if (_movingPort && selectedPort != null)
              Positioned(
                top: 10,
                left: 10,
                right: 165,
                child: Material(
                  color: theme.colorScheme.tertiaryContainer,
                  borderRadius: BorderRadius.circular(10),
                  elevation: 2,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    child: Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(
                          _movedPortPoint == null
                              ? 'Click map to set new boarding gate for ${selectedPort['name']}.'
                              : 'New gate placed (${_movedPortPoint!.latitude.toStringAsFixed(5)}, ${_movedPortPoint!.longitude.toStringAsFixed(5)}).',
                          style: TextStyle(
                            color: theme.colorScheme.onTertiaryContainer,
                          ),
                        ),
                        FilledButton(
                          onPressed: _movedPortPoint == null || _saving
                              ? null
                              : _saveMovedPort,
                          child: const Text('Save gate'),
                        ),
                        TextButton(
                          onPressed: _saving
                              ? null
                              : () => setState(() {
                                  _movingPort = false;
                                  _movedPortPoint = null;
                                }),
                          child: const Text('Cancel'),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  List<Polyline> _linkPolylines() {
    final lines = <Polyline>[];
    for (final link in _links) {
      final linkId = (link['link_id'] as num?)?.toInt();
      final selected = linkId == _selectedLinkId;
      final poly = link['geometry_polyline']?.toString().trim() ?? '';
      final fromPt = _latLng(link['from_lat'], link['from_lng']);
      final toPt = _latLng(link['to_lat'], link['to_lng']);
      final pts = poly.isNotEmpty
          ? decodePolyline5(poly)
          : (fromPt != null && toPt != null ? [fromPt, toPt] : const <LatLng>[]);
      if (pts.length < 2) continue;
      final active = link['is_active'] == true;
      lines.add(
        Polyline(
          points: pts,
          strokeWidth: selected ? 5 : 3.5,
          color: !active
              ? Colors.grey
              : (poly.isNotEmpty
                    ? const Color(0xFF1D4ED8)
                    : const Color(0xFF0284C7)),
          pattern: poly.isNotEmpty
              ? const StrokePattern.solid()
              : StrokePattern.dashed(segments: const [8, 6]),
        ),
      );
    }
    return lines;
  }

  List<Marker> _portMarkers(ThemeData theme) => [
    for (final port in _ports)
      if (_latLng(port['lat'], port['lng']) case final pt?)
        Marker(
          key: ValueKey('sea-port-${port['port_id']}'),
          point: pt,
          width: (port['port_id'] as num?)?.toInt() == _selectedPortId ? 40 : 32,
          height: (port['port_id'] as num?)?.toInt() == _selectedPortId ? 40 : 32,
          child: Tooltip(
            message: '${port['name']} (${port['island_group']})',
            child: GestureDetector(
              onTap: () {
                if (_movingPort) return;
                setState(() => _selectedPortId = (port['port_id'] as num).toInt());
              },
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: port['is_active'] == true
                      ? const Color(0xFF1D4ED8)
                      : Colors.grey,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: (port['port_id'] as num?)?.toInt() == _selectedPortId
                        ? const Color(0xFFD66F29)
                        : Colors.white,
                    width: 2.5,
                  ),
                  boxShadow: const [BoxShadow(blurRadius: 4, color: Colors.black26)],
                ),
                child: const Icon(
                  Icons.anchor_rounded,
                  size: 16,
                  color: Colors.white,
                ),
              ),
            ),
          ),
        ),
  ];

  Widget _buildPanel(ThemeData theme) => AdminPanel(
    padding: EdgeInsets.zero,
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        TabBar(
          controller: _tabs,
          tabs: [
            Tab(text: 'Piers (${_ports.length})'),
            Tab(text: 'Boat Links (${_links.length})'),
          ],
        ),
        SizedBox(
          height: 540,
          child: TabBarView(
            controller: _tabs,
            children: [
              _portsList(theme),
              _linksList(theme),
            ],
          ),
        ),
      ],
    ),
  );

  Widget _portsList(ThemeData theme) {
    if (_ports.isEmpty) {
      return const Center(child: Text('No piers configured yet.'));
    }
    return ListView.separated(
      padding: const EdgeInsets.all(14),
      itemCount: _ports.length,
      separatorBuilder: (_, _) => const SizedBox(height: 10),
      itemBuilder: (context, index) {
        final p = _ports[index];
        final portId = (p['port_id'] as num).toInt();
        final selected = portId == _selectedPortId;
        final verified = p['verified'] == true;
        final active = p['is_active'] == true;
        return Material(
          color: selected
              ? theme.colorScheme.primaryContainer.withValues(alpha: 0.35)
              : theme.colorScheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(10),
          child: InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: () {
              setState(() => _selectedPortId = portId);
              if (_latLng(p['lat'], p['lng']) case final pt?) {
                _map.move(pt, 14);
              }
            },
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          p['name']?.toString() ?? 'Pier',
                          style: theme.textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      Chip(
                        label: Text(
                          !active
                              ? 'Inactive'
                              : (verified ? 'Verified' : 'Unverified'),
                          style: const TextStyle(fontSize: 11),
                        ),
                        visualDensity: VisualDensity.compact,
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Island: ${p['island_group']} · ${(p['lat'] as num).toStringAsFixed(5)}, ${(p['lng'] as num).toStringAsFixed(5)}',
                    style: theme.textTheme.bodySmall,
                  ),
                  if ((p['notes'] ?? '').toString().trim().isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        p['notes'].toString(),
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    children: [
                      OutlinedButton.icon(
                        onPressed: _saving
                            ? null
                            : () {
                                setState(() {
                                  _selectedPortId = portId;
                                  _movingPort = true;
                                  _movedPortPoint = null;
                                });
                                if (_latLng(p['lat'], p['lng']) case final pt?) {
                                  _map.move(pt, 15.5);
                                }
                              },
                        icon: const Icon(Icons.open_with_rounded, size: 16),
                        label: const Text('Move gate on map'),
                      ),
                      TextButton.icon(
                        onPressed: _saving ? null : () => _openPortDialog(p),
                        icon: const Icon(Icons.edit_outlined, size: 16),
                        label: const Text('Edit pier'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _linksList(ThemeData theme) {
    if (_links.isEmpty) {
      return const Center(child: Text('No boat links configured yet.'));
    }
    return ListView.separated(
      padding: const EdgeInsets.all(14),
      itemCount: _links.length,
      separatorBuilder: (_, _) => const SizedBox(height: 10),
      itemBuilder: (context, index) {
        final link = _links[index];
        final linkId = (link['link_id'] as num).toInt();
        final selected = linkId == _selectedLinkId;
        final poly = link['geometry_polyline']?.toString().trim() ?? '';
        final pts = poly.isEmpty ? const <LatLng>[] : decodePolyline5(poly);
        final verified = link['verified'] == true;
        final active = link['is_active'] == true;
        return Material(
          color: selected
              ? theme.colorScheme.primaryContainer.withValues(alpha: 0.35)
              : theme.colorScheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(10),
          child: InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: () => setState(() => _selectedLinkId = linkId),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          '${link['from_port_name']} ${link['bidirectional'] == true ? '↔' : '→'} ${link['to_port_name']}',
                          style: theme.textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      Chip(
                        label: Text(
                          !active
                              ? 'Inactive'
                              : (verified ? 'Verified' : 'Unverified'),
                          style: const TextStyle(fontSize: 11),
                        ),
                        visualDensity: VisualDensity.compact,
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${link['vessel_type']} · ${link['crossing_minutes']}m crossing + ${link['typical_wait_minutes']}m wait'
                    '${link['allows_private_vehicle'] == true ? ' · Vehicles OK' : ' · Passenger only'}',
                    style: theme.textTheme.bodySmall,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    pts.length >= 2
                        ? 'Custom boat track: ${pts.length} pts · ${formatDistanceMeters(polylineLengthMeters(pts))}'
                        : 'Track: direct pier-to-pier line',
                    style: theme.textTheme.bodySmall,
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    children: [
                      OutlinedButton.icon(
                        onPressed: _saving ? null : () => _editBoatTrack(link),
                        icon: const Icon(Icons.route_outlined, size: 16),
                        label: const Text('Draw boat track'),
                      ),
                      TextButton.icon(
                        onPressed: _saving ? null : () => _openLinkDialog(link),
                        icon: const Icon(Icons.edit_outlined, size: 16),
                        label: const Text('Edit link'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _SeaPortDialog extends StatefulWidget {
  const _SeaPortDialog({required this.api, this.port});

  final ApiService api;
  final Map<String, dynamic>? port;

  @override
  State<_SeaPortDialog> createState() => _SeaPortDialogState();
}

class _SeaPortDialogState extends State<_SeaPortDialog> {
  final _form = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.port?['name']?.toString() ?? '');
  late final _island = TextEditingController(
    text: widget.port?['island_group']?.toString() ?? 'samal',
  );
  late final _province = TextEditingController(
    text: widget.port?['province']?.toString() ?? '',
  );
  late final _lat = TextEditingController(
    text: widget.port?['lat']?.toString() ?? '',
  );
  late final _lng = TextEditingController(
    text: widget.port?['lng']?.toString() ?? '',
  );
  late final _sourceUrl = TextEditingController(
    text: widget.port?['source_url']?.toString() ?? '',
  );
  late final _notes = TextEditingController(
    text: widget.port?['notes']?.toString() ?? '',
  );
  late bool _verified = widget.port?['verified'] == true;
  late bool _isActive = widget.port?['is_active'] != false;
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    for (final c in [_name, _island, _province, _lat, _lng, _sourceUrl, _notes]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _pickOnMap() async {
    final picked = await showAdminMapPinPickerDialog(
      context,
      initialLat: double.tryParse(_lat.text.trim()),
      initialLng: double.tryParse(_lng.text.trim()),
      title: 'Pick sea port boarding gate on map',
    );
    if (picked == null || !mounted) return;
    setState(() {
      _lat.text = picked.latitude.toStringAsFixed(6);
      _lng.text = picked.longitude.toStringAsFixed(6);
    });
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    final payload = <String, dynamic>{
      'name': _name.text.trim(),
      'island_group': _island.text.trim().toLowerCase(),
      'province': _province.text.trim().isEmpty ? null : _province.text.trim(),
      'lat': double.parse(_lat.text.trim()),
      'lng': double.parse(_lng.text.trim()),
      'source_url': _sourceUrl.text.trim().isEmpty ? null : _sourceUrl.text.trim(),
      'notes': _notes.text.trim().isEmpty ? null : _notes.text.trim(),
      'verified': _verified,
      'is_active': _isActive,
    };
    try {
      if (widget.port == null) {
        await widget.api.createSeaPort(payload);
      } else {
        await widget.api.updateSeaPort(
          (widget.port!['port_id'] as num).toInt(),
          payload,
        );
      }
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        setState(
          () => _error = e.toString().replaceFirst(RegExp(r'^Exception: '), ''),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.port == null ? 'Add sea port' : 'Edit sea port'),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Form(
            key: _form,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextFormField(
                  controller: _name,
                  decoration: const InputDecoration(labelText: 'Pier name *'),
                  validator: (v) => (v ?? '').trim().length < 2 ? 'Required' : null,
                ),
                const SizedBox(height: 10),
                TextFormField(
                  controller: _island,
                  decoration: const InputDecoration(
                    labelText: 'Island group *',
                    helperText: 'e.g. mainland, samal, talikud',
                  ),
                  validator: (v) => (v ?? '').trim().length < 2 ? 'Required' : null,
                ),
                const SizedBox(height: 10),
                TextFormField(
                  controller: _province,
                  decoration: const InputDecoration(labelText: 'Province / city'),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: TextFormField(
                        controller: _lat,
                        decoration: const InputDecoration(labelText: 'Gate latitude *'),
                        validator: (v) => double.tryParse((v ?? '').trim()) == null
                            ? 'Invalid number'
                            : null,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: TextFormField(
                        controller: _lng,
                        decoration: const InputDecoration(labelText: 'Gate longitude *'),
                        validator: (v) => double.tryParse((v ?? '').trim()) == null
                            ? 'Invalid number'
                            : null,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerLeft,
                  child: OutlinedButton.icon(
                    onPressed: _saving ? null : _pickOnMap,
                    icon: const Icon(Icons.pin_drop_outlined),
                    label: const Text('Pick gate on map'),
                  ),
                ),
                const SizedBox(height: 10),
                TextFormField(
                  controller: _sourceUrl,
                  decoration: const InputDecoration(labelText: 'Source URL (optional)'),
                ),
                const SizedBox(height: 10),
                TextFormField(
                  controller: _notes,
                  maxLines: 2,
                  decoration: const InputDecoration(labelText: 'Notes'),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Verified gate location'),
                  value: _verified,
                  onChanged: (v) => setState(() => _verified = v),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Active'),
                  value: _isActive,
                  onChanged: (v) => setState(() => _isActive = v),
                ),
                if (_error != null)
                  Text(
                    _error!,
                    style: TextStyle(color: Theme.of(context).colorScheme.error),
                  ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: Text(_saving ? 'Saving…' : 'Save pier'),
        ),
      ],
    );
  }
}

class _SeaLinkDialog extends StatefulWidget {
  const _SeaLinkDialog({required this.api, required this.ports, this.link});

  final ApiService api;
  final List<Map<String, dynamic>> ports;
  final Map<String, dynamic>? link;

  @override
  State<_SeaLinkDialog> createState() => _SeaLinkDialogState();
}

class _SeaLinkDialogState extends State<_SeaLinkDialog> {
  final _form = GlobalKey<FormState>();
  late int _fromPortId =
      (widget.link?['from_port_id'] as num?)?.toInt() ??
      (widget.ports.first['port_id'] as num).toInt();
  late int _toPortId =
      (widget.link?['to_port_id'] as num?)?.toInt() ??
      (widget.ports[1]['port_id'] as num).toInt();
  late String _vessel = widget.link?['vessel_type']?.toString() ?? 'roro_barge';
  late bool _bidirectional = widget.link?['bidirectional'] != false;
  late bool _allowsVehicles = widget.link?['allows_private_vehicle'] == true;
  late final _crossing = TextEditingController(
    text: (widget.link?['crossing_minutes'] ?? 15).toString(),
  );
  late final _wait = TextEditingController(
    text: (widget.link?['typical_wait_minutes'] ?? 20).toString(),
  );
  late final _farePass = TextEditingController(
    text: widget.link?['fare_passenger']?.toString() ?? '',
  );
  late final _fareVeh = TextEditingController(
    text: widget.link?['fare_vehicle']?.toString() ?? '',
  );
  late final _schedule = TextEditingController(
    text: widget.link?['schedule_text']?.toString() ?? '',
  );
  late bool _verified = widget.link?['verified'] == true;
  late bool _isActive = widget.link?['is_active'] != false;
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    for (final c in [_crossing, _wait, _farePass, _fareVeh, _schedule]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    if (_fromPortId == _toPortId) {
      setState(() => _error = 'Choose two different piers.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    final payload = <String, dynamic>{
      'from_port_id': _fromPortId,
      'to_port_id': _toPortId,
      'vessel_type': _vessel,
      'bidirectional': _bidirectional,
      'allows_private_vehicle': _allowsVehicles,
      'crossing_minutes': int.parse(_crossing.text.trim()),
      'typical_wait_minutes': int.parse(_wait.text.trim()),
      'fare_passenger': _farePass.text.trim().isEmpty
          ? null
          : _farePass.text.trim(),
      'fare_vehicle': _fareVeh.text.trim().isEmpty
          ? null
          : _fareVeh.text.trim(),
      'schedule_text': _schedule.text.trim().isEmpty
          ? null
          : _schedule.text.trim(),
      'verified': _verified,
      'is_active': _isActive,
    };
    try {
      if (widget.link == null) {
        await widget.api.createSeaLink(payload);
      } else {
        await widget.api.updateSeaLink(
          (widget.link!['link_id'] as num).toInt(),
          payload,
        );
      }
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        setState(
          () => _error = e.toString().replaceFirst(RegExp(r'^Exception: '), ''),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.link == null ? 'Add boat link' : 'Edit boat link'),
      content: SizedBox(
        width: 500,
        child: SingleChildScrollView(
          child: Form(
            key: _form,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                DropdownButtonFormField<int>(
                  initialValue: _fromPortId,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'From pier'),
                  items: [
                    for (final p in widget.ports)
                      DropdownMenuItem(
                        value: (p['port_id'] as num).toInt(),
                        child: Text(p['name']?.toString() ?? ''),
                      ),
                  ],
                  onChanged: (v) {
                    if (v != null) setState(() => _fromPortId = v);
                  },
                ),
                const SizedBox(height: 10),
                DropdownButtonFormField<int>(
                  initialValue: _toPortId,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'To pier'),
                  items: [
                    for (final p in widget.ports)
                      DropdownMenuItem(
                        value: (p['port_id'] as num).toInt(),
                        child: Text(p['name']?.toString() ?? ''),
                      ),
                  ],
                  onChanged: (v) {
                    if (v != null) setState(() => _toPortId = v);
                  },
                ),
                const SizedBox(height: 10),
                DropdownButtonFormField<String>(
                  initialValue: _vessel,
                  decoration: const InputDecoration(labelText: 'Vessel type'),
                  items: const [
                    DropdownMenuItem(value: 'roro_barge', child: Text('RoRo barge')),
                    DropdownMenuItem(
                      value: 'passenger_ferry',
                      child: Text('Passenger ferry'),
                    ),
                    DropdownMenuItem(value: 'pump_boat', child: Text('Pump boat')),
                  ],
                  onChanged: (v) {
                    if (v != null) setState(() => _vessel = v);
                  },
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: TextFormField(
                        controller: _crossing,
                        decoration: const InputDecoration(
                          labelText: 'Crossing (min) *',
                        ),
                        validator: (v) {
                          final n = int.tryParse((v ?? '').trim());
                          return n == null || n <= 0 ? 'Positive minutes' : null;
                        },
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: TextFormField(
                        controller: _wait,
                        decoration: const InputDecoration(labelText: 'Wait (min) *'),
                        validator: (v) {
                          final n = int.tryParse((v ?? '').trim());
                          return n == null || n < 0 ? '0 or more' : null;
                        },
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: TextFormField(
                        controller: _farePass,
                        decoration: const InputDecoration(
                          labelText: 'Passenger fare (PHP)',
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: TextFormField(
                        controller: _fareVeh,
                        decoration: const InputDecoration(
                          labelText: 'Vehicle fare (PHP)',
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                TextFormField(
                  controller: _schedule,
                  maxLines: 2,
                  decoration: const InputDecoration(labelText: 'Schedule notes'),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Bidirectional service'),
                  value: _bidirectional,
                  onChanged: (v) => setState(() => _bidirectional = v),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Allows private vehicles (driving)'),
                  value: _allowsVehicles,
                  onChanged: (v) => setState(() => _allowsVehicles = v),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Verified schedule & fares'),
                  value: _verified,
                  onChanged: (v) => setState(() => _verified = v),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Active'),
                  value: _isActive,
                  onChanged: (v) => setState(() => _isActive = v),
                ),
                if (_error != null)
                  Text(
                    _error!,
                    style: TextStyle(color: Theme.of(context).colorScheme.error),
                  ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: Text(_saving ? 'Saving…' : 'Save boat link'),
        ),
      ],
    );
  }
}

LatLng? _latLng(Object? latRaw, Object? lngRaw) {
  final lat = latRaw is num ? latRaw.toDouble() : double.tryParse('${latRaw ?? ''}');
  final lng = lngRaw is num ? lngRaw.toDouble() : double.tryParse('${lngRaw ?? ''}');
  return lat == null || lng == null ? null : LatLng(lat, lng);
}
