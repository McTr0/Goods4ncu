import 'package:flutter_test/flutter_test.dart';
import 'package:goods4ncu_mobile/companion/companion_events.dart';
import 'package:goods4ncu_mobile/companion/state_machine.dart';

void main() {
  late CompanionEventBus bus;
  late List<CompanionEvent> seen;

  setUp(() {
    bus = CompanionEventBus();
    seen = [];
    bus.stream.listen(seen.add);
  });

  tearDown(() => bus.dispose());

  test('starts idle and follows the canonical listening loop', () {
    final sm = CompanionStateMachine(bus: bus);

    expect(sm.state, CompanionState.idle);
    expect(sm.transition(CompanionState.listening), isTrue);
    expect(sm.transition(CompanionState.thinking), isTrue);
    expect(sm.transition(CompanionState.speaking), isTrue);
    expect(sm.transition(CompanionState.idle), isTrue);
    expect(sm.state, CompanionState.idle);
  });

  test('rejects illegal transitions and keeps the previous state', () {
    final illegal = <CompanionState, CompanionState>{};
    final sm = CompanionStateMachine(
      bus: bus,
      onIllegalTransition: (from, attempt) => illegal[from] = attempt,
    );

    // idle → speaking skips notice/listen/think.
    expect(sm.transition(CompanionState.speaking), isFalse);
    expect(sm.state, CompanionState.idle);
    expect(illegal[CompanionState.idle], CompanionState.speaking);

    // speaking must not jump straight back to toolUsing? It may — but
    // sleeping directly from listening is nonsense.
    sm.reset(CompanionState.listening);
    expect(sm.transition(CompanionState.sleeping), isFalse);
    expect(sm.state, CompanionState.listening);
  });

  test('barge-in contract: interrupted resolves only into listening/idle', () {
    final sm = CompanionStateMachine(bus: bus);

    sm.reset(CompanionState.speaking);
    expect(sm.transition(CompanionState.interrupted), isTrue);
    expect(
      sm.transition(CompanionState.speaking),
      isFalse,
      reason: 'must never resume the cancelled utterance',
    );
    expect(sm.transition(CompanionState.listening), isTrue);
  });

  test('emits characterStateChanged events with from/to payload', () async {
    final sm = CompanionStateMachine(bus: bus);

    sm.transition(CompanionState.listening);
    await Future<void>.delayed(Duration.zero);

    expect(
      seen.where((e) => e.type == CompanionEventType.characterStateChanged),
      hasLength(1),
    );
    final event = seen.firstWhere(
      (e) => e.type == CompanionEventType.characterStateChanged,
    );
    expect(event.data['from'], 'idle');
    expect(event.data['to'], 'listening');
  });

  test('timeInState resets on transition', () async {
    final sm = CompanionStateMachine(bus: bus);

    sm.transition(CompanionState.listening);
    await Future<void>.delayed(const Duration(milliseconds: 15));

    expect(sm.timeInState.inMilliseconds, lessThan(500));
  });
}
