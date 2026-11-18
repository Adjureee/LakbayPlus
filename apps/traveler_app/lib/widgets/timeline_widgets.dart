import 'package:flutter/material.dart';

import '../models/timeline_models.dart';
import '../models/travel_models.dart';
import '../services/travel_repository.dart';
import '../theme/lakbay_theme.dart';

/// How far to trust a time, in the traveler's words.
const _basisLabels = <String, String>{
  'confirmed': 'Confirmed',
  'estimated': 'Estimated',
  'provisional': 'Provisional',
  'unknown': 'Unknown',
};

const _checkTitles = <String, String>{
  'chronological_order': 'Order of the day',
  'selected_places': 'Your places',
  'travel_date': 'Travel date',
  'geographic_scope': 'Inside the Davao Region',
  'operating_status': 'Open at all',
  'opening_hours': 'Opening hours',
  'travel_times': 'Travel times',
  'visit_durations': 'Visit lengths',
  'return_deadline': 'Return deadline',
  'activity_suitability': 'Suitable for children',
  'budget_arithmetic': 'Costs add up',
};

const _choiceLabels = <String, String>{
  'prioritise_places': 'Choose which places to keep',
  'change_time_window': 'Change the time window',
  'relax_another_constraint': 'Change another limit',
};

String _peso(double amount) {
  final whole = amount == amount.roundToDouble();
  final text = whole ? amount.toStringAsFixed(0) : amount.toStringAsFixed(2);
  final parts = text.split('.');
  final grouped = parts[0].replaceAllMapped(
    RegExp(r'\B(?=(\d{3})+(?!\d))'),
    (_) => ',',
  );
  return '₱${parts.length > 1 ? '$grouped.${parts[1]}' : grouped}';
}

IconData _kindIcon(String kind) => switch (kind) {
  'visit' => Icons.place_outlined,
  'travel' => Icons.directions_car_outlined,
  'meal' => Icons.restaurant_outlined,
  'rest' => Icons.self_improvement_outlined,
  'buffer' => Icons.hourglass_empty_rounded,
  'depart' => Icons.flag_outlined,
  'return' => Icons.home_outlined,
  _ => Icons.circle_outlined,
};

Color _statusColor(String status) => switch (status) {
  'passed' => LakbayColors.successGreen,
  'failed' => const Color(0xFFB3261E),
  _ => LakbayColors.cocoaOrange,
};

IconData _statusIcon(String status) => switch (status) {
  'passed' => Icons.check_circle_outline_rounded,
  'failed' => Icons.error_outline_rounded,
  _ => Icons.help_outline_rounded,
};

String _statusText(String status) => switch (status) {
  'passed' => 'Passed',
  'failed' => 'Failed',
  _ => "Can't verify",
};

/// The compact itinerary card in the chat: status, check counts and costs, with the
/// actions to open the full timeline, revise it, or open the trip.
class TimelineCard extends StatelessWidget {
  const TimelineCard({
    super.key,
    required this.timeline,
    required this.repo,
    this.trip,
    this.onOpenTrip,
  });

  final TimelineData timeline;
  final TravelRepository repo;
  final ItineraryTrip? trip;
  final VoidCallback? onOpenTrip;

