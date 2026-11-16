import 'package:flutter/material.dart';

import '../services/api_service.dart';

const commuteVehicles = <String, String>{
  'jeepney': 'Jeepney',
  'tricycle': 'Tricycle',
  'habal_habal': 'Habal-habal',
  'van': 'Van',
  'bus': 'Bus',
  'taxi': 'Taxi',
  'ferry': 'Ferry',
  'walk': 'Walk',
  'fee': 'Fee',
};

/// How travelers reach a place by public transport. Admins write the steps (or
/// draft them from the "How to get there" notes), then verify them. Only
/// verified routes are shown to travelers.
class CommuteSection extends StatefulWidget {
  const CommuteSection({
    super.key,
    required this.api,
    required this.destinationId,
  });

  final ApiService api;
  final String destinationId;

  @override
  State<CommuteSection> createState() => _CommuteSectionState();
}

class _CommuteSectionState extends State<CommuteSection> {
  List<Map<String, dynamic>> _routes = const [];
  bool _loading = true;
  bool _drafting = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final routes = await widget.api.getCommuteRoutes(widget.destinationId);
      if (!mounted) return;
      setState(() {
        _routes = routes.whereType<Map<String, dynamic>>().toList();
        _loading = false;
        _error = null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Could not load commute routes. $error';
      });
    }
  }

  Future<void> _edit([Map<String, dynamic>? route, List<String>? unclear]) async {
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => _CommuteRouteDialog(
        api: widget.api,
        destinationId: widget.destinationId,
        route: route,
        unclear: unclear ?? const [],
      ),
    );
    if (saved == true) await _load();
  }

  Future<void> _draft() async {
    setState(() {
      _drafting = true;
      _error = null;
    });
    try {
      final draft = await widget.api.draftCommuteRoutes(widget.destinationId);
      if (!mounted) return;
      final routes = (draft['routes'] as List? ?? const [])
          .whereType<Map<String, dynamic>>()
          .toList();
      final unclear = (draft['unclear'] as List? ?? const [])
          .map((item) => item.toString())
          .toList();
      setState(() => _drafting = false);
      if (routes.isEmpty) {
        setState(
          () => _error = unclear.isEmpty
              ? 'The AI found no commute steps in the notes.'
              : 'No usable steps. ${unclear.join(' ')}',
        );
        return;
      }
      // Open the draft as a new, unsaved, unverified route for review.
      await _edit({...routes.first, 'commute_route_id': null}, unclear);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _drafting = false;
        _error = 'Could not draft steps. $error';
      });
    }
  }

  Future<void> _switchOff(Map<String, dynamic> route) async {
    try {
      await widget.api.deactivateCommuteRoute(route['commute_route_id'] as int);
      await _load();
    } catch (error) {
      if (mounted) setState(() => _error = 'Could not switch it off. $error');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      key: const ValueKey('commute-section'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Commute directions', style: theme.textTheme.titleLarge),
        const SizedBox(height: 6),
        Text(
          'Public-transport steps to reach this place. Travelers only see '
          'routes you mark as verified, so check each step before verifying.',
          style: theme.textTheme.bodyMedium,
        ),
        const SizedBox(height: 16),
        Wrap(
          spacing: 12,
          runSpacing: 8,
          children: [
            FilledButton.icon(
              onPressed: () => _edit(),
              icon: const Icon(Icons.add),
              label: const Text('Add route'),
            ),
            OutlinedButton.icon(
              key: const ValueKey('commute-draft'),
              onPressed: _drafting ? null : _draft,
              icon: _drafting
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.auto_awesome),
              label: const Text('Draft steps from notes'),
            ),
          ],
        ),
        if (_error != null) ...[
          const SizedBox(height: 12),
          Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
        ],
        const SizedBox(height: 16),
        if (_loading)
          const LinearProgressIndicator()
        else if (_routes.isEmpty)
          Text(
            'No commute routes yet.',
            style: theme.textTheme.bodyMedium,
          )
        else
          for (final route in _routes) _routeTile(route),
      ],
    );
  }

  Widget _routeTile(Map<String, dynamic> route) {
    final steps = (route['steps'] as List? ?? const [])
        .whereType<Map<String, dynamic>>()
        .toList();
    final verified = route['is_verified'] == true;
    final active = route['is_active'] != false;
    final chain = steps
        .map((s) => commuteVehicles[s['vehicle']] ?? '${s['vehicle']}')
        .join(' → ');
    final theme = Theme.of(context);
    // Text takes the full width; the two buttons sit on their own line below,
    // so a long place name does not get squeezed into a narrow column.
    return Card(
      key: ValueKey('commute-route-${route['commute_route_id']}'),
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              chain.isEmpty ? 'No steps' : chain,
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 4),
            Text(
              [
                if ((route['start_area'] ?? '').toString().isNotEmpty)
                  'From ${route['start_area']}',
                verified ? 'Verified' : 'Not verified (hidden from travelers)',
                if (!active) 'Switched off',
              ].join(' · '),
              style: theme.textTheme.bodyMedium,
            ),
            Align(
              alignment: Alignment.centerRight,
              child: Wrap(
                children: [
                  IconButton(
                    tooltip: 'Edit',
                    icon: const Icon(Icons.edit_outlined),
                    onPressed: () => _edit(route),
                  ),
                  if (active)
                    IconButton(
                      tooltip: 'Switch off',
                      icon: const Icon(Icons.visibility_off_outlined),
                      onPressed: () => _switchOff(route),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StepDraft {
  _StepDraft(Map<String, dynamic> step)
    : vehicle = (step['vehicle'] ?? 'jeepney').toString(),
      unit = step['charging_unit']?.toString(),
      from = TextEditingController(text: '${step['from_place'] ?? ''}'),
      to = TextEditingController(text: '${step['to_place'] ?? ''}'),
      getOff = TextEditingController(text: '${step['get_off_at'] ?? ''}'),
      minutes = TextEditingController(text: '${step['minutes'] ?? ''}'),
      fare = TextEditingController(
        text: step['fare_php'] == null
            ? ''
            : _trimFare(step['fare_php'].toString()),
      ),
      notes = TextEditingController(text: '${step['notes'] ?? ''}');

  String vehicle;
  String? unit;
  final TextEditingController from, to, getOff, minutes, fare, notes;

  static String _trimFare(String value) => value.contains('.')
      ? value.replaceFirst(RegExp(r'\.?0+$'), '')
      : value;

  void dispose() {
    for (final c in [from, to, getOff, minutes, fare, notes]) {
      c.dispose();
    }
  }

  /// Empty fields stay null: an unknown time or fare is never filled in.
  Map<String, dynamic> toJson() {
    String? text(TextEditingController c) =>
        c.text.trim().isEmpty ? null : c.text.trim();
    final fareText = text(fare);
    return {
      'vehicle': vehicle,
      'from_place': text(from),
      'to_place': text(to),
      'get_off_at': text(getOff),
      'minutes': int.tryParse(minutes.text.trim()),
      'fare_php': fareText,
      'charging_unit': fareText == null ? null : unit,
      'notes': text(notes),
    };
  }
}

class _CommuteRouteDialog extends StatefulWidget {
  const _CommuteRouteDialog({
    required this.api,
    required this.destinationId,
    required this.route,
    required this.unclear,
  });

  final ApiService api;
  final String destinationId;
  final Map<String, dynamic>? route;
  final List<String> unclear;

  @override
  State<_CommuteRouteDialog> createState() => _CommuteRouteDialogState();
}

class _CommuteRouteDialogState extends State<_CommuteRouteDialog> {
  late final TextEditingController _startArea;
  late final TextEditingController _sourceUrl;
  late final List<_StepDraft> _steps;
  late bool _verified;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final route = widget.route ?? const <String, dynamic>{};
    _startArea = TextEditingController(text: '${route['start_area'] ?? ''}');
    _sourceUrl = TextEditingController(text: '${route['source_url'] ?? ''}');
    _verified = route['is_verified'] == true;
    final steps = (route['steps'] as List? ?? const [])
        .whereType<Map<String, dynamic>>();
    _steps = [for (final s in steps) _StepDraft(s)];
    if (_steps.isEmpty) _steps.add(_StepDraft(const {}));
  }

  @override
  void dispose() {
    _startArea.dispose();
    _sourceUrl.dispose();
    for (final step in _steps) {
      step.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    final body = {
      'start_area': _startArea.text.trim().isEmpty
          ? null
          : _startArea.text.trim(),
      'source_url': _sourceUrl.text.trim().isEmpty
          ? null
          : _sourceUrl.text.trim(),
      'is_verified': _verified,
      'is_active': true,
      'steps': [for (final s in _steps) s.toJson()],
    };
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final id = widget.route?['commute_route_id'];
      if (id is int) {
        await widget.api.replaceCommuteRoute(id, body);
      } else {
        await widget.api.createCommuteRoute(widget.destinationId, body);
      }
      if (mounted) Navigator.of(context).pop(true);
    } catch (error) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = 'Could not save. $error';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(
        widget.route?['commute_route_id'] is int
            ? 'Edit commute route'
            : 'New commute route',
      ),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (widget.unclear.isNotEmpty) ...[
                Text(
                  'The AI drafted this from the notes. Check every step. '
                  'It was unsure about:',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                for (final item in widget.unclear) Text('• $item'),
                const SizedBox(height: 12),
              ],
              TextField(
                controller: _startArea,
                decoration: const InputDecoration(
                  labelText: 'Starting from (area)',
                ),
              ),
              TextField(
                controller: _sourceUrl,
                decoration: const InputDecoration(
                  labelText: 'Source link (optional)',
                ),
              ),
              const SizedBox(height: 12),
              for (var i = 0; i < _steps.length; i++) _stepCard(i),
              TextButton.icon(
                onPressed: _steps.length >= 12
                    ? null
                    : () => setState(() => _steps.add(_StepDraft(const {}))),
                icon: const Icon(Icons.add),
                label: const Text('Add step'),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Verified'),
                subtitle: const Text(
                  'Only verified routes are shown to travelers.',
                ),
                value: _verified,
                onChanged: (value) => setState(() => _verified = value),
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
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: Text(_saving ? 'Saving…' : 'Save route'),
        ),
      ],
    );
  }

  Widget _stepCard(int index) {
    final step = _steps[index];
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            Row(
              children: [
                Text('Step ${index + 1}'),
                const SizedBox(width: 12),
                Expanded(
                  child: DropdownButton<String>(
                    isExpanded: true,
                    value: commuteVehicles.containsKey(step.vehicle)
                        ? step.vehicle
                        : 'jeepney',
                    items: [
                      for (final e in commuteVehicles.entries)
                        DropdownMenuItem(value: e.key, child: Text(e.value)),
                    ],
                    onChanged: (v) =>
                        setState(() => step.vehicle = v ?? step.vehicle),
                  ),
                ),
                IconButton(
                  tooltip: 'Remove step',
                  icon: const Icon(Icons.delete_outline),
                  onPressed: _steps.length <= 1
                      ? null
                      : () => setState(() => _steps.removeAt(index).dispose()),
                ),
              ],
            ),
            TextField(
              controller: step.from,
              decoration: const InputDecoration(labelText: 'From'),
            ),
            TextField(
              controller: step.to,
              decoration: const InputDecoration(labelText: 'To'),
            ),
            TextField(
              controller: step.getOff,
              decoration: const InputDecoration(labelText: 'Get off at'),
            ),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: step.minutes,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'Minutes',
                      helperText: 'Blank = unknown',
                      helperMaxLines: 2,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: step.fare,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    decoration: const InputDecoration(
                      labelText: 'Fare (₱)',
                      helperText: 'Blank = unknown',
                      helperMaxLines: 2,
                    ),
                  ),
                ),
              ],
            ),
            DropdownButton<String?>(
              isExpanded: true,
              value: step.unit,
              hint: const Text('Fare is charged…'),
              items: const [
                DropdownMenuItem(value: null, child: Text('Not stated')),
                DropdownMenuItem(value: 'per_person', child: Text('Per person')),
                DropdownMenuItem(value: 'per_trip', child: Text('Per trip')),
              ],
              onChanged: (v) => setState(() => step.unit = v),
            ),
            TextField(
              controller: step.notes,
              decoration: const InputDecoration(labelText: 'Notes'),
            ),
          ],
        ),
      ),
    );
  }
}
