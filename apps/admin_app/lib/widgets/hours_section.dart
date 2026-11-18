import 'package:flutter/material.dart';

import '../services/api_service.dart';

const _dayNames = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

/// How a weekday is described. `unset` saves no row: the hours stay unknown,
/// which is different from closed.
enum DayState { unset, open, closed }

class HoursWindow {
  HoursWindow(this.opens, this.closes);
  TimeOfDay opens;
  TimeOfDay closes;
}

TimeOfDay? parseApiTime(Object? value) {
  final parts = value?.toString().split(':');
  if (parts == null || parts.length < 2) return null;
  final hour = int.tryParse(parts[0]);
  final minute = int.tryParse(parts[1]);
  if (hour == null || minute == null) return null;
  return TimeOfDay(hour: hour, minute: minute);
}

String apiTime(TimeOfDay t) =>
    '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}:00';

String _shown(TimeOfDay t) {
  final h = t.hour % 12 == 0 ? 12 : t.hour % 12;
  return '$h:${t.minute.toString().padLeft(2, '0')} ${t.hour < 12 ? 'AM' : 'PM'}';
}

/// Weekly opening hours, date exceptions and where they came from. Saved on
/// its own (one request replaces everything), so the rest of the place form is
/// unaffected. A day left "Not set" stays unknown; it is never saved as closed.
class HoursSection extends StatefulWidget {
  const HoursSection({super.key, required this.api, required this.destinationId});

  final ApiService api;
  final String destinationId;

  @override
  State<HoursSection> createState() => _HoursSectionState();
}

