import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../core/timeline_labels.dart';
import '../models/timeline_models.dart';
import 'pdf_design_tokens.dart';

/// Builds the flagship Lakbay+ itinerary timeline PDF on the phone from the
/// timeline itself: no server, no sign-in, and no connection needed.
///
/// Preserves every trust invariant: every time carries its
/// Confirmed / Estimated / Provisional / Unknown badge, an unknown cost stays
/// unknown (never invented as free), `Remaining` is omitted when null, and a
/// check that could not be confirmed stays "Can't verify", never passed.
class TimelinePdfBuilder {
  TimelinePdfBuilder._();

  static String _money(double php) => LakbayPdfTokens.moneyPhp(php);

  static String _date(DateTime d) {
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    return '${months[d.month - 1]} ${d.day}, ${d.year}';
  }

  static ({PdfColor bg, PdfColor fg, PdfColor border}) _basisStyle(
    String basis,
  ) {
    return switch (basis) {
      'confirmed' => (
        bg: LakbayPdfTokens.successSoft,
        fg: LakbayPdfTokens.successGreen,
        border: LakbayPdfTokens.successBorder,
      ),
      'estimated' => (
        bg: LakbayPdfTokens.primaryLight,
        fg: LakbayPdfTokens.primaryDark,
        border: LakbayPdfTokens.cardBorder,
      ),
      'provisional' => (
        bg: LakbayPdfTokens.warningSoft,
        fg: LakbayPdfTokens.warning,
        border: LakbayPdfTokens.warningBorder,
      ),
      _ => (
        bg: LakbayPdfTokens.canvasBg,
        fg: LakbayPdfTokens.textMuted,
        border: LakbayPdfTokens.cardBorder,
      ),
    };
  }

  static ({PdfColor bg, PdfColor fg, PdfColor border}) _checkStyle(
    String status,
  ) {
    return switch (status) {
      'passed' => (
        bg: LakbayPdfTokens.successSoft,
        fg: LakbayPdfTokens.successGreen,
        border: LakbayPdfTokens.successBorder,
      ),
      'failed' => (
        bg: LakbayPdfTokens.errorSoft,
        fg: LakbayPdfTokens.error,
        border: LakbayPdfTokens.errorBorder,
      ),
      _ => (
        bg: LakbayPdfTokens.cocoaSoft,
        fg: LakbayPdfTokens.cocoaOrange,
        border: LakbayPdfTokens.cocoaBorder,
      ),
    };
  }