  @override
  Widget build(BuildContext context) {
    final places = timeline.places.length;
    final budget = timeline.budget;
    final status = timeline.feasible ? 'passed' : 'failed';
    return Container(
      key: const ValueKey('timeline-card'),
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: LakbayColors.canvasBg,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: LakbayColors.cardBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.event_note_outlined, color: LakbayColors.primary),
              const SizedBox(width: 8),
              const Expanded(
                child: Text(
                  'Your itinerary',
                  style: TextStyle(
                    fontFamily: 'FigGrotesk',
                    fontWeight: FontWeight.w700,
                    fontSize: 15,
                    color: LakbayColors.tealDeep,
                  ),
                ),
              ),
              Chip(
                key: const ValueKey('timeline-status'),
                visualDensity: VisualDensity.compact,
                avatar: Icon(_statusIcon(status), size: 16, color: _statusColor(status)),
                label: Text(timeline.feasible ? 'Works' : 'Has problems'),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            '${timeline.days.length} ${timeline.days.length == 1 ? 'day' : 'days'} · '
            '$places ${places == 1 ? 'place' : 'places'}',
            style: const TextStyle(color: LakbayColors.textSecondary),
          ),
          const SizedBox(height: 10),
          Wrap(
            key: const ValueKey('timeline-check-counts'),
            spacing: 8,
            runSpacing: 4,
            children: [
              for (final s in const ['passed', 'failed', 'cannot_verify'])
                if (timeline.count(s) > 0)
                  Chip(
                    visualDensity: VisualDensity.compact,
                    avatar: Icon(_statusIcon(s), size: 15, color: _statusColor(s)),
                    label: Text('${timeline.count(s)} ${_statusText(s).toLowerCase()}'),
                  ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            budget.complete
                ? 'Costs: ${_peso(budget.subtotal)}'
                : 'Costs we know: ${_peso(budget.subtotal)}. Not the full cost: '
                    '${budget.unknown.length} ${budget.unknown.length == 1 ? 'cost is' : 'costs are'} unknown.',
            key: const ValueKey('timeline-budget-line'),
            style: const TextStyle(fontSize: 13),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              FilledButton.icon(
                key: const ValueKey('timeline-view'),
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => TimelineScreen(timeline: timeline, repo: repo),
                  ),
                ),
                icon: const Icon(Icons.view_timeline_outlined, size: 18),
                label: const Text('View timeline'),
              ),
              OutlinedButton.icon(
                key: const ValueKey('timeline-revise'),
                onPressed: () => showReviseTimelineSheet(context, timeline, repo),
                icon: const Icon(Icons.tune_rounded, size: 18),
                label: const Text('Revise'),
              ),
              if (repo.timelineBackendTripId != null)
                TextButton(
                  key: const ValueKey('timeline-history'),
                  onPressed: () => showTimelineHistorySheet(context, repo),
                  child: const Text('History'),
                ),
              if (onOpenTrip != null)
                TextButton(
                  key: const ValueKey('timeline-open-trip'),
                  onPressed: onOpenTrip,
                  child: const Text('Open trip'),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// The full day-by-day timeline with the checks, problems and costs.
class TimelineScreen extends StatelessWidget {
  const TimelineScreen({super.key, required this.timeline, required this.repo});

  final TimelineData timeline;
  final TravelRepository repo;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Your itinerary')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (timeline.conflicts.isNotEmpty) ...[
            _ConflictCard(timeline: timeline, repo: repo),
            const SizedBox(height: 16),
          ],
          for (final day in timeline.days) _DaySection(day: day),
          const SizedBox(height: 8),
          _ChecksPanel(checks: timeline.checks),
          const SizedBox(height: 16),
          _BudgetPanel(budget: timeline.budget),
          if (timeline.assumptions.isNotEmpty) ...[
            const SizedBox(height: 16),
            const Text('Planning defaults',
                style: TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: 6),
            for (final text in timeline.assumptions)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(text, style: const TextStyle(fontSize: 13)),
              ),
          ],
        ],
      ),
    );
  }
}

class _ConflictCard extends StatelessWidget {
  const _ConflictCard({required this.timeline, required this.repo});

  final TimelineData timeline;
  final TravelRepository repo;

  @override
  Widget build(BuildContext context) {
    final choices = {
      for (final c in timeline.conflicts) ...c.choices,
    };
    return Container(
      key: const ValueKey('timeline-conflict-card'),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF4E5),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: LakbayColors.cocoaOrange),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Some of your places do not fit yet',
            style: TextStyle(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 6),
          for (final conflict in timeline.conflicts)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(conflict.message),
            ),
          const SizedBox(height: 4),
          const Text(
            'Nothing has been removed. Choose what to change:',
            style: TextStyle(fontSize: 13),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              for (final choice in choices)
                ActionChip(
                  key: ValueKey('timeline-choice-$choice'),
                  label: Text(_choiceLabels[choice] ?? choice),
                  onPressed: () =>
                      showReviseTimelineSheet(context, timeline, repo, focus: choice),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _DaySection extends StatelessWidget {
  const _DaySection({required this.day});

  final TimelineDay day;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 4, bottom: 6),
          child: Text(
            day.date == null ? 'Day ${day.day}' : 'Day ${day.day} · ${day.date}',
            style: const TextStyle(
              fontFamily: 'FigGrotesk',
              fontWeight: FontWeight.w700,
              fontSize: 16,
              color: LakbayColors.tealDeep,
            ),
          ),
        ),
        for (final item in day.items) _ItemTile(item: item),
        const SizedBox(height: 8),
      ],
    );
  }
}

class _ItemTile extends StatelessWidget {
  const _ItemTile({required this.item});

  final TimelineItem item;

