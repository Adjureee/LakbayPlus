import 'package:flutter/material.dart';

import '../services/api_service.dart';
import 'hours_section.dart' show apiTime, parseApiTime;

const activityAvailability = <String, String>{
  'always': 'Available during opening hours',
  'scheduled': 'Runs on a schedule',
  'seasonal': 'Seasonal',
  'by_arrangement': 'By arrangement',
};
const activityEffort = <String, String>{
  'easy': 'Easy',
  'moderate': 'Moderate',
  'challenging': 'Challenging',
};
const activityWeather = <String, String>{
  'none': 'Not weather dependent',
  'dry_weather': 'Needs dry weather',
  'calm_seas': 'Needs calm seas',
  'daylight': 'Daylight only',
};

/// One activity being edited. A field left empty is saved as null (unknown).
class ActivityRow {
  ActivityRow({Map<String, dynamic> data = const {}})
    : availability = data['availability']?.toString(),
      effort = data['effort_level']?.toString(),
      weather = data['weather_dependency']?.toString(),
      feeIncluded = data['fee_included_in_admission'] as bool?,
      lastAdmission = parseApiTime(data['last_admission_at']),
      verifiedAt = DateTime.tryParse(data['verified_at']?.toString() ?? ''),
      summary = data['summary']?.toString(),
      quality = data['data_quality']?.toString() {
    for (final key in textKeys) {
      controllers[key] = TextEditingController(
        text: data[key] == null ? '' : _plain(data[key]),
      );
    }
  }

  static const textKeys = [
    'name',
    'description',
    'schedule_note',
    'duration_min_minutes',
    'duration_max_minutes',
    'extra_fee',
    'min_age',
    'max_age',
    'restriction_note',
    'accessibility_note',
    'best_time_note',
    'best_time_basis',
    'source_url',
  ];

  final controllers = <String, TextEditingController>{};
  String? availability;
  String? effort;
  String? weather;
  bool? feeIncluded;
  TimeOfDay? lastAdmission;
  DateTime? verifiedAt;
  String? summary;
  String? quality;

  /// "500.00" shows as 500 so the field matches how an admin typed it.
  static String _plain(Object value) {
    final parsed = num.tryParse(value.toString());
    if (parsed == null) return value.toString();
    return parsed == parsed.roundToDouble()
        ? parsed.toInt().toString()
        : parsed.toString();
  }

  void dispose() {
    for (final controller in controllers.values) {
      controller.dispose();
    }
  }

  String _text(String key) => controllers[key]!.text.trim();

  /// The API row, or an error message when a number field is not a number.
  (Map<String, dynamic>?, String?) toJson() {
    final name = _text('name');
    if (name.length < 2) return (null, 'Every activity needs a name.');
    final numbers = <String, Object?>{};
    for (final key in const [
      'duration_min_minutes',
      'duration_max_minutes',
      'min_age',
      'max_age',
    ]) {
      final raw = _text(key);
      if (raw.isEmpty) continue;
      final value = int.tryParse(raw);
      if (value == null) return (null, '"$name": $key must be a whole number.');
      numbers[key] = value;
    }
    final fee = _text('extra_fee').replaceAll(',', '');
    if (fee.isNotEmpty && num.tryParse(fee) == null) {
      return (null, '"$name": the extra fee must be a number.');
    }
    String? optional(String key) => _text(key).isEmpty ? null : _text(key);
    return (
      {
        'name': name,
        'description': optional('description'),
        'availability': availability,
        'schedule_note': optional('schedule_note'),
        'last_admission_at': lastAdmission == null
            ? null
            : apiTime(lastAdmission!),
        ...numbers,
        'extra_fee': fee.isEmpty ? null : fee,
        'fee_included_in_admission': feeIncluded,
        'effort_level': effort,
        'accessibility_note': optional('accessibility_note'),
        'restriction_note': optional('restriction_note'),
        'weather_dependency': weather,
        'best_time_note': optional('best_time_note'),
        'best_time_basis': optional('best_time_basis'),
        'source_url': optional('source_url'),
        'verified_at': verifiedAt?.toUtc().toIso8601String(),
      },
      null,
    );
  }
}

