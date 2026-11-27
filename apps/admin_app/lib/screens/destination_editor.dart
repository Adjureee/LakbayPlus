import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';
import 'package:url_launcher/url_launcher.dart';
import '../core/image_urls.dart';
import '../core/polyline5.dart';
import '../services/api_service.dart';
import '../widgets/admin_map_pin_picker.dart';
import '../widgets/admin_trail_editor_dialog.dart';
import '../widgets/admin_widgets.dart';
import '../widgets/category_picker_field.dart';
import '../widgets/commute_section.dart';
import '../widgets/activities_section.dart';
import '../widgets/hours_section.dart';
import '../widgets/prices_section.dart';
import '../widgets/destination_photo_upload.dart';

const destinationSuitability = <String, String>{
  'is_kid_friendly': 'Kid friendly',
  'is_wheelchair_accessible': 'Wheelchair accessible',
  'is_pet_friendly': 'Pet friendly',
  'is_elderly_friendly': 'Elderly friendly',
  'family_friendly': 'Family friendly',
  'couple_friendly': 'Couple friendly',
  'group_friendly': 'Group friendly',
};

/// A dedicated destination editor inside the existing admin navigation shell.
class DestinationEditor extends StatefulWidget {
  const DestinationEditor({
    super.key,
    required this.api,
    required this.onSaved,
    required this.onCancel,
    this.destination,
  });

  final ApiService api;
  final Map<String, dynamic>? destination;
  final ValueChanged<Map<String, dynamic>> onSaved;
  final VoidCallback onCancel;

  @override
  State<DestinationEditor> createState() => _DestinationEditorState();
}

class _DestinationEditorState extends State<DestinationEditor> {
  final _form = GlobalKey<FormState>();
  final _controllers = <String, TextEditingController>{};
  // true = yes, false = checked and no, null = not checked yet.
  final _suitability = <String, bool?>{};
  String _status = '';
  String _booking = '';
  bool _routeReady = false;
  late String _islandGroup;
  String? _accessTrailPolyline;
  String _mediaUrl = '';
  String _mediaType = '';
  String _mediaPublicId = '';
  double? _mediaDurationSeconds;
  late Map<String, dynamic> _initial;
  bool _dirty = false;
  bool _saving = false;
  bool _leaving = false;
  String? _error;

  static const _textKeys = [
    'name',
    'description',
    'district',
    'location',
    'category',
    'vibes',
    'activities',
    'lat',
    'lng',
    'estimated_cost',
    'entrance_fee',
    'overnight_fee',
    'operating_hours',
    'best_time_to_visit',
    'best_time_basis',
    'typical_visit_min_minutes',
    'typical_visit_max_minutes',
    'booking_note',
    'parking_note',
    'how_to_get_there',
    'estimated_travel_time',
    'travel_notes',
    'what_to_bring',
    'budget_class',
    'crowd_level',
    'difficulty_level',
    'stay_duration_type',
    'transport_accessibility',
    'image_url',
    'image_credit',
    'image_license',
    'image_source_url',
  ];

  /// Where road routes end (gate, parking, trailhead). Sent separately from
  /// [_textKeys] because the API validates them together.
  static const _arrivalKeys = [
    'arrival_lat',
    'arrival_lng',
    'arrival_source_url',
  ];

  /// Farther than this, the endpoint probably belongs to an old pin.
  static const _arrivalWarnMeters = 2000.0;
  List<Map<String, dynamic>> _categoryFacets = const [];

  @override
  void initState() {
    super.initState();
    widget.api.getDestinationFacets().then((facets) {
      if (!mounted) return;
      final cats = (facets['categories'] as List<dynamic>? ?? const [])
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
      setState(() => _categoryFacets = cats);
    }).catchError((_) {});
    final record = widget.destination ?? <String, dynamic>{};
    for (final key in [..._textKeys, ..._arrivalKeys]) {
      final value = record[key]?.toString() ?? '';
      _controllers[key] = TextEditingController(text: value);
    }
    for (final key in destinationSuitability.keys) {
      _suitability[key] = record[key] is bool ? record[key] as bool : null;
    }
    _status = record['operating_status']?.toString() ?? '';
    _booking = record['booking_requirement']?.toString() ?? '';
    _routeReady = record['route_ready'] == true;
    _islandGroup = record['island_group']?.toString().trim() ?? '';
    final rawTrail = record['access_trail_polyline']?.toString().trim() ?? '';
    _accessTrailPolyline = rawTrail.isEmpty ? null : rawTrail;
    _mediaUrl = record['media_url']?.toString().trim() ?? '';
    _mediaType = record['media_type']?.toString().trim() ?? '';
    _mediaPublicId = record['media_public_id']?.toString().trim() ?? '';
    final rawDur = record['media_duration_seconds'];
    _mediaDurationSeconds = rawDur is num
        ? rawDur.toDouble()
        : double.tryParse(rawDur?.toString() ?? '');
    _initial = _snapshot();
    for (final controller in _controllers.values) {
      controller.addListener(_changed);
    }
  }