  @override
  Widget build(BuildContext context) {
    final range = item.timeRange ?? 'Time unknown';
    final minor = item.kind == 'buffer' || item.kind == 'depart';
    final detailed = item.travel != null ||
        item.costs.isNotEmpty ||
        item.booking != null ||
        item.notes.isNotEmpty;
    final title = Row(
      children: [
        Expanded(
          child: Text(
            item.label,
            style: TextStyle(
              fontWeight: minor ? FontWeight.w500 : FontWeight.w700,
            ),
          ),
        ),
        _BasisChip(basis: item.timeBasis),
      ],
    );
    final subtitle = Text(
      [
        range,
        if (durationLabel(item.durationMinutes) != null)
          durationLabel(item.durationMinutes)!
        else if (item.kind == 'travel')
          'travel time unknown',
      ].join(' · '),
    );
    return Card(
      key: ValueKey('timeline-item-${item.day}-${item.kind}-${item.label}'),
      margin: const EdgeInsets.only(bottom: 6),
      child: detailed
          ? ExpansionTile(
              leading: Icon(_kindIcon(item.kind)),
              title: title,
              subtitle: subtitle,
              childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              expandedCrossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (item.travel != null) _travelDetail(item.travel!),
                if (item.booking != null && item.booking!.isNotEmpty)
                  _line(Icons.event_available_outlined, item.booking!),
                for (final cost in item.costs) _costLine(cost),
                for (final note in item.notes) _line(Icons.info_outline_rounded, note),
              ],
            )
          : ListTile(
              leading: Icon(_kindIcon(item.kind)),
              title: title,
              subtitle: subtitle,
            ),
    );
  }

  Widget _travelDetail(TimelineTravel leg) {
    final basis = switch (leg.basis) {
      'supported' => leg.routeVerified ? 'route-based' : 'route estimate',
      'estimated' => 'estimated from straight-line distance',
      _ => 'no travel time available',
    };
    return _line(
      Icons.alt_route_rounded,
      '${leg.fromLabel} to ${leg.toLabel}: '
      '${durationLabel(leg.minutes) ?? 'unknown time'} ($basis)',
    );
  }

  Widget _costLine(TimelineCost cost) {
    final amount = cost.amount == null
        ? 'unknown'
        : _peso(cost.amount!) + (cost.scope == 'per_person' ? ' per person' : '');
    final status = cost.status == 'known' ? '' : ' (${cost.status})';
    final included = cost.includedIn == null ? '' : ', included in ${cost.includedIn}';
    return _line(Icons.payments_outlined, '${cost.label}: $amount$status$included');
  }

  Widget _line(IconData icon, String text) => Padding(
    padding: const EdgeInsets.only(top: 6),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 16, color: LakbayColors.textMuted),
        const SizedBox(width: 8),
        Expanded(child: Text(text, style: const TextStyle(fontSize: 13))),
      ],
    ),
  );
}

class _BasisChip extends StatelessWidget {
  const _BasisChip({required this.basis});

  final String basis;

  @override
  Widget build(BuildContext context) {
    final color = switch (basis) {
      'confirmed' => LakbayColors.successGreen,
      'estimated' => LakbayColors.primary,
      'provisional' => LakbayColors.cocoaOrange,
      _ => LakbayColors.textMuted,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        _basisLabels[basis] ?? basis,
        style: TextStyle(fontSize: 11, color: color, fontWeight: FontWeight.w600),
      ),
    );
  }
}

class _ChecksPanel extends StatelessWidget {
  const _ChecksPanel({required this.checks});

  final List<TimelineCheck> checks;

  @override
  Widget build(BuildContext context) {
    return Column(
      key: const ValueKey('timeline-checks'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Checks', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
        const SizedBox(height: 4),
        const Text(
          "A check we cannot confirm is never counted as passed.",
          style: TextStyle(fontSize: 12.5, color: LakbayColors.textSecondary),
        ),
        const SizedBox(height: 6),
        for (final check in checks)
          ListTile(
            key: ValueKey('timeline-check-${check.id}'),
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(_statusIcon(check.status), color: _statusColor(check.status)),
            title: Text(_checkTitles[check.id] ?? check.id),
            subtitle: Text('${_statusText(check.status)}: ${check.message}'),
          ),
      ],
    );
  }
}

class _BudgetPanel extends StatelessWidget {
  const _BudgetPanel({required this.budget});

  final TimelineBudget budget;

