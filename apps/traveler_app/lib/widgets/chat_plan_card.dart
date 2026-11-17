import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../design/design.dart';
import '../models/travel_models.dart';
import 'estimate_note.dart';

/// The v8 plan card in Chat: mini route map, one line per day, the cost per
/// person with its split (only when the server priced it), and Save / Open.
class ChatPlanCard extends StatelessWidget {
  const ChatPlanCard({
    super.key,
    required this.trip,
    required this.title,
    required this.onSave,
    required this.onOpen,
    this.label,
    this.totalPhp,
    this.isOverBudget = false,
    this.budgetSplit = const {},
    this.highlighted = false,
    this.width,
  });

  final ItineraryTrip trip;
  final String title;

  /// Small tag above the title, e.g. "Option 1 · Best Value".
  final String? label;

  /// Whole-trip estimate from the server, in pesos.
  final double? totalPhp;
  final bool isOverBudget;

  /// Whole-trip cost by server category. Shown as a bar only when it adds up
  /// to [totalPhp], so the split never contradicts the total.
  final Map<String, double> budgetSplit;
  final bool highlighted;
  final double? width;
  final VoidCallback onSave;
  final VoidCallback onOpen;

  static const _weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

  int get _people => (trip.adults + trip.children).clamp(1, 100);

  List<_Slice> get _slices {
    final total = totalPhp;
    if (total == null || total <= 0 || budgetSplit.isEmpty) return const [];
    final sum = budgetSplit.values.fold<double>(0, (a, b) => a + b);
    if ((sum - total).abs() > total * 0.05) return const [];
    double pick(List<String> keys) =>
        keys.fold(0, (a, k) => a + (budgetSplit[k] ?? 0));
    final slices = [
      _Slice('Stay', pick(['accommodation']), LkColors.budgetStay),
      _Slice('Food', pick(['food']), LkColors.budgetFood),
      _Slice('Rides', pick(['transportation']), LkColors.budgetRides),
      _Slice(
        'Entrance',
        pick(['destination', 'activity']),
        LkColors.budgetEntrance,
      ),
      _Slice('Other', pick(['other']), LkColors.faint),
    ];
    return slices.where((s) => s.amount > 0).toList();
  }

  String _dayLabel(ItineraryDay day) {
    final start = trip.startDate;
    if (start == null) return 'Day ${day.dayNumber}';
    final date = start.add(Duration(days: day.dayNumber - 1));
    return _weekdays[date.weekday - 1];
  }

  String _dayText(ItineraryDay day) {
    final names = day.stops
        .where((s) => s.category != 'stay')
        .map((s) => s.title.trim())
        .where((t) => t.isNotEmpty)
        .toList();
    return names.isEmpty ? day.cityTitle : names.join(', ');
  }

