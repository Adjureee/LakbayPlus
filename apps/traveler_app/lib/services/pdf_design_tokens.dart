import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/material.dart' show Color, ColorScheme;
import 'package:flutter/services.dart' show ByteData, rootBundle;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../core/plain_words.dart';
import '../core/theme/app_theme.dart';
import '../core/timeline_labels.dart';
import '../theme/lakbay_theme.dart';

class _CachedPdfAssets {
  const _CachedPdfAssets({
    required this.regularFontBytes,
    required this.boldFontBytes,
    required this.supportedRunes,
    required this.markSvg,
  });

  final ByteData regularFontBytes;
  final ByteData boldFontBytes;
  final Set<int> supportedRunes;
  final String? markSvg;
}

/// Canonical Lakbay+ design tokens for exported PDF dossiers.
///
/// All colors map directly from [LakbayColors] and [AppTheme] without
/// duplicating hex literals. Uses `Inter-Regular.ttf` and `Inter-Bold.ttf`
/// (verified TrueType `glyf`/`loca` fonts with full `₱`, `ñ`, `°`, `—` support).
class LakbayPdfTokens {
  LakbayPdfTokens._();

  static PdfColor fromColor(Color color) => PdfColor.fromInt(color.toARGB32());

  static PdfColor alphaBlend(
    PdfColor foreground,
    PdfColor background,
    double alpha,
  ) => foreground.withAlpha(alpha).flatten(background: background);

  // Core Brand Palette (from LakbayColors & AppTheme)
  static final PdfColor primary = fromColor(LakbayColors.primary);
  static final PdfColor primaryDark = fromColor(LakbayColors.primaryDark);
  static final PdfColor primaryLight = fromColor(LakbayColors.primaryLight);
  static final PdfColor primarySoft = fromColor(LakbayColors.primarySoft);
  static final PdfColor tealDeep = fromColor(LakbayColors.tealDeep);
  static final PdfColor tealAccent = fromColor(LakbayColors.tealAccent);
  static final PdfColor tealWash = fromColor(LakbayColors.tealWash);
  static final PdfColor cocoaOrange = fromColor(LakbayColors.cocoaOrange);
  static final PdfColor canvasBg = fromColor(LakbayColors.canvasBg);
  static final PdfColor surfaceWhite = fromColor(LakbayColors.surfaceWhite);
  static final PdfColor cardBorder = fromColor(LakbayColors.cardBorder);
  static final PdfColor textPrimary = fromColor(LakbayColors.textPrimary);
  static final PdfColor textSecondary = fromColor(LakbayColors.textSecondary);
  static final PdfColor textMuted = fromColor(LakbayColors.textMuted);
  static final PdfColor successGreen = fromColor(LakbayColors.successGreen);
  static final PdfColor warning = fromColor(AppTheme.warning);
  static final PdfColor error = fromColor(
    ColorScheme.fromSeed(
      seedColor: LakbayColors.primary,
      primary: LakbayColors.primary,
      secondary: LakbayColors.cocoaOrange,
      surface: LakbayColors.surfaceWhite,
    ).error,
  );
  static final PdfColor white = fromColor(AppTheme.onPrimary);

  // Derived Tints (blended onto surfaceWhite / tealDeep for crisp print contrast)
  static final PdfColor cocoaSoft = alphaBlend(cocoaOrange, surfaceWhite, 0.10);
  static final PdfColor cocoaBorder = alphaBlend(
    cocoaOrange,
    surfaceWhite,
    0.32,
  );
  static final PdfColor successSoft = alphaBlend(
    successGreen,
    surfaceWhite,
    0.10,
  );
  static final PdfColor successBorder = alphaBlend(
    successGreen,
    surfaceWhite,
    0.30,
  );
  static final PdfColor warningSoft = alphaBlend(warning, surfaceWhite, 0.10);
  static final PdfColor warningBorder = alphaBlend(warning, surfaceWhite, 0.30);
  static final PdfColor errorSoft = alphaBlend(error, surfaceWhite, 0.08);
  static final PdfColor errorBorder = alphaBlend(error, surfaceWhite, 0.28);
  static final PdfColor bannerMutedText = alphaBlend(white, tealDeep, 0.84);
  static final PdfColor bannerPillBg = alphaBlend(white, tealDeep, 0.14);
  static final PdfColor bannerPillBorder = alphaBlend(white, tealDeep, 0.28);