  static Future<Uint8List> build(
    TimelineData timeline, {
    String title = 'Your itinerary',
    String? startingFrom,
    DateTime? now,
    bool compress = true,
  }) async {
    final theme = await LakbayPdfTokens.loadTheme();
    final doc = pw.Document(
      title: theme.clean(title),
      author: 'Lakbay+',
      compress: compress,
    );

    final places = timeline.places.length;
    final cannot = timeline.count('cannot_verify');
    final daysText =
        '${timeline.days.length} ${timeline.days.length == 1 ? 'day' : 'days'}';
    final placesText = '$places ${places == 1 ? 'place' : 'places'}';

    final widgets = <pw.Widget>[];

    // 1. Branded Hero Banner
    widgets.add(
      theme.heroBanner(
        title: title,
        subtitle: startingFrom != null && startingFrom.trim().isNotEmpty
            ? 'Lakbay+ Itinerary • Starting from: $startingFrom'
            : 'Lakbay+ Itinerary',
        statusLabel: timeline.feasible ? 'Works' : 'Needs attention',
        statusBg: timeline.feasible
            ? LakbayPdfTokens.successSoft
            : LakbayPdfTokens.warningSoft,
        statusFg: timeline.feasible
            ? LakbayPdfTokens.successGreen
            : LakbayPdfTokens.warning,
        statusBorder: timeline.feasible
            ? LakbayPdfTokens.successBorder
            : LakbayPdfTokens.warningBorder,
        pills: [
          daysText,
          placesText,
          if (cannot > 0) '$cannot unverified',
        ],
      ),
    );
    widgets.add(pw.SizedBox(height: LakbayPdfTokens.spaceMd));

    // 2. Summary KPI Row
    final budget = timeline.budget;
    widgets.add(
      theme.kpiRow([
        PdfKpiItem(
          label: 'Schedule',
          value: '$daysText, $placesText',
          subtitle: startingFrom != null && startingFrom.trim().isNotEmpty
              ? 'From $startingFrom'
              : null,
        ),
        PdfKpiItem(
          label: 'Known Costs',
          value: _money(budget.knownTotal),
          valueColor: LakbayPdfTokens.primaryDark,
        ),
        PdfKpiItem(
          label: 'Subtotal',
          value: _money(budget.subtotal),
          subtitle: budget.estimatedTotal > 0
              ? 'Incl. ${_money(budget.estimatedTotal)} est.'
              : null,
        ),
        if (budget.totalBudget != null)
          PdfKpiItem(
            label: 'Your Budget',
            value: _money(budget.totalBudget!),
            subtitle: budget.remaining != null
                ? 'Remaining: ${_money(budget.remaining!)}'
                : null,
          )
        else
          PdfKpiItem(
            label: 'Checks',
            value: '${timeline.count('passed')} Passed',
            subtitle: cannot > 0 ? "$cannot Can't verify" : null,
          ),
      ]),
    );
    widgets.add(pw.SizedBox(height: LakbayPdfTokens.spaceSm));

    // 3. Honesty & Feasibility Strip
    widgets.add(
      pw.Container(
        width: double.infinity,
        padding: const pw.EdgeInsets.all(LakbayPdfTokens.spaceMd),
        decoration: pw.BoxDecoration(
          color: timeline.feasible
              ? LakbayPdfTokens.successSoft
              : LakbayPdfTokens.warningSoft,
          borderRadius: pw.BorderRadius.circular(LakbayPdfTokens.radiusTile),
          border: pw.Border.all(
            color: timeline.feasible
                ? LakbayPdfTokens.successBorder
                : LakbayPdfTokens.warningBorder,
            width: 0.8,
          ),
        ),
        child: pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Text(
              theme.clean(
                timeline.feasible
                    ? 'Nothing we can check conflicts with your places.'
                    : 'Some places do not fit yet: see "Places that do not fit" below.',
              ),
              style: theme.styleBody(
                color: timeline.feasible
                    ? LakbayPdfTokens.successGreen
                    : LakbayPdfTokens.warning,
                bold: true,
              ),
            ),
            if (cannot > 0) ...[
              pw.SizedBox(height: LakbayPdfTokens.spaceXs),
              pw.Text(
                theme.clean(
                  '$cannot ${cannot == 1 ? 'detail' : 'details'} could not be confirmed, so '
                  'the times that depend on them are provisional.',
                ),
                style: theme.styleCaption(color: LakbayPdfTokens.textPrimary),
              ),
            ],
          ],
        ),
      ),
    );

    // 4. Trust-Basis Legend Card
    widgets.add(theme.sectionHeader('How to Read the Times'));
    widgets.add(
      pw.Container(
        width: double.infinity,
        padding: const pw.EdgeInsets.all(LakbayPdfTokens.spaceMd),
        decoration: pw.BoxDecoration(
          color: LakbayPdfTokens.surfaceWhite,
          borderRadius: pw.BorderRadius.circular(LakbayPdfTokens.radiusCard),
          border: pw.Border.all(color: LakbayPdfTokens.cardBorder, width: 0.8),
        ),
        child: pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            for (var i = 0; i < timelineBasisLabels.entries.length; i++) ...[
              if (i > 0) pw.SizedBox(height: LakbayPdfTokens.spaceXs + 2),
              _buildLegendRow(
                theme,
                timelineBasisLabels.entries.elementAt(i),
              ),
            ],
          ],
        ),
      ),
    );

    // 5. Conflicts Card (only when conflicts exist)
    if (timeline.conflicts.isNotEmpty) {
      widgets.add(
        theme.sectionHeader(
          'Places that do not fit',
          accentColor: LakbayPdfTokens.cocoaOrange,
        ),
      );
      widgets.add(
        pw.Container(
          width: double.infinity,
          padding: const pw.EdgeInsets.all(LakbayPdfTokens.spaceMd),
          decoration: pw.BoxDecoration(
            color: LakbayPdfTokens.cocoaSoft,
            borderRadius: pw.BorderRadius.circular(LakbayPdfTokens.radiusCard),
            border: pw.Border.all(
              color: LakbayPdfTokens.cocoaBorder,
              width: 0.9,
            ),
          ),
          child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              for (final conflict in timeline.conflicts) ...[
                pw.Text(
                  theme.clean('• ${conflict.message}'),
                  style: theme.styleBody(bold: true),
                ),
                pw.SizedBox(height: LakbayPdfTokens.spaceXs),
              ],
              theme.divider(
                color: LakbayPdfTokens.cocoaBorder,
                verticalPadding: LakbayPdfTokens.spaceXs,
              ),
              pw.Text(
                theme.clean(
                  'Nothing has been removed. You can choose which places to keep, '
                  'change the time window, or change another limit.',
                ),
                style: theme.styleCaption(color: LakbayPdfTokens.textSecondary),
              ),
            ],
          ),
        ),
      );
    }

    // 6. Day-by-Day Timeline
    if (timeline.days.isNotEmpty) {
      widgets.add(
        theme.sectionHeader('Day-by-Day Schedule', trailing: daysText),
      );
    }
    for (final day in timeline.days) {
      widgets.add(pw.NewPage(freeSpace: 110));
      widgets.add(
        pw.Container(
          width: double.infinity,
          margin: const pw.EdgeInsets.only(bottom: LakbayPdfTokens.spaceSm),
          padding: const pw.EdgeInsets.symmetric(
            horizontal: LakbayPdfTokens.spaceMd,
            vertical: LakbayPdfTokens.spaceSm + 2,
          ),
          decoration: pw.BoxDecoration(
            color: LakbayPdfTokens.primarySoft,
            borderRadius: pw.BorderRadius.circular(LakbayPdfTokens.radiusCard),
            border: pw.Border.all(
              color: LakbayPdfTokens.cardBorder,
              width: 0.9,
            ),
          ),
          child: pw.Row(
            mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
            children: [
              pw.Expanded(
                child: pw.Text(
                  theme.clean(
                    day.date == null
                        ? 'Day ${day.day}'
                        : 'Day ${day.day} (${day.date})',
                  ),
                  style: theme.styleSectionTitle(
                    color: LakbayPdfTokens.tealDeep,
                  ),
                ),
              ),
              pw.Text(
                '${day.items.length} ${day.items.length == 1 ? 'item' : 'items'}',
                style: theme.styleCaption(color: LakbayPdfTokens.primaryDark),
              ),
            ],
          ),
        ),
      );
      for (final item in day.items) {
        widgets.add(_buildTimelineItemCard(theme, item));
      }
    }

    // 7. Verification Checks
    widgets.add(theme.sectionHeader('Verification Checks'));
    widgets.add(
      pw.Padding(
        padding: const pw.EdgeInsets.only(bottom: LakbayPdfTokens.spaceSm),
        child: pw.Text(
          theme.clean(
            'A check we cannot confirm is never counted as passed.',
          ),
          style: theme.styleCaption(color: LakbayPdfTokens.textSecondary),
        ),
      ),
    );
    for (final check in timeline.checks) {
      final style = _checkStyle(check.status);
      final titleText = timelineCheckTitles[check.id] ?? check.id;
      final statusText = timelineStatusText(check.status);
      widgets.add(
        pw.Container(
          width: double.infinity,
          margin: const pw.EdgeInsets.only(bottom: LakbayPdfTokens.spaceXs + 2),
          padding: const pw.EdgeInsets.symmetric(
            horizontal: LakbayPdfTokens.spaceMd,
            vertical: LakbayPdfTokens.spaceSm,
          ),
          decoration: pw.BoxDecoration(
            color: LakbayPdfTokens.surfaceWhite,
            borderRadius: pw.BorderRadius.circular(LakbayPdfTokens.radiusTile),
            border: pw.Border.all(
              color: LakbayPdfTokens.cardBorder,
              width: 0.8,
            ),
          ),
          child: pw.Row(
            crossAxisAlignment: pw.CrossAxisAlignment.center,
            children: [
              theme.statusBadge(
                statusText,
                background: style.bg,
                foreground: style.fg,
                borderColor: style.border,
              ),
              pw.SizedBox(width: LakbayPdfTokens.spaceSm),
              pw.Expanded(
                child: pw.Text(
                  theme.clean('$titleText: $statusText. ${check.message}'),
                  style: theme.styleBody(fontSize: 9.2),
                ),
              ),
            ],
          ),
        ),
      );
    }

    // 8. Budget Breakdown
    widgets.addAll(_buildBudgetSection(theme, budget));

    // 9. Planning Defaults
    if (timeline.assumptions.isNotEmpty) {
      widgets.add(theme.sectionHeader('Planning Defaults'));
      widgets.add(
        pw.Container(
          width: double.infinity,
          padding: const pw.EdgeInsets.all(LakbayPdfTokens.spaceMd),
          decoration: pw.BoxDecoration(
            color: LakbayPdfTokens.surfaceWhite,
            borderRadius: pw.BorderRadius.circular(LakbayPdfTokens.radiusCard),
            border: pw.Border.all(
              color: LakbayPdfTokens.cardBorder,
              width: 0.8,
            ),
          ),
          child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              for (var i = 0; i < timeline.assumptions.length; i++) ...[
                if (i > 0) pw.SizedBox(height: LakbayPdfTokens.spaceXs),
                pw.Text(
                  theme.clean('• ${timeline.assumptions[i]}'),
                  style: theme.styleBody(fontSize: 9.2),
                ),
              ],
            ],
          ),
        ),
      );
    }

    // 10. Honesty Disclaimer
    widgets.add(pw.SizedBox(height: LakbayPdfTokens.spaceLg));
    widgets.add(theme.divider());
    widgets.add(pw.SizedBox(height: LakbayPdfTokens.spaceSm));
    widgets.add(
      pw.Text(
        theme.clean(
          "Built from Lakbay's records on ${_date(now ?? DateTime.now())}. "
          'Anything marked Estimated, Provisional or Unknown has not been '
          'confirmed: check opening hours, prices and travel times before you go.',
        ),
        style: theme.styleCaption(color: LakbayPdfTokens.textMuted),
      ),
    );

    doc.addPage(
      pw.MultiPage(
        maxPages: 60,
        pageFormat: PdfPageFormat.a4,
        margin: LakbayPdfTokens.pageMargin,
        theme: theme.themeData,
        header: (context) => theme.runningHeader(context, title: title),
        footer: (context) => theme.runningFooter(context),
        build: (_) => widgets,
      ),
    );
    return doc.save();
  }

  static pw.Widget _buildLegendRow(
    LakbayPdfTheme theme,
    MapEntry<String, String> entry,
  ) {
    final style = _basisStyle(entry.key);
    final meaning = timelineBasisMeanings[entry.key] ?? '';
    return pw.Row(
      crossAxisAlignment: pw.CrossAxisAlignment.center,
      children: [
        theme.statusBadge(
          entry.value,
          background: style.bg,
          foreground: style.fg,
          borderColor: style.border,
        ),
        pw.SizedBox(width: LakbayPdfTokens.spaceSm),
        pw.Expanded(
          child: pw.Text(
            theme.clean('${entry.value}: $meaning'),
            style: theme.styleCaption(color: LakbayPdfTokens.textPrimary),
          ),
        ),
      ],
    );
  }

  static pw.Widget _buildTimelineItemCard(
    LakbayPdfTheme theme,
    TimelineItem item,
  ) {
    final range = item.timeRange ?? 'time unknown';
    final length =
        durationLabel(item.durationMinutes) ??
        (item.kind == 'travel' ? 'travel time unknown' : null);
    final basis = timelineBasisLabels[item.timeBasis] ?? item.timeBasis;
    final basisStyle = _basisStyle(item.timeBasis);
    final leg = item.travel;

    return pw.Container(
      width: double.infinity,
      margin: const pw.EdgeInsets.only(bottom: LakbayPdfTokens.spaceSm),
      padding: const pw.EdgeInsets.all(LakbayPdfTokens.spaceMd),
      decoration: pw.BoxDecoration(
        color: LakbayPdfTokens.surfaceWhite,
        borderRadius: pw.BorderRadius.circular(LakbayPdfTokens.radiusCard),
        border: pw.Border.all(color: LakbayPdfTokens.cardBorder, width: 0.8),
      ),
      child: pw.Row(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Container(
            width: 82,
            padding: const pw.EdgeInsets.symmetric(
              horizontal: LakbayPdfTokens.spaceXs + 2,
              vertical: LakbayPdfTokens.spaceXs,
            ),
            decoration: pw.BoxDecoration(
              color: LakbayPdfTokens.primarySoft,
              borderRadius: pw.BorderRadius.circular(LakbayPdfTokens.radiusTag),
            ),
            child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                pw.Text(
                  theme.clean(range),
                  style: theme.styleCaption(
                    color: LakbayPdfTokens.primaryDark,
                    bold: true,
                  ),
                ),
                if (length != null) ...[
                  pw.SizedBox(height: 2),
                  pw.Text(
                    theme.clean(length),
                    style: theme.styleMicro(
                      color: LakbayPdfTokens.textSecondary,
                      bold: false,
                    ),
                  ),
                ],
              ],
            ),
          ),
          pw.SizedBox(width: LakbayPdfTokens.spaceMd),
          pw.Expanded(
            child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                pw.Row(
                  crossAxisAlignment: pw.CrossAxisAlignment.start,
                  children: [
                    pw.Expanded(
                      child: pw.Text(
                        theme.clean(item.label),
                        style: item.kind == 'visit'
                            ? theme.styleCardTitle()
                            : theme.styleBody(bold: false),
                      ),
                    ),
                    pw.SizedBox(width: LakbayPdfTokens.spaceXs),
                    theme.statusBadge(
                      '[$basis]',
                      background: basisStyle.bg,
                      foreground: basisStyle.fg,
                      borderColor: basisStyle.border,
                    ),
                  ],
                ),
                if (leg != null) ...[
                  pw.SizedBox(height: LakbayPdfTokens.spaceXs + 2),
                  pw.Container(
                    width: double.infinity,
                    padding: const pw.EdgeInsets.symmetric(
                      horizontal: LakbayPdfTokens.spaceSm,
                      vertical: 3,
                    ),
                    decoration: pw.BoxDecoration(
                      color: LakbayPdfTokens.canvasBg,
                      borderRadius: pw.BorderRadius.circular(
                        LakbayPdfTokens.radiusTag,
                      ),
                    ),
                    child: pw.Text(
                      theme.clean(
                        'From ${leg.fromLabel} to ${leg.toLabel}: '
                        '${durationLabel(leg.minutes) ?? 'unknown time'} (${switch (leg.basis) {
                          'supported' => leg.routeVerified ? 'route-based' : 'route estimate',
                          'estimated' => 'estimated from straight-line distance',
                          _ => 'no travel time available',
                        }})',
                      ),
                      style: theme.styleCaption(
                        color: LakbayPdfTokens.textSecondary,
                      ),
                    ),
                  ),
                ],
                if (item.booking != null && item.booking!.isNotEmpty) ...[
                  pw.SizedBox(height: LakbayPdfTokens.spaceXs + 2),
                  pw.Container(
                    width: double.infinity,
                    padding: const pw.EdgeInsets.symmetric(
                      horizontal: LakbayPdfTokens.spaceSm,
                      vertical: 3,
                    ),
                    decoration: pw.BoxDecoration(
                      color: LakbayPdfTokens.cocoaSoft,
                      borderRadius: pw.BorderRadius.circular(
                        LakbayPdfTokens.radiusTag,
                      ),
                      border: pw.Border.all(
                        color: LakbayPdfTokens.cocoaBorder,
                        width: 0.5,
                      ),
                    ),
                    child: pw.Text(
                      theme.clean('Booking: ${item.booking}'),
                      style: theme.styleCaption(
                        color: LakbayPdfTokens.cocoaOrange,
                        bold: true,
                      ),
                    ),
                  ),
                ],
                for (final cost in item.costs) ...[
                  pw.SizedBox(height: LakbayPdfTokens.spaceXs),
                  pw.Text(
                    theme.clean(
                      'Cost — ${cost.label}: '
                      '${cost.amount == null ? 'unknown' : _money(cost.amount!) + (cost.scope == 'per_person' ? ' per person' : '')}'
                      '${cost.status == 'known' ? '' : ' (${cost.status})'}'
                      '${cost.includedIn == null ? '' : ', included in ${cost.includedIn}'}',
                    ),
                    style: theme.styleCaption(
                      color: cost.amount == null
                          ? LakbayPdfTokens.textMuted
                          : LakbayPdfTokens.textPrimary,
                    ),
                  ),
                ],
                for (final note in item.notes) ...[
                  pw.SizedBox(height: LakbayPdfTokens.spaceXs),
                  pw.Text(
                    theme.clean('Note: $note'),
                    style: theme.styleCaption(
                      color: LakbayPdfTokens.textSecondary,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  static List<pw.Widget> _buildBudgetSection(
    LakbayPdfTheme theme,
    TimelineBudget budget,
  ) {
    final fit = switch (budget.fit) {
      'fits_known_costs' => 'Within your budget, with every cost known.',
      'over_budget' => 'The costs we know already pass your budget.',
      _ => 'We cannot say yet whether it fits your budget.',
    };
    return [
      theme.sectionHeader('Budget Breakdown'),
      pw.Container(
        width: double.infinity,
        padding: const pw.EdgeInsets.all(LakbayPdfTokens.spaceMd),
        decoration: pw.BoxDecoration(
          color: LakbayPdfTokens.surfaceWhite,
          borderRadius: pw.BorderRadius.circular(LakbayPdfTokens.radiusCard),
          border: pw.Border.all(color: LakbayPdfTokens.cardBorder, width: 0.8),
        ),
        child: pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Text(
              theme.clean('Known: ${_money(budget.knownTotal)}'),
              style: theme.styleBody(),
            ),
            pw.SizedBox(height: 2),
            pw.Text(
              theme.clean('Estimated: ${_money(budget.estimatedTotal)}'),
              style: theme.styleBody(),
            ),
            pw.SizedBox(height: 2),
            pw.Text(
              theme.clean('Subtotal: ${_money(budget.subtotal)}'),
              style: theme.styleBody(bold: true),
            ),
            if (budget.totalBudget != null) ...[
              pw.SizedBox(height: 2),
              pw.Text(
                theme.clean('Your budget: ${_money(budget.totalBudget!)}'),
                style: theme.styleBody(),
              ),
            ],
            if (budget.remaining != null) ...[
              pw.SizedBox(height: 2),
              pw.Text(
                theme.clean('Remaining: ${_money(budget.remaining!)}'),
                style: theme.styleBody(
                  color: LakbayPdfTokens.primaryDark,
                  bold: true,
                ),
              ),
            ],
            theme.divider(verticalPadding: LakbayPdfTokens.spaceSm),
            pw.Text(
              theme.clean(fit),
              style: theme.styleBody(
                color: budget.fit == 'over_budget'
                    ? LakbayPdfTokens.error
                    : budget.fit == 'fits_known_costs'
                    ? LakbayPdfTokens.successGreen
                    : LakbayPdfTokens.textPrimary,
                bold: true,
              ),
            ),
            if (budget.unknown.isNotEmpty) ...[
              pw.SizedBox(height: LakbayPdfTokens.spaceSm),
              pw.Text(
                'Unknown costs (not in the subtotal):',
                style: theme.styleCaption(bold: true),
              ),
              for (final u in budget.unknown)
                pw.Text(
                  theme.clean('• $u'),
                  style: theme.styleCaption(color: LakbayPdfTokens.textPrimary),
                ),
            ],
            if (budget.unbased.isNotEmpty) ...[
              pw.SizedBox(height: LakbayPdfTokens.spaceSm),
              pw.Text(
                'Estimates with no recorded basis (not used to judge your budget):',
                style: theme.styleCaption(bold: true),
              ),
              for (final u in budget.unbased)
                pw.Text(
                  theme.clean('• $u'),
                  style: theme.styleCaption(color: LakbayPdfTokens.textPrimary),
                ),
            ],
            if (budget.toComplete.isNotEmpty) ...[
              pw.SizedBox(height: LakbayPdfTokens.spaceSm),
              pw.Text(
                'To complete the estimate:',
                style: theme.styleCaption(bold: true),
              ),
              for (final p in budget.toComplete)
                pw.Text(
                  theme.clean('• $p'),
                  style: theme.styleCaption(color: LakbayPdfTokens.textPrimary),
                ),
            ],
            if (budget.notes.isNotEmpty) ...[
              pw.SizedBox(height: LakbayPdfTokens.spaceSm),
              for (final note in budget.notes)
                pw.Text(
                  theme.clean(note),
                  style: theme.styleCaption(
                    color: LakbayPdfTokens.textSecondary,
                  ),
                ),
            ],
          ],
        ),
      ),
    ];
  }
}
