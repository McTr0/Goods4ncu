import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

import 'animation_priority.dart';
import 'animation_scheduler.dart';
import 'attention.dart';
import 'behavior_planner.dart';
import 'character_renderer.dart';
import 'companion_events.dart';
import 'emotion_engine.dart';
import 'gaze.dart';
import 'mock_renderer.dart';
import 'motion_library.dart';
import 'state_machine.dart';

/// Owns the companion runtime singletons and exposes one snapshot stream.
///
/// Provided at app root so the assistant page, debug console, and timeline
/// debugger all observe the *same* runtime.
class CompanionRuntimeHost extends ChangeNotifier {
  CompanionRuntimeHost({bool startTicker = true}) {
    bus = CompanionEventBus();
    machine = CompanionStateMachine(
      bus: bus,
      onIllegalTransition: (from, attempt) => debugPrint(
        'companion: illegal transition ${from.name}→${attempt.name}',
      ),
    );
    emotions = EmotionEngine(bus: bus);
    attention = AttentionController(bus: bus);
    renderer = MockCharacterRenderer();
    timeline.attachTo(bus);
    _busSub = bus.stream.listen(_onEvent);

    planner = const BehaviorPlanner();
    scheduler = AnimationScheduler(
      bus: bus,
      onPlayClip: (clip) => unawaited(renderer.playMotion(clip)),
      onGaze: (x, y) => _gaze.setTarget(x, y),
      onHeadTilt: (degrees) => renderer.setParameter('headTilt', degrees),
    );

    if (startTicker) {
      _lastTick = DateTime.now();
      _ticker = Timer.periodic(
        const Duration(milliseconds: 16),
        (_) => _tick(),
      );
    }
  }

  late final CompanionEventBus bus;
  late final CompanionStateMachine machine;
  late final EmotionEngine emotions;
  late final AttentionController attention;
  late final MockCharacterRenderer renderer;
  late final BehaviorPlanner planner;
  late final AnimationScheduler scheduler;
  final CompanionTimeline timeline = CompanionTimeline();
  StreamSubscription<CompanionEvent>? _busSub;
  bool _disposed = false;

  final GazeSmoother _gaze = GazeSmoother();
  final Random _random = Random();
  Timer? _ticker;
  DateTime _lastTick = DateTime.now();
  DateTime _lastInteraction = DateTime.now();

  String? currentMotion;

  CompanionRuntimeSnapshot snapshot() => CompanionRuntimeSnapshot(
    state: machine.state,
    emotion: emotions.state,
    attention: attention.state,
    currentMotion: currentMotion,
    mouthOpen: renderer.mouthOpen,
  );

  // ---------------------------------------------------------------------------
  // Inputs
  // ---------------------------------------------------------------------------

  /// Agent/tool/UI signals expressed in semantics ("tool_using_search_inventory",
  /// "SHOW_POSTS", "greet_user", …). The director decides the body's reaction.
  void onSignal(String signal, {AnimationPriority? priority}) {
    _lastInteraction = DateTime.now();
    final plan = planner.planForSignal(
      signal,
      priority: priority ?? AnimationPriority.speechGesture,
    );
    if (plan.tag != MotionTag.idleShift || plan.steps.isNotEmpty) {
      scheduler.request(plan);
    }
  }

  /// User touched/poked the character — always a local reaction, never an LLM
  /// call (goal §59).
  void onPhysicalInteraction(String zone) {
    _lastInteraction = DateTime.now();
    attention.focusUser(lockFor: const Duration(seconds: 3));
    final tag = zone == 'head' ? MotionTag.smallGreeting : MotionTag.agree;
    scheduler.request(planForTag(tag, AnimationPriority.userInteraction));
  }

