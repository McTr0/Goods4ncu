import 'package:flutter/foundation.dart';

import 'attention.dart';
import 'character_renderer.dart';
import 'companion_events.dart';
import 'emotion_engine.dart';
import 'mock_renderer.dart';
import 'state_machine.dart';

/// Owns the companion runtime singletons and exposes one snapshot stream.
///
/// Provided at app root so the assistant page, debug console, and timeline
/// debugger all observe the *same* runtime.
class CompanionRuntimeHost extends ChangeNotifier {
  CompanionRuntimeHost() {
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
    bus.stream.listen((event) {
      switch (event.type) {
        case CompanionEventType.characterStateChanged:
          renderer.setCharacterState(machine.state);
          break;
        case CompanionEventType.motionStarted:
          currentMotion = event.data['tag'] as String?;
          break;
        case CompanionEventType.motionFinished:
          currentMotion = null;
          break;
        default:
          break;
      }
      notifyListeners();
    });
  }

  late final CompanionEventBus bus;
  late final CompanionStateMachine machine;
  late final EmotionEngine emotions;
  late final AttentionController attention;
  late final MockCharacterRenderer renderer;
  final CompanionTimeline timeline = CompanionTimeline();

  String? currentMotion;

  CompanionRuntimeSnapshot snapshot() => CompanionRuntimeSnapshot(
    state: machine.state,
    emotion: emotions.state,
    attention: attention.state,
    currentMotion: currentMotion,
    mouthOpen: renderer.mouthOpen,
  );

  /// Demo/verification loop used by the debug console (goal §81):
  /// tap → LISTENING → THINKING → SPEAKING → IDLE with no LLM involved.
  Future<void> runInteractionLoop() async {
    if (!machine.transition(CompanionState.listening)) return;
    await Future<void>.delayed(const Duration(milliseconds: 250));
    if (!machine.transition(CompanionState.thinking)) return;
    await Future<void>.delayed(const Duration(milliseconds: 350));
    if (!machine.transition(CompanionState.speaking)) return;
    renderer.playMotion('acknowledge', priority: 70);
    bus.emit(CompanionEventType.ttsStart, {'source': 'demo'});
    await Future<void>.delayed(const Duration(milliseconds: 500));
    bus.emit(CompanionEventType.ttsEnd, {'source': 'demo'});
    machine.transition(CompanionState.idle);
  }

  @override
  void dispose() {
    bus.dispose();
    super.dispose();
  }
}