  @override
  void dispose() {
    for (final controller in _controllers.values) {
      controller.removeListener(_changed);
      controller.dispose();
    }
    adminHasUnsavedChanges.value = false;
    if (_saving) adminIsSaving.value = false;
    super.dispose();
  }

  Map<String, dynamic> _snapshot() => {
    for (final entry in _controllers.entries)
      entry.key: entry.value.text.trim(),
    ..._suitability,
    'operating_status': _status,
    'booking_requirement': _booking,
    'route_ready': _routeReady,
    'island_group': _islandGroup,
    'access_trail_polyline': _accessTrailPolyline ?? '',
    'media_url': _mediaUrl,
    'media_type': _mediaType,
    'media_public_id': _mediaPublicId,
    'media_duration_seconds': _mediaDurationSeconds,
  };

  void _changed() {
    final current = _snapshot();
    final dirty = current.entries.any(
      (entry) => entry.value != _initial[entry.key],
    );
    adminHasUnsavedChanges.value = dirty;
    if (dirty != _dirty && mounted) setState(() => _dirty = dirty);
  }

  Future<void> _pickCoordinatesOnMap() async {
    final currentLat = double.tryParse(_controllers['lat']!.text.trim());
    final currentLng = double.tryParse(_controllers['lng']!.text.trim());
    final picked = await showAdminMapPinPickerDialog(
      context,
      initialLat: currentLat,
      initialLng: currentLng,
    );
    if (picked == null || !mounted) return;
    _controllers['lat']!.text = picked.latitude.toStringAsFixed(6);
    _controllers['lng']!.text = picked.longitude.toStringAsFixed(6);
  }

  Future<void> _pickArrivalOnMap() async {
    double? read(String key) => double.tryParse(_controllers[key]!.text.trim());
    final picked = await showAdminMapPinPickerDialog(
      context,
      initialLat: read('arrival_lat') ?? read('lat'),
      initialLng: read('arrival_lng') ?? read('lng'),
    );
    if (picked == null || !mounted) return;
    _controllers['arrival_lat']!.text = picked.latitude.toStringAsFixed(6);
    _controllers['arrival_lng']!.text = picked.longitude.toStringAsFixed(6);
  }

  void _clearArrival() {
    for (final key in _arrivalKeys) {
      _controllers[key]!.clear();
    }
    setState(() => _routeReady = false);
    _changed();
  }

  Future<void> _drawAccessTrail() async {
    double? read(String key) => double.tryParse(_controllers[key]!.text.trim());
    final pinLat = read('lat'), pinLng = read('lng');
    final arrLat = read('arrival_lat'), arrLng = read('arrival_lng');
    final res = await showAdminTrailEditorDialog(
      context,
      title: 'Draw access road / last-mile trail',
      subtitle:
          'Trace points from the mapped road gate or entrance to the destination pin.',
      initialPolyline: _accessTrailPolyline,
      startPin: arrLat != null && arrLng != null ? LatLng(arrLat, arrLng) : null,
      endPin: pinLat != null && pinLng != null ? LatLng(pinLat, pinLng) : null,
      startLabel: 'Route endpoint / gate',
      endLabel: _controllers['name']!.text.trim().isEmpty
          ? 'Destination pin'
          : _controllers['name']!.text.trim(),
    );
    if (res == null || !mounted) return;
    setState(() => _accessTrailPolyline = res.isEmpty ? null : res);
    _changed();
  }

  void _clearAccessTrail() {
    if (_accessTrailPolyline == null) return;
    setState(() => _accessTrailPolyline = null);
    _changed();
  }

  void _useTrailStartAsEndpoint() {
    final encoded = _accessTrailPolyline;
    if (encoded == null || encoded.isEmpty) return;
    final pts = decodePolyline5(encoded);
    if (pts.isEmpty) return;
    _controllers['arrival_lat']!.text = pts.first.latitude.toStringAsFixed(6);
    _controllers['arrival_lng']!.text = pts.first.longitude.toStringAsFixed(6);
    _changed();
  }

  Widget _islandGroupField() {
    const known = <String, String>{
      '': 'Mainland (road connected)',
      'samal': 'Samal Island (via sea link)',
      'talikud': 'Talikud Island (via sea link)',
      'kopiat': 'Kopiat Island (via sea link)',
      'sarangani_islands': 'Sarangani Islands (via sea link)',
    };
    final items = <String, String>{
      ...known,
      if (_islandGroup.isNotEmpty && !known.containsKey(_islandGroup))
        _islandGroup: _islandGroup,
    };
    return DropdownButtonFormField<String>(
      key: ValueKey('island-$_islandGroup'),
      initialValue: _islandGroup,
      decoration: const InputDecoration(
        labelText: 'Island group (sea routing)',
        helperText:
            'Controls whether mainland trips cross via a pier and boat connection.',
      ),
      items: [
        for (final entry in items.entries)
          DropdownMenuItem(value: entry.key, child: Text(entry.value)),
      ],
      onChanged: _saving
          ? null
          : (value) {
              if (value == null) return;
              setState(() => _islandGroup = value);
              _changed();
            },
    );
  }

