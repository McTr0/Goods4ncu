import 'package:flutter_test/flutter_test.dart';
import 'package:goods4ncu_mobile/companion/companion_events.dart';
import 'package:goods4ncu_mobile/companion/emotion_engine.dart';

void main() {
  late CompanionEventBus bus;
  late List<CompanionEvent> seen;

  setUp(() {
    bus = CompanionEventBus();
    seen = [];
    bus.stream.listen(seen.add);
  });

  tearDown(() => bus.dispose());

  group('compose (deterministic)', () {
    test('agent suggestion moves the vector by table delta * intensity', () {
      final previous = const EmotionVector();
      final next = EmotionEngine.compose(
        previous: previous,
        suggestion: const EmotionSuggestion(EmotionIntent.happy, 0.5),
      );

      expect(next.valence, closeTo(previous.valence + 0.275, 1e-9));
      expect(next.arousal, closeTo(previous.arousal + 0.125, 1e-9));
    });

    test('same inputs always produce the same output', () {
      const suggestion = EmotionSuggestion(EmotionIntent.curious, 0.8);
      const event = {'arousal': 0.1};

      final a = EmotionEngine.compose(
        previous: const EmotionVector(),
        suggestion: suggestion,
        eventDelta: EmotionVector.fromMap(event),
        relationshipAffinityBonus: 0.2,
      );
      final b = EmotionEngine.compose(
        previous: const EmotionVector(),
        suggestion: suggestion,
        eventDelta: EmotionVector.fromMap(event),
        relationshipAffinityBonus: 0.2,
      );

      expect(a.toMap(), b.toMap());
    });

    test('relationship bonus scales existing positive valence only', () {
      final positive = EmotionEngine.compose(
        previous: const EmotionVector(),
        suggestion: const EmotionSuggestion(EmotionIntent.happy, 1),
        relationshipAffinityBonus: 0.5,
      );
      final negative = EmotionEngine.compose(
        previous: const EmotionVector(),
        suggestion: const EmotionSuggestion(EmotionIntent.concerned, 1),
        relationshipAffinityBonus: 0.5,
      );

      // Positive moment amplified…
      expect(positive.valence, greaterThan(0.55));
      // …negative moment never flipped or deepened by affinity.
      expect(negative.valence, closeTo(-0.35, 1e-9));
    });

    test('clamps at vector bounds', () {
      var v = const EmotionVector();
      for (var i = 0; i < 10; i++) {
        v = EmotionEngine.compose(
          previous: v,
          suggestion: const EmotionSuggestion(EmotionIntent.excited, 1),
        );
      }
      expect(v.valence, lessThanOrEqualTo(1));
      expect(v.arousal, lessThanOrEqualTo(1));
    });
  });

  group('decay', () {
    test('arousal decays much faster than affection', () async {
      final engine = EmotionEngine(bus: bus);
      engine.applyEvent({'arousal': 0.8, 'affection': 0.8});
      final start = engine.state;

      // Simulate ~2 seconds of ticks.
      for (var i = 0; i < 20; i++) {
        engine.tick(const Duration(milliseconds: 100));
      }

      final arousalLost = start.arousal - engine.state.arousal;
      final affectionLost = start.affection - engine.state.affection;
      expect(arousalLost, greaterThan(affectionLost * 5));
    });

    test('embarrassment decays at a medium rate', () async {
      final engine = EmotionEngine(bus: bus);
      engine.applyEvent({'embarrassment': 1.0});

      for (var i = 0; i < 50; i++) {
        engine.tick(const Duration(milliseconds: 100)); // 5 s
      }

      expect(engine.state.embarrassment, inInclusiveRange(0.3, 0.95));
    });

    test('emits emotionChanged when decay moves a dimension', () async {
      final engine = EmotionEngine(bus: bus);
      engine.applyEvent({'arousal': 0.6});
      seen.clear();

      engine.tick(const Duration(seconds: 1));
      await Future<void>.delayed(Duration.zero);

      expect(
        seen.any((e) => e.type == CompanionEventType.emotionChanged),
        isTrue,
      );
    });
  });

  test('zero-intensity suggestions are rejected via callback', () {
    final rejected = <EmotionIntent>[];
    final engine = EmotionEngine(bus: bus, onIllegalSuggestion: rejected.add);

    engine.suggest(const EmotionSuggestion(EmotionIntent.happy, 0));

    expect(rejected, [EmotionIntent.happy]);
    expect(engine.state.valence, 0);
  });
}
