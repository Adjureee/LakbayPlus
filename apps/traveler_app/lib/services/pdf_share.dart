import 'dart:io';

import 'package:flutter/foundation.dart'
    show Uint8List, kIsWeb, visibleForTesting;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

/// Hands a finished PDF to the phone's share sheet (save, send, print).
class PdfShare {
  PdfShare._();

  /// Tests replace the share sheet to see what would be shared.
  @visibleForTesting
  static Future<void> Function(List<int> bytes, String name, String text)?
  override;

  static String _sanitizeFileName(String name) {
    final cleaned = name.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    if (cleaned.isEmpty) return 'lakbay-itinerary.pdf';
    return cleaned.toLowerCase().endsWith('.pdf') ? cleaned : '$cleaned.pdf';
  }

  static Future<void> share(List<int> bytes, String name, String text) async {
    final custom = override;
    if (custom != null) return custom(bytes, name, text);
    final safeName = _sanitizeFileName(name);
    final List<XFile> files;
    if (kIsWeb) {
      files = [
        XFile.fromData(
          Uint8List.fromList(bytes),
          mimeType: 'application/pdf',
          name: safeName,
        ),
      ];
    } else {
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}${Platform.pathSeparator}$safeName');
      await file.writeAsBytes(bytes, flush: true);
      files = [XFile(file.path, mimeType: 'application/pdf', name: safeName)];
    }
    await SharePlus.instance.share(ShareParams(files: files, text: text));
  }
}
