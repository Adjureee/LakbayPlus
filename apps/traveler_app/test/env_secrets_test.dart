import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// `.env` is bundled into the APK as a Flutter asset, so anything in it can be
/// extracted from the app. Server credentials must live in the API instead.
const _serverOnlyKeys = [
  'CLOUDINARY_API_KEY',
  'CLOUDINARY_API_SECRET',
  'GROQ_API_KEY',
  'DATABASE_URL',
  'JWT_SECRET_KEY',
];

void main() {
  for (final path in ['.env', '.env.example']) {
    test('$path bundles no server-only secrets', () {
      final file = File(path);
      if (!file.existsSync()) return; // .env is local-only and gitignored.
      final keys = file
          .readAsLinesSync()
          .map((line) => line.trim())
          .where((line) => line.isNotEmpty && !line.startsWith('#'))
          .map((line) => line.split('=').first.trim())
          .toSet();
      final leaked = [
        for (final key in keys)
          if (_serverOnlyKeys.contains(key) || key.endsWith('_SECRET')) key,
      ];
      expect(leaked, isEmpty, reason: '$path would ship these in the APK');
    });
  }
}