  /// Route-endpoint fields for the request body, or empty when unchanged.
  Map<String, dynamic> _arrivalPayload(Map<String, dynamic> current) {
    final changed = [
      ..._arrivalKeys,
      'route_ready',
    ].any((key) => current[key] != _initial[key]);
    if (widget.destination != null && !changed) return const {};
    final lat = double.tryParse(_controllers['arrival_lat']!.text.trim());
    final lng = double.tryParse(_controllers['arrival_lng']!.text.trim());
    final source = _controllers['arrival_source_url']!.text.trim();
    if (lat == null || lng == null) {
      if (widget.destination == null) return const {};
      return {
        'arrival_lat': null,
        'arrival_lng': null,
        'arrival_source_url': null,
        'arrival_verified_at': null,
        'route_ready': false,
      };
    }
    return {
      'arrival_lat': lat,
      'arrival_lng': lng,
      'arrival_source_url': source.isEmpty ? null : source,
      // Saving a sourced endpoint is the admin's confirmation of it.
      'arrival_verified_at': source.isEmpty
          ? null
          : DateTime.now().toUtc().toIso8601String(),
      'route_ready': _routeReady,
    };
  }

  /// Meters between the destination pin and the route endpoint, if both set.
  double? _arrivalGapMeters() {
    double? read(String key) => double.tryParse(_controllers[key]!.text.trim());
    final lat = read('lat'), lng = read('lng');
    final aLat = read('arrival_lat'), aLng = read('arrival_lng');
    if (lat == null || lng == null || aLat == null || aLng == null) return null;
    double rad(double degrees) => degrees * math.pi / 180;
    final h =
        math.pow(math.sin(rad(aLat - lat) / 2), 2) +
        math.cos(rad(lat)) *
            math.cos(rad(aLat)) *
            math.pow(math.sin(rad(aLng - lng) / 2), 2);
    return 2 * 6371000 * math.asin(math.sqrt(h));
  }

  /// The upload already saved the photo, so it is not an unsaved change.
  void _photoUploaded(Map<String, dynamic> saved) {
    final url = saved['image_url']?.toString() ?? '';
    _controllers['image_url']!.text = url;
    _initial['image_url'] = url;
    _changed();
  }

  /// The upload already saved the media clip on the server, so sync without
  /// flagging unsaved changes.
  void _mediaUploaded(Map<String, dynamic> saved) {
    final url = saved['image_url']?.toString() ?? '';
    final mediaUrl = saved['media_url']?.toString().trim() ?? '';
    final mediaType = saved['media_type']?.toString().trim() ?? '';
    final mediaPublicId = saved['media_public_id']?.toString().trim() ?? '';
    final rawDur = saved['media_duration_seconds'];
    final mediaDuration = rawDur is num
        ? rawDur.toDouble()
        : double.tryParse(rawDur?.toString() ?? '');
    setState(() {
      _controllers['image_url']!.text = url;
      _initial['image_url'] = url;
      _mediaUrl = mediaUrl;
      _mediaType = mediaType;
      _mediaPublicId = mediaPublicId;
      _mediaDurationSeconds = mediaDuration;
      _initial['media_url'] = mediaUrl;
      _initial['media_type'] = mediaType;
      _initial['media_public_id'] = mediaPublicId;
      _initial['media_duration_seconds'] = mediaDuration;
    });
    _changed();
  }

  void _clearMediaClip() {
    setState(() {
      _mediaUrl = '';
      _mediaType = '';
      _mediaPublicId = '';
      _mediaDurationSeconds = null;
    });
    _changed();
  }

  Future<void> _cancel() async {
    if (_saving || _leaving) return;
    _leaving = true;
    final accepted = await confirmAdminNavigation(context);
    _leaving = false;
    if (accepted && mounted) widget.onCancel();
  }

