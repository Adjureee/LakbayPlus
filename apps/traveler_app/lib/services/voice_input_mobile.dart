import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:speech_to_text/speech_to_text.dart';

/// Native mobile speech-to-text implementation backed by `speech_to_text`.
class VoiceInputService {
  const VoiceInputService();

  bool get isSupported =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  Future<String?> listenOnce({String lang = 'en-PH'}) async {
    if (!isSupported) return null;

    final speech = SpeechToText();
    final completer = Completer<String?>();
    var latestWords = '';
    Timer? timeoutTimer;

    void finish(String? value) {
      timeoutTimer?.cancel();
      if (!completer.isCompleted) {
        final trimmed = value?.trim();
        completer.complete(trimmed != null && trimmed.isNotEmpty ? trimmed : null);
      }
    }

    try {
      final ready = await speech.initialize(
        onError: (_) => finish(latestWords),
        onStatus: (status) {
          if (status == SpeechToText.doneStatus ||
              status == SpeechToText.notListeningStatus) {
            finish(latestWords);
          }
        },
      );
      if (!ready) {
        finish(null);
        return null;
      }

      // Refresh listeners because SpeechToText is a singleton whose initialize()
      // short-circuits once initialized.
      speech.errorListener = (_) => finish(latestWords);
      speech.statusListener = (status) {
        if (status == SpeechToText.doneStatus ||
            status == SpeechToText.notListeningStatus) {
          finish(latestWords);
        }
      };

      timeoutTimer = Timer(const Duration(seconds: 14), () {
        speech.stop();
        finish(latestWords);
      });

      await speech.listen(
        onResult: (result) {
          latestWords = result.recognizedWords;
          if (result.finalResult) {
            finish(latestWords);
          }
        },
        listenOptions: SpeechListenOptions(
          listenFor: const Duration(seconds: 12),
          pauseFor: const Duration(seconds: 3),
          partialResults: true,
          cancelOnError: true,
          listenMode: ListenMode.dictation,
          localeId: lang.replaceAll('-', '_'),
        ),
      );

      final transcript = await completer.future;
      if (speech.isListening) {
        await speech.stop();
      }
      return transcript;
    } catch (_) {
      finish(latestWords);
      return null;
    }
  }
}
