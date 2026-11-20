import 'package:flutter/material.dart';

import '../core/timeline_labels.dart';
import '../models/timeline_models.dart';
import '../services/pdf_share.dart';
import '../services/timeline_pdf.dart';
import '../models/travel_models.dart';
import '../services/travel_repository.dart';
import '../theme/lakbay_theme.dart';

const _basisLabels = timelineBasisLabels;
const _checkTitles = timelineCheckTitles;
const _choiceLabels = timelineChoiceLabels;
String _peso(double amount) => pesoText(amount);
String _statusText(String status) => timelineStatusText(status);

IconData _kindIcon(String kind) => switch (kind) {
  'visit' => Icons.place_outlined,
  'travel' => Icons.directions_car_outlined,
  'meal' => Icons.restaurant_outlined,
  'rest' => Icons.self_improvement_outlined,
  'buffer' => Icons.hourglass_empty_rounded,
  'overnight' => Icons.hotel_outlined,
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
              TextButton.icon(
                key: const ValueKey('timeline-export-pdf'),
                onPressed: () => exportTimelinePdf(
                  context,
                  timeline,
                  title: trip?.title ?? 'Your itinerary',
                  startingFrom: repo.routeOrigin?.label,
                ),
                icon: const Icon(Icons.picture_as_pdf_outlined, size: 18),
                label: const Text('Export PDF'),
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
          for (final day in timeline.days) _DaySection(day: day, timeline: timeline),
          const SizedBox(height: 8),
          _ChecksPanel(checks: timeline.checks, timeline: timeline, repo: repo),
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
          for (final id in {
            for (final c in timeline.conflicts)
              if (c.destinationId != null) c.destinationId!,
          })
            _SwapOptions(destinationId: id, timeline: timeline, repo: repo),
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
  const _DaySection({required this.day, required this.timeline});

  final TimelineDay day;
  final TimelineData timeline;

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
        for (final item in day.items)
          _ItemTile(
            item: item,
            pin: item.destinationId == null ? null : timeline.pinFor(item.destinationId!),
          ),
        const SizedBox(height: 8),
      ],
    );
  }
}

class _ItemTile extends StatelessWidget {
  const _ItemTile({required this.item, this.pin});

  final TimelineItem item;