  // Brand Gradients (mirroring LakbayColors)
  static final pw.LinearGradient brandGradient = pw.LinearGradient(
    colors: [primary, tealAccent],
    begin: pw.Alignment.topLeft,
    end: pw.Alignment.bottomRight,
  );

  static final pw.LinearGradient deepTealGradient = pw.LinearGradient(
    colors: [tealDeep, primaryDark],
    begin: pw.Alignment.topLeft,
    end: pw.Alignment.bottomRight,
  );

  // Spacing Scale (4, 8, 12, 16, 20, 24)
  static const double spaceXs = 4.0;
  static const double spaceSm = 8.0;
  static const double spaceMd = 12.0;
  static const double spaceLg = 16.0;
  static const double spaceXl = 20.0;
  static const double spaceXxl = 24.0;

  static const pw.EdgeInsets pageMargin = pw.EdgeInsets.fromLTRB(
    32,
    28,
    32,
    28,
  );

  // Corner Radii Scale (7, 12, 14, 18, 20)
  static const double radiusTag = 7.0;
  static const double radiusTile = 12.0;
  static const double radiusCard = 14.0;
  static const double radiusBanner = 18.0;
  static const double radiusPill = 20.0;

  // Typography Sizes (harmonized with AppTheme.textTheme for A4 print)
  static const double fontHero = 20.0;
  static const double fontSection = 13.0;
  static const double fontCardTitle = 10.8;
  static const double fontBody = 9.5;
  static const double fontCaption = 8.4;
  static const double fontMicro = 7.6;

  static const String _interRegularAsset = 'assets/fonts/Inter-Regular.ttf';
  static const String _interBoldAsset = 'assets/fonts/Inter-Bold.ttf';
  static const String _markSvgAsset = 'assets/brand/lakbay_mark.svg';

  static Future<_CachedPdfAssets>? _cached;

  @visibleForTesting
  static void resetCache() {
    _cached = null;
  }

  static Future<_CachedPdfAssets> _loadAssets() async {
    final regularBytes = await rootBundle.load(_interRegularAsset);
    final boldBytes = await rootBundle.load(_interBoldAsset);
    String? markSvg;
    try {
      markSvg = await rootBundle.loadString(_markSvgAsset);
    } catch (_) {
      markSvg = null;
    }

    final regularRunes = TtfParser(
      regularBytes,
    ).charToGlyphIndexMap.keys.toSet();
    final boldRunes = TtfParser(boldBytes).charToGlyphIndexMap.keys.toSet();
    final supported = regularRunes.intersection(boldRunes);

    return _CachedPdfAssets(
      regularFontBytes: regularBytes,
      boldFontBytes: boldBytes,
      supportedRunes: supported,
      markSvg: markSvg,
    );
  }

  /// Loads cached font bytes and instantiates fresh [pw.Font] objects per
  /// document build so mutable `_pdfFont` state never leaks across PDFs.
  static Future<LakbayPdfTheme> loadTheme() async {
    final cached = await (_cached ??= _loadAssets());
    final regular = pw.Font.ttf(cached.regularFontBytes);
    final bold = pw.Font.ttf(cached.boldFontBytes);
    return LakbayPdfTheme._(
      regularFont: regular,
      boldFont: bold,
      supportedRunes: cached.supportedRunes,
      markSvg: cached.markSvg,
    );
  }

  static String moneyPhp(double php) => pesoText(php);
}

class PdfKpiItem {
  const PdfKpiItem({
    required this.label,
    required this.value,
    this.subtitle,
    this.valueColor,
  });

  final String label;
  final String value;
  final String? subtitle;
  final PdfColor? valueColor;
}

class LakbayPdfTheme {
  LakbayPdfTheme._({
    required this.regularFont,
    required this.boldFont,
    required this.supportedRunes,
    required this.markSvg,
  }) : themeData = pw.ThemeData.withFont(
         base: regularFont,
         bold: boldFont,
         italic: regularFont,
         boldItalic: boldFont,
         fontFallback: [regularFont, boldFont],
       );

  final pw.Font regularFont;
  final pw.Font boldFont;
  final Set<int> supportedRunes;
  final String? markSvg;
  final pw.ThemeData themeData;

