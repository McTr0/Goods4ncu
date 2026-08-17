@JS()
library;

import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'speech_dictation_contract.dart';

extension type _Recognition(JSObject _) implements JSObject {
  external set lang(String value);
  external set continuous(bool value);
  external set interimResults(bool value);
  external set maxAlternatives(int value);
  external set onresult(JSFunction value);
  external set onerror(JSFunction value);
  external set onend(JSFunction value);
  external void start();
  external void stop();
  external void abort();
}

extension type _RecognitionEvent(JSObject _) implements JSObject {
  external int get resultIndex;
  external _RecognitionResultList get results;
}

extension type _RecognitionResultList(JSObject _) implements JSObject {
  external int get length;
  external _RecognitionResult item(int index);
}

extension type _RecognitionResult(JSObject _) implements JSObject {
  external bool get isFinal;
  external _RecognitionAlternative item(int index);
}

extension type _RecognitionAlternative(JSObject _) implements JSObject {
  external String get transcript;
}

extension type _RecognitionErrorEvent(JSObject _) implements JSObject {
  external String get error;
}

SpeechDictation createSpeechDictation() => _WebSpeechDictation();

class _WebSpeechDictation implements SpeechDictation {
  _Recognition? _recognition;
  SpeechDictationEnded? _onEnded;
  bool _listening = false;
  bool _shouldContinue = false;

  JSFunction? get _constructor {
    final standard = globalContext.getProperty<JSAny?>(
      'SpeechRecognition'.toJS,
    );
    if (standard != null && standard.typeofEquals('function')) {
      return standard as JSFunction;
    }
    final prefixed = globalContext.getProperty<JSAny?>(
      'webkitSpeechRecognition'.toJS,
    );
    if (prefixed != null && prefixed.typeofEquals('function')) {
      return prefixed as JSFunction;
    }
    return null;
  }

  @override
  bool get isSupported => _constructor != null;

  @override
  Future<void> start({
    required String locale,
    required void Function(SpeechDictationResult result) onResult,
    required void Function(String code) onError,
    required SpeechDictationEnded onEnded,
  }) async {
    if (_listening) return;
    final constructor = _constructor;
    if (constructor == null) {
      onError('unsupported');
      onEnded();
      return;
    }

    try {
      final recognition = _Recognition(
        constructor.callAsConstructor<JSObject>(),
      );
      recognition
        ..lang = locale
        ..continuous = true
        ..interimResults = true
        ..maxAlternatives = 1
        ..onresult = ((JSObject rawEvent) {
          final event = _RecognitionEvent(rawEvent);
          final finalText = StringBuffer();
          final interimText = StringBuffer();
          for (
            var index = event.resultIndex;
            index < event.results.length;
            index++
          ) {
            final result = event.results.item(index);
            final transcript = result.item(0).transcript;
            if (result.isFinal) {
              finalText.write(transcript);
            } else {
              interimText.write(transcript);
            }
          }
          if (finalText.isNotEmpty) {
            onResult(
              SpeechDictationResult(text: finalText.toString(), isFinal: true),
            );
          }
          if (interimText.isNotEmpty) {
            onResult(
              SpeechDictationResult(
                text: interimText.toString(),
                isFinal: false,
              ),
            );
          }
        }).toJS
        ..onerror = ((JSObject rawEvent) {
          final code = _RecognitionErrorEvent(rawEvent).error;
          _shouldContinue = false;
          onError(code);
        }).toJS
        ..onend = ((JSAny? _) {
          if (_shouldContinue) {
            scheduleMicrotask(() {
              if (!_shouldContinue) return;
              try {
                recognition.start();
              } catch (_) {
                _finish();
              }
            });
            return;
          }
          _finish();
        }).toJS;
      _recognition = recognition;
      _onEnded = onEnded;
      _listening = true;
      _shouldContinue = true;
      recognition.start();
    } catch (_) {
      _shouldContinue = false;
      _recognition = null;
      _listening = false;
      _onEnded = null;
      onError('unavailable');
      onEnded();
    }
  }

  @override
  Future<void> stop() async {
    if (!_listening) return;
    _shouldContinue = false;
    try {
      _recognition?.stop();
    } catch (_) {
      _finish();
    }
  }

  void _finish() {
    _shouldContinue = false;
    _listening = false;
    _recognition = null;
    final callback = _onEnded;
    _onEnded = null;
    callback?.call();
  }

  @override
  void dispose() {
    _onEnded = null;
    _shouldContinue = false;
    if (_listening) {
      try {
        _recognition?.abort();
      } catch (_) {
        // The recognition session may already have ended in the browser.
      }
    }
    _listening = false;
    _recognition = null;
  }
}