  @override
  Widget build(BuildContext context) {
    final fit = switch (budget.fit) {
      'fits_known_costs' => 'Within your budget, with every cost known.',
      'over_budget' => 'The costs we know already pass your budget.',
      _ => 'We cannot say yet whether it fits your budget.',
    };
    return Column(
      key: const ValueKey('timeline-budget'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Costs', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
        const SizedBox(height: 6),
        Text('Known: ${_peso(budget.knownTotal)}'),
        Text('Estimated: ${_peso(budget.estimatedTotal)}'),
        Text('Subtotal: ${_peso(budget.subtotal)}'),
        if (budget.remaining != null) Text('Remaining: ${_peso(budget.remaining!)}'),
        const SizedBox(height: 6),
        Text(fit, style: const TextStyle(fontWeight: FontWeight.w600)),
        if (budget.unknown.isNotEmpty) ...[
          const SizedBox(height: 6),
          const Text('Unknown costs (not in the subtotal):'),
          for (final u in budget.unknown)
            Padding(
              padding: const EdgeInsets.only(left: 8, top: 2),
              child: Text('• $u', style: const TextStyle(fontSize: 13)),
            ),
        ],
        if (budget.unbased.isNotEmpty) ...[
          const SizedBox(height: 6),
          const Text('Estimates with no recorded basis (not used to judge your budget):'),
          for (final u in budget.unbased)
            Padding(
              padding: const EdgeInsets.only(left: 8, top: 2),
              child: Text('• $u', style: const TextStyle(fontSize: 13)),
            ),
        ],
        if (budget.toComplete.isNotEmpty) ...[
          const SizedBox(height: 6),
          const Text('To complete the estimate:'),
          for (final p in budget.toComplete)
            Padding(
              padding: const EdgeInsets.only(left: 8, top: 2),
              child: Text('• $p', style: const TextStyle(fontSize: 13)),
            ),
        ],
        for (final note in budget.notes)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(note, style: const TextStyle(fontSize: 12.5)),
          ),
      ],
    );
  }
}

/// The Revise sheet: change the start, the deadline, the days, the pace, or which places
/// to keep. `focus` puts the section a conflict choice points to first.
Future<void> showReviseTimelineSheet(
  BuildContext context,
  TimelineData timeline,
  TravelRepository repo, {
  String? focus,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => _ReviseSheet(timeline: timeline, repo: repo, focus: focus),
  );
}

class _ReviseSheet extends StatefulWidget {
  const _ReviseSheet({required this.timeline, required this.repo, this.focus});

  final TimelineData timeline;
  final TravelRepository repo;
  final String? focus;

  @override
  State<_ReviseSheet> createState() => _ReviseSheetState();
}

class _ReviseSheetState extends State<_ReviseSheet> {
  TimeOfDay? _departure;
  TimeOfDay? _deadline;
  late int _days = widget.timeline.days.length;
  String? _pace;
  late final Set<int> _keep = {for (final p in widget.timeline.places) p.id};

  String _hms(TimeOfDay t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}:00';

  Future<void> _pick(bool departure) async {
    final picked = await showTimePicker(
      context: context,
      initialTime: (departure ? _departure : _deadline) ??
          TimeOfDay(hour: departure ? 8 : 18, minute: 0),
    );
    if (picked == null) return;
    setState(() => departure ? _departure = picked : _deadline = picked);
  }

  void _apply() {
    final original = [for (final p in widget.timeline.places) p.id];
    final kept = [for (final id in original) if (_keep.contains(id)) id];
    final revision = TimelineRevision(
      departureTime: _departure == null ? null : _hms(_departure!),
      returnDeadline: _deadline == null ? null : _hms(_deadline!),
      dayCount: _days == widget.timeline.days.length ? null : _days,
      pace: _pace,
      destinationIds: kept.length == original.length ? null : kept,
    );
    Navigator.of(context).pop();
    widget.repo.reviseTimeline(revision);
  }

  Widget _time(String key, String label, TimeOfDay? value, bool departure) =>
      OutlinedButton(
        key: ValueKey(key),
        onPressed: () => _pick(departure),
        child: Text(value == null ? '$label: unchanged' : '$label: ${value.format(context)}'),
      );