  /// Strips control characters and glyphs unsupported by Inter (such as color
  /// emojis) while preserving `₱`, `ñ`, `Ñ`, `°`, `—`, `–`, `•`, `·`, curly
  /// quotes, `→`, `✓`, `…`, `≈`, and `\n`.
  String clean(String input) {
    if (input.isEmpty) return '';
    final normalized = input
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n')
        .replaceAll('\t', '  ');
    final buf = StringBuffer();
    final newline = '\n'.codeUnitAt(0);
    final space = ' '.codeUnitAt(0);
    for (final rune in normalized.runes) {
      if (rune == newline) {
        buf.writeCharCode(rune);
        continue;
      }
      if (rune < space || rune == 127) {
        continue;
      }
      if (supportedRunes.contains(rune)) {
        buf.writeCharCode(rune);
      }
    }
    return buf.toString();
  }

  pw.TextStyle styleHeroTitle({PdfColor? color}) => pw.TextStyle(
    font: boldFont,
    fontBold: boldFont,
    fontFallback: [regularFont, boldFont],
    fontSize: LakbayPdfTokens.fontHero,
    fontWeight: pw.FontWeight.bold,
    color: color ?? LakbayPdfTokens.white,
    lineSpacing: 2.5,
  );

  pw.TextStyle styleSectionTitle({PdfColor? color}) => pw.TextStyle(
    font: boldFont,
    fontBold: boldFont,
    fontFallback: [regularFont, boldFont],
    fontSize: LakbayPdfTokens.fontSection,
    fontWeight: pw.FontWeight.bold,
    color: color ?? LakbayPdfTokens.textPrimary,
  );

  pw.TextStyle styleCardTitle({PdfColor? color}) => pw.TextStyle(
    font: boldFont,
    fontBold: boldFont,
    fontFallback: [regularFont, boldFont],
    fontSize: LakbayPdfTokens.fontCardTitle,
    fontWeight: pw.FontWeight.bold,
    color: color ?? LakbayPdfTokens.textPrimary,
    lineSpacing: 1.5,
  );

  pw.TextStyle styleBody({
    PdfColor? color,
    bool bold = false,
    double? fontSize,
  }) => pw.TextStyle(
    font: bold ? boldFont : regularFont,
    fontNormal: regularFont,
    fontBold: boldFont,
    fontFallback: [regularFont, boldFont],
    fontSize: fontSize ?? LakbayPdfTokens.fontBody,
    fontWeight: bold ? pw.FontWeight.bold : pw.FontWeight.normal,
    color: color ?? LakbayPdfTokens.textPrimary,
    lineSpacing: 2.2,
  );

  pw.TextStyle styleCaption({
    PdfColor? color,
    bool bold = false,
    double? fontSize,
  }) => pw.TextStyle(
    font: bold ? boldFont : regularFont,
    fontNormal: regularFont,
    fontBold: boldFont,
    fontFallback: [regularFont, boldFont],
    fontSize: fontSize ?? LakbayPdfTokens.fontCaption,
    fontWeight: bold ? pw.FontWeight.bold : pw.FontWeight.normal,
    color: color ?? LakbayPdfTokens.textSecondary,
    lineSpacing: 1.8,
  );

  pw.TextStyle styleMicro({PdfColor? color, bool bold = true}) => pw.TextStyle(
    font: bold ? boldFont : regularFont,
    fontNormal: regularFont,
    fontBold: boldFont,
    fontFallback: [regularFont, boldFont],
    fontSize: LakbayPdfTokens.fontMicro,
    fontWeight: bold ? pw.FontWeight.bold : pw.FontWeight.normal,
    color: color ?? LakbayPdfTokens.textMuted,
  );

  pw.Widget brandWordmark({double fontSize = 14, bool lightText = false}) {
    final baseColor = lightText
        ? LakbayPdfTokens.white
        : LakbayPdfTokens.primaryDark;
    return pw.Row(
      mainAxisSize: pw.MainAxisSize.min,
      crossAxisAlignment: pw.CrossAxisAlignment.center,
      children: [
        if (markSvg != null) ...[
          pw.Container(
            width: fontSize * 1.45,
            height: fontSize * 1.45,
            padding: const pw.EdgeInsets.all(2.5),
            decoration: pw.BoxDecoration(
              color: LakbayPdfTokens.surfaceWhite,
              borderRadius: pw.BorderRadius.circular(
                LakbayPdfTokens.radiusTag,
              ),
              border: lightText
                  ? null
                  : pw.Border.all(
                      color: LakbayPdfTokens.cardBorder,
                      width: 0.6,
                    ),
            ),
            child: pw.SvgImage(svg: markSvg!),
          ),
          pw.SizedBox(width: LakbayPdfTokens.spaceSm),
        ],
        pw.RichText(
          text: pw.TextSpan(
            style: pw.TextStyle(
              font: boldFont,
              fontBold: boldFont,
              fontFallback: [regularFont, boldFont],
              fontSize: fontSize,
              fontWeight: pw.FontWeight.bold,
              color: baseColor,
            ),
            children: [
              const pw.TextSpan(text: 'Lakbay'),
              pw.TextSpan(
                text: '+',
                style: pw.TextStyle(color: LakbayPdfTokens.cocoaOrange),
              ),
            ],
          ),
        ),
      ],
    );
  }

