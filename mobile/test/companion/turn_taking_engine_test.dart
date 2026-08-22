import 'package:flutter_test/flutter_test.dart';
import 'package:goods4ncu_mobile/companion/companion_events.dart';
import 'package:goods4ncu_mobile/companion/turn_taking_engine.dart';

void main() {
  late CompanionEventBus bus;
  late TurnTakingEngine engine;
  late DateTime now;
  var bargeInCount = 0;
  var lastLatency = Duration.zero;
  final turns = <String>[];

  setUp(() {
    bus = CompanionEventBus();
    bargeInCount = 0;
    lastLatency = Duration.zero;
    turns.clear();
    now = DateTime(2026, 8, 22, 12);
    engine = TurnTakingEngine(
      bus: bus,
      onBargeIn: (latency) {
        bargeInCount++;
        lastLatency = latency;
      },
      onTurnComplete: turns.add,
      now: () => now,
    );
    engine.clockForTest = () => now;
  });

  tearDown(() => bus.dispose());

  test('full happy path: speech → turn complete → response → idle', () {
    expect(engine.state, ConversationState.idle);

    engine.onPartialTranscript('你好');
    expect(engine.state, ConversationState.userSpeaking);

    engine.onFinalTranscript('你好');
    expect(engine.state, ConversationState.thinking);
    expect(turns, ['你好']);

    engine.onResponseStart();
    expect(engine.state, ConversationState.assistantStarting);

    engine.onAssistantSpeechStart();
    expect(engine.state, ConversationState.assistantSpeaking);

    engine.onAssistantSpeechEnd();
    expect(engine.state, ConversationState.idle);
  });

  test('short pause does not end the turn until final result arrives', () {
    engine.onPartialTranscript('我想找一个');
    engine.onPartialTranscript('我想找一个二手显示器');

    expect(engine.state, ConversationState.userSpeaking);
    expect(
      turns,
      isEmpty,
      reason: 'interim results must not trigger agent requests',
    );

    engine.onFinalTranscript('我想找一个二手显示器');
    expect(turns, ['我想找一个二手显示器']);
  });

  test(
    'barge-in: user speech while assistant talks fires interrupt fast',
    () async {
      final events = <CompanionEvent>[];
      bus.stream.listen(events.add);

      engine.onFinalTranscript('在吗');
      engine.onResponseStart();
      engine.onAssistantSpeechStart();
      expect(engine.state, ConversationState.assistantSpeaking);

      // User starts talking mid-answer, 120 ms after speech began.
      now = now.add(const Duration(milliseconds: 120));
      engine.bargeIn();

      expect(engine.state, ConversationState.interrupted);
      expect(bargeInCount, 1);
      expect(lastLatency.inMilliseconds, 120);
      // Latency budget §8: recorded so we can verify the <300 ms goal.
      expect(lastLatency.inMilliseconds, lessThanOrEqualTo(300));

      engine.resumeAfterInterrupt();
      expect(engine.state, ConversationState.userSpeaking);
      // And the interrupted answer never completes the old turn.
      expect(turns, hasLength(1));
    },
  );

  test('barge-in only fires while assistant audio is active', () {
    engine.onPartialTranscript('嗯');
    engine.bargeIn();

    expect(
      bargeInCount,
      0,
      reason: 'user speaking over themselves is not a barge-in',
    );
  });
}