  /// Demo/verification loop used by the debug console (goal §81):
  /// tap → LISTENING → THINKING → SPEAKING → IDLE with no LLM involved.
  Future<void> runInteractionLoop() async {
    _lastInteraction = DateTime.now();
    if (!machine.transition(CompanionState.listening)) return;
    await Future<void>.delayed(const Duration(milliseconds: 250));
    if (!machine.transition(CompanionState.thinking)) return;
    await Future<void>.delayed(const Duration(milliseconds: 350));
    if (!machine.transition(CompanionState.speaking)) return;
    scheduler.request(
      planForTag(MotionTag.acknowledge, AnimationPriority.speechGesture),
      preemptEqual: true, // speaking replaces the thinking gesture
    );
    bus.emit(CompanionEventType.ttsStart, {'source': 'demo'});
    await Future<void>.delayed(const Duration(milliseconds: 500));
    bus.emit(CompanionEventType.ttsEnd, {'source': 'demo'});
    machine.transition(CompanionState.idle);
  }

  // ---------------------------------------------------------------------------
  // Director internals
  // ---------------------------------------------------------------------------

  void _onEvent(CompanionEvent event) {
    if (_disposed) return;
    switch (event.type) {
      case CompanionEventType.characterStateChanged:
        renderer.setCharacterState(machine.state);
        _planForStateChange(event.data['to'] as String? ?? machine.state.name);
        break;
      case CompanionEventType.motionStarted:
        currentMotion = event.data['tag'] as String?;
        break;
      case CompanionEventType.motionFinished:
        currentMotion = null;
        _returnFromAffectState(event.data['reason'] as String? ?? 'finished');
        break;
      default:
        break;
    }
    notifyListeners();
  }

  void _planForStateChange(String stateName) {
    // Interrupt overrides all; functional states (listen/think/tools) outrank
    // affective overlays because equal priority never preempts.
    var priority = AnimationPriority.emotion;
    const functional = {'listening', 'thinking', 'toolUsing', 'speaking'};
    if (stateName == 'interrupted') {
      priority = AnimationPriority.interrupt;
    } else if (functional.contains(stateName)) {
      priority = AnimationPriority.speechGesture;
    }
    final plan = planner.planForState(
      stateName,
      emotion: emotions.state,
      priority: priority,
    );
    // State transitions are sequential by nature: a newer state replaces an
    // older state's gesture even at equal priority.
    if (plan.steps.isNotEmpty) scheduler.request(plan, preemptEqual: true);
  }

  void _returnFromAffectState(String reason) {
    if (reason == 'preempted') return; // something more important took over.
    const affectStates = {
      'happy',
      'excited',
      'shy',
      'surprised',
      'curious',
      'bored',
    };
    if (affectStates.contains(machine.state.name)) {
      machine.transition(CompanionState.idle);
    }
  }

  void _tick() {
    if (_disposed) return;
    final now = DateTime.now();
    final elapsed = now.difference(_lastTick);
    _lastTick = now;

    emotions.tick(elapsed);
    _gaze.tick(elapsed);
    renderer.setGaze(_gaze.x, _gaze.y);

    if (machine.state == CompanionState.idle &&
        !scheduler.isBusy &&
        now.isAfter(_nextIdleCheck)) {
      _nextIdleCheck = now.add(const Duration(seconds: 5));
      _driveIdleTier(now.difference(_lastInteraction));
    }
  }

  DateTime _nextIdleCheck = DateTime.now();

  void _driveIdleTier(Duration idleFor) {
    switch (idleTierFor(idleFor)) {
      case IdleTier.micro:
      case IdleTier.none:
        break;
      case IdleTier.shortIdle:
        scheduler.request(
          planForTag(MotionTag.idleShift, AnimationPriority.idle),
        );
      case IdleTier.longIdle:
        if (_random.nextBool()) {
          scheduler.request(
            planForTag(MotionTag.stretch, AnimationPriority.idle),
          );
        } else if (idleFor > const Duration(minutes: 6)) {
          // Long absence: doze off rather than freeze (§35).
          machine.transition(CompanionState.sleeping);
        } else {
          attention.lookAt(AttentionTarget.none);
        }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _ticker?.cancel();
    unawaited(_busSub?.cancel());
    super.dispose();
  }
}
