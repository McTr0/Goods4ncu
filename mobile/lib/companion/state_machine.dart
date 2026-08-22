import 'companion_events.dart';

/// Full character state vocabulary required by the master goal (§9).
enum CompanionState {
  sleeping,
  idle,
  noticeUser,
  listening,
  thinking,
  speaking,
  toolUsing,
  waiting,
  curious,
  happy,
  excited,
  shy,
  surprised,
  confused,
  concerned,
  bored,
  error,
  interrupted,
}

/// Legal transitions of the character state machine.
///
/// Emotion is a separate system: `happy`/`curious`/… here are *behavioural
/// states* (how the body behaves), not how the emotion engine scores valence.
const Map<CompanionState, Set<CompanionState>> _transitions = {
  // Sleeping wakes into idle or straight to noticing the user.
  CompanionState.sleeping: {CompanionState.idle, CompanionState.noticeUser},
  CompanionState.idle: {
    CompanionState.noticeUser,
    CompanionState.listening,
    CompanionState.curious,
    CompanionState.bored,
    CompanionState.sleeping,
    CompanionState.error,
    CompanionState.happy,
  },
  CompanionState.noticeUser: {
    CompanionState.listening,
    CompanionState.idle,
    CompanionState.curious,
    CompanionState.happy,
  },
  // While listening, only user-driven or system events may take over.
  CompanionState.listening: {
    CompanionState.thinking,
    CompanionState.interrupted,
    CompanionState.idle,
    CompanionState.noticeUser,
    CompanionState.error,
  },
  CompanionState.thinking: {
    CompanionState.speaking,
    CompanionState.toolUsing,
    CompanionState.waiting,
    CompanionState.interrupted,
    CompanionState.error,
    CompanionState.listening,
    CompanionState.confused,
  },
  CompanionState.speaking: {
    CompanionState.idle,
    CompanionState.listening,
    CompanionState.interrupted,
    CompanionState.toolUsing,
    CompanionState.error,
    CompanionState.happy,
    CompanionState.excited,
    CompanionState.shy,
  },
  CompanionState.toolUsing: {
    CompanionState.thinking,
    CompanionState.speaking,
    CompanionState.waiting,
    CompanionState.interrupted,
    CompanionState.error,
    CompanionState.confused,
  },
  CompanionState.waiting: {
    CompanionState.listening,
    CompanionState.thinking,
    CompanionState.interrupted,
    CompanionState.error,
    CompanionState.idle,
  },
  // Affective states are transient overlays that fall back automatically.
  CompanionState.curious: {
    CompanionState.idle,
    CompanionState.listening,
    CompanionState.thinking,
    CompanionState.noticeUser,
  },
  CompanionState.happy: {CompanionState.idle, CompanionState.listening},
  CompanionState.excited: {CompanionState.idle, CompanionState.speaking},
  CompanionState.shy: {CompanionState.idle},
  CompanionState.surprised: {
    CompanionState.idle,
    CompanionState.listening,
    CompanionState.thinking,
  },
  CompanionState.confused: {
    CompanionState.idle,
    CompanionState.thinking,
    CompanionState.error,
    CompanionState.listening,
  },
  CompanionState.concerned: {
    CompanionState.idle,
    CompanionState.thinking,
    CompanionState.speaking,
    CompanionState.listening,
  },
  CompanionState.bored: {
    CompanionState.idle,
    CompanionState.sleeping,
    CompanionState.noticeUser,
  },
  CompanionState.error: {
    CompanionState.idle,
    CompanionState.thinking,
    CompanionState.listening,
  },
  // Interrupted must resolve into listening (barge-in contract, §8).
  CompanionState.interrupted: {
    CompanionState.listening,
    CompanionState.idle,
    CompanionState.error,
  },
};

/// Owns and guards the character's current state.
///
/// Illegal transitions are rejected (keeping the previous state) so a rogue
/// producer can never wedge the body into an undefined pose; every accepted
/// transition is announced on the event bus.
class CompanionStateMachine {
  CompanionStateMachine({
    required CompanionEventBus bus,
    this.onIllegalTransition,
  }) : _bus = bus;

  final CompanionEventBus _bus;
  final void Function(CompanionState from, CompanionState attempt)?
  onIllegalTransition;

  CompanionState _state = CompanionState.idle;
  DateTime _enteredAt = DateTime.now();

  CompanionState get state => _state;

  /// How long the character has been in the current state.
  Duration get timeInState => DateTime.now().difference(_enteredAt);

  bool can(CompanionState next) =>
      _transitions[_state]?.contains(next) ?? false;

  /// Returns true when the transition was applied.
  bool transition(CompanionState next, {Map<String, Object?> data = const {}}) {
    if (next == _state) return false;
    if (!can(next)) {
      onIllegalTransition?.call(_state, next);
      return false;
    }
    final previous = _state;
    _state = next;
    _enteredAt = DateTime.now();
    _bus.emit(CompanionEventType.characterStateChanged, {
      'from': previous.name,
      'to': next.name,
      ...data,
    });
    return true;
  }

  /// Force-set used only by tests and recovery paths.
  void reset([CompanionState state = CompanionState.idle]) {
    _state = state;
    _enteredAt = DateTime.now();
  }
}
