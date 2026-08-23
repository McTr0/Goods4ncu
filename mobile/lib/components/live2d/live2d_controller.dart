import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'live2d_effects.dart';
import 'xiaochang_brain.dart';

/// Available expression moods for the Live2D digital character.
enum Live2DExpression { idle, happy, thinking, shy, surprised, tongueOut }

/// Hit reaction zones for Talking-Tom style physical interaction.
enum Live2DHitZone { head, belly, none }

/// Controller that coordinates Live2D parameter state, motions, lip-sync, and LookAt tracking.
class Live2DController extends ChangeNotifier {
  final XiaochangBrain brain = XiaochangBrain();
  bool _brainDetached = false;

  /// Companion takeover: stop routing XiaochangBrain into this body so the
  /// CharacterDirector has exclusive control (goal §113).
  void detachBrain() {
    brain.removeListener(_onBrainChanged);
    _brainDetached = true;
  }

  // LookAt target coordinates (-1.0 to 1.0)
  double _lookAtX = 0.0;
  double _lookAtY = 0.0;

  // Mouth open factor for speech Lip-Sync (0.0 = closed, 1.0 = fully open)
  double _mouthOpen = 0.0;

  // Expression state
  Live2DExpression _expression = Live2DExpression.idle;

  // Active temporary motion cue / reaction
  String? _activeMotion;
  String? _speechBubble;
  Timer? _speechBubbleTimer;
  Timer? _motionTimer;
  Timer? _talkingSimulationTimer;
  Timer? _idleTimer;
  double _idleSway = 0.0;
  bool _isBlinking = false;

  // Drag physics
  bool _isDragging = false;
  Offset _dragOffset = Offset.zero;
  Live2DParticleSystem particleSystem = Live2DParticleSystem();

  // Touch & hit reaction states
  Live2DHitZone _lastHitZone = Live2DHitZone.none;
  int _hitCount = 0;
  String? _lastIntentReason;

  // Getters
  double get lookAtX => _lookAtX;
  double get lookAtY => _lookAtY;
  double get mouthOpen => _mouthOpen;
  Live2DExpression get expression => _expression;
  String? get activeMotion => _activeMotion;
  String? get speechBubble => _speechBubble;
  Live2DHitZone get lastHitZone => _lastHitZone;
  int get hitCount => _hitCount;
  double get idleSway => _idleSway;
  bool get isBlinking => _isBlinking;
  bool get isDragging => _isDragging;
  Offset get dragOffset => _dragOffset;

  Live2DController() {
    _startIdleMotion();
    particleSystem.start();
    brain.addListener(_onBrainChanged);
  }

  void _onBrainChanged() {
    lookAt(brain.gazeTargetX, brain.gazeTargetY);
    switch (brain.mood) {
      case XiaochangMood.happy:
        setExpression(Live2DExpression.happy);
      case XiaochangMood.curious:
        setExpression(Live2DExpression.thinking);
      case XiaochangMood.concerned:
        setExpression(Live2DExpression.surprised);
      case XiaochangMood.playful:
        setExpression(Live2DExpression.tongueOut);
      case XiaochangMood.sleepy:
        setExpression(Live2DExpression.idle);
      case XiaochangMood.neutral:
        if (!brain.isThinking && !brain.isSpeaking) {
          setExpression(Live2DExpression.idle);
        }
    }
    final intent = brain.currentIntent;
    if (intent != null &&
        (_activeMotion != intent.action ||
            _lastIntentReason != intent.reason)) {
      playMotion(intent.action, duration: intent.duration);
    }
    _lastIntentReason = intent?.reason;
  }

