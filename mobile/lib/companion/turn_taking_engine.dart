import 'companion_events.dart';

/// Conversation-level state machine (master goal §6).
enum ConversationState {
  idle,
  userSpeaking,
  userPause,
  thinking,
  assistantStarting,
  assistantSpeaking,
  interrupted,
  recovering,
}

/// Drives turn-taking *without* asking the model (goal §6–8).
///
/// Inputs are low-level signals (speech start/end from VAD/STT, response
/// lifecycle from the agent). Outputs are callbacks the companion acts on:
/// barge-in must stop TTS within the latency budget, and end-of-turn is what
/// actually triggers a request to the agent.
class TurnTakingEngine {
  TurnTakingEngine({
    required CompanionEventBus bus,
    required this.onBargeIn,
    required this.onTurnComplete,
    this.pauseThreshold = const Duration(milliseconds: 900),
    DateTime Function()? now,
  }) : _bus = bus,
       _now = now ?? DateTime.now;

  final CompanionEventBus _bus;
  final void Function(Duration interruptLatency)? onBargeIn;
  void Function(String transcript)? onTurnComplete;
  final Duration pauseThreshold;
  final DateTime Function() _now;

  /// Test hook: swap the clock mid-test (kept public for determinism).
  DateTime Function()? clockForTest;

  ConversationState _state = ConversationState.idle;
  String _transcript = '';
  DateTime? _assistantSpeechStartedAt;
  DateTime? _interruptedAt;

  /// Set by the voice controller when interim STT text arrives.
  void onPartialTranscript(String text) {
    if (_state == ConversationState.assistantSpeaking ||
        _state == ConversationState.assistantStarting) {
      bargeIn();
    }
    if (_state != ConversationState.userSpeaking) {
      _transition(ConversationState.userSpeaking);
    }
    _transcript = text;
  }

  /// STT produced a final result for this utterance.
  void onFinalTranscript(String text) {
    _transcript = text.trim();
    if (_transcript.isEmpty) {
      _transition(ConversationState.idle);
      return;
    }
    _transition(ConversationState.userPause);
    // End-of-turn: hand off to the agent.
    final transcript = _transcript;
    _transcript = '';
    _transition(ConversationState.thinking);
    onTurnComplete?.call(transcript);
  }

  /// Agent accepted the turn and will respond.
  void onResponseStart() {
    if (_state == ConversationState.thinking ||
        _state == ConversationState.userPause) {
      _transition(ConversationState.assistantStarting);
    }
  }

  /// First response token / TTS started.
  void onAssistantSpeechStart() {
    if (_state == ConversationState.assistantStarting ||
        _state == ConversationState.thinking) {
      _assistantSpeechStartedAt = _now();
      _transition(ConversationState.assistantSpeaking);
    }
  }

  /// Response finished playing.
  void onAssistantSpeechEnd() {
    if (_state == ConversationState.assistantSpeaking) {
      _assistantSpeechStartedAt = null;
      _transition(ConversationState.idle);
    }
  }

  /// Connection trouble → recovering → idle (goal §73).
  void onError() {
    _transition(ConversationState.recovering);
    _transition(ConversationState.idle);
  }

  /// User starts speaking while the assistant is talking (hard requirement §8).
  void bargeIn() {
    if (_state != ConversationState.assistantSpeaking &&
        _state != ConversationState.assistantStarting) {
      return;
    }
    final startedAt = _assistantSpeechStartedAt;
    final at = clockForTest?.call() ?? _now();
    _interruptedAt = at;
    final latency = startedAt == null ? null : at.difference(startedAt);
    _assistantSpeechStartedAt = null;
    _transition(ConversationState.interrupted);
    _bus.emit(CompanionEventType.interrupted, {
      if (latency != null)
        'interruptLatencyMs': latency.inMilliseconds.clamp(0, 10000),
    });
    onBargeIn?.call(latency ?? const Duration(milliseconds: 300));
  }

  /// After an interruption resolves, the user owns the floor.
  void resumeAfterInterrupt() {
    if (_state == ConversationState.interrupted) {
      _interruptedAt = null;
      _transition(ConversationState.userSpeaking);
    } else if (_state == ConversationState.recovering) {
      _transition(ConversationState.idle);
    }
  }

  bool get isAwaitingAgent =>
      _state == ConversationState.thinking ||
      _state == ConversationState.assistantStarting;

  DateTime get interruptedAt => _interruptedAt ?? DateTime.now();

  void reset() {
    _state = ConversationState.idle;
    _transcript = '';
    _assistantSpeechStartedAt = null;
    _interruptedAt = null;
  }

  void _transition(ConversationState next) {
    if (_state == next) return;
    _state = next;
    _bus.emit(CompanionEventType.agentThinking, {
      'conversationState': next.name,
    });
  }

  ConversationState get state => _state;
}
