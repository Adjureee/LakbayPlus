import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/api_service.dart';
import 'admin_widgets.dart';

/// A place about to be added to the review queue: an OpenStreetMap search
/// result, or a pin the admin dropped on the map.
class PlaceDraft {
  PlaceDraft.fromOsm(Map<String, dynamic> match)
    : osm = match,
      point = LatLng(
        (match['lat'] as num).toDouble(),
        (match['lng'] as num).toDouble(),
      ),
      name = match['name']?.toString() ?? '';

  PlaceDraft.pin(this.point) : osm = null, name = '';

  /// The OSM search result, or null for a dropped pin.
  final Map<String, dynamic>? osm;
  final LatLng point;
  final String name;

  bool get isOsm => osm != null;
}

/// Search box over the admin map: OpenStreetMap places by name around the
/// current map center.
class MapPlaceSearch extends StatefulWidget {
  const MapPlaceSearch({
    super.key,
    required this.api,
    required this.center,
    required this.onSelected,
    required this.onDropPin,
  });

  final ApiService api;

  /// Search around this point (the map center).
  final LatLng Function() center;
  final ValueChanged<Map<String, dynamic>> onSelected;
  final VoidCallback onDropPin;

  @override
  State<MapPlaceSearch> createState() => _MapPlaceSearchState();
}

class _MapPlaceSearchState extends State<MapPlaceSearch> {
  final _query = TextEditingController();
  List<Map<String, dynamic>>? _results;
  bool _searching = false;
  String? _error;

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final name = _query.text.trim();
    if (name.length < 2) {
      setState(() => _error = 'Type at least two letters.');
      return;
    }
    final center = widget.center();
    setState(() {
      _searching = true;
      _error = null;
    });
    try {
      final rows = await widget.api.searchOsmPlaces(
        name: name,
        lat: center.latitude,
        lng: center.longitude,
      );
      if (!mounted) return;
      setState(
        () => _results = rows
            .whereType<Map>()
            .map((row) => Map<String, dynamic>.from(row))
            .toList(),
      );
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  void _clear() => setState(() {
    _results = null;
    _error = null;
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surface.withValues(alpha: 0.97),
      borderRadius: BorderRadius.circular(10),
      elevation: 3,
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _query,
                    textInputAction: TextInputAction.search,
                    onSubmitted: (_) => _search(),
                    decoration: InputDecoration(
                      isDense: true,
                      hintText: 'Find a place to add (OpenStreetMap)',
                      prefixIcon: const Icon(Icons.search, size: 20),
                      suffixIcon: _searching
                          ? const Padding(
                              padding: EdgeInsets.all(12),
                              child: SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              ),
                            )
                          : _results == null
                          ? null
                          : IconButton(
                              tooltip: 'Clear results',
                              icon: const Icon(Icons.close, size: 18),
                              onPressed: _clear,
                            ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Tooltip(
                  message: 'Drop a pin for a place not in OpenStreetMap',
                  child: OutlinedButton.icon(
                    onPressed: widget.onDropPin,
                    icon: const Icon(Icons.add_location_alt_outlined),
                    label: const Text('Add a place'),
                  ),
                ),
              ],
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  _error!,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                ),
              ),
            if (_results != null)
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 260),
                child: _results!.isEmpty
                    ? Padding(
                        padding: const EdgeInsets.all(10),
                        child: Text(
                          'No OpenStreetMap place with that name within 30 km of the map center. '
                          'Move the map closer, or use Add a place to drop a pin.',
                          style: theme.textTheme.bodySmall,
                        ),
                      )
                    : ListView(
                        shrinkWrap: true,
                        children: [
                          for (final row in _results!)
                            ListTile(
                              dense: true,
                              leading: const Icon(Icons.place_outlined),
                              title: Text(row['name']?.toString() ?? ''),
                              subtitle: Text(_status(row)),
                              onTap: () {
                                _clear();
                                widget.onSelected(row);
                              },
                            ),
                        ],
                      ),
              ),
          ],
        ),
      ),
    );
  }

  static String _status(Map<String, dynamic> row) {
    final category = row['category']?.toString() ?? 'Place';
    if (row['existing_destination_id'] != null) {
      return '$category · already a destination';
    }
    if (row['existing_candidate_id'] != null) {
      return '$category · already in review (${row['existing_candidate_status']})';
    }
    return category;
  }
}

/// Side panel for a [PlaceDraft]: name, nearby places, and "Add to review
/// queue".
class AddPlacePanel extends StatefulWidget {
  const AddPlacePanel({
    super.key,
    required this.api,
    required this.draft,
    required this.onCancel,
    required this.onQueued,
  });

  final ApiService api;
  final PlaceDraft draft;
  final VoidCallback onCancel;
  final ValueChanged<Map<String, dynamic>> onQueued;

  @override
  State<AddPlacePanel> createState() => _AddPlacePanelState();
}

class _AddPlacePanelState extends State<AddPlacePanel> {
  late final _name = TextEditingController(text: widget.draft.name);
  final _category = TextEditingController();
  final _notes = TextEditingController();
  late Future<Map<String, dynamic>> _nearby = _loadNearby();
  bool _saving = false;
  String? _error;

  /// Pins closer than this to an existing place are probably duplicates.
  static const _duplicateMeters = 150.0;

