import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../core/timeline_labels.dart';
import '../models/timeline_models.dart';

/// Builds the itinerary PDF on the phone from the timeline itself: no server, no sign-in
/// and no connection needed, for guests and for trips that were never saved.
///
/// It prints what the timeline says and how far to trust it: every time carries its
/// Confirmed / Estimated / Provisional / Unknown label, a cost nobody knows is printed as
/// unknown (never as free), and a check that could not be confirmed is printed as
/// "Can't verify", never as passed. The built-in PDF font has no peso sign, so amounts are
/// written as "PHP".
class TimelinePdfBuilder {
  TimelinePdfBuilder._();

  static String _money(double php) => pesoText(php, symbol: 'PHP ');

  static String _date(DateTime d) {
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    return '${months[d.month - 1]} ${d.day}, ${d.year}';
  }

  /// PDF text is plain Latin: anything the font cannot draw is replaced.
  static String _safe(String text) => text
      .replaceAll('₱', 'PHP ')
      .replaceAll(RegExp('[‘’]'), "'")
      .replaceAll(RegExp('[“”]'), '"')
      .replaceAll(RegExp('[‐-―]'), '-')
      .replaceAll('•', '-')
      .replaceAll('·', '-')
      .replaceAll(RegExp(r'[^\x20-\x7E\n]'), '');

  static Future<Uint8List> build(
    TimelineData timeline, {
    String title = 'Your itinerary',
    String? startingFrom,
    DateTime? now,
    bool compress = true,
  }) async {
    final doc = pw.Document(title: _safe(title), author: 'Lakbay+', compress: compress);
    final widgets = <pw.Widget>[];

    pw.Widget h1(String t) => pw.Text(
      _safe(t),
      style: pw.TextStyle(fontSize: 22, fontWeight: pw.FontWeight.bold),
    );
    pw.Widget h2(String t) => pw.Padding(
      padding: const pw.EdgeInsets.only(top: 14, bottom: 4),
      child: pw.Text(
        _safe(t),
        style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold),
      ),
    );
    pw.Widget body(String t, {double size = 10.5, bool bold = false}) => pw.Padding(
      padding: const pw.EdgeInsets.only(bottom: 3),
      child: pw.Text(
        _safe(t),
        style: pw.TextStyle(
          fontSize: size,
          fontWeight: bold ? pw.FontWeight.bold : pw.FontWeight.normal,
        ),
      ),
    );

    widgets.add(h1(title));
    widgets.add(body('Lakbay+ itinerary', size: 11));
    if (startingFrom != null && startingFrom.trim().isNotEmpty) {
      widgets.add(body('Starting from: $startingFrom'));
    }
    final places = timeline.places.length;
    widgets.add(
      body(
        '${timeline.days.length} ${timeline.days.length == 1 ? 'day' : 'days'}, '
        '$places ${places == 1 ? 'place' : 'places'}',
      ),
    );
    widgets.add(
      body(
        timeline.feasible
            ? 'Nothing we can check conflicts with your places.'
            : 'Some places do not fit yet: see "Places that do not fit" below.',
        bold: true,
      ),
    );
    final cannot = timeline.count('cannot_verify');
    if (cannot > 0) {
      widgets.add(
        body(
          '$cannot ${cannot == 1 ? 'detail' : 'details'} could not be confirmed, so '
          'the times that depend on them are provisional.',
        ),
      );
    }

    widgets.add(h2('How to read the times'));
    for (final entry in timelineBasisLabels.entries) {
      widgets.add(
        body('${entry.value}: ${timelineBasisMeanings[entry.key]}', size: 9.5),
      );
    }

    if (timeline.conflicts.isNotEmpty) {
      widgets.add(h2('Places that do not fit'));
      for (final conflict in timeline.conflicts) {
        widgets.add(body('- ${conflict.message}'));
      }
      widgets.add(
        body(
          'Nothing has been removed. You can choose which places to keep, change the '
          'time window, or change another limit.',
          size: 9.5,
        ),
      );
    }

    for (final day in timeline.days) {
      widgets.add(h2(day.date == null ? 'Day ${day.day}' : 'Day ${day.day} (${day.date})'));
      for (final item in day.items) {
        widgets.addAll(_item(item, body));
      }
    }

    widgets.add(h2('Checks'));
    widgets.add(
      body("A check we cannot confirm is never counted as passed.", size: 9.5),
    );
    for (final check in timeline.checks) {
      widgets.add(
        body(
          '${timelineCheckTitles[check.id] ?? check.id}: '
          '${timelineStatusText(check.status)}. ${check.message}',
        ),
      );
    }