  void _startIdleMotion() {
    double phase = 0.0;
    int blinkCountdown = 120; // ~7 seconds before first blink at 60ms ticks
    _idleTimer = Timer.periodic(const Duration(milliseconds: 60), (timer) {
      if (_activeMotion != null) return;
      phase += 0.03;
      final newSway = math.sin(phase) * 0.04 + math.sin(phase * 2.3) * 0.02;
      if ((newSway - _idleSway).abs() > 0.005) {
        _idleSway = newSway;
        notifyListeners();
      }

      blinkCountdown--;
      if (blinkCountdown <= 0) {
        _isBlinking = true;
        notifyListeners();
        Future.delayed(const Duration(milliseconds: 140), () {
          _isBlinking = false;
          notifyListeners();
          // Random next blink in 3–8 seconds
          blinkCountdown = 50 + math.Random().nextInt(84);
        });
      }
    });
  }

  /// Update the LookAt target point in normalized space (-1.0 to 1.0).
  void lookAt(double normalizedX, double normalizedY) {
    final clampedX = normalizedX.clamp(-1.0, 1.0);
    final clampedY = normalizedY.clamp(-1.0, 1.0);
    if ((clampedX - _lookAtX).abs() > 0.01 ||
        (clampedY - _lookAtY).abs() > 0.01) {
      _lookAtX = clampedX;
      _lookAtY = clampedY;
      notifyListeners();
    }
  }

  /// Reset the character gaze back to the center.
  void resetGaze() {
    _lookAtX = 0.0;
    _lookAtY = 0.0;
    notifyListeners();
  }

  /// Begin a drag gesture at the current touch point.
  void startDrag(Offset position) {
    _isDragging = true;
    playMotion('lift', duration: const Duration(milliseconds: 220));
    notifyListeners();
  }

  /// Update the drag offset while the character is being dragged.
  void updateDrag(Offset delta) {
    if (!_isDragging) return;
    _dragOffset = Offset.lerp(_dragOffset, delta, 0.35)!;
    if (_dragOffset.distance > 40) {
      setExpression(Live2DExpression.surprised);
    }
    notifyListeners();
  }

  /// Release the drag with a spring-back animation.
  void endDrag() {
    if (!_isDragging) return;
    _isDragging = false;
    if (!_brainDetached) brain.onPhysicalInteraction('drag');
    // Spawn particles at release point proportional to drag distance
    final dist = _dragOffset.distance;
    if (dist > 15) {
      particleSystem.spawnBurst(
        type: Live2DParticleType.star,
        x: _dragOffset.dx,
        y: _dragOffset.dy,
        count: math.min(dist ~/ 10 + 2, 12),
      );
    }
    playMotion('spring_back');
    setExpression(Live2DExpression.happy);
    showSpeechBubble('哇~ 好好玩呀！', duration: const Duration(seconds: 2));
    // Spring back is animated in the widget via dragOffset lerp to zero.
    Future.delayed(const Duration(milliseconds: 100), () {
      _dragOffset = Offset.zero;
      notifyListeners();
    });
  }

  /// Set the mouth opening factor (0.0 to 1.0) for speech Lip-Sync.
  void setMouthOpen(double factor) {
    final clamped = factor.clamp(0.0, 1.0);
    if ((clamped - _mouthOpen).abs() > 0.05) {
      _mouthOpen = clamped;
      notifyListeners();
    }
  }

  /// Switch the active emotional expression.
  void setExpression(Live2DExpression expr) {
    if (_expression != expr) {
      _expression = expr;
      notifyListeners();
    }
  }

