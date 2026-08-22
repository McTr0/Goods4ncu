@JS()
library;

import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'voice_provider.dart';

VoiceProvider createVoiceProvider() => _WebSpeechTts();

_SpeechSynthesis? _synth() {
  final synth = globalContext.getProperty<JSAny?>('speechSynthesis'.toJS);
  if (synth == null || !synth.typeofEquals('object')) return null;
  return synth as _SpeechSynthesis;
}

extension type _SpeechSynthesis(JSObject _) implements JSObject {
  external bool get speaking;
  external void speak(JSObject utterance);
  external void cancel();
}

/// Output voice via the Web Speech Synthesis API (goal §46, Level 3).
class _WebSpeechTts implements VoiceProvider {
  _SpeechSynthesis? get _engine {
    try {
      return _synth();
    } catch (_) {
      return null;
    }
  }

  @override
  bool get isSupported => _engine != null;

  @override
  bool get isSpeaking => _engine?.speaking ?? false;

  @override
  Future<void> startSession() async {}

  @override
  Stream<SpeechUtteranceEvent> speak(String text, {VoiceStyle? style}) {
    final engine = _engine;
    if (engine == null) return const Stream.empty();

    final controller = StreamController<SpeechUtteranceEvent>();
    final ctor = globalContext.getProperty<JSAny?>(
      'SpeechSynthesisUtterance'.toJS,
    );
    if (ctor == null || !ctor.typeofEquals('function')) {
      return const Stream.empty();
    }
    final utterance = (ctor as JSFunction).callAsConstructor<JSObject>(
      text.toJS,
    );

    utterance.setProperty('lang'.toJS, 'zh-CN'.toJS);
    final speed = (style?.speed ?? 1.0).clamp(0.5, 2.0);
    utterance.setProperty('rate'.toJS, speed.toJS);
    if (style != null) {
      final pitch = (0.8 + style.warmth * 0.4).clamp(0.5, 1.5);
      final volume = (0.5 + style.energy * 0.5).clamp(0.1, 1.0);
      utterance.setProperty('pitch'.toJS, pitch.toJS);
      utterance.setProperty('volume'.toJS, volume.toJS);
    }

    void finish() {
      if (!controller.isClosed) {
        controller
          ..add(SpeechUtteranceEvent(SpeechEventKind.ended))
          ..close();
      }
    }

    utterance.setProperty(
      'onstart'.toJS,
      (() {
        if (!controller.isClosed) {
          controller.add(SpeechUtteranceEvent(SpeechEventKind.started));
        }
      }).toJS,
    );
    utterance.setProperty(
      'onboundary'.toJS,
      ((JSObject event) {
        if (controller.isClosed) return;
        final index = event.getProperty<JSAny?>('charIndex'.toJS);
        controller.add(
          SpeechUtteranceEvent(
            SpeechEventKind.boundary,
            charIndex: index?.dartify() is int
                ? (index!.dartify() as int)
                : null,
          ),
        );
      }).toJS,
    );
    utterance.setProperty('onend'.toJS, (() => finish()).toJS);

    engine.speak(utterance);
    return controller.stream;
  }

  @override
  Future<void> stop() async {
    try {
      _engine?.cancel();
    } catch (_) {}
  }
}
