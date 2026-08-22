import 'package:flutter/foundation.dart';

import 'companion_events.dart';

/// Where the character's focus can be (goal §40).
enum AttentionTarget {
  user,
  chat,
  post,
  postList,
  notification,
  message,
  none;

  static AttentionTarget tryParse(String? value) => AttentionTarget.values
      .firstWhere((t) => t.name == value, orElse: () => AttentionTarget.none);
}

class AttentionState {
  const AttentionState({
    this.primary = AttentionTarget.user,
    this.secondary,
    this.lockedUntil,
  });

  final AttentionTarget primary;
  final AttentionTarget? secondary;

  /// While set, environment events may not steal the primary target
  /// (e.g. keep eye contact while the user is mid-sentence).
  final DateTime? lockedUntil;

  bool get isLocked =>
      lockedUntil != null && DateTime.now().isBefore(lockedUntil!);

  Map<String, Object?> toDebugMap() => {
    'primary': primary.name,
    if (secondary != null) 'secondary': secondary!.name,
    if (lockedUntil != null) 'lockedUntil': lockedUntil!.toIso8601String(),
  };
}

/// Owns the character's focus and converts changes into bus events.
///
/// Locks are honoured: a locked primary target cannot be stolen by weaker
/// stimuli, only expired or explicitly released (barge-in does exactly that).
class AttentionController extends ChangeNotifier {
  AttentionController({required CompanionEventBus bus}) : _bus = bus;

  final CompanionEventBus _bus;

  AttentionState _state = const AttentionState();

  AttentionState get state => _state;

  void lookAt(
    AttentionTarget target, {
    AttentionTarget? secondary,
    Duration lockFor = Duration.zero,
    Map<String, Object?> debugData = const {},
  }) {
    if (_state.isLocked && lockFor == Duration.zero) return;
    final next = AttentionState(
      primary: target,
      secondary: secondary ?? _state.secondary,
      lockedUntil: lockFor == Duration.zero
          ? null
          : DateTime.now().add(lockFor),
    );
    if (next.primary == _state.primary &&
        next.secondary == _state.secondary &&
        next.lockedUntil == _state.lockedUntil) {
      return;
    }
    _state = next;
    _bus.emit(CompanionEventType.attentionChanged, {
      ..._state.toDebugMap(),
      ...debugData,
    });
    notifyListeners();
  }

  /// Barge-in and direct user speech always win, even over locks.
  void focusUser({Duration lockFor = const Duration(seconds: 2)}) => lookAt(
    AttentionTarget.user,
    secondary: null,
    lockFor: lockFor,
    debugData: {'reason': 'user_focus'},
  );

  void releaseLock() {
    if (!_state.isLocked) return;
    _state = AttentionState(
      primary: _state.primary,
      secondary: _state.secondary,
    );
    notifyListeners();
  }
}
