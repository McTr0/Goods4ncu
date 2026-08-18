import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';

import '../models/models.dart';
import 'social_persona_renderer.dart';

/// Coordinates both visible characters from one authoritative interaction.
///
/// It never subscribes to presence, read, typing or inferred emotion. The only
/// accepted input is a persisted interaction payload or an explicit local
/// replay of that payload.
class AvatarChoreographyController extends ChangeNotifier {
  static AvatarChoreographyController? _activeController;

  final Queue<_QueuedChoreography> _queue = Queue();
  final Set<String> _seenMessageIds = <String>{};
  Timer? _resetTimer;
  bool _disposed = false;

  AvatarMotionCue selfCue = AvatarMotionCue.idle;
  AvatarMotionCue otherCue = AvatarMotionCue.idle;
  int selfRevision = 0;
  int otherRevision = 0;
  bool get isPlaying => _resetTimer?.isActive == true;

  void play(
    AvatarInteractionPayload payload, {
    required String messageId,
    required bool actorIsSelf,
    bool replay = false,
  }) {
    if (_disposed) return;
    if (!replay && !_seenMessageIds.add(messageId)) return;
    if (_seenMessageIds.length > 128) {
      _seenMessageIds.remove(_seenMessageIds.first);
    }
    final request = _QueuedChoreography(
      payload: payload,
      actorIsSelf: actorIsSelf,
    );
    if (isPlaying) {
      if (_queue.length >= 3) _queue.removeFirst();
      _queue.addLast(request);
      return;
    }
    _start(request);
  }

  void _start(_QueuedChoreography request) {
    final previous = _activeController;
    if (previous != null && !identical(previous, this)) {
      previous.stop(clearQueue: false);
    }
    _activeController = this;

    final actorCue = _cueForAction(request.payload.action);
    final recipientCue = switch (request.payload.choreography) {
      AvatarInteractionChoreography.solo => AvatarMotionCue.idle,
      AvatarInteractionChoreography.acknowledge => AvatarMotionCue.acknowledge,
      AvatarInteractionChoreography.reciprocal => actorCue,
    };
    if (request.actorIsSelf) {
      selfCue = actorCue;
      otherCue = recipientCue;
    } else {
      selfCue = recipientCue;
      otherCue = actorCue;
    }
    selfRevision += 1;
    otherRevision += 1;
    notifyListeners();

    final duration = actorCue.fallbackDuration > recipientCue.fallbackDuration
        ? actorCue.fallbackDuration
        : recipientCue.fallbackDuration;
    _resetTimer = Timer(duration + const Duration(milliseconds: 80), () {
      selfCue = AvatarMotionCue.idle;
      otherCue = AvatarMotionCue.idle;
      selfRevision += 1;
      otherRevision += 1;
      _resetTimer = null;
      notifyListeners();
      if (_queue.isNotEmpty) {
        _start(_queue.removeFirst());
      } else if (identical(_activeController, this)) {
        _activeController = null;
      }
    });
  }

  static AvatarMotionCue _cueForAction(AvatarInteractionAction action) =>
      switch (action) {
        AvatarInteractionAction.wave => AvatarMotionCue.wave,
        AvatarInteractionAction.poke => AvatarMotionCue.poke,
        AvatarInteractionAction.highFive => AvatarMotionCue.highFive,
        AvatarInteractionAction.encourage => AvatarMotionCue.encourage,
      };

  void stop({bool clearQueue = true}) {
    _resetTimer?.cancel();
    _resetTimer = null;
    if (clearQueue) _queue.clear();
    selfCue = AvatarMotionCue.idle;
    otherCue = AvatarMotionCue.idle;
    selfRevision += 1;
    otherRevision += 1;
    if (!_disposed) notifyListeners();
    if (identical(_activeController, this)) _activeController = null;
  }

  @override
  void dispose() {
    _disposed = true;
    _resetTimer?.cancel();
    _queue.clear();
    if (identical(_activeController, this)) _activeController = null;
    super.dispose();
  }
}

class _QueuedChoreography {
  const _QueuedChoreography({required this.payload, required this.actorIsSelf});

  final AvatarInteractionPayload payload;
  final bool actorIsSelf;
}
