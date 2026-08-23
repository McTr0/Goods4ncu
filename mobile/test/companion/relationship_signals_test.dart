import 'package:flutter_test/flutter_test.dart';
import 'package:goods4ncu_mobile/companion/relationship_signals.dart';

void main() {
  late CompanionRelationshipSignals signals;
  var clock = DateTime(2026, 8, 22, 12);

  setUp(() {
    signals = CompanionRelationshipSignals();
    clock = DateTime(2026, 8, 22, 12);
  });

  test('thanks wins over everything on the same turn', () {
    signals.onTurnStart();
    signals.onToolActivity();
    final event = signals.eventForCompletedTurn('太感谢了！', now: () => clock);
    expect(event, 'user_thanks');
  });

  test('tool use maps to user_uses_agent_tool', () {
    signals.onTurnStart();
    signals.onToolActivity();

    final event = signals.eventForCompletedTurn('帮我看看手环', now: () => clock);
    expect(event, 'user_uses_agent_tool');
  });

  test('plain turns accumulate into long_conversation after six rounds', () {
    for (var i = 0; i < 5; i++) {
      signals.onTurnStart();
      expect(signals.eventForCompletedTurn('继续', now: () => clock), isNull);
    }

    signals.onTurnStart();
    expect(
      signals.eventForCompletedTurn('还在吗', now: () => clock),
      'long_conversation',
    );
  });

  test('long_conversation re-arms only outside the window', () {
    // First long-conversation at round 6.
    for (var i = 0; i < 6; i++) {
      signals.onTurnStart();
      signals.eventForCompletedTurn('聊', now: () => clock);
    }
    expect(
      signals.eventForCompletedTurn('聊', now: () => clock),
      isNull,
      reason: 'within the 30 min window no second credit',
    );

    clock = clock.add(const Duration(minutes: 31));
    signals.onTurnStart();
    expect(signals.eventForCompletedTurn('又来了', now: () => clock), isNotNull);
  });
}