  Future<void> _save() async {
    if (_saving) return;
    if (!_form.currentState!.validate()) {
      setState(() => _error = 'Check the highlighted fields before saving.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    adminIsSaving.value = true;
    final current = _snapshot();
    final payload = <String, dynamic>{};
    for (final key in _textKeys) {
      if (widget.destination != null && current[key] == _initial[key]) continue;
      final text = _controllers[key]!.text.trim();
      payload[key] = switch (key) {
        'lat' || 'lng' => double.parse(text),
        'name' => text,
        'typical_visit_min_minutes' ||
        'typical_visit_max_minutes' => text.isEmpty ? null : int.parse(text),
        _ => text.isEmpty ? null : text,
      };
    }
    for (final entry in _suitability.entries) {
      if (widget.destination == null || entry.value != _initial[entry.key]) {
        payload[entry.key] = entry.value;
      }
    }
    for (final entry in {
      'operating_status': _status,
      'booking_requirement': _booking,
    }.entries) {
      if (widget.destination == null
          ? entry.value.isNotEmpty
          : entry.value != _initial[entry.key]) {
        payload[entry.key] = entry.value.isEmpty ? null : entry.value;
      }
    }
    if (widget.destination == null && _islandGroup.isNotEmpty) {
      payload['island_group'] = _islandGroup;
    } else if (widget.destination != null &&
        current['island_group'] != _initial['island_group']) {
      payload['island_group'] = _islandGroup.isEmpty ? null : _islandGroup;
    }
    if ((widget.destination == null && _accessTrailPolyline != null) ||
        (widget.destination != null &&
            current['access_trail_polyline'] !=
                _initial['access_trail_polyline'])) {
      payload['access_trail_polyline'] = _accessTrailPolyline;
    }
    if (widget.destination != null &&
        (current['media_url'] != _initial['media_url'] ||
            current['media_type'] != _initial['media_type'] ||
            current['media_public_id'] != _initial['media_public_id'] ||
            current['media_duration_seconds'] !=
                _initial['media_duration_seconds'])) {
      payload['media_url'] = _mediaUrl.isEmpty ? null : _mediaUrl;
      payload['media_type'] = _mediaType.isEmpty ? null : _mediaType;
      payload['media_public_id'] = _mediaPublicId.isEmpty
          ? null
          : _mediaPublicId;
      payload['media_duration_seconds'] = _mediaDurationSeconds;
    }
    payload.addAll(_arrivalPayload(current));
    try {
      final saved = widget.destination == null
          ? await widget.api.createDestination(payload)
          : await widget.api.updateDestination(
              widget.destination!['destination_id'].toString(),
              payload,
            );
      if (!mounted) return;
      _initial = current;
      adminHasUnsavedChanges.value = false;
      adminIsSaving.value = false;
      setState(() {
        _dirty = false;
        _saving = false;
      });
      widget.onSaved(saved);
    } catch (error) {
      if (!mounted) return;
      adminIsSaving.value = false;
      setState(() {
        _saving = false;
        _error = error.toString().replaceFirst(RegExp(r'^Exception: '), '');
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final creating = widget.destination == null;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) _cancel();
      },
      child: AdminPage(
        key: PageStorageKey(
          'destination-editor-${widget.destination?['destination_id'] ?? 'new'}',
        ),
        child: Align(
          alignment: Alignment.topLeft,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1040),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextButton.icon(
                  onPressed: _saving ? null : _cancel,
                  icon: const Icon(Icons.arrow_back, size: 18),
                  label: Text(
                    creating ? 'Back to destinations' : 'Back to destination',
                  ),
                ),
                const SizedBox(height: 12),
                AdminPageHeader(
                  title: creating ? 'Add destination' : 'Edit destination',
                  description: creating
                      ? 'Add a place and the information travelers need to plan their visit.'
                      : 'Update ${widget.destination!['name'] ?? 'this destination'} and save your changes.',
                ),
                const SizedBox(height: 24),
                if (_error != null) ...[
                  AdminMessage(
                    icon: Icons.error_outline,
                    title: 'Destination has not been saved',
                    message: _error!,
                    isError: true,
                  ),
                  const SizedBox(height: 16),
                ],
                Form(
                  key: _form,
                  autovalidateMode: AutovalidateMode.onUserInteraction,
                  child: AbsorbPointer(
                    absorbing: _saving,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _section(
                          'Identity & description',
                          'Name is required. Optional information can be left blank.',
                          [
                            _field(
                              'name',
                              'Destination name *',
                              maxLength: 255,
                              validator: _name,
                            ),
                            _pair(
                              _field('district', 'District', maxLength: 255),
                              CategoryPickerField(
                                controller: _controllers['category']!,
                                categoryFacets: _categoryFacets,
                              ),
                            ),
                            _field('description', 'Description', lines: 4),
                            _field(
                              'vibes',
                              'Vibes',
                              maxLength: 500,
                              helper:
                                  'Descriptive travel atmosphere, such as peaceful or adventurous.',
                            ),
                          ],
                        ),
                        _section(
                          'Location & travel',
                          'Enter geographic coordinates in decimal degrees. Both coordinates are required.',
                          [
                            _field(
                              'location',
                              'Location / address',
                              maxLength: 500,
                            ),
                            _pair(
                              _field(
                                'lat',
                                'Latitude *',
                                numeric: true,
                                validator: (value) =>
                                    _coordinate(value, -90, 90, 'latitude'),
                              ),
                              _field(
                                'lng',
                                'Longitude *',
                                numeric: true,
                                validator: (value) =>
                                    _coordinate(value, -180, 180, 'longitude'),
                              ),
                            ),
                            Align(
                              alignment: Alignment.centerLeft,
                              child: OutlinedButton.icon(
                                onPressed: _saving
                                    ? null
                                    : _pickCoordinatesOnMap,
                                icon: const Icon(Icons.pin_drop_outlined),
                                label: const Text(
                                  'Pick pin on Davao Region map',
                                ),
                              ),
                            ),
                            _islandGroupField(),
                            _pair(
                              _field(
                                'operating_hours',
                                'Operating hours',
                                maxLength: 255,
                              ),
                              _field(
                                'estimated_travel_time',
                                'Estimated travel time',
                              ),
                            ),
                            _field('best_time_to_visit', 'Best time to visit'),
                            _field(
                              'best_time_basis',
                              'Why that time (shown with the recommendation)',
                            ),
                            _pair(
                              _choice(
                                'status-field',
                                'Operating status',
                                _status,
                                const {
                                  '': 'Not checked',
                                  'open': 'Open',
                                  'temporarily_closed': 'Temporarily closed',
                                  'permanently_closed': 'Permanently closed',
                                },
                                (v) => _status = v,
                              ),
                              _choice(
                                'booking-field',
                                'Booking',
                                _booking,
                                const {
                                  '': 'Not checked',
                                  'required': 'Required',
                                  'recommended': 'Recommended',
                                  'not_required': 'Not required',
                                },
                                (v) => _booking = v,
                              ),
                            ),
                            _field('booking_note', 'How to book', lines: 2),
                            _field('parking_note', 'Parking', lines: 2),
                            _pair(
                              _field(
                                'typical_visit_min_minutes',
                                'Typical visit, shortest (minutes)',
                                numeric: true,
                                validator: _wholeMinutes,
                              ),
                              _field(
                                'typical_visit_max_minutes',
                                'Typical visit, longest (minutes)',
                                numeric: true,
                                validator: _wholeMinutes,
                              ),
                            ),
                            _field(
                              'how_to_get_there',
                              'How to get there',
                              lines: 3,
                            ),
                            _field(
                              'transport_accessibility',
                              'Transport accessibility',
                              maxLength: 100,
                            ),
                            _field('travel_notes', 'Travel notes', lines: 3),
                            _field('what_to_bring', 'What to bring', lines: 3),
                          ],
                        ),
                        _section(
                          'Route endpoint & access trail',
                          'Where road routes end (gate, parking, trailhead) and optional '
                              'last-mile road/trail path to off-road pins.',
                          _arrivalFields(),
                        ),
                        _section(
                          'Activities & traveler suitability',
                          'Describe activities as text. These are not separately priced activity records.',
                          [
                            _field(
                              'activities',
                              'Activities',
                              lines: 3,
                              helper:
                                  'For example: Hiking, photography, and guided walks.',
                            ),
                            LayoutBuilder(
                              builder: (context, constraints) => Wrap(
                                spacing: 16,
                                runSpacing: 8,
                                children: [
                                  for (final entry
                                      in destinationSuitability.entries)
                                    SizedBox(
                                      width: constraints.maxWidth >= 640
                                          ? (constraints.maxWidth - 16) / 2
                                          : constraints.maxWidth,
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(entry.value),
                                          const SizedBox(height: 4),
                                          SegmentedButton<String>(
                                            key: ValueKey(
                                              'suitability-${entry.key}',
                                            ),
                                            showSelectedIcon: false,
                                            emptySelectionAllowed: false,
                                            segments: const [
                                              ButtonSegment(
                                                value: 'unknown',
                                                label: Text('Not checked'),
                                              ),
                                              ButtonSegment(
                                                value: 'yes',
                                                label: Text('Yes'),
                                              ),
                                              ButtonSegment(
                                                value: 'no',
                                                label: Text('No'),
                                              ),
                                            ],
                                            selected: {
                                              switch (_suitability[entry.key]) {
                                                true => 'yes',
                                                false => 'no',
                                                null => 'unknown',
                                              },
                                            },
                                            onSelectionChanged: (picked) {
                                              setState(
                                                () => _suitability[entry.key] =
                                                    switch (picked.first) {
                                                      'yes' => true,
                                                      'no' => false,
                                                      _ => null,
                                                    },
                                              );
                                              _changed();
                                            },
                                          ),
                                        ],
                                      ),
                                    ),
                                ],
                              ),
                            ),
                            _pair(
                              _field(
                                'difficulty_level',
                                'Difficulty level',
                                maxLength: 50,
                              ),
                              _field(
                                'crowd_level',
                                'Crowd level',
                                maxLength: 50,
                              ),
                            ),
                            _field(
                              'stay_duration_type',
                              'Stay duration type',
                              maxLength: 50,
                            ),
                          ],
                        ),
                        _section(
                          'Estimated fees',
                          'Keep estimates separate from the accommodation and transport prices in Market Rates.',
                          [
                            _pair(
                              _field(
                                'estimated_cost',
                                'Estimated cost (PHP)',
                                numeric: true,
                                validator: _cost,
                                helper:
                                    'Leave blank if unknown. Enter 0 only for a known zero cost.',
                              ),
                              _field(
                                'budget_class',
                                'Budget class',
                                maxLength: 50,
                              ),
                            ),
                            _pair(
                              _field(
                                'entrance_fee',
                                'Entrance fee',
                                maxLength: 255,
                                helper:
                                    'Descriptive fee with a unit, such as PHP 150 / person.',
                              ),
                              _field(
                                'overnight_fee',
                                'Overnight fee',
                                maxLength: 255,
                                helper:
                                    'Descriptive fee, such as PHP 2,500 / night.',
                              ),
                            ),
                          ],
                        ),
                        _section(
                          'Photos & media',
                          'Upload a static poster photo (JPEG, PNG or WebP, up to 5 MB), or add an animated GIF (<= 10 MB) or short video clip (MP4/WebM, <= 15 MB, <= 15s). '
                              'Uploads save immediately; new destinations can add media after their first save.',
                          [
                            _field(
                              'image_url',
                              'Poster / primary image URL',
                              maxLength: 2048,
                              validator: _url,
                              helper:
                                  'An http:// or https:// poster image URL, or leave blank.',
                            ),
                            _pair(
                              _field(
                                'image_credit',
                                'Photo / media credit',
                                maxLength: 500,
                              ),
                              _field(
                                'image_license',
                                'License',
                                maxLength: 100,
                                helper: 'For example: CC-BY-4.0 or LGU Permission.',
                              ),
                            ),
                            _field(
                              'image_source_url',
                              'Attribution source URL',
                              maxLength: 2048,
                              validator: _url,
                              helper:
                                  'An http:// or https:// source link for the image or clip.',
                            ),
                            if (!creating) ...[
                              if (_mediaUrl.isNotEmpty)
                                _mediaClipStatusCard(context),
                              Wrap(
                                spacing: 12,
                                runSpacing: 12,
                                crossAxisAlignment: WrapCrossAlignment.center,
                                children: [
                                  ReplacePhotoButton(
                                    api: widget.api,
                                    destination: widget.destination!,
                                    onUploaded: _photoUploaded,
                                  ),
                                  UploadMediaButton(
                                    api: widget.api,
                                    destination: widget.destination!,
                                    onUploaded: _mediaUploaded,
                                  ),
                                ],
                              ),
                            ],
                          ],
                        ),
                        if (!creating)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 24),
                            child: AdminPanel(
                              child: HoursSection(
                                api: widget.api,
                                destinationId: widget
                                    .destination!['destination_id']
                                    .toString(),
                              ),
                            ),
                          ),
                        if (!creating)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 24),
                            child: AdminPanel(
                              child: PricesSection(
                                api: widget.api,
                                destinationId: widget
                                    .destination!['destination_id']
                                    .toString(),
                              ),
                            ),
                          ),
                        if (!creating)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 24),
                            child: AdminPanel(
                              child: ActivitiesSection(
                                api: widget.api,
                                destinationId: widget
                                    .destination!['destination_id']
                                    .toString(),
                              ),
                            ),
                          ),
                        if (!creating)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 24),
                            child: AdminPanel(
                              child: CommuteSection(
                                api: widget.api,
                                destinationId: widget
                                    .destination!['destination_id']
                                    .toString(),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                if (_error != null) ...[
                  Semantics(
                    liveRegion: true,
                    child: Text(
                      _error!,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                ],
                AdminPanel(
                  child: Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      FilledButton.icon(
                        onPressed: _saving || (!creating && !_dirty)
                            ? null
                            : _save,
                        icon: _saving
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.check),
                        label: Text(_saving ? 'Saving…' : 'Save destination'),
                      ),
                      OutlinedButton(
                        onPressed: _saving ? null : _cancel,
                        child: const Text('Cancel'),
                      ),
                      Text(
                        _saving
                            ? 'Saving destination…'
                            : _dirty
                            ? 'Unsaved changes'
                            : creating
                            ? 'Complete the required fields to save.'
                            : 'No unsaved changes',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _mediaClipStatusCard(BuildContext context) {
    final theme = Theme.of(context);
    final isVideo = _mediaType == 'video';
    final isGif = _mediaType == 'gif';
    final badgeLabel = isVideo
        ? (_mediaDurationSeconds != null
              ? 'Video (${_mediaDurationSeconds!.toStringAsFixed(1)}s)'
              : 'Video')
        : (isGif ? 'GIF' : 'Image');
    final previewUrl = isGif
        ? cloudinarySized(
            _mediaUrl,
            width: 320,
            height: 160,
            preserveAnimation: true,
          )
        : destinationPosterUrl(
            {
              'image_url': _controllers['image_url']!.text.trim(),
              'media_url': _mediaUrl,
              'media_type': _mediaType,
            },
            width: 320,
            height: 160,
          );
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: theme.dividerColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              AdminBadge(label: badgeLabel),
              Text(
                'Attached media clip',
                style: theme.textTheme.titleSmall,
              ),
            ],
          ),
          const SizedBox(height: 10),
          if (previewUrl != null) ...[
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Image.network(
                previewUrl,
                height: 140,
                width: double.infinity,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => const SizedBox.shrink(),
              ),
            ),
            const SizedBox(height: 10),
          ],
          SelectableText(
            _mediaUrl,
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              TextButton.icon(
                onPressed: () {
                  final uri = Uri.tryParse(_mediaUrl);
                  if (uri != null) {
                    launchUrl(uri, mode: LaunchMode.externalApplication);
                  }
                },
                icon: const Icon(Icons.open_in_new, size: 16),
                label: const Text('Open clip'),
              ),
              TextButton.icon(
                onPressed: _saving ? null : _clearMediaClip,
                icon: const Icon(Icons.delete_outline, size: 16),
                label: const Text('Remove clip'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  List<Widget> _arrivalFields() {
    final verifiedAt = DateTime.tryParse(
      widget.destination?['arrival_verified_at']?.toString() ?? '',
    );
    final confirmed = verifiedAt == null
        ? ''
        : 'Last confirmed ${verifiedAt.toLocal().toString().substring(0, 16)}. ';
    return [
      _pair(
        _field(
          'arrival_lat',
          'Endpoint latitude',
          numeric: true,
          validator: (value) => _arrivalCoordinate(value, -90, 90, 'latitude'),
        ),
        _field(
          'arrival_lng',
          'Endpoint longitude',
          numeric: true,
          validator: (value) =>
              _arrivalCoordinate(value, -180, 180, 'longitude'),
        ),
      ),
      Wrap(
        spacing: 12,
        runSpacing: 8,
        children: [
          OutlinedButton.icon(
            onPressed: _saving ? null : _pickArrivalOnMap,
            icon: const Icon(Icons.local_parking_outlined),
            label: const Text('Pick endpoint on map'),
          ),
          TextButton.icon(
            onPressed: _saving ? null : _clearArrival,
            icon: const Icon(Icons.backspace_outlined),
            label: const Text('Clear endpoint'),
          ),
        ],
      ),
      ListenableBuilder(
        listenable: Listenable.merge([
          for (final key in ['lat', 'lng', 'arrival_lat', 'arrival_lng'])
            _controllers[key]!,
        ]),
        builder: (context, _) {
          final gap = _arrivalGapMeters();
          if (gap == null) return const SizedBox.shrink();
          final far = gap > _arrivalWarnMeters;
          final distance = gap >= 1000
              ? '${(gap / 1000).toStringAsFixed(1)} km'
              : '${gap.round()} m';
          final scheme = Theme.of(context).colorScheme;
          return Row(
            children: [
              Icon(
                far ? Icons.warning_amber_rounded : Icons.straighten,
                size: 18,
                color: far ? scheme.error : scheme.onSurfaceVariant,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  far
                      ? 'Endpoint is $distance from the pin. Check it still belongs '
                            'to this place, or clear it if the pin moved.'
                      : 'Endpoint is $distance from the pin.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: far ? scheme.error : null,
                  ),
                ),
              ),
            ],
          );
        },
      ),
      _field(
        'arrival_source_url',
        'Source link',
        maxLength: 2048,
        validator: _sourceUrl,
        helper:
            "Where this point comes from, such as an OpenStreetMap node or the operator's directions page.",
      ),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('Route-ready'),
        subtitle: Text(
          'Routes end at this endpoint instead of the pin. Needs coordinates '
          'and a source link. ${confirmed}Saving confirms it again.',
        ),
        value: _routeReady,
        onChanged: (value) {
          setState(() => _routeReady = value);
          _changed();
          _form.currentState?.validate();
        },
      ),
      const Divider(height: 24),
      Text(
        _accessTrailPolyline == null
            ? 'No custom last-mile access trail (uses OSRM road route or direct connector to pin).'
            : () {
                final pts = decodePolyline5(_accessTrailPolyline!);
                return 'Custom access trail: ${pts.length} waypoints · ${formatDistanceMeters(polylineLengthMeters(pts))}';
              }(),
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
          fontWeight: _accessTrailPolyline == null
              ? FontWeight.normal
              : FontWeight.w600,
        ),
      ),
      Wrap(
        spacing: 12,
        runSpacing: 8,
        children: [
          OutlinedButton.icon(
            onPressed: _saving ? null : _drawAccessTrail,
            icon: const Icon(Icons.route_outlined),
            label: Text(
              _accessTrailPolyline == null
                  ? 'Draw access trail on map'
                  : 'Edit access trail',
            ),
          ),
          if (_accessTrailPolyline != null)
            TextButton.icon(
              onPressed: _saving ? null : _useTrailStartAsEndpoint,
              icon: const Icon(Icons.my_location_outlined),
              label: const Text('Use trail start as endpoint'),
            ),
          if (_accessTrailPolyline != null)
            TextButton.icon(
              onPressed: _saving ? null : _clearAccessTrail,
              icon: const Icon(Icons.clear),
              label: const Text('Clear trail'),
            ),
        ],
      ),
    ];
  }

  String? _arrivalCoordinate(
    String? value,
    double minimum,
    double maximum,
    String label,
  ) {
    final text = value?.trim() ?? '';
    final otherKey = label == 'latitude' ? 'arrival_lng' : 'arrival_lat';
    final otherEmpty = _controllers[otherKey]!.text.trim().isEmpty;
    if (text.isEmpty) {
      if (!otherEmpty) return 'Enter both endpoint coordinates, or neither.';
      if (_routeReady) return 'Route-ready needs an endpoint.';
      return null;
    }
    return _coordinate(text, minimum, maximum, label);
  }

  String? _sourceUrl(String? value) {
    final text = value?.trim() ?? '';
    if (text.isEmpty) {
      return _routeReady ? 'Route-ready needs a source link.' : null;
    }
    final uri = Uri.tryParse(text);
    if (uri == null ||
        !uri.hasAuthority ||
        uri.host.isEmpty ||
        !['http', 'https'].contains(uri.scheme)) {
      return 'Enter a complete http:// or https:// link.';
    }
    return null;
  }

  Widget _section(String title, String description, List<Widget> children) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 24),
        child: AdminPanel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 6),
              Text(description, style: Theme.of(context).textTheme.bodyMedium),
              const SizedBox(height: 20),
              for (final child in children) ...[
                child,
                const SizedBox(height: 16),
              ],
            ],
          ),
        ),
      );

  Widget _pair(Widget first, Widget second) => LayoutBuilder(
    builder: (context, constraints) {
      if (constraints.maxWidth < 640) {
        return Column(children: [first, const SizedBox(height: 16), second]);
      }
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(child: first),
          const SizedBox(width: 16),
          Expanded(child: second),
        ],
      );
    },
  );

  Widget _field(
    String key,
    String label, {
    int? maxLength,
    int lines = 1,
    bool numeric = false,
    String? helper,
    FormFieldValidator<String>? validator,
  }) => TextFormField(
    controller: _controllers[key],
    maxLines: lines,
    keyboardType: numeric
        ? const TextInputType.numberWithOptions(decimal: true, signed: true)
        : lines > 1
        ? TextInputType.multiline
        : TextInputType.text,
    decoration: InputDecoration(
      labelText: label,
      helperText: helper,
      helperMaxLines: 3,
      errorMaxLines: 3,
    ),
    validator: (value) {
      if (maxLength != null && (value?.trim().length ?? 0) > maxLength) {
        return 'Use at most $maxLength characters.';
      }
      return validator?.call(value);
    },
  );

  /// Empty means unknown; otherwise a whole number of minutes from 1 to 1440.
  String? _wholeMinutes(String? value) {
    final text = value?.trim() ?? '';
    if (text.isEmpty) return null;
    final minutes = int.tryParse(text);
    return minutes == null || minutes < 1 || minutes > 1440
        ? 'Enter whole minutes from 1 to 1440, or leave empty.'
        : null;
  }

  /// A dropdown whose empty choice means "not checked" (saved as null).
  Widget _choice(
    String id,
    String label,
    String value,
    Map<String, String> options,
    void Function(String) assign,
  ) => DropdownButtonFormField<String>(
    key: ValueKey('$id-$value'),
    initialValue: value,
    decoration: InputDecoration(labelText: label),
    items: [
      for (final entry in options.entries)
        DropdownMenuItem(value: entry.key, child: Text(entry.value)),
    ],
    onChanged: _saving
        ? null
        : (picked) {
            if (picked == null) return;
            setState(() => assign(picked));
            _changed();
          },
  );

  String? _name(String? value) => (value?.trim().length ?? 0) < 2
      ? 'Enter a name with at least two characters.'
      : null;

  String? _coordinate(
    String? value,
    double minimum,
    double maximum,
    String label,
  ) {
    final number = double.tryParse(value?.trim() ?? '');
    if (number == null || !number.isFinite) return 'Enter a valid $label.';
    if (number < minimum || number > maximum) {
      return 'Use a value between $minimum and $maximum.';
    }
    return null;
  }

  String? _cost(String? value) {
    final text = value?.trim() ?? '';
    if (text.isNotEmpty && !RegExp(r'^\d{1,8}(\.\d{1,2})?$').hasMatch(text)) {
      return 'Enter 0 to 99,999,999.99 with at most two decimal places.';
    }
    return null;
  }

  String? _url(String? value) {
    final text = value?.trim() ?? '';
    if (text.isEmpty) return null;
    final uri = Uri.tryParse(text);
    if (uri == null ||
        !uri.hasAuthority ||
        uri.host.isEmpty ||
        !['http', 'https'].contains(uri.scheme)) {
      return 'Enter a complete http:// or https:// image URL.';
    }
    return null;
  }
}
