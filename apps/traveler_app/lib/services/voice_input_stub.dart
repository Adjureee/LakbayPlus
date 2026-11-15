/// Non-web stub for speech recognition. Returns `null` cleanly so callers can
/// present an interactive typed-prompt fallback sheet.
class VoiceInputService {
  const VoiceInputService();

  bool get isSupported => false;

  Future<String?> listenOnce({String lang = 'en-PH'}) async => null;
}
