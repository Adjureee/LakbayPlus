import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

@JS('window')
external JSObject get _window;

/// Web Speech API implementation using `SpeechRecognition` / `webkitSpeechRecognition`.
class VoiceInputService {
  const VoiceInputService();

  JSFunction? get _recognitionCtor {
    final std = _window['SpeechRecognition'];
    if (std != null && std.isA<JSFunction>()) return std as JSFunction;
    final webkit = _window['webkitSpeechRecognition'];
    if (webkit != null && webkit.isA<JSFunction>()) return webkit as JSFunction;
    return null;
  }

  bool get isSupported => _recognitionCtor != null;

  Future<String?> listenOnce({String lang = 'en-PH'}) async {
    final ctor = _recognitionCtor;
    if (ctor == null) return null;

    final completer = Completer<String?>();
    final recognition = ctor.callAsConstructor<JSObject>();
    recognition['lang'] = lang.toJS;
    recognition['interimResults'] = false.toJS;
    recognition['maxAlternatives'] = 1.toJS;

    recognition['onresult'] = ((JSObject event) {
      if (completer.isCompleted) return;
      try {
        final results = event['results'] as JSObject?;
        final first = results?.getProperty<JSObject?>(0.toJS);
        final alt = first?.getProperty<JSObject?>(0.toJS);
        final transcript = alt?.getProperty<JSString?>('transcript'.toJS)?.toDart;
        completer.complete(transcript?.trim());
      } catch (_) {
        completer.complete(null);
      }
    }).toJS;

    recognition['onerror'] = ((JSAny? _) {
      if (!completer.isCompleted) completer.complete(null);
    }).toJS;

    recognition['onend'] = (() {
      if (!completer.isCompleted) completer.complete(null);
    }).toJS;

    try {
      recognition.callMethod<JSAny?>('start'.toJS);
    } catch (_) {
      if (!completer.isCompleted) completer.complete(null);
    }

    return completer.future.timeout(
      const Duration(seconds: 12),
      onTimeout: () => null,
    );
  }
}
