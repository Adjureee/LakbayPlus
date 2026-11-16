import 'dart:math' as math;

import 'package:flutter/material.dart';
import '../services/api_service.dart';
import '../widgets/admin_map_pin_picker.dart';
import '../widgets/admin_widgets.dart';

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
  final _suitability = <String, bool>{};
  bool _routeReady = false;
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

  @override
  void initState() {
    super.initState();
    final record = widget.destination ?? <String, dynamic>{};
    for (final key in [..._textKeys, ..._arrivalKeys]) {
      final value = record[key]?.toString() ?? '';
      _controllers[key] = TextEditingController(text: value);
    }
    for (final key in destinationSuitability.keys) {
      _suitability[key] = record[key] == true;
    }
    _routeReady = record['route_ready'] == true;
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
    'route_ready': _routeReady,
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
        _ => text.isEmpty ? null : text,
      };
    }
    for (final entry in _suitability.entries) {
      if (widget.destination == null || entry.value != _initial[entry.key]) {
        payload[entry.key] = entry.value;
      }
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
                              _field('category', 'Category', maxLength: 500),
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
                          'Route endpoint',
                          'Where road routes end: the public gate, parking area, trailhead or '
                              'registration point. Leave blank to route to the pin itself.',
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
                                      child: CheckboxListTile(
                                        contentPadding: EdgeInsets.zero,
                                        controlAffinity:
                                            ListTileControlAffinity.leading,
                                        title: Text(entry.value),
                                        value: _suitability[entry.key],
                                        onChanged: (value) {
                                          setState(
                                            () => _suitability[entry.key] =
                                                value ?? false,
                                          );
                                          _changed();
                                        },
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
                          'Image',
                          'Use a publicly accessible image URL. Images are not uploaded from this editor.',
                          [
                            _field(
                              'image_url',
                              'Image URL',
                              maxLength: 2048,
                              validator: _url,
                              helper:
                                  'An http:// or https:// image URL, or leave blank.',
                            ),
                          ],
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
