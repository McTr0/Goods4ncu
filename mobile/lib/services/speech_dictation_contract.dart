/// One live speech-recognition update.
class SpeechDictationResult {
  const SpeechDictationResult({required this.text, required this.isFinal});

  final String text;
  final bool isFinal;
}

typedef SpeechDictationEnded = void Function();

/// Text-only speech input used by every message composer.
///
/// The browser implementation delegates recognition to the browser. A future
/// self-hosted implementation can satisfy this contract without changing any
/// chat page or composer UI.
abstract interface class SpeechDictation {
  bool get isSupported;

  Future<void> start({
    required String locale,
    required void Function(SpeechDictationResult result) onResult,
    required void Function(String code) onError,
    required SpeechDictationEnded onEnded,
  });

  Future<void> stop();

  void dispose();
}