class _HoursSectionState extends State<HoursSection> {
  final _states = List<DayState>.filled(7, DayState.unset);
  final _windows = List.generate(7, (_) => <HoursWindow>[]);
  final _exceptions = <Map<String, dynamic>>[];
  final _source = TextEditingController();
  bool _open24 = false;
  DateTime? _verifiedAt;
  String? _summary;
  String? _quality;
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
    _source.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final data = await widget.api.getDestinationHours(widget.destinationId);
      if (!mounted) return;
      setState(() {
        _apply(data);
        _loading = false;
        _error = null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Could not load hours. $error';
      });
    }
  }

  void _apply(Map<String, dynamic> data) {
    for (var d = 0; d < 7; d++) {
      _states[d] = DayState.unset;
      _windows[d].clear();
    }
    for (final row in (data['weekly'] as List? ?? const [])) {
      final map = Map<String, dynamic>.from(row as Map);
      final day = map['weekday'] as int;
      if (map['is_closed'] == true) {
        _states[day] = DayState.closed;
        continue;
      }
      final opens = parseApiTime(map['opens_at']);
      final closes = parseApiTime(map['closes_at']);
      if (opens == null || closes == null) continue;
      _states[day] = DayState.open;
      _windows[day].add(HoursWindow(opens, closes));
    }
    _exceptions
      ..clear()
      ..addAll(
        (data['exceptions'] as List? ?? const []).map(
          (e) => Map<String, dynamic>.from(e as Map),
        ),
      );
    _open24 = data['open_24_hours'] == true;
    _source.text = data['hours_source_url']?.toString() ?? '';
    _verifiedAt = DateTime.tryParse(data['hours_verified_at']?.toString() ?? '');
    _summary = data['summary']?.toString();
    _quality = data['data_quality']?.toString();
  }

  Map<String, dynamic> _payload() => {
    'open_24_hours': _open24 ? true : null,
    'hours_source_url': _source.text.trim().isEmpty ? null : _source.text.trim(),
    'hours_verified_at': _verifiedAt?.toUtc().toIso8601String(),
    'weekly': _open24
        ? const []
        : [
            for (var d = 0; d < 7; d++)
              if (_states[d] == DayState.closed)
                {'weekday': d, 'is_closed': true}
              else if (_states[d] == DayState.open)
                for (final w in _windows[d])
                  {
                    'weekday': d,
                    'opens_at': apiTime(w.opens),
                    'closes_at': apiTime(w.closes),
                  },
          ],
    'exceptions': _exceptions,
  };

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
      _notice = null;
    });
    try {
      final saved = await widget.api.saveDestinationHours(
        widget.destinationId,
        _payload(),
      );
      if (!mounted) return;
      setState(() {
        _apply(saved);
        _saving = false;
        _notice = 'Hours saved.';
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = 'Could not save hours. $error';
      });
    }
  }

  Future<TimeOfDay?> _pick(TimeOfDay initial) =>
      showTimePicker(context: context, initialTime: initial);

  void _setDay(int day, DayState state) {
    setState(() {
      _states[day] = state;
      if (state == DayState.open && _windows[day].isEmpty) {
        _windows[day].add(
          HoursWindow(const TimeOfDay(hour: 8, minute: 0), const TimeOfDay(hour: 17, minute: 0)),
        );
      }
    });
  }

  void _copyMondayToAll() {
    setState(() {
      for (var d = 1; d < 7; d++) {
        _states[d] = _states[0];
        _windows[d]
          ..clear()
          ..addAll(_windows[0].map((w) => HoursWindow(w.opens, w.closes)));
      }
    });
  }

  Future<void> _addException() async {
    final range = await showDateRangePicker(
      context: context,
      firstDate: DateTime.now().subtract(const Duration(days: 1)),
      lastDate: DateTime.now().add(const Duration(days: 730)),
    );
    if (range == null || !mounted) return;
    final reason = TextEditingController();
    var closed = true;
    var opens = const TimeOfDay(hour: 8, minute: 0);
    var closes = const TimeOfDay(hour: 17, minute: 0);
    final saved = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialog) => AlertDialog(
          title: const Text('Date exception'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('${_date(range.start)} to ${_date(range.end)}'),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Closed on these dates'),
                value: closed,
                onChanged: (v) => setDialog(() => closed = v),
              ),
              if (!closed)
                Wrap(
                  spacing: 8,
                  children: [
                    OutlinedButton(
                      onPressed: () async {
                        final t = await _pick(opens);
                        if (t != null) setDialog(() => opens = t);
                      },
                      child: Text('Opens ${_shown(opens)}'),
                    ),
                    OutlinedButton(
                      onPressed: () async {
                        final t = await _pick(closes);
                        if (t != null) setDialog(() => closes = t);
                      },
                      child: Text('Closes ${_shown(closes)}'),
                    ),
                  ],
                ),
              TextField(
                controller: reason,
                maxLength: 255,
                decoration: const InputDecoration(labelText: 'Reason (optional)'),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('Add'),
            ),
          ],
        ),
      ),
    );
    final text = reason.text.trim();
    reason.dispose();
    if (saved != true || !mounted) return;
    setState(() {
      _exceptions.add({
        'starts_on': _date(range.start),
        'ends_on': _date(range.end),
        'is_closed': closed,
        if (!closed) 'opens_at': apiTime(opens),
        if (!closed) 'closes_at': apiTime(closes),
        if (text.isNotEmpty) 'reason': text,
      });
    });
  }

  String _date(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      key: const ValueKey('hours-section'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Opening hours', style: theme.textTheme.titleLarge),
        const SizedBox(height: 6),
        Text(
          'Hours by day, saved separately from the rest of the form. A day left '
          '"Not set" stays unknown to travelers; it is not treated as closed.',
          style: theme.textTheme.bodyMedium,
        ),
        const SizedBox(height: 16),
        if (_loading)
          const LinearProgressIndicator()
        else ...[
          SwitchListTile(
            key: const ValueKey('hours-24'),
            contentPadding: EdgeInsets.zero,
            title: const Text('Open 24 hours'),
            value: _open24,
            onChanged: (v) => setState(() => _open24 = v),
          ),
          if (!_open24) ...[
            for (var d = 0; d < 7; d++) _dayRow(d),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                key: const ValueKey('hours-copy'),
                onPressed: _copyMondayToAll,
                icon: const Icon(Icons.copy_all_outlined),
                label: const Text('Copy Monday to every day'),
              ),
            ),
          ],
          const SizedBox(height: 8),
          Text('Date exceptions', style: theme.textTheme.titleMedium),
          for (var i = 0; i < _exceptions.length; i++)
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: Text(
                '${_exceptions[i]['starts_on']} to ${_exceptions[i]['ends_on']}: '
                '${_exceptions[i]['is_closed'] == true ? 'closed' : 'open ${_shown(parseApiTime(_exceptions[i]['opens_at'])!)} to ${_shown(parseApiTime(_exceptions[i]['closes_at'])!)}'}',
              ),
              subtitle: _exceptions[i]['reason'] == null
                  ? null
                  : Text('${_exceptions[i]['reason']}'),
              trailing: IconButton(
                tooltip: 'Remove exception',
                icon: const Icon(Icons.close),
                onPressed: () => setState(() => _exceptions.removeAt(i)),
              ),
            ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              key: const ValueKey('hours-add-exception'),
              onPressed: _addException,
              icon: const Icon(Icons.event_busy_outlined),
              label: const Text('Add a date exception'),
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            key: const ValueKey('hours-source'),
            controller: _source,
            decoration: const InputDecoration(
              labelText: 'Where these hours came from (web address)',
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 12,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                _verifiedAt == null
                    ? 'Never verified'
                    : 'Verified ${_date(_verifiedAt!.toLocal())}',
              ),
              OutlinedButton(
                key: const ValueKey('hours-verified-today'),
                onPressed: () => setState(() => _verifiedAt = DateTime.now()),
                child: const Text('Verified today'),
              ),
            ],
          ),
          if (_summary != null) ...[
            const SizedBox(height: 12),
            Text(
              'Travelers see: $_summary'
              '${_quality == null ? '' : ' (${_quality!})'}',
              style: theme.textTheme.bodyMedium,
            ),
          ],
        ],
        if (_error != null) ...[
          const SizedBox(height: 12),
          Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
        ],
        if (_notice != null) ...[const SizedBox(height: 12), Text(_notice!)],
        const SizedBox(height: 16),
        FilledButton.icon(
          key: const ValueKey('hours-save'),
          onPressed: _loading || _saving ? null : _save,
          icon: const Icon(Icons.save_outlined),
          label: Text(_saving ? 'Saving...' : 'Save hours'),
        ),
      ],
    );
  }

  Widget _dayRow(int day) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Wrap(
        spacing: 12,
        runSpacing: 4,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          SizedBox(width: 40, child: Text(_dayNames[day])),
          SegmentedButton<DayState>(
            key: ValueKey('hours-day-$day'),
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: DayState.unset, label: Text('Not set')),
              ButtonSegment(value: DayState.open, label: Text('Open')),
              ButtonSegment(value: DayState.closed, label: Text('Closed')),
            ],
            selected: {_states[day]},
            onSelectionChanged: (s) => _setDay(day, s.first),
          ),
          if (_states[day] == DayState.open)
            for (var i = 0; i < _windows[day].length; i++) ..._windowButtons(day, i),
          if (_states[day] == DayState.open)
            IconButton(
              tooltip: 'Add a second window (for a lunch break)',
              icon: const Icon(Icons.add),
              onPressed: () => setState(
                () => _windows[day].add(
                  HoursWindow(const TimeOfDay(hour: 13, minute: 0), const TimeOfDay(hour: 17, minute: 0)),
                ),
              ),
            ),
        ],
      ),
    );
  }

  List<Widget> _windowButtons(int day, int index) {
    final window = _windows[day][index];
    return [
      OutlinedButton(
        key: ValueKey('hours-open-$day-$index'),
        onPressed: () async {
          final t = await _pick(window.opens);
          if (t != null) setState(() => window.opens = t);
        },
        child: Text(_shown(window.opens)),
      ),
      const Text('to'),
      OutlinedButton(
        key: ValueKey('hours-close-$day-$index'),
        onPressed: () async {
          final t = await _pick(window.closes);
          if (t != null) setState(() => window.closes = t);
        },
        child: Text(_shown(window.closes)),
      ),
      if (_windows[day].length > 1)
        IconButton(
          tooltip: 'Remove this window',
          icon: const Icon(Icons.close),
          onPressed: () => setState(() => _windows[day].removeAt(index)),
        ),
    ];
  }
}