  Future<Map<String, dynamic>> _loadNearby() => widget.api.nearbyPlaces(
    lat: widget.draft.point.latitude,
    lng: widget.draft.point.longitude,
  );

  @override
  void didUpdateWidget(covariant AddPlacePanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.draft != widget.draft) {
      _name.text = widget.draft.name;
      _nearby = _loadNearby();
      _error = null;
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _category.dispose();
    _notes.dispose();
    super.dispose();
  }

  bool get _alreadyKnown =>
      widget.draft.osm?['existing_destination_id'] != null ||
      widget.draft.osm?['existing_candidate_id'] != null;

  Future<void> _queue() async {
    final name = _name.text.trim();
    if (name.length < 2) {
      setState(() => _error = 'Enter the place name.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    adminIsSaving.value = true;
    try {
      final osm = widget.draft.osm;
      final point = widget.draft.point;
      final category = _category.text.trim();
      final notes = _notes.text.trim();
      final saved = osm != null
          ? await widget.api.stageOsmCandidate({
              'osm_type': osm['osm_type'],
              'osm_id': osm['osm_id'],
              'osm_url': osm['osm_url'],
              'source_area': 'Admin map search',
              'source_tag': osm['source_tag'] ?? 'name',
              'name': name,
              'lat': point.latitude,
              'lng': point.longitude,
              'suggested_category': category.isNotEmpty
                  ? category
                  : osm['category'],
            })
          : await widget.api.stageManualCandidate({
              'name': name,
              'lat': double.parse(point.latitude.toStringAsFixed(6)),
              'lng': double.parse(point.longitude.toStringAsFixed(6)),
              if (category.isNotEmpty) 'suggested_category': category,
              if (notes.isNotEmpty) 'review_notes': notes,
            });
      if (mounted) widget.onQueued(saved);
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      adminIsSaving.value = false;
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final draft = widget.draft;
    final osm = draft.osm;
    return AdminPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('New place', style: theme.textTheme.titleLarge),
          const SizedBox(height: 4),
          Text(
            osm != null
                ? 'From OpenStreetMap${osm['category'] != null ? ' · ${osm['category']}' : ''}'
                : 'Pin dropped on the map (not in OpenStreetMap)',
            style: theme.textTheme.bodySmall,
          ),
          if (osm != null)
            TextButton.icon(
              style: TextButton.styleFrom(padding: EdgeInsets.zero),
              onPressed: () => launchUrl(
                Uri.parse(osm['osm_url'].toString()),
                mode: LaunchMode.externalApplication,
              ),
              icon: const Icon(Icons.open_in_new, size: 16),
              label: const Text('Open in OpenStreetMap'),
            ),
          const SizedBox(height: 8),
          SelectableText(
            '${draft.point.latitude.toStringAsFixed(6)}, ${draft.point.longitude.toStringAsFixed(6)}',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _name,
            decoration: const InputDecoration(labelText: 'Place name *'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _category,
            decoration: InputDecoration(
              labelText: 'Category',
              hintText: osm?['category']?.toString() ?? 'e.g. Waterfall',
            ),
          ),
          if (osm == null) ...[
            const SizedBox(height: 12),
            TextField(
              controller: _notes,
              maxLines: 2,
              decoration: const InputDecoration(
                labelText: 'Note for the reviewer',
                hintText: 'How you found it, what to check',
              ),
            ),
          ],
          const SizedBox(height: 12),
          if (_alreadyKnown)
            Text(
              osm!['existing_destination_id'] != null
                  ? 'This OpenStreetMap place is already destination #${osm['existing_destination_id']}.'
                  : 'This OpenStreetMap place is already in the review queue (${osm['existing_candidate_status']}).',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          FutureBuilder<Map<String, dynamic>>(
            future: _nearby,
            builder: (context, snapshot) {
              if (snapshot.connectionState != ConnectionState.done) {
                return Text(
                  'Checking for places nearby…',
                  style: theme.textTheme.bodySmall,
                );
              }
              if (snapshot.hasError) {
                return Text(
                  'Could not check for nearby places.',
                  style: theme.textTheme.bodySmall,
                );
              }
              final places = (snapshot.data?['places'] as List? ?? const [])
                  .whereType<Map>()
                  .toList();
              if (places.isEmpty) {
                return Text(
                  'No destinations or queued places within 500 m.',
                  style: theme.textTheme.bodySmall,
                );
              }
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Already within 500 m. Check this isn\'t a duplicate:',
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  for (final place in places.take(5))
                    Text(
                      '• ${place['name']} (${place['kind'] == 'destination' ? 'destination' : 'in review'}, '
                      '${(place['distance_m'] as num).round()} m)',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: (place['distance_m'] as num) <= _duplicateMeters
                            ? theme.colorScheme.error
                            : null,
                      ),
                    ),
                ],
              );
            },
          ),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(
              _error!,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          ],
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.icon(
                onPressed: _saving || _alreadyKnown ? null : _queue,
                icon: _saving
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.playlist_add),
                label: Text(_saving ? 'Adding…' : 'Add to review queue'),
              ),
              OutlinedButton(
                onPressed: _saving ? null : widget.onCancel,
                child: const Text('Cancel'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