  /// Trigger a hit reaction based on tap position.
  /// Top 45% is treated as head; bottom is treated as belly/body.
  Live2DHitZone handleTap(Offset localPos, Size size) {
    if (size.height <= 0 || size.width <= 0) return Live2DHitZone.none;

    final relativeY = localPos.dy / size.height;
    _hitCount++;

    if (relativeY <= 0.45) {
      // Tapped Head
      _lastHitZone = Live2DHitZone.head;
      if (!_brainDetached) brain.onPhysicalInteraction('head');
      playMotion('tap_head');
      setExpression(Live2DExpression.shy);
      showSpeechBubble(_randomHeadGreeting());
      particleSystem.spawnBurst(
        type: Live2DParticleType.heart,
        x: localPos.dx,
        y: localPos.dy,
        count: 4,
      );
    } else {
      // Tapped Belly / Body
      _lastHitZone = Live2DHitZone.belly;
      if (!_brainDetached) brain.onPhysicalInteraction('belly');
      playMotion('poke_belly');
      setExpression(Live2DExpression.surprised);
      showSpeechBubble(_randomBellyGreeting());
      particleSystem.spawnBurst(
        type: Live2DParticleType.bubble,
        x: localPos.dx,
        y: localPos.dy,
        count: 6,
      );
    }

    notifyListeners();
    return _lastHitZone;
  }

  /// Play a named motion track with automatic reset to idle.
  void playMotion(
    String motionName, {
    Duration duration = const Duration(milliseconds: 1200),
  }) {
    _activeMotion = motionName;
    _motionTimer?.cancel();
    _motionTimer = Timer(duration, () {
      _activeMotion = null;
      if (_expression == Live2DExpression.shy ||
          _expression == Live2DExpression.surprised) {
        _expression = Live2DExpression.idle;
      }
      notifyListeners();
    });
    notifyListeners();
  }

  /// Display a speech bubble above the character.
  /// If [duration] is provided, the bubble will automatically hide after that duration.
  /// If [duration] is null, the bubble remains visible until explicitly updated or cleared.
  void showSpeechBubble(String text, {Duration? duration}) {
    _speechBubble = text;
    _speechBubbleTimer?.cancel();
    if (duration != null) {
      _speechBubbleTimer = Timer(duration, () {
        _speechBubble = null;
        notifyListeners();
      });
    }
    notifyListeners();
  }

  /// Clear any active speech bubble immediately.
  void clearSpeechBubble() {
    _speechBubbleTimer?.cancel();
    if (_speechBubble != null) {
      _speechBubble = null;
      notifyListeners();
    }
  }

  /// Start simulated lip-sync speech animation (for mock testing or demo).
  void startTalkingSimulation({
    Duration duration = const Duration(seconds: 3),
  }) {
    _talkingSimulationTimer?.cancel();
    int ticks = 0;
    _talkingSimulationTimer = Timer.periodic(const Duration(milliseconds: 60), (
      timer,
    ) {
      ticks++;
      // Oscillate mouth open with natural phonetic cadence
      final openVal =
          (math.sin(ticks * 0.8) * 0.5 + 0.5) *
          (0.4 + 0.6 * math.Random().nextDouble());
      setMouthOpen(openVal);

      if (ticks >= duration.inMilliseconds ~/ 60) {
        timer.cancel();
        setMouthOpen(0.0);
      }
    });
  }

  /// Stop any active speech simulation.
  void stopTalking() {
    _talkingSimulationTimer?.cancel();
    setMouthOpen(0.0);
  }

  String _randomHeadGreeting() {
    const greetings = [
      '摸摸头~ 今天有什么想买或者想出的宝贝吗？',
      '好舒服呀！小昌随时为你服务~',
      '嘻嘻，头上的智慧天线收到你的指令啦！',
      '别摸啦，发型都要乱啦 (害羞)',
    ];
    return greetings[_hitCount % greetings.length];
  }

  String _randomBellyGreeting() {
    const greetings = [
      '戳我干嘛呀~ 痒痒的！',
      '快去前湖广场淘点二手好物吧！',
      '小昌元气满满，正在待命中！',
      '哎呀，肚子要被你戳扁啦！',
    ];
    return greetings[_hitCount % greetings.length];
  }

  @override
  void dispose() {
    brain.removeListener(_onBrainChanged);
    brain.dispose();
    _motionTimer?.cancel();
    _speechBubbleTimer?.cancel();
    _talkingSimulationTimer?.cancel();
    _idleTimer?.cancel();
    particleSystem.dispose();
    super.dispose();
  }
}