  /// Set when the traveler pinned this place to a day or a time.
  final TimelinePin? pin;

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
        if (pin != null && item.kind == 'visit')
          Padding(
            padding: const EdgeInsets.only(right: 6),
            child: Tooltip(
              message: 'Pinned: ${pin!.summary}',
              child: Icon(
                Icons.push_pin,
                key: ValueKey('timeline-pinned-${item.destinationId}'),
                size: 16,
                color: LakbayColors.primary,
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

/// Tested replacements for one place that does not work, as chips; tapping one asks first.
class _SwapOptions extends StatelessWidget {
  const _SwapOptions({
    required this.destinationId,
    required this.timeline,
    required this.repo,
  });

  final int destinationId;
  final TimelineData timeline;
  final TravelRepository repo;

  @override
  Widget build(BuildContext context) {
    final set = timeline.alternativeSetFor(destinationId);
    // No alternatives came with this timeline (an older one): offer nothing.
    if (set == null) return const SizedBox.shrink();
    if (set.options.isEmpty) {
      return Padding(
        key: ValueKey('timeline-no-swap-$destinationId'),
        padding: const EdgeInsets.only(bottom: 6),
        child: Text(
          'We could not find a place that fits instead of ${set.name}.',
          style: const TextStyle(fontSize: 13),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Swap ${set.name} for:', style: const TextStyle(fontSize: 13)),
          const SizedBox(height: 4),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              for (final option in set.options)
                ActionChip(
                  key: ValueKey('timeline-swap-$destinationId-${option.destinationId}'),
                  label: Text('${option.name} · ${option.distanceKm.toStringAsFixed(1)} km'),
                  onPressed: () => _confirmSwap(context, set, option, repo),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Shows what the swap changes and what is not recorded, then swaps only on a tap.
Future<void> _confirmSwap(
  BuildContext context,
  TimelineAlternativeSet set,
  TimelineAlternative option,
  TravelRepository repo,
) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      key: const ValueKey('timeline-swap-dialog'),
      title: Text('Swap ${set.name} for ${option.name}?'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final r in option.reasons) Text('• $r'),
            if (option.unverified.isNotEmpty) ...[
              const SizedBox(height: 8),
              const Text('Not recorded:', style: TextStyle(fontWeight: FontWeight.w700)),
              for (final u in option.unverified) Text('• $u'),
            ],
            if (option.changes.isNotEmpty) ...[
              const SizedBox(height: 8),
              const Text('What changes:', style: TextStyle(fontWeight: FontWeight.w700)),
              for (final c in option.changes) Text('• $c'),
            ],
            const SizedBox(height: 8),
            if (option.stillFailing.isEmpty)
              const Text('After this swap, nothing in the itinerary is flagged as not fitting.')
            else ...[
              const Text(
                'Still not working after this swap:',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
              for (final p in option.stillFailing) Text('• $p'),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          key: const ValueKey('timeline-swap-cancel'),
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey('timeline-swap-confirm'),
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: const Text('Swap'),
        ),
      ],
    ),
  );
  if (ok == true) {
    repo.reviseTimeline(TimelineRevision(
      destinationIds: option.destinationIds,
      bringIn: [option.destinationId],
    ));
  }
}

class _ChecksPanel extends StatelessWidget {
  const _ChecksPanel({required this.checks, required this.timeline, required this.repo});

  final List<TimelineCheck> checks;
  final TimelineData timeline;
  final TravelRepository repo;

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
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('${_statusText(check.status)}: ${check.message}'),
                // A place already offered in the conflict card is not offered twice.
                if (check.status == 'failed')
                  for (final id in check.destinationIds)
                    if (!timeline.conflicts.any((c) => c.destinationId == id))
                      _SwapOptions(destinationId: id, timeline: timeline, repo: repo),
              ],
            ),
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
  late final Map<int, TimelinePin> _pins = {
    for (final p in widget.timeline.pins) p.destinationId: p,
  };
  bool _pinsChanged = false;

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
      pins: _pinsChanged
          ? [for (final p in _pins.values) if (_keep.contains(p.destinationId)) p]
          : null,
    );
    Navigator.of(context).pop();
    widget.repo.reviseTimeline(revision);
  }

  Future<void> _editPin(({int id, String name}) place) async {
    final current = _pins[place.id];
    var day = current?.day;
    TimeOfDay? time;
    final startsAt = current?.startsAt;
    if (startsAt != null && startsAt.length >= 5) {
      time = TimeOfDay(
        hour: int.tryParse(startsAt.substring(0, 2)) ?? 8,
        minute: int.tryParse(startsAt.substring(3, 5)) ?? 0,
      );
    }
    final result = await showDialog<TimelinePin?>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialog) => AlertDialog(
          key: const ValueKey('pin-dialog'),
          title: Text('Pin ${place.name}'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('A pinned place keeps its day and start time when the rest of the plan changes.'),
              const SizedBox(height: 12),
              DropdownButtonFormField<int?>(
                key: const ValueKey('pin-day'),
                initialValue: day,
                decoration: const InputDecoration(labelText: 'Day'),
                items: [
                  const DropdownMenuItem<int?>(value: null, child: Text('Any day')),
                  for (var d = 1; d <= _days; d++)
                    DropdownMenuItem<int?>(value: d, child: Text('Day $d')),
                ],
                onChanged: (v) => setDialog(() => day = v),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                children: [
                  OutlinedButton(
                    key: const ValueKey('pin-time'),
                    onPressed: () async {
                      final picked = await showTimePicker(
                        context: context,
                        initialTime: time ?? const TimeOfDay(hour: 9, minute: 0),
                      );
                      if (picked != null) setDialog(() => time = picked);
                    },
                    child: Text(time == null ? 'Any time' : 'Start at ${time!.format(context)}'),
                  ),
                  if (time != null)
                    TextButton(
                      onPressed: () => setDialog(() => time = null),
                      child: const Text('Clear time'),
                    ),
                ],
              ),
            ],
          ),
          actions: [
            if (current != null)
              TextButton(
                key: const ValueKey('pin-remove'),
                onPressed: () => Navigator.pop(
                  dialogContext,
                  TimelinePin(destinationId: place.id),
                ),
                child: const Text('Unpin'),
              ),
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Cancel'),
            ),
            FilledButton(
              key: const ValueKey('pin-save'),
              onPressed: () => Navigator.pop(
                dialogContext,
                TimelinePin(
                  destinationId: place.id,
                  day: day,
                  startsAt: time == null ? null : _hms(time!),
                ),
              ),
              child: const Text('Pin'),
            ),
          ],
        ),
      ),
    );
    if (result == null) return;
    setState(() {
      _pinsChanged = true;
      if (result.day == null && result.startsAt == null) {
        _pins.remove(place.id);
      } else {
        _pins[place.id] = result;
      }
    });
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
    final pins = Column(
      key: const ValueKey('revise-pins'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Pins', style: TextStyle(fontWeight: FontWeight.w700)),
        const Text(
          'Lock a place to a day or a start time. Everything else moves around it.',
          style: TextStyle(fontSize: 12.5, color: LakbayColors.textSecondary),
        ),
        for (final place in widget.timeline.places)
          if (_keep.contains(place.id))
            ListTile(
              key: ValueKey('revise-pin-${place.id}'),
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: Icon(
                _pins.containsKey(place.id) ? Icons.push_pin : Icons.push_pin_outlined,
                color: _pins.containsKey(place.id)
                    ? LakbayColors.primary
                    : LakbayColors.textMuted,
              ),
              title: Text(place.name),
              subtitle: Text(_pins[place.id]?.summary ?? 'Not pinned'),
              trailing: TextButton(
                key: ValueKey('revise-pin-edit-${place.id}'),
                onPressed: () => _editPin(place),
                child: Text(_pins.containsKey(place.id) ? 'Change' : 'Pin'),
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
      'prioritise_places' => [places, window, pins, pace],
      'relax_another_constraint' => [pace, window, places, pins],
      _ => [window, places, pins, pace],
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
              for (final (index, r) in revisions.indexed)
                ListTile(
                  key: ValueKey('timeline-revision-${r.revision}'),
                  dense: true,
                  // The newest is what you have now; every older one can be brought back.
                  trailing: index == 0
                      ? const Text('Current', style: TextStyle(fontSize: 12))
                      : TextButton(
                          key: ValueKey('timeline-restore-${r.revision}'),
                          onPressed: () {
                            Navigator.of(context).pop();
                            repo.restoreTimelineRevision(r.revision);
                          },
                          child: const Text('Restore'),
                        ),
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


/// Builds the itinerary PDF on the phone and opens the share sheet. It needs no sign-in
/// and no connection.
Future<void> exportTimelinePdf(
  BuildContext context,
  TimelineData timeline, {
  String title = 'Your itinerary',
  String? startingFrom,
}) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  try {
    final bytes = await TimelinePdfBuilder.build(
      timeline,
      title: title,
      startingFrom: startingFrom,
    );
    await PdfShare.share(bytes, 'lakbay-itinerary.pdf', '$title - Lakbay+ itinerary PDF');
  } catch (e) {
    messenger?.showSnackBar(
      SnackBar(content: Text('Could not make the PDF on this phone: $e')),
    );
  }
}
