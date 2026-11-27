import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../models/travel_models.dart';
import 'pdf_design_tokens.dart';

/// Builds a flagship Lakbay+ trip dossier PDF on the phone from the trip
/// itself: no server, no sign-in, and no connection needed.
///
/// Preserves all honesty invariants: any cost, traveler count, or start date
/// that is not known says so explicitly and never invents zero/placeholder data.
class TripPdfBuilder {
  TripPdfBuilder._();

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

  static String _durationText(int minutes) {
    if (minutes <= 0) return '';
    if (minutes < 60) return '$minutes min';
    final hours = minutes ~/ 60;
    final rest = minutes % 60;
    return rest == 0 ? '$hours h' : '$hours h $rest min';
  }

  static String _capitalize(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) return '';
    return '${trimmed[0].toUpperCase()}${trimmed.substring(1)}';
  }

  static ({String label, PdfColor bg, PdfColor fg, PdfColor border})
  _statusStyle(String status) {
    return switch (status) {
      'completed' => (
        label: 'Completed',
        bg: LakbayPdfTokens.successSoft,
        fg: LakbayPdfTokens.successGreen,
        border: LakbayPdfTokens.successBorder,
      ),
      'ongoing' => (
        label: 'Ongoing',
        bg: LakbayPdfTokens.primaryLight,
        fg: LakbayPdfTokens.primaryDark,
        border: LakbayPdfTokens.cardBorder,
      ),
      'archived' => (
        label: 'Archived',
        bg: LakbayPdfTokens.canvasBg,
        fg: LakbayPdfTokens.textMuted,
        border: LakbayPdfTokens.cardBorder,
      ),
      _ => (
        label: 'Planned',
        bg: LakbayPdfTokens.bannerPillBg,
        fg: LakbayPdfTokens.white,
        border: LakbayPdfTokens.bannerPillBorder,
      ),
    };
  }

  static ({String label, PdfColor bg, PdfColor fg}) _categoryStyle(
    String category,
  ) {
    return switch (category) {
      'food' => (
        label: 'Food',
        bg: LakbayPdfTokens.cocoaSoft,
        fg: LakbayPdfTokens.cocoaOrange,
      ),
      'nature' => (
        label: 'Nature',
        bg: LakbayPdfTokens.successSoft,
        fg: LakbayPdfTokens.successGreen,
      ),
      'stay' => (
        label: 'Stay',
        bg: LakbayPdfTokens.primaryLight,
        fg: LakbayPdfTokens.primaryDark,
      ),
      _ => (
        label: 'Sight',
        bg: LakbayPdfTokens.primarySoft,
        fg: LakbayPdfTokens.primary,
      ),
    };
  }

  static Future<Uint8List> build(
    ItineraryTrip trip, {
    required double phpPerUsd,
    GeoPoint? origin,
    DateTime? now,
    bool compress = true,
  }) async {
    final theme = await LakbayPdfTokens.loadTheme();
    final doc = pw.Document(
      title: theme.clean(trip.title),
      author: 'Lakbay+',
      compress: compress,
    );

    final status = _statusStyle(trip.backendStatus);
    final widgets = <pw.Widget>[];

    // 1. Branded Hero Banner
    widgets.add(
      theme.heroBanner(
        title: trip.title,
        subtitle: '${trip.destination} • Lakbay+ Travel Dossier',
        statusLabel: status.label,
        statusBg: status.bg,
        statusFg: status.fg,
        statusBorder: status.border,
        pills: [
          if (trip.vibeTag.trim().isNotEmpty) trip.vibeTag,
          if (trip.pace.trim().isNotEmpty) '${_capitalize(trip.pace)} pace',
          if (trip.roundtrip) 'Roundtrip',
        ],
      ),
    );
    widgets.add(pw.SizedBox(height: LakbayPdfTokens.spaceMd));

    // 2. Summary KPI Cards Row
    final totalPhp = trip.hasCostEstimate
        ? _money(trip.totalEstimatedCostUsd * phpPerUsd)
        : null;
    widgets.add(
      theme.kpiRow([
        PdfKpiItem(
          label: 'Duration',
          value: '${trip.daysCount} ${trip.daysCount == 1 ? 'Day' : 'Days'}',
          subtitle: '${trip.days.expand((d) => d.stops).length} stops',
        ),
        PdfKpiItem(
          label: 'Schedule',
          value: trip.startDate != null
              ? 'Starts ${_date(trip.startDate!)}'
              : 'Start date: not set',
          subtitle: trip.endDate != null
              ? 'Ends ${_date(trip.endDate!)}'
              : null,
        ),
        PdfKpiItem(
          label: 'Travelers',
          value: trip.travelerCount != null
              ? 'Travelers: ${trip.travelerCount}'
              : 'Travelers: not set',
          subtitle: trip.adults != null && trip.children > 0
              ? '${trip.adults} adults, ${trip.children} children'
              : null,
        ),
        PdfKpiItem(
          label: 'Estimated Cost',
          value: totalPhp ?? 'Cost not listed',
          valueColor: totalPhp != null
              ? LakbayPdfTokens.primaryDark
              : LakbayPdfTokens.textSecondary,
          subtitle: trip.backendBudgetPhp != null
              ? 'Budget: ${_money(trip.backendBudgetPhp!)}'
              : null,
        ),
      ]),
    );

    // 3. Trip Metadata Strip
    final metadataFacts = <String>[
      if (origin != null) 'Starting from: ${origin.label}',
      if (trip.avgTemp.trim().isNotEmpty) 'Weather now: ${trip.avgTemp}',
      if (trip.bestMonths.trim().isNotEmpty) 'Best months: ${trip.bestMonths}',
      if ((trip.operatingHours ?? '').trim().isNotEmpty)
        'Hours: ${trip.operatingHours}',
      if ((trip.entranceFee ?? '').trim().isNotEmpty)
        'Entrance fee: ${trip.entranceFee}',
    ];
    if (metadataFacts.isNotEmpty) {
      widgets.add(pw.SizedBox(height: LakbayPdfTokens.spaceSm));
      widgets.add(
        pw.Container(
          width: double.infinity,
          padding: const pw.EdgeInsets.symmetric(
            horizontal: LakbayPdfTokens.spaceMd,
            vertical: LakbayPdfTokens.spaceSm + 2,
          ),
          decoration: pw.BoxDecoration(
            color: LakbayPdfTokens.primarySoft,
            borderRadius: pw.BorderRadius.circular(LakbayPdfTokens.radiusTile),
            border: pw.Border.all(
              color: LakbayPdfTokens.cardBorder,
              width: 0.8,
            ),
          ),
          child: pw.Wrap(
            spacing: LakbayPdfTokens.spaceLg,
            runSpacing: LakbayPdfTokens.spaceXs,
            children: [
              for (final fact in metadataFacts)
                pw.Text(
                  theme.clean(fact),
                  style: theme.styleCaption(
                    color: LakbayPdfTokens.textPrimary,
                    bold: false,
                  ),
                ),
            ],
          ),
        ),
      );
    }

    // 4. Overview & Route Optimization Card
    final hasOverview = trip.overviewText.trim().isNotEmpty;
    final opt = trip.optimizationSummary;
    if (hasOverview || opt != null || trip.routeWarnings.isNotEmpty) {
      widgets.add(theme.sectionHeader('Overview & Cost Summary'));
      if (hasOverview) {
        final paragraphs = theme
            .clean(trip.overviewText)
            .split('\n')
            .where((p) => p.trim().isNotEmpty)
            .toList();
        if (trip.overviewText.length <= 1200 && paragraphs.length <= 4) {
          widgets.add(
            pw.Container(
              width: double.infinity,
              padding: const pw.EdgeInsets.all(LakbayPdfTokens.spaceMd),
              decoration: pw.BoxDecoration(
                color: LakbayPdfTokens.surfaceWhite,
                borderRadius: pw.BorderRadius.circular(
                  LakbayPdfTokens.radiusCard,
                ),
                border: pw.Border.all(
                  color: LakbayPdfTokens.cardBorder,
                  width: 0.8,
                ),
              ),
              child: pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  for (var i = 0; i < paragraphs.length; i++) ...[
                    if (i > 0) pw.SizedBox(height: LakbayPdfTokens.spaceXs + 2),
                    pw.Text(paragraphs[i], style: theme.styleBody()),
                  ],
                ],
              ),
            ),
          );
        } else {
          for (final para in paragraphs) {
            widgets.add(
              pw.Padding(
                padding: const pw.EdgeInsets.only(
                  bottom: LakbayPdfTokens.spaceXs + 2,
                ),
                child: pw.Text(para, style: theme.styleBody()),
              ),
            );
          }
        }
      }
      if (opt != null) {
        widgets.add(pw.SizedBox(height: LakbayPdfTokens.spaceSm));
        widgets.add(
          pw.Container(
            width: double.infinity,
            padding: const pw.EdgeInsets.symmetric(
              horizontal: LakbayPdfTokens.spaceMd,
              vertical: LakbayPdfTokens.spaceSm + 2,
            ),
            decoration: pw.BoxDecoration(
              color: LakbayPdfTokens.successSoft,
              borderRadius: pw.BorderRadius.circular(
                LakbayPdfTokens.radiusTile,
              ),
              border: pw.Border.all(
                color: LakbayPdfTokens.successBorder,
                width: 0.8,
              ),
            ),
            child: pw.Row(
              mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
              children: [
                pw.Expanded(
                  child: pw.Text(
                    theme.clean(opt.savingsHeadline),
                    style: theme.styleCaption(
                      color: LakbayPdfTokens.successGreen,
                      bold: true,
                    ),
                  ),
                ),
                pw.SizedBox(width: LakbayPdfTokens.spaceSm),
                pw.Text(
                  theme.clean(opt.sourceLabel),
                  style: theme.styleMicro(color: LakbayPdfTokens.textSecondary),
                ),
              ],
            ),
          ),
        );
      }
      if (trip.routeWarnings.isNotEmpty) {
        widgets.add(pw.SizedBox(height: LakbayPdfTokens.spaceSm));
        widgets.add(
          pw.Container(
            width: double.infinity,
            padding: const pw.EdgeInsets.all(LakbayPdfTokens.spaceMd),
            decoration: pw.BoxDecoration(
              color: LakbayPdfTokens.warningSoft,
              borderRadius: pw.BorderRadius.circular(
                LakbayPdfTokens.radiusTile,
              ),
              border: pw.Border.all(
                color: LakbayPdfTokens.warningBorder,
                width: 0.8,
              ),
            ),
            child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                for (final warning in trip.routeWarnings)
                  pw.Padding(
                    padding: const pw.EdgeInsets.only(bottom: 2),
                    child: pw.Text(
                      theme.clean('• $warning'),
                      style: theme.styleCaption(
                        color: LakbayPdfTokens.warning,
                        bold: true,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      }
    }

    // 5. Day-by-Day Timeline
    if (trip.days.isNotEmpty) {
      widgets.add(
        theme.sectionHeader(
          'Day-by-Day Itinerary',
          trailing:
              '${trip.days.length} ${trip.days.length == 1 ? 'day' : 'days'}',
        ),
      );
    }

    for (final day in trip.days) {
      // Prevent orphaned day headers near the bottom of a page.
      widgets.add(pw.NewPage(freeSpace: 110));
      widgets.add(_buildDayHeaderCard(theme, day));
      widgets.add(pw.SizedBox(height: LakbayPdfTokens.spaceSm));

      if (day.stops.isEmpty) {
        widgets.add(
          pw.Container(
            width: double.infinity,
            margin: const pw.EdgeInsets.only(bottom: LakbayPdfTokens.spaceSm),
            padding: const pw.EdgeInsets.all(LakbayPdfTokens.spaceMd),
            decoration: pw.BoxDecoration(
              color: LakbayPdfTokens.surfaceWhite,
              borderRadius: pw.BorderRadius.circular(
                LakbayPdfTokens.radiusCard,
              ),
              border: pw.Border.all(
                color: LakbayPdfTokens.cardBorder,
                width: 0.8,
              ),
            ),
            child: pw.Text(
              'No stops planned for this day.',
              style: theme.styleBody(color: LakbayPdfTokens.textSecondary),
            ),
          ),
        );
      } else {
        for (final stop in day.stops) {
          widgets.add(_buildStopCard(theme, stop, phpPerUsd));
        }
      }

      final hotel = day.recommendedHotel;
      if (hotel != null) {
        widgets.add(_buildHotelCard(theme, hotel, prefix: 'Day stay: '));
      }
      widgets.add(pw.SizedBox(height: LakbayPdfTokens.spaceSm));
    }

    // 6. Stays Section
    if (trip.hotels.isNotEmpty) {
      widgets.add(theme.sectionHeader('Recommended Stays'));
      for (final hotel in trip.hotels) {
        widgets.add(_buildHotelCard(theme, hotel));
      }
    }

    // 7. Advisories ("Good to know")
    if (trip.advisories.isNotEmpty) {
      widgets.add(
        theme.sectionHeader(
          'Good to Know',
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
              width: 0.8,
            ),
          ),
          child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              for (var i = 0; i < trip.advisories.length; i++) ...[
                if (i > 0) pw.SizedBox(height: LakbayPdfTokens.spaceXs),
                pw.Text(
                  theme.clean('• ${trip.advisories[i]}'),
                  style: theme.styleBody(color: LakbayPdfTokens.textPrimary),
                ),
              ],
            ],
          ),
        ),
      );
    }

    // 8. Packing ("What to bring")
    if ((trip.whatToBring ?? '').trim().isNotEmpty) {
      widgets.add(theme.sectionHeader('What to Bring'));
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
          child: pw.Text(
            theme.clean(trip.whatToBring!),
            style: theme.styleBody(),
          ),
        ),
      );
    }

    // 9. Document Disclaimer
    widgets.add(pw.SizedBox(height: LakbayPdfTokens.spaceLg));
    widgets.add(theme.divider());
    widgets.add(pw.SizedBox(height: LakbayPdfTokens.spaceSm));
    widgets.add(
      pw.Text(
        theme.clean(
          'Made with Lakbay+ on ${_date(now ?? DateTime.now())}. Times, prices '
          'and forecasts can change; check before you go.',
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
        header: (context) => theme.runningHeader(context, title: trip.title),
        footer: (context) => theme.runningFooter(context),
        build: (_) => widgets,
      ),
    );
    return doc.save();
  }

  static pw.Widget _buildDayHeaderCard(LakbayPdfTheme theme, ItineraryDay day) {
    final transport = day.transportFromPrevious;
    final transportLine = transport != null
        ? 'Transfer: ${_capitalize(transport.name)}'
              '${(day.transportDuration ?? '').trim().isNotEmpty ? ' • ${day.transportDuration}' : ''}'
        : null;

    return pw.Container(
      width: double.infinity,
      padding: const pw.EdgeInsets.all(LakbayPdfTokens.spaceMd),
      decoration: pw.BoxDecoration(
        color: LakbayPdfTokens.primarySoft,
        borderRadius: pw.BorderRadius.circular(LakbayPdfTokens.radiusCard),
        border: pw.Border.all(color: LakbayPdfTokens.cardBorder, width: 0.9),
      ),
      child: pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Row(
            crossAxisAlignment: pw.CrossAxisAlignment.center,
            children: [
              pw.Expanded(
                child: pw.Text(
                  theme.clean('Day ${day.dayNumber}: ${day.cityTitle}'),
                  style: theme.styleSectionTitle(
                    color: LakbayPdfTokens.tealDeep,
                  ),
                ),
              ),
              if (day.isContinuationDay) ...[
                pw.SizedBox(width: LakbayPdfTokens.spaceXs),
                theme.statusBadge(
                  'Continuation',
                  background: LakbayPdfTokens.surfaceWhite,
                  foreground: LakbayPdfTokens.primaryDark,
                  borderColor: LakbayPdfTokens.cardBorder,
                ),
              ],
              if (day.tempCelsius != null) ...[
                pw.SizedBox(width: LakbayPdfTokens.spaceXs),
                theme.statusBadge(
                  '${day.tempCelsius}°C',
                  background: LakbayPdfTokens.surfaceWhite,
                  foreground: LakbayPdfTokens.primaryDark,
                  borderColor: LakbayPdfTokens.cardBorder,
                ),
              ],
            ],
          ),
          if (day.summary.trim().isNotEmpty) ...[
            pw.SizedBox(height: LakbayPdfTokens.spaceXs),
            pw.Text(
              theme.clean(day.summary),
              style: theme.styleCaption(color: LakbayPdfTokens.textSecondary),
            ),
          ],
          if (transportLine != null) ...[
            pw.SizedBox(height: LakbayPdfTokens.spaceXs),
            pw.Text(
              theme.clean(transportLine),
              style: theme.styleCaption(
                color: LakbayPdfTokens.primaryDark,
                bold: true,
              ),
            ),
          ],
          if ((day.overloadWarning ?? '').trim().isNotEmpty) ...[
            pw.SizedBox(height: LakbayPdfTokens.spaceXs + 2),
            pw.Container(
              width: double.infinity,
              padding: const pw.EdgeInsets.symmetric(
                horizontal: LakbayPdfTokens.spaceSm,
                vertical: LakbayPdfTokens.spaceXs,
              ),
              decoration: pw.BoxDecoration(
                color: LakbayPdfTokens.warningSoft,
                borderRadius: pw.BorderRadius.circular(
                  LakbayPdfTokens.radiusTag,
                ),
                border: pw.Border.all(
                  color: LakbayPdfTokens.warningBorder,
                  width: 0.6,
                ),
              ),
              child: pw.Text(
                theme.clean(day.overloadWarning!),
                style: theme.styleCaption(
                  color: LakbayPdfTokens.warning,
                  bold: true,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  static pw.Widget _buildStopCard(
    LakbayPdfTheme theme,
    ItineraryStop stop,
    double phpPerUsd,
  ) {
    final category = _categoryStyle(stop.category);
    final costLabel = stop.costEstimateUsd > 0
        ? _money(stop.costEstimateUsd * phpPerUsd)
        : 'Cost not listed';

    final minutes = stop.travelFromPrevMinutes;
    final km = stop.travelFromPrevKm;
    final hasLeg = (minutes != null && minutes > 0) || stop.isSeaCrossingFromPrev;
    final legParts = <String>[
      if (minutes != null && minutes > 0) _durationText(minutes),
      if (km != null && km > 0) '${km.toStringAsFixed(1)} km',
      if (stop.travelFromPrevMode != null)
        _capitalize(stop.travelFromPrevMode!.name),
      if (stop.isSeaCrossingFromPrev) 'Sea crossing',
    ];

    final desc = theme.clean(stop.description.trim());

    // Keep typical stop cards atomic in a single Container; if an unusually
    // huge description (>1600 chars) appears, split overflow paragraphs outside
    // the header card so MultiPage never throws PdfException.
    final isOversizedDesc = desc.length > 1600;
    final headerAndShortDesc = pw.Container(
      width: double.infinity,
      margin: const pw.EdgeInsets.only(bottom: LakbayPdfTokens.spaceSm),
      padding: const pw.EdgeInsets.all(LakbayPdfTokens.spaceMd),
      decoration: pw.BoxDecoration(
        color: LakbayPdfTokens.surfaceWhite,
        borderRadius: pw.BorderRadius.circular(LakbayPdfTokens.radiusCard),
        border: pw.Border.all(color: LakbayPdfTokens.cardBorder, width: 0.8),
      ),
      child: pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          if (hasLeg && legParts.isNotEmpty) ...[
            pw.Container(
              width: double.infinity,
              margin: const pw.EdgeInsets.only(bottom: LakbayPdfTokens.spaceSm),
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
                theme.clean('Getting here: ${legParts.join(' • ')}'),
                style: theme.styleCaption(color: LakbayPdfTokens.textSecondary),
              ),
            ),
          ],
          pw.Row(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Container(
                width: 66,
                padding: const pw.EdgeInsets.symmetric(
                  horizontal: LakbayPdfTokens.spaceXs + 2,
                  vertical: LakbayPdfTokens.spaceXs,
                ),
                decoration: pw.BoxDecoration(
                  color: LakbayPdfTokens.primaryLight,
                  borderRadius: pw.BorderRadius.circular(
                    LakbayPdfTokens.radiusTag,
                  ),
                ),
                child: pw.Text(
                  theme.clean(stop.time),
                  textAlign: pw.TextAlign.center,
                  style: theme.styleCaption(
                    color: LakbayPdfTokens.primaryDark,
                    bold: true,
                  ),
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
                            theme.clean(stop.title),
                            style: theme.styleCardTitle(),
                          ),
                        ),
                        pw.SizedBox(width: LakbayPdfTokens.spaceXs),
                        theme.statusBadge(
                          category.label,
                          background: category.bg,
                          foreground: category.fg,
                        ),
                        pw.SizedBox(width: LakbayPdfTokens.spaceXs),
                        theme.statusBadge(
                          costLabel,
                          background: stop.costEstimateUsd > 0
                              ? LakbayPdfTokens.primarySoft
                              : LakbayPdfTokens.canvasBg,
                          foreground: stop.costEstimateUsd > 0
                              ? LakbayPdfTokens.primaryDark
                              : LakbayPdfTokens.textSecondary,
                          borderColor: LakbayPdfTokens.cardBorder,
                        ),
                      ],
                    ),
                    if (desc.isNotEmpty && !isOversizedDesc) ...[
                      pw.SizedBox(height: LakbayPdfTokens.spaceXs),
                      pw.Text(
                        desc,
                        style: theme.styleBody(
                          color: LakbayPdfTokens.textSecondary,
                          fontSize: 9.2,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );

    if (!isOversizedDesc) return headerAndShortDesc;

    final chunks = <String>[];
    for (var start = 0; start < desc.length; start += 900) {
      final end = (start + 900).clamp(0, desc.length);
      chunks.add(desc.substring(start, end));
    }
    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        headerAndShortDesc,
        for (final chunk in chunks)
          pw.Padding(
            padding: const pw.EdgeInsets.only(
              left: LakbayPdfTokens.spaceMd,
              right: LakbayPdfTokens.spaceMd,
              bottom: LakbayPdfTokens.spaceXs,
            ),
            child: pw.Text(
              chunk,
              style: theme.styleBody(
                color: LakbayPdfTokens.textSecondary,
                fontSize: 9.2,
              ),
            ),
          ),
      ],
    );
  }

  static pw.Widget _buildHotelCard(
    LakbayPdfTheme theme,
    HotelOffer hotel, {
    String prefix = '',
  }) {
    final unit = hotel.chargingUnitLabel ?? hotel.chargingUnit;
    final priceText = hotel.pricePhp != null
        ? '${_money(hotel.pricePhp!)}${unit != null && unit.isNotEmpty ? ' $unit' : ''}'
        : 'price not listed';

    return pw.Container(
      width: double.infinity,
      margin: const pw.EdgeInsets.only(bottom: LakbayPdfTokens.spaceSm),
      padding: const pw.EdgeInsets.symmetric(
        horizontal: LakbayPdfTokens.spaceMd,
        vertical: LakbayPdfTokens.spaceSm + 2,
      ),
      decoration: pw.BoxDecoration(
        color: LakbayPdfTokens.surfaceWhite,
        borderRadius: pw.BorderRadius.circular(LakbayPdfTokens.radiusTile),
        border: pw.Border.all(color: LakbayPdfTokens.cardBorder, width: 0.8),
      ),
      child: pw.Row(
        crossAxisAlignment: pw.CrossAxisAlignment.center,
        children: [
          pw.Expanded(
            child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                pw.Text(
                  theme.clean('$prefix${hotel.name}'),
                  style: theme.styleCardTitle(),
                ),
                if (hotel.city.trim().isNotEmpty)
                  pw.Text(
                    theme.clean(hotel.city),
                    style: theme.styleCaption(
                      color: LakbayPdfTokens.textSecondary,
                    ),
                  ),
              ],
            ),
          ),
          pw.SizedBox(width: LakbayPdfTokens.spaceSm),
          theme.statusBadge(
            priceText,
            background: hotel.pricePhp != null
                ? LakbayPdfTokens.primarySoft
                : LakbayPdfTokens.canvasBg,
            foreground: hotel.pricePhp != null
                ? LakbayPdfTokens.primaryDark
                : LakbayPdfTokens.textSecondary,
            borderColor: LakbayPdfTokens.cardBorder,
          ),
        ],
      ),
    );
  }
}
