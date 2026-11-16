import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../models/travel_models.dart';
import 'route_summary.dart';

/// Builds a trip PDF on the phone from the trip itself: no server, no sign-in
/// and no connection needed.
///
/// Only what the trip really holds is printed. A cost, weather or traveler
/// count that is not known says so. The built-in PDF font has no peso sign, so
/// amounts are written as "PHP".
class TripPdfBuilder {
  TripPdfBuilder._();

  static String _money(double php) => 'PHP ${php.round()}';

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
      .replaceAll(RegExp(r'[‘’]'), "'")
      .replaceAll(RegExp(r'[“”]'), '"')
      .replaceAll(RegExp(r'[–—]'), '-')
      .replaceAll('•', '-')
      .replaceAll('°', ' deg')
      .replaceAll(RegExp(r'[^\x20-\x7E\n]'), '');

  static Future<Uint8List> build(
    ItineraryTrip trip, {
    required double phpPerUsd,
    GeoPoint? origin,
    DateTime? now,
    bool compress = true,
  }) async {
    final doc = pw.Document(
      title: _safe(trip.title),
      author: 'Lakbay+',
      compress: compress,
    );
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
    pw.Widget body(String t, {double size = 10.5}) => pw.Padding(
      padding: const pw.EdgeInsets.only(bottom: 3),
      child: pw.Text(_safe(t), style: pw.TextStyle(fontSize: size)),
    );

    widgets.add(h1(trip.title));
    widgets.add(body('Lakbay+ itinerary - ${trip.destination}', size: 11));
    widgets.add(pw.SizedBox(height: 6));

    final facts = <String>[
      'Days: ${trip.daysCount}',
      trip.startDate != null
          ? 'Starts: ${_date(trip.startDate!)}'
          : 'Start date: not set',
      trip.travelerCount != null
          ? 'Travelers: ${trip.travelerCount}'
          : 'Travelers: not set',
      if (origin != null) 'Starting from: ${origin.label}',
      if (trip.avgTemp.trim().isNotEmpty) 'Weather now: ${trip.avgTemp}',
    ];
    for (final fact in facts) {
      widgets.add(body(fact));
    }

    if (trip.overviewText.trim().isNotEmpty) {
      widgets.add(h2('Overview'));
      widgets.add(body(trip.overviewText));
    }

    widgets.add(h2('Cost'));
    if (trip.hasCostEstimate) {
      widgets.add(
        body('Estimated total: ${_money(trip.totalEstimatedCostUsd * phpPerUsd)}'),
      );
    } else {
      widgets.add(body('Cost not listed for this trip.'));
    }
    if (trip.backendBudgetPhp != null) {
      widgets.add(body('Budget: ${_money(trip.backendBudgetPhp!)}'));
    }

    for (final day in trip.days) {
      widgets.add(h2('Day ${day.dayNumber}: ${day.cityTitle}'));
      if (day.summary.trim().isNotEmpty) widgets.add(body(day.summary));
      if (day.tempCelsius != null) {
        widgets.add(body('Forecast: ${day.tempCelsius} deg C'));
      }
      if (day.stops.isEmpty) {
        widgets.add(body('No stops planned for this day.'));
      }
      for (final stop in day.stops) {
        final cost = stop.costEstimateUsd > 0
            ? _money(stop.costEstimateUsd * phpPerUsd)
            : 'cost not listed';
        widgets.add(
          pw.Padding(
            padding: const pw.EdgeInsets.only(top: 4),
            child: pw.Text(
              _safe('${stop.time}  ${stop.title}  ($cost)'),
              style: pw.TextStyle(fontSize: 11, fontWeight: pw.FontWeight.bold),
            ),
          ),
        );
        if (stop.description.trim().isNotEmpty) {
          widgets.add(body(stop.description, size: 10));
        }
        final minutes = stop.travelFromPrevMinutes;
        final km = stop.travelFromPrevKm;
        if (minutes != null && minutes > 0) {
          widgets.add(
            body(
              'Getting here: ${RouteSummaryText.durationText(minutes)}'
              '${km != null && km > 0 ? ', ${km.toStringAsFixed(1)} km' : ''}'
              '${stop.travelFromPrevMode != null ? ' (${stop.travelFromPrevMode})' : ''}',
              size: 9.5,
            ),
          );
        }
      }
      final hotel = day.recommendedHotel;
      if (hotel != null) {
        widgets.add(
          body(
            'Stay: ${hotel.name}'
            '${hotel.pricePhp != null ? ' - ${_money(hotel.pricePhp!)}'
                '${hotel.chargingUnit != null ? ' ${hotel.chargingUnit}' : ''}' : ' - price not listed'}',
          ),
        );
      }
    }

    if (trip.hotels.isNotEmpty) {
      widgets.add(h2('Stays'));
      for (final hotel in trip.hotels) {
        widgets.add(
          body(
            '${hotel.name} - ${hotel.pricePhp != null ? _money(hotel.pricePhp!) : 'price not listed'}'
            '${hotel.pricePhp != null && hotel.chargingUnit != null ? ' ${hotel.chargingUnit}' : ''}',
          ),
        );
      }
    }

    if (trip.advisories.isNotEmpty) {
      widgets.add(h2('Good to know'));
      for (final note in trip.advisories) {
        widgets.add(body('- $note'));
      }
    }
    if ((trip.whatToBring ?? '').trim().isNotEmpty) {
      widgets.add(h2('What to bring'));
      widgets.add(body(trip.whatToBring!));
    }

    widgets.add(pw.SizedBox(height: 18));
    widgets.add(
      body(
        'Made with Lakbay+ on ${_date(now ?? DateTime.now())}. Times, prices and '
        'forecasts can change; check before you go.',
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
}
