import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../services/speech_dictation.dart';
import '../services/speech_dictation_contract.dart';
import 'companion_events.dart';
import 'turn_taking_engine.dart';
import 'voice_provider.dart';

/// Glue between the human's voice, the turn-taking engine, and the TTS
/// provider (goal §5–8, §43–48).
///
/// * Mic/STT events drive [engine] — interim results mark USER_SPEECH_START,
///   recognizer-end finalizes the turn and hands the transcript to the agent.
/// * Assistant replies are spoken through [provider]; word-boundary pulses
///   approximate mouth opening until a phoneme-capable provider exists (§44).
/// * Barge-in: partial speech while the assistant talks stops TTS first and
///   feeds the interruption into the agent pipeline.
class CompanionVoiceController {
  CompanionVoiceController({
    required this.bus,
    required this.engine,
    required this.provider,
    SpeechDictation? dictation,
    required void Function(String text) onTurnReady,
    VoidCallback? onInterrupted,
    this.locale = 'zh-CN',
  }) : _dictation = dictation,
       _onTurnReady = onTurnReady,
       _onInterrupted = onInterrupted {
    engine.onTurnComplete = (text) => _onTurnReady(text);
    // Barge-in contract: the moment an interruption is detected, audio stops.
    _busSub = bus.on(CompanionEventType.interrupted, (_) {
      unawaited(interruptTts());
    });
  }
  final CompanionEventBus bus;
  StreamSubscription<CompanionEvent>? _busSub;
  StreamSubscription<void>? _interruptSub;

  final TurnTakingEngine engine;
  final VoiceProvider provider;
  final SpeechDictation? _dictation;
  final void Function(String text) _onTurnReady;
  final VoidCallback? _onInterrupted;
  final String locale;

  SpeechDictation? get dictation => _dictation;

  String lastPartial = '';
  bool micActive = false;

  /// Live mouth value for the renderer sampler while TTS speaks.
  double mouthValue = 0;
  Timer? _mouthTimer;
  DateTime _mouthPhaseStart = DateTime.now();
  DateTime _speechStartedAt = DateTime.now();

  Future<bool> startListening() async {
    final d = _dictation;
    if (d == null || !d.isSupported || micActive) return false;
    var started = false;
    await d.start(
      locale: locale,
      onResult: (result) {
        if (result.isFinal) {
          // A final segment ends the current turn.
          stopListening();
          engine.onFinalTranscript(result.text.trim());
        } else if (result.text.trim().isNotEmpty) {
          lastPartial = result.text;
          engine.onPartialTranscript(result.text);
        }
      },
      onError: (code) => engine.onError(),
      onEnded: () => micActive = false,
    );
    started = d.isSupported && !micActive ? false : true;
    // The recognizer reports liveness via onEnded only after start; assume
    // active once start() resolves without error.
    micActive = true;
    return started || micActive;
  }

  Future<void> stopListening() async {
    try {
      await _dictation?.stop();
    } finally {
      micActive = false;
    }
  }

  /// Speak an assistant reply; pulses mouth on word boundaries.
  Future<void> speak(String text, {VoiceStyle? style}) async {
    if (!provider.isSupported) return;
    _speechStartedAt = DateTime.now();
    engine.onAssistantSpeechStart();
    _startMouthPulse();
    try {
      final events = provider.speak(text, style: style);
      await for (final event in events) {
        switch (event.kind) {
          case SpeechEventKind.started:
            break;
          case SpeechEventKind.boundary:
            pulseMouth();
            break;
          case SpeechEventKind.ended:
            break;
        }
      }
    } finally {
      _stopMouthPulse();
      engine.onAssistantSpeechEnd();
    }
  }

  /// Hard interrupt: stop audio now, close the mouth (§8, §48).
  Future<void> interruptTts() async {
    await provider.stop();
    _stopMouthPulse();
    mouthValue = 0;
    _onInterrupted?.call();
  }

  Duration get assistantSpeechDuration =>
      DateTime.now().difference(_speechStartedAt);

  void pulseMouth() {
    mouthValue = 0.45 + Random().nextDouble() * 0.4;
  }

  void _startMouthPulse() {
    _mouthPhaseStart = DateTime.now();
    _mouthTimer?.cancel();
    _mouthTimer = Timer.periodic(const Duration(milliseconds: 60), (_) {
      final t = DateTime.now().difference(_mouthPhaseStart).inMilliseconds;
      mouthValue = (0.35 + 0.3 * sin(t / 90) + 0.15 * sin(t / 37)).clamp(
        0.05,
        1.0,
      );
    });
  }

  void _stopMouthPulse() {
    _mouthTimer?.cancel();
    _mouthTimer = null;
    mouthValue = 0;
  }

  void dispose() {
    _mouthTimer?.cancel();
    unawaited(_busSub?.cancel());
    _interruptSub?.cancel();
  }
}