  @override
  Widget build(BuildContext context) {
    final places = Column(
      key: const ValueKey('revise-places'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Places to keep', style: TextStyle(fontWeight: FontWeight.w700)),
        for (final place in widget.timeline.places)
          CheckboxListTile(
            key: ValueKey('revise-place-${place.id}'),
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: Text(place.name),
            value: _keep.contains(place.id),
            onChanged: (v) => setState(
              () => v == true ? _keep.add(place.id) : _keep.remove(place.id),
            ),
          ),
      ],
    );
    final window = Column(
      key: const ValueKey('revise-window'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Time window', style: TextStyle(fontWeight: FontWeight.w700)),
        const SizedBox(height: 6),
        Wrap(
          spacing: 8,
          runSpacing: 6,
          children: [
            _time('revise-departure', 'Start', _departure, true),
            _time('revise-deadline', 'Be back by', _deadline, false),
          ],
        ),
        Row(
          children: [
            const Text('Days'),
            IconButton(
              key: const ValueKey('revise-days-minus'),
              onPressed: _days > 1 ? () => setState(() => _days--) : null,
              icon: const Icon(Icons.remove_circle_outline),
            ),
            Text('$_days', key: const ValueKey('revise-days')),
            IconButton(
              key: const ValueKey('revise-days-plus'),
              onPressed: _days < 30 ? () => setState(() => _days++) : null,
              icon: const Icon(Icons.add_circle_outline),
            ),
          ],
        ),
      ],
    );
    final pace = Column(
      key: const ValueKey('revise-pace'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Pace', style: TextStyle(fontWeight: FontWeight.w700)),
        const SizedBox(height: 6),
        SegmentedButton<String>(
          emptySelectionAllowed: true,
          showSelectedIcon: false,
          segments: const [
            ButtonSegment(value: 'relaxed', label: Text('Relaxed')),
            ButtonSegment(value: 'balanced', label: Text('Balanced')),
            ButtonSegment(value: 'packed', label: Text('Packed')),
          ],
          selected: {?_pace},
          onSelectionChanged: (s) => setState(() => _pace = s.isEmpty ? null : s.first),
        ),
      ],
    );
    final ordered = switch (widget.focus) {
      'prioritise_places' => [places, window, pace],
      'relax_another_constraint' => [pace, window, places],
      _ => [window, places, pace],
    };
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          16, 0, 16, 16 + MediaQuery.of(context).viewInsets.bottom,
        ),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Revise your itinerary',
                style: TextStyle(fontFamily: 'FigGrotesk', fontWeight: FontWeight.w700, fontSize: 17),
              ),
              const SizedBox(height: 4),
              const Text(
                'Only what you change is updated. A place is removed only if you untick it.',
                style: TextStyle(fontSize: 13, color: LakbayColors.textSecondary),
              ),
              const SizedBox(height: 12),
              for (final section in ordered) ...[section, const SizedBox(height: 14)],
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  key: const ValueKey('revise-apply'),
                  onPressed: _keep.isEmpty ? null : _apply,
                  child: const Text('Update itinerary'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}


/// The saved revisions of this itinerary, newest first, with what moved in each.
Future<void> showTimelineHistorySheet(BuildContext context, TravelRepository repo) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => FutureBuilder<List<TimelineRevisionSummary>?>(
      future: repo.loadTimelineHistory(),
      builder: (context, snapshot) {
        final revisions = snapshot.data;
        Widget body;
        if (snapshot.connectionState != ConnectionState.done) {
          body = const Padding(
            padding: EdgeInsets.all(24),
            child: Center(child: CircularProgressIndicator()),
          );
        } else if (revisions == null) {
          body = const Padding(
            padding: EdgeInsets.all(16),
            child: Text("The history could not be loaded right now. Your itinerary is not affected."),
          );
        } else if (revisions.isEmpty) {
          body = const Padding(
            padding: EdgeInsets.all(16),
            child: Text('No saved revisions yet.'),
          );
        } else {
          body = Column(
            key: const ValueKey('timeline-history-list'),
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final r in revisions)
                ListTile(
                  key: ValueKey('timeline-revision-${r.revision}'),
                  dense: true,
                  title: Text(
                    'Revision ${r.revision}'
                    '${r.createdAt == null ? '' : ' \u00b7 ${_date(r.createdAt!.toLocal())}'}',
                  ),
                  subtitle: Text(
                    r.changes.isEmpty ? 'First saved version' : r.changes.join(' '),
                  ),
                ),
            ],
          );
        }
        return SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Itinerary history',
                  style: TextStyle(fontFamily: 'FigGrotesk', fontWeight: FontWeight.w700, fontSize: 17),
                ),
                const SizedBox(height: 8),
                body,
              ],
            ),
          ),
        );
      },
    ),
  );
}

String _date(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