  @override
  Widget build(BuildContext context) {
    final stops = trip.days
        .expand((d) => d.stops)
        .where((s) => s.category != 'stay')
        .length;
    final ferries = trip.seaCrossings.length;
    final days = trip.days.where((d) => !d.isContinuationDay).take(4).toList();
    final total = totalPhp;
    final perPerson = total != null && total > 0
        ? (total / _people).round()
        : null;
    final slices = _slices;

    return Container(
      width: width,
      decoration: BoxDecoration(
        color: LkColors.s1,
        borderRadius: LkRadius.lgAll,
        border: Border.all(
          color: highlighted ? LkColors.lagoon : LkColors.stroke,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: 128,
            child: Stack(
              fit: StackFit.expand,
              children: [
                ColoredBox(
                  color: LkColors.s2,
                  child: CustomPaint(
                    painter: _MiniRoutePainter(trip.routeWaypoints),
                  ),
                ),
                Positioned(
                  left: LkSpace.l,
                  right: LkSpace.l,
                  top: LkSpace.m,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (label != null) ...[
                        Text(
                          label!,
                          style: LkType.micro.copyWith(
                            color: isOverBudget
                                ? LkColors.danger
                                : LkColors.lagoon,
                          ),
                        ),
                        const SizedBox(height: 2),
                      ],
                      Text(
                        title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: LkType.section,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        [
                          '$stops ${stops == 1 ? 'stop' : 'stops'}',
                          if (ferries > 0)
                            '$ferries ferry '
                                '${ferries == 1 ? 'crossing' : 'crossings'}',
                        ].join(', '),
                        style: LkType.caption,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              LkSpace.l,
              LkSpace.m,
              LkSpace.l,
              LkSpace.l,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final day in days)
                  Padding(
                    padding: const EdgeInsets.only(bottom: LkSpace.xs),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(
                          constraints: const BoxConstraints(minWidth: 44),
                          padding: const EdgeInsets.symmetric(
                            horizontal: LkSpace.xs,
                            vertical: 3,
                          ),
                          decoration: BoxDecoration(
                            color: LkColors.s2,
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            _dayLabel(day),
                            textAlign: TextAlign.center,
                            style: LkType.micro.copyWith(color: LkColors.text),
                          ),
                        ),
                        const SizedBox(width: LkSpace.s),
                        Expanded(
                          child: Text(
                            _dayText(day),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: LkType.caption.copyWith(
                              color: LkColors.text,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                if (perPerson != null) ...[
                  const SizedBox(height: LkSpace.s),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          isOverBudget
                              ? 'Per person · over budget'
                              : 'Per person',
                          style: LkType.caption.copyWith(
                            color: isOverBudget
                                ? LkColors.danger
                                : LkColors.muted,
                          ),
                        ),
                      ),
                      Text('₱${_thousands(perPerson)}', style: LkType.title),
                    ],
                  ),
                ],
                if (slices.isNotEmpty) ...[
                  const SizedBox(height: LkSpace.s),
                  _BudgetBar(slices: slices, people: _people),
                ],
                const SizedBox(height: LkSpace.m),
                Row(
                  children: [
                    Expanded(
                      child: LkButton(
                        label: 'Save trip',
                        icon: Icons.bookmark_add_outlined,
                        onPressed: onSave,
                      ),
                    ),
                    const SizedBox(width: LkSpace.s),
                    Expanded(
                      child: LkButton(
                        label: 'Open',
                        icon: Icons.map_outlined,
                        variant: LkButtonVariant.secondary,
                        onPressed: onOpen,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: LkSpace.m),
                const EstimateNote(),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

String _thousands(int n) => n.toString().replaceAllMapped(
  RegExp(r'(\d{1,3})(?=(\d{3})+(?!\d))'),
  (m) => '${m[1]},',
);

class _Slice {
  const _Slice(this.label, this.amount, this.color);

  final String label;
  final double amount;
  final Color color;
}

class _BudgetBar extends StatelessWidget {
  const _BudgetBar({required this.slices, required this.people});

  final List<_Slice> slices;
  final int people;

  @override
  Widget build(BuildContext context) {
    final total = slices.fold<double>(0, (a, s) => a + s.amount);
    return Semantics(
      label:
          'Per person: ${slices.map((s) => '${s.label} ₱${_thousands((s.amount / people).round())}').join(', ')}',
      excludeSemantics: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: SizedBox(
              height: 8,
              child: Row(
                children: [
                  for (var i = 0; i < slices.length; i++) ...[
                    if (i > 0) const SizedBox(width: 2),
                    Expanded(
                      flex: math.max(
                        1,
                        (slices[i].amount / total * 1000).round(),
                      ),
                      child: ColoredBox(color: slices[i].color),
                    ),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: LkSpace.xs),
          Wrap(
            spacing: LkSpace.m,
            runSpacing: 2,
            children: [
              for (final s in slices)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: s.color,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                    const SizedBox(width: 4),
                    Text(
                      '${s.label} ₱${_thousands((s.amount / people).round())}',
                      style: LkType.micro.copyWith(color: LkColors.muted),
                    ),
                  ],
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// The route drawn from the trip's own stop coordinates: a dashed lagoon
/// line with stop dots and a mango start.
class _MiniRoutePainter extends CustomPainter {
  _MiniRoutePainter(this.points);

  final List<GeoPoint> points;

  @override
  void paint(Canvas canvas, Size size) {
    if (points.length < 2) return;
    var minLat = points.first.lat, maxLat = points.first.lat;
    var minLng = points.first.lng, maxLng = points.first.lng;
    for (final p in points) {
      minLat = math.min(minLat, p.lat);
      maxLat = math.max(maxLat, p.lat);
      minLng = math.min(minLng, p.lng);
      maxLng = math.max(maxLng, p.lng);
    }
    // Keep the drawing in the lower right, clear of the title.
    final box = Rect.fromLTRB(
      size.width * 0.12,
      size.height * 0.5,
      size.width - 20,
      size.height - 16,
    );
    final spanLat = math.max(maxLat - minLat, 1e-4);
    final spanLng = math.max(maxLng - minLng, 1e-4);
    Offset at(GeoPoint p) => Offset(
      box.left + (p.lng - minLng) / spanLng * box.width,
      box.bottom - (p.lat - minLat) / spanLat * box.height,
    );

    final line = Paint()
      ..color = LkColors.lagoon
      ..strokeWidth = 2.4
      ..strokeCap = StrokeCap.round;
    for (var i = 1; i < points.length; i++) {
      final a = at(points[i - 1]);
      final b = at(points[i]);
      final d = b - a;
      final len = d.distance;
      if (len == 0) continue;
      final dir = d / len;
      for (var t = 0.0; t < len; t += 8) {
        canvas.drawLine(a + dir * t, a + dir * math.min(t + 4, len), line);
      }
    }
    final dot = Paint()..color = LkColors.lagoon;
    for (final p in points.skip(1)) {
      canvas.drawCircle(at(p), 4, dot);
    }
    canvas.drawCircle(at(points.first), 5.5, Paint()..color = LkColors.mango);
  }

  @override
  bool shouldRepaint(covariant _MiniRoutePainter old) => old.points != points;
}
