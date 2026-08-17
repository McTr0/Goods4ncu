import 'speech_dictation_contract.dart';

SpeechDictation createSpeechDictation() => const _UnsupportedSpeechDictation();

class _UnsupportedSpeechDictation implements SpeechDictation {
  const _UnsupportedSpeechDictation();

  @override
  bool get isSupported => false;

  @override
  Future<void> start({
    required String locale,
    required void Function(SpeechDictationResult result) onResult,
    required void Function(String code) onError,
    required SpeechDictationEnded onEnded,
  }) async {
    onError('unsupported');
    onEnded();
  }

  @override
  Future<void> stop() async {}

  @override
  void dispose() {}
}
