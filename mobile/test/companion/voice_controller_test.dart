import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:goods4ncu_mobile/companion/companion_events.dart';
import 'package:goods4ncu_mobile/companion/turn_taking_engine.dart';
import 'package:goods4ncu_mobile/companion/voice_controller.dart';
import 'package:goods4ncu_mobile/companion/voice_provider.dart';
import 'package:goods4ncu_mobile/services/speech_dictation.dart';
import 'package:goods4ncu_mobile/services/speech_dictation_contract.dart';

class _FakeDictation implements SpeechDictation {
  _FakeDictation();

  void Function(SpeechDictationResult result)? resultSink;
  final List<String> errors = [];

  @override
  bool get isSupported => true;

  @override
  Future<void> start({
    required String locale,
    required void Function(SpeechDictationResult result) onResult,
    required void Function(String code) onError,
    required SpeechDictationEnded onEnded,
  }) async {
    resultSink = onResult;
  }

  @override
  Future<void> stop() async {}

  @override
  void dispose() {}

  void emitPartial(String text) =>
      resultSink?.call(SpeechDictationResult(text: text, isFinal: false));

  void emitFinal(String text) =>
      resultSink?.call(SpeechDictationResult(text: text, isFinal: true));
}

class _FakeVoiceProvider implements VoiceProvider {
  StreamController<SpeechUtteranceEvent>? active;

  var stopped = false;
  var spoken = <String>[];

  @override
  bool get isSupported => true;

  @override
  bool get isSpeaking => active != null && !active!.isClosed;

  @override
  Future<void> startSession() async {}

  @override
  Stream<SpeechUtteranceEvent> speak(String text, {VoiceStyle? style}) {
    spoken.add(text);
    final controller = StreamController<SpeechUtteranceEvent>();
    active = controller;
    controller.add(SpeechUtteranceEvent(SpeechEventKind.started));
    return controller.stream;
  }

  void emitBoundary() =>
      active?.add(SpeechUtteranceEvent(SpeechEventKind.boundary, charIndex: 3));

  @override
  Future<void> stop() async {
    stopped = true;
    active?.add(SpeechUtteranceEvent(SpeechEventKind.ended));
    await active?.close();
    active = null;
  }
}

void main() {
  late CompanionEventBus bus;
  late TurnTakingEngine engine;
  late _FakeDictation dictation;
  late _FakeVoiceProvider provider;
  late CompanionVoiceController controller;
  final turns = <String>[];
  var interrupted = 0;

  setUp(() {
    bus = CompanionEventBus();
    turns.clear();
    interrupted = 0;
    engine = TurnTakingEngine(
      bus: bus,
      onBargeIn: (_) => interrupted++,
      onTurnComplete: turns.add,
    );
    dictation = _FakeDictation();
    provider = _FakeVoiceProvider();
    controller = CompanionVoiceController(
      bus: bus,
      engine: engine,
      provider: provider,
      dictation: dictation,
      onTurnReady: (text) => turns.add('ready:$text'),
      onInterrupted: () => interrupted++,
    );
  });

  tearDown(() {
    controller.dispose();
    bus.dispose();
  });

  test(
    'partial transcript opens the user turn; final closes and dispatches',
    () async {
      await controller.startListening();
      expect(dictation.resultSink, isNotNull);

      dictation.emitPartial('帮我看看');
      expect(engine.state, ConversationState.userSpeaking);
      expect(turns, isEmpty);

      dictation.emitFinal('帮我看看有没有显示器');
      // The controller wraps the engine callback with its own dispatch marker.
      expect(turns, ['ready:帮我看看有没有显示器']);
      expect(engine.state, ConversationState.thinking);
    },
  );

  test('speaking through the provider pulses mouth and closes it', () async {
    final events = provider.speak('你好呀', style: const VoiceStyle());
    events.listen((e) {});
    // Give the fake a boundary then end.
    provider.emitBoundary();
    await provider.stop();

    expect(provider.spoken, ['你好呀']);
    expect(controller.mouthValue, 0);
  });

  test('barge-in stops TTS first and notifies both paths', () async {
    await controller.startListening();
    final events = provider.speak('我刚才看到几条显示器的帖子');
    events.listen((_) {});
    final interruptEvents = <CompanionEventType>[];
    bus.on(CompanionEventType.interrupted, (e) => interruptEvents.add(e.type));
    // TTS is now active: mark the conversation accordingly.
    engine.onFinalTranscript('在吗');
    engine.onResponseStart();
    engine.onAssistantSpeechStart();
    expect(engine.state, ConversationState.assistantSpeaking);

    // User starts talking mid-answer.
    dictation.emitPartial('等一下');
    await Future<void>.delayed(Duration.zero); // bus delivery is async

    expect(
      interrupted,
      greaterThanOrEqualTo(1),
      reason: 'onInterrupted fires via barge-in hook',
    );
    expect(provider.stopped, isTrue, reason: 'TTS must stop immediately');
    // Interrupted is transient: the user takes the floor immediately.
    expect(engine.state, ConversationState.userSpeaking);
    expect(
      interruptEvents,
      hasLength(1),
      reason: 'INTERRUPTED is announced once on the bus',
    );
  });
}