    widgets.addAll(_budget(timeline.budget, h2, body));

    if (timeline.assumptions.isNotEmpty) {
      widgets.add(h2('Planning defaults'));
      for (final text in timeline.assumptions) {
        widgets.add(body('- $text', size: 10));
      }
    }

    widgets.add(pw.SizedBox(height: 18));
    widgets.add(
      body(
        "Built from Lakbay's records on ${_date(now ?? DateTime.now())}. Anything marked "
        'Estimated, Provisional or Unknown has not been confirmed: check opening hours, '
        'prices and travel times before you go.',
        size: 9,
      ),
    );

    doc.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(36),
        build: (_) => widgets,
      ),
    );
    return doc.save();
  }

  static List<pw.Widget> _item(
    TimelineItem item,
    pw.Widget Function(String, {double size, bool bold}) body,
  ) {
    final range = item.timeRange ?? 'time unknown';
    final length = durationLabel(item.durationMinutes) ??
        (item.kind == 'travel' ? 'travel time unknown' : null);
    final basis = timelineBasisLabels[item.timeBasis] ?? item.timeBasis;
    final out = <pw.Widget>[
      pw.Padding(
        padding: const pw.EdgeInsets.only(top: 4),
        child: pw.Text(
          _safe('$range  ${item.label}  [$basis]${length == null ? '' : ' - $length'}'),
          style: pw.TextStyle(
            fontSize: 11,
            fontWeight: item.kind == 'visit' ? pw.FontWeight.bold : pw.FontWeight.normal,
          ),
        ),
      ),
    ];
    final leg = item.travel;
    if (leg != null) {
      final how = switch (leg.basis) {
        'supported' => leg.routeVerified ? 'route-based' : 'route estimate',
        'estimated' => 'estimated from straight-line distance',
        _ => 'no travel time available',
      };
      out.add(
        body(
          'From ${leg.fromLabel} to ${leg.toLabel}: '
          '${durationLabel(leg.minutes) ?? 'unknown time'} ($how)',
          size: 9.5,
        ),
      );
    }
    if (item.booking != null && item.booking!.isNotEmpty) {
      out.add(body('Booking: ${item.booking}', size: 9.5));
    }
    for (final cost in item.costs) {
      final amount = cost.amount == null
          ? 'unknown'
          : _money(cost.amount!) + (cost.scope == 'per_person' ? ' per person' : '');
      final status = cost.status == 'known' ? '' : ' (${cost.status})';
      final included = cost.includedIn == null ? '' : ', included in ${cost.includedIn}';
      out.add(body('Cost - ${cost.label}: $amount$status$included', size: 9.5));
    }
    for (final note in item.notes) {
      out.add(body('Note: $note', size: 9.5));
    }
    return out;
  }

  static List<pw.Widget> _budget(
    TimelineBudget budget,
    pw.Widget Function(String) h2,
    pw.Widget Function(String, {double size, bool bold}) body,
  ) {
    final fit = switch (budget.fit) {
      'fits_known_costs' => 'Within your budget, with every cost known.',
      'over_budget' => 'The costs we know already pass your budget.',
      _ => 'We cannot say yet whether it fits your budget.',
    };
    return [
      h2('Costs'),
      body('Known: ${_money(budget.knownTotal)}'),
      body('Estimated: ${_money(budget.estimatedTotal)}'),
      body('Subtotal: ${_money(budget.subtotal)}'),
      if (budget.totalBudget != null) body('Your budget: ${_money(budget.totalBudget!)}'),
      if (budget.remaining != null) body('Remaining: ${_money(budget.remaining!)}'),
      body(fit, bold: true),
      if (budget.unknown.isNotEmpty) ...[
        body('Unknown costs (not in the subtotal):', size: 10),
        for (final u in budget.unknown) body('- $u', size: 10),
      ],
      if (budget.unbased.isNotEmpty) ...[
        body('Estimates with no recorded basis (not used to judge your budget):', size: 10),
        for (final u in budget.unbased) body('- $u', size: 10),
      ],
      if (budget.toComplete.isNotEmpty) ...[
        body('To complete the estimate:', size: 10),
        for (final p in budget.toComplete) body('- $p', size: 10),
      ],
      for (final note in budget.notes) body(note, size: 9.5),
    ];
  }
}
