import 'dart:async';

/// How the voice should feel (goal §46). Providers may ignore any part.
class VoiceStyle {
  const VoiceStyle({
    this.energy = 0.5,
    this.warmth = 0.6,
    this.speed = 1.0,
    this.emotion,
  });

  /// 0..1 quiet → loud/lively.
  final double energy;

  /// 0..1 flat → warm.
  final double warmth;

  /// 0.5 … 1.5 rate multiplier.
  final double speed;

  /// Free-form hint, e.g. `happy`, `concerned`. Ignored if unsupported.
  final String? emotion;
}

/// Events emitted while an utterance plays.
enum SpeechEventKind { started, boundary, ended }

class SpeechUtteranceEvent {
  const SpeechUtteranceEvent(this.kind, {this.charIndex, this.timestamp});

  final SpeechEventKind kind;

  /// Character offset into the spoken text for boundary events.
  final int? charIndex;
  final DateTime? timestamp;
}

/// Output voice abstraction (goal §46). Streaming-capable providers can emit
/// boundary/amplitude chunks as audio plays; the companion only needs
/// started / progress / ended semantics for lip-sync and interruption.
abstract class VoiceProvider {
  bool get isSupported;

  Future<void> startSession();

  /// Speaks [text]; the returned stream finishes when the utterance ends.
  Stream<SpeechUtteranceEvent> speak(String text, {VoiceStyle? style});

  /// Stops immediately — the barge-in path depends on this being fast.
  Future<void> stop();

  bool get isSpeaking;
}

/// A provider that cannot speak on this platform (graceful degradation, §74).
class UnsupportedVoiceProvider implements VoiceProvider {
  @override
  bool get isSupported => false;

  @override
  bool get isSpeaking => false;

  @override
  Future<void> startSession() async {}

  @override
  Stream<SpeechUtteranceEvent> speak(String text, {VoiceStyle? style}) =>
      const Stream.empty();

  @override
  Future<void> stop() async {}
}