  pw.Widget statusBadge(
    String label, {
    required PdfColor background,
    required PdfColor foreground,
    PdfColor? borderColor,
  }) {
    return pw.Container(
      padding: const pw.EdgeInsets.symmetric(
        horizontal: LakbayPdfTokens.spaceSm,
        vertical: 3.5,
      ),
      decoration: pw.BoxDecoration(
        color: background,
        borderRadius: pw.BorderRadius.circular(LakbayPdfTokens.radiusPill),
        border: borderColor == null
            ? null
            : pw.Border.all(color: borderColor, width: 0.7),
      ),
      child: pw.Text(
        clean(label),
        style: styleMicro(color: foreground, bold: true),
      ),
    );
  }

  pw.Widget runningHeader(pw.Context context, {required String title}) {
    if (context.pageNumber <= 1) {
      return pw.SizedBox.shrink();
    }
    return pw.Container(
      margin: const pw.EdgeInsets.only(bottom: LakbayPdfTokens.spaceMd),
      padding: const pw.EdgeInsets.only(bottom: LakbayPdfTokens.spaceXs + 2),
      decoration: pw.BoxDecoration(
        border: pw.Border(
          bottom: pw.BorderSide(
            color: LakbayPdfTokens.cardBorder,
            width: 0.7,
          ),
        ),
      ),
      child: pw.Row(
        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
        crossAxisAlignment: pw.CrossAxisAlignment.center,
        children: [
          brandWordmark(fontSize: 10.5, lightText: false),
          pw.SizedBox(width: LakbayPdfTokens.spaceMd),
          pw.Expanded(
            child: pw.Text(
              clean(title),
              textAlign: pw.TextAlign.right,
              style: styleCaption(
                color: LakbayPdfTokens.textMuted,
                bold: true,
              ),
              maxLines: 1,
            ),
          ),
        ],
      ),
    );
  }

  pw.Widget runningFooter(pw.Context context) {
    return pw.Container(
      margin: const pw.EdgeInsets.only(top: LakbayPdfTokens.spaceMd),
      padding: const pw.EdgeInsets.only(top: LakbayPdfTokens.spaceXs + 2),
      decoration: pw.BoxDecoration(
        border: pw.Border(
          top: pw.BorderSide(
            color: LakbayPdfTokens.cardBorder,
            width: 0.7,
          ),
        ),
      ),
      child: pw.Row(
        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
        children: [
          pw.Expanded(
            child: pw.Text(
              clean('Lakbay+ • ${PlainWords.region}'),
              style: styleCaption(color: LakbayPdfTokens.textMuted),
            ),
          ),
          pw.Text(
            'Page ${context.pageNumber} of ${context.pagesCount}',
            style: styleCaption(
              color: LakbayPdfTokens.textSecondary,
              bold: true,
            ),
          ),
        ],
      ),
    );
  }