/// What to do at a place, each activity with its own availability, fee,
/// duration and limits. Saved on its own (one request replaces the list). A
/// field left empty stays unknown to travelers; it is never read as "no" or
/// "free", and an activity without availability is shown as not confirmed.
class ActivitiesSection extends StatefulWidget {
  const ActivitiesSection({
    super.key,
    required this.api,
    required this.destinationId,
  });

  final ApiService api;
  final String destinationId;

  @override
  State<ActivitiesSection> createState() => _ActivitiesSectionState();
}

class _ActivitiesSectionState extends State<ActivitiesSection> {
  final _rows = <ActivityRow>[];
  bool _loading = true;
  bool _saving = false;
  String? _error;
  String? _notice;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final row in _rows) {
      row.dispose();
    }
    super.dispose();
  }

  void _replaceRows(List<ActivityRow> rows) {
    for (final row in _rows) {
      row.dispose();
    }
    _rows
      ..clear()
      ..addAll(rows);
  }

  List<ActivityRow> _fromResponse(Map<String, dynamic> data) => [
    for (final raw in (data['activities'] as List? ?? const []))
      ActivityRow(data: Map<String, dynamic>.from(raw as Map)),
  ];

  Future<void> _load() async {
    try {
      final data = await widget.api.getDestinationActivities(
        widget.destinationId,
      );
      if (!mounted) return;
      setState(() {
        _replaceRows(_fromResponse(data));
        _loading = false;
        _error = null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Could not load activities. $error';
      });
    }
  }

  Future<void> _save() async {
    final payload = <Map<String, dynamic>>[];
    for (final row in _rows) {
      final (json, problem) = row.toJson();
      if (json == null) {
        setState(() => _error = problem);
        return;
      }
      payload.add(json);
    }
    setState(() {
      _saving = true;
      _error = null;
      _notice = null;
    });
    try {
      final saved = await widget.api.saveDestinationActivities(
        widget.destinationId,
        {'activities': payload},
      );
      if (!mounted) return;
      setState(() {
        _replaceRows(_fromResponse(saved));
        _saving = false;
        _notice = 'Activities saved.';
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = 'Could not save activities. $error';
      });
    }
  }

  String _date(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      key: const ValueKey('activities-section'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Activities', style: theme.textTheme.titleLarge),
        const SizedBox(height: 6),
        Text(
          'Things to do here, saved separately from the rest of the form. A place '
          'being open does not mean every activity is available, so give each '
          'one its own availability. Anything left empty stays unknown.',
          style: theme.textTheme.bodyMedium,
        ),
        const SizedBox(height: 16),
        if (_loading)
          const LinearProgressIndicator()
        else ...[
          if (_rows.isEmpty)
            Text('No activities entered yet.', style: theme.textTheme.bodyMedium),
          for (var i = 0; i < _rows.length; i++) _card(i),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              key: const ValueKey('activities-add'),
              onPressed: () => setState(() => _rows.add(ActivityRow())),
              icon: const Icon(Icons.add),
              label: const Text('Add an activity'),
            ),
          ),
        ],
        if (_error != null) ...[
          const SizedBox(height: 12),
          Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
        ],
        if (_notice != null) ...[const SizedBox(height: 12), Text(_notice!)],
        const SizedBox(height: 16),
        FilledButton.icon(
          key: const ValueKey('activities-save'),
          onPressed: _loading || _saving ? null : _save,
          icon: const Icon(Icons.save_outlined),
          label: Text(_saving ? 'Saving...' : 'Save activities'),
        ),
      ],
    );
  }

  Widget _card(int index) {
    final row = _rows[index];
    final title = row.controllers['name']!.text.trim();
    return Card(
      key: ValueKey('activity-card-$index'),
      margin: const EdgeInsets.only(bottom: 8),
      child: ExpansionTile(
        initiallyExpanded: row.controllers['name']!.text.isEmpty,
        title: Text(title.isEmpty ? 'New activity' : title),
        subtitle: row.summary == null
            ? null
            : Text('Travelers see: ${row.summary} (${row.quality ?? 'estimated'})'),
        childrenPadding: const EdgeInsets.all(12),
        children: [
          Wrap(
            spacing: 12,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              _field(row, 'name', 'Name *', 220, key: ValueKey('activity-name-$index')),
              _dropdown(
                'Availability',
                row.availability,
                activityAvailability,
                (v) => setState(() => row.availability = v),
                ValueKey('activity-availability-$index'),
              ),
              _field(row, 'schedule_note', 'Schedule or season', 220),
              OutlinedButton(
                onPressed: () async {
                  final t = await showTimePicker(
                    context: context,
                    initialTime:
                        row.lastAdmission ?? const TimeOfDay(hour: 15, minute: 0),
                  );
                  if (t != null) setState(() => row.lastAdmission = t);
                },
                child: Text(
                  row.lastAdmission == null
                      ? 'Last admission: not set'
                      : 'Last admission ${row.lastAdmission!.format(context)}',
                ),
              ),
              if (row.lastAdmission != null)
                IconButton(
                  tooltip: 'Clear last admission',
                  icon: const Icon(Icons.close),
                  onPressed: () => setState(() => row.lastAdmission = null),
                ),
              _field(row, 'duration_min_minutes', 'Minutes (from)', 110, number: true),
              _field(row, 'duration_max_minutes', 'Minutes (to)', 110, number: true),
              _field(row, 'extra_fee', 'Extra fee (PHP)', 130, number: true),
              _dropdown(
                'Fee in admission?',
                row.feeIncluded == null ? null : (row.feeIncluded! ? 'yes' : 'no'),
                const {'yes': 'Included in admission', 'no': 'Not included'},
                (v) => setState(() => row.feeIncluded = v == 'yes'),
                ValueKey('activity-fee-included-$index'),
              ),
              _dropdown(
                'Effort',
                row.effort,
                activityEffort,
                (v) => setState(() => row.effort = v),
                ValueKey('activity-effort-$index'),
              ),
              _dropdown(
                'Weather',
                row.weather,
                activityWeather,
                (v) => setState(() => row.weather = v),
                ValueKey('activity-weather-$index'),
              ),
              _field(row, 'min_age', 'Min age', 90, number: true),
              _field(row, 'max_age', 'Max age', 90, number: true),
              _field(row, 'description', 'Description', 460),
              _field(row, 'restriction_note', 'Restrictions (health, gear)', 460),
              _field(row, 'accessibility_note', 'Accessibility', 460),
              _field(row, 'best_time_note', 'Best time', 220),
              _field(row, 'best_time_basis', 'Why that time', 220),
              _field(row, 'source_url', 'Source (web address)', 460),
              Text(
                row.verifiedAt == null
                    ? 'Never verified'
                    : 'Verified ${_date(row.verifiedAt!.toLocal())}',
              ),
              OutlinedButton(
                key: ValueKey('activity-verified-$index'),
                onPressed: () => setState(() => row.verifiedAt = DateTime.now()),
                child: const Text('Verified today'),
              ),
              TextButton.icon(
                key: ValueKey('activity-remove-$index'),
                onPressed: () => setState(() => _rows.removeAt(index).dispose()),
                icon: const Icon(Icons.delete_outline),
                label: const Text('Remove activity'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _field(
    ActivityRow row,
    String name,
    String label,
    double width, {
    bool number = false,
    Key? key,
  }) => SizedBox(
    width: width,
    child: TextField(
      key: key,
      controller: row.controllers[name],
      keyboardType: number
          ? const TextInputType.numberWithOptions(decimal: true)
          : TextInputType.text,
      decoration: InputDecoration(labelText: label),
      // The card title follows the name as it is typed.
      onChanged: name == 'name' ? (_) => setState(() {}) : null,
    ),
  );

  /// A choice with no selection means "not set": the value saves as null.
  Widget _dropdown(
    String label,
    String? value,
    Map<String, String> options,
    ValueChanged<String> onChanged,
    Key key,
  ) => SizedBox(
    width: 200,
    child: DropdownButtonFormField<String>(
      key: key,
      initialValue: value,
      isExpanded: true,
      decoration: InputDecoration(labelText: label, hintText: 'Not set'),
      items: [
        for (final entry in options.entries)
          DropdownMenuItem(value: entry.key, child: Text(entry.value)),
      ],
      onChanged: (v) {
        if (v != null) onChanged(v);
      },
    ),
  );
}
