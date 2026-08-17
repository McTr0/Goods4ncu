import 'dart:async';

import 'package:speech_to_text/speech_recognition_error.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart';

import 'speech_dictation_contract.dart';

final _NativeSpeechDictation _sharedDictation = _NativeSpeechDictation();

SpeechDictation createSpeechDictation() => _sharedDictation;

/// Android/iOS speech input backed by each platform's system recognizer.
///
/// `SpeechToText` is a process-wide singleton, so this adapter is shared too.
/// Session callbacks are replaced whenever the active composer starts listening.
class _NativeSpeechDictation implements SpeechDictation {
  final SpeechToText _speech = SpeechToText();

  bool _initialized = false;
  bool _listening = false;
  void Function(SpeechDictationResult result)? _onResult;
  void Function(String code)? _onError;
  SpeechDictationEnded? _onEnded;

  @override
  bool get isSupported => true;

  @override
  Future<void> start({
    required String locale,
    required void Function(SpeechDictationResult result) onResult,
    required void Function(String code) onError,
    required SpeechDictationEnded onEnded,
  }) async {
    if (_listening) return;

    _onResult = onResult;
    _onError = onError;
    _onEnded = onEnded;

    try {
      if (!_initialized) {
        _initialized = await _speech.initialize(
          onError: _handleError,
          onStatus: _handleStatus,
          options: [SpeechToText.androidNoBluetooth],
        );
      }
      if (!_initialized) {
        _onError?.call('not-allowed');
        _finish();
        return;
      }

      _listening = true;
      await _speech.listen(
        onResult: _handleResult,
        listenOptions: SpeechListenOptions(
          cancelOnError: true,
          partialResults: true,
          listenMode: ListenMode.dictation,
          autoPunctuation: true,
          pauseFor: const Duration(seconds: 5),
          listenFor: const Duration(minutes: 1),
          localeId: locale.replaceAll('-', '_'),
        ),
      );
    } catch (_) {
      _onError?.call('unavailable');
      _finish();
    }
  }

  void _handleResult(SpeechRecognitionResult result) {
    final text = result.recognizedWords.trim();
    if (text.isEmpty) return;
    _onResult?.call(
      SpeechDictationResult(text: text, isFinal: result.finalResult),
    );
  }

  void _handleError(SpeechRecognitionError error) {
    final code = error.errorMsg;
    if (code == 'error_no_match' || code == 'error_speech_timeout') {
      _finish();
      return;
    }
    final normalized = switch (code) {
      'error_permission' || 'error_speech_recognizer_disabled' => 'not-allowed',
      'error_network' ||
      'error_network_timeout' ||
      'error_server' ||
      'error_server_disconnected' => 'network',
      _ => 'unavailable',
    };
    _onError?.call(normalized);
    _finish();
  }

  void _handleStatus(String status) {
    if (status == SpeechToText.doneStatus ||
        status == SpeechToText.notListeningStatus) {
      _finish();
    }
  }

  @override
  Future<void> stop() async {
    if (!_listening) return;
    await _speech.stop();
  }

  void _finish() {
    if (!_listening && _onEnded == null) return;
    _listening = false;
    final callback = _onEnded;
    _onResult = null;
    _onError = null;
    _onEnded = null;
    callback?.call();
  }

  @override
  void dispose() {
    if (_listening) unawaited(_speech.cancel());
    _finish();
  }
}