  pw.Widget heroBanner({
    required String title,
    required String subtitle,
    String? statusLabel,
    PdfColor? statusBg,
    PdfColor? statusFg,
    PdfColor? statusBorder,
    List<String> pills = const [],
  }) {
    return pw.Container(
      width: double.infinity,
      padding: const pw.EdgeInsets.all(LakbayPdfTokens.spaceXl),
      decoration: pw.BoxDecoration(
        gradient: LakbayPdfTokens.deepTealGradient,
        borderRadius: pw.BorderRadius.circular(LakbayPdfTokens.radiusBanner),
      ),
      child: pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Row(
            mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
            crossAxisAlignment: pw.CrossAxisAlignment.center,
            children: [
              brandWordmark(fontSize: 13, lightText: true),
              if (statusLabel != null && statusLabel.trim().isNotEmpty)
                statusBadge(
                  statusLabel,
                  background: statusBg ?? LakbayPdfTokens.bannerPillBg,
                  foreground: statusFg ?? LakbayPdfTokens.white,
                  borderColor: statusBorder ?? LakbayPdfTokens.bannerPillBorder,
                ),
            ],
          ),
          pw.SizedBox(height: LakbayPdfTokens.spaceMd),
          pw.Text(clean(title), style: styleHeroTitle()),
          if (subtitle.trim().isNotEmpty) ...[
            pw.SizedBox(height: LakbayPdfTokens.spaceXs),
            pw.Text(
              clean(subtitle),
              style: styleBody(
                color: LakbayPdfTokens.bannerMutedText,
                fontSize: 10.2,
              ),
            ),
          ],
          if (pills.isNotEmpty) ...[
            pw.SizedBox(height: LakbayPdfTokens.spaceMd),
            pw.Wrap(
              spacing: LakbayPdfTokens.spaceXs + 2,
              runSpacing: LakbayPdfTokens.spaceXs + 2,
              children: [
                for (final pill in pills)
                  if (pill.trim().isNotEmpty)
                    statusBadge(
                      pill,
                      background: LakbayPdfTokens.bannerPillBg,
                      foreground: LakbayPdfTokens.white,
                      borderColor: LakbayPdfTokens.bannerPillBorder,
                    ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  pw.Widget kpiRow(List<PdfKpiItem> items) {
    if (items.isEmpty) return pw.SizedBox.shrink();
    return pw.Row(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < items.length; i++) ...[
          if (i > 0) pw.SizedBox(width: LakbayPdfTokens.spaceSm),
          pw.Expanded(
            child: pw.Container(
              padding: const pw.EdgeInsets.all(LakbayPdfTokens.spaceMd),
              decoration: pw.BoxDecoration(
                color: LakbayPdfTokens.surfaceWhite,
                borderRadius: pw.BorderRadius.circular(
                  LakbayPdfTokens.radiusTile,
                ),
                border: pw.Border.all(
                  color: LakbayPdfTokens.cardBorder,
                  width: 0.8,
                ),
              ),
              child: pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  pw.Text(
                    clean(items[i].label.toUpperCase()),
                    style: styleMicro(color: LakbayPdfTokens.textMuted),
                  ),
                  pw.SizedBox(height: LakbayPdfTokens.spaceXs),
                  pw.Text(
                    clean(items[i].value),
                    style: styleCardTitle(
                      color: items[i].valueColor ?? LakbayPdfTokens.textPrimary,
                    ),
                  ),
                  if (items[i].subtitle != null &&
                      items[i].subtitle!.trim().isNotEmpty) ...[
                    pw.SizedBox(height: 2),
                    pw.Text(
                      clean(items[i].subtitle!),
                      style: styleCaption(
                        color: LakbayPdfTokens.textSecondary,
                        fontSize: 7.8,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ],
    );
  }

  pw.Widget sectionHeader(
    String title, {
    String? trailing,
    PdfColor? accentColor,
  }) {
    return pw.Container(
      margin: const pw.EdgeInsets.only(
        top: LakbayPdfTokens.spaceLg,
        bottom: LakbayPdfTokens.spaceSm,
      ),
      padding: const pw.EdgeInsets.only(bottom: LakbayPdfTokens.spaceXs + 2),
      decoration: pw.BoxDecoration(
        border: pw.Border(
          bottom: pw.BorderSide(
            color: LakbayPdfTokens.cardBorder,
            width: 0.8,
          ),
        ),
      ),
      child: pw.Row(
        crossAxisAlignment: pw.CrossAxisAlignment.center,
        children: [
          pw.Container(
            width: 3,
            height: 14,
            decoration: pw.BoxDecoration(
              color: accentColor ?? LakbayPdfTokens.primary,
              borderRadius: pw.BorderRadius.circular(2),
            ),
          ),
          pw.SizedBox(width: LakbayPdfTokens.spaceSm),
          pw.Expanded(child: pw.Text(clean(title), style: styleSectionTitle())),
          if (trailing != null && trailing.trim().isNotEmpty)
            pw.Text(
              clean(trailing),
              style: styleCaption(color: LakbayPdfTokens.textMuted),
            ),
        ],
      ),
    );
  }

  pw.Widget divider({PdfColor? color, double verticalPadding = 0}) {
    final line = pw.Container(
      height: 0.75,
      color: color ?? LakbayPdfTokens.cardBorder,
    );
    if (verticalPadding <= 0) return line;
    return pw.Padding(
      padding: pw.EdgeInsets.symmetric(vertical: verticalPadding),
      child: line,
    );
  }
}
