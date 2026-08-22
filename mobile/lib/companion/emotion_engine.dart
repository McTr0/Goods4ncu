import 'package:flutter/foundation.dart';

import 'companion_events.dart';

/// Continuous emotion state (master goal §10).
///
/// Deliberately separate from the behavioural [CompanionState]: the body can
/// be `SPEAKING` while valence/arousal say "worried but composed".
@immutable
class EmotionVector {
  const EmotionVector({
    this.valence = 0,
    this.arousal = 0.2,
    this.dominance = 0.5,
    this.curiosity = 0.3,
    this.confidence = 0.6,
    this.embarrassment = 0,
    this.affection = 0.1,
  });

  /// -1 … 1 (unhappy → happy).
  final double valence;

  /// The additive identity — safe to use as a delta default. The unnamed
  /// constructor is the *neutral baseline*, not zero.
  static const EmotionVector zero = EmotionVector(
    valence: 0,
    arousal: 0,
    dominance: 0,
    curiosity: 0,
    confidence: 0,
    embarrassment: 0,
    affection: 0,
  );

  /// 0 … 1 (calm → agitated). Fast-decaying energy.
  final double arousal;

  /// 0 … 1 (submissive → in control).
  final double dominance;

  /// 0 … 1.
  final double curiosity;

  /// 0 … 1.
  final double confidence;

  /// 0 … 1. Medium decay.
  final double embarrassment;

  /// 0 … 1. Extremely slow decay by design.
  final double affection;

  static double _clamp01(double v) => v.clamp(0.0, 1.0);

  EmotionVector._normalized(
    double valence,
    double arousal,
    double dominance,
    double curiosity,
    double confidence,
    double embarrassment,
    double affection,
  ) : valence = valence.clamp(-1.0, 1.0),
      arousal = _clamp01(arousal),
      dominance = _clamp01(dominance),
      curiosity = _clamp01(curiosity),
      confidence = _clamp01(confidence),
      embarrassment = _clamp01(embarrassment),
      affection = _clamp01(affection);

  /// Missing keys are treated as zero so partial event deltas never inject
  /// baseline values by accident.
  factory EmotionVector.fromMap(Map<String, double> map) =>
      EmotionVector._normalized(
        map['valence'] ?? 0,
        map['arousal'] ?? 0,
        map['dominance'] ?? 0,
        map['curiosity'] ?? 0,
        map['confidence'] ?? 0,
        map['embarrassment'] ?? 0,
        map['affection'] ?? 0,
      );

  EmotionVector operator +(EmotionVector other) => EmotionVector._normalized(
    valence + other.valence,
    arousal + other.arousal,
    dominance + other.dominance,
    curiosity + other.curiosity,
    confidence + other.confidence,
    embarrassment + other.embarrassment,
    affection + other.affection,
  );

  EmotionVector scaled(double factor) => EmotionVector(
    valence: valence * factor,
    arousal: arousal * factor,
    dominance: dominance * factor,
    curiosity: curiosity * factor,
    confidence: confidence * factor,
    embarrassment: embarrassment * factor,
    affection: affection * factor,
  );

  Map<String, double> toMap() => {
    'valence': valence,
    'arousal': arousal,
    'dominance': dominance,
    'curiosity': curiosity,
    'confidence': confidence,
    'embarrassment': embarrassment,
    'affection': affection,
  };

  @override
  String toString() =>
      'v=${valence.toStringAsFixed(2)} a=${arousal.toStringAsFixed(2)} '
      'c=${curiosity.toStringAsFixed(2)} aff=${affection.toStringAsFixed(2)}';
}

/// High-level emotional intents an agent may *suggest* (§11). The runtime
/// composes them with history/events — suggestions never hard-set state.
enum EmotionIntent {
  neutral,
  happy,
  excited,
  curious,
  confused,
  surprised,
  shy,
  concerned,
  bored,
  affectionate,
}

class EmotionSuggestion {
  const EmotionSuggestion(this.type, this.intensity);

  final EmotionIntent type;

  /// 0 … 1.
  final double intensity;
}

/// Per-dimension decay toward baseline, fraction per second (§12).
///
/// Surprise-grade spikes live in `arousal` (fast), affection barely moves.
class EmotionDecayConfig {
  const EmotionDecayConfig({
    this.valencePerSecond = 0.03,
    this.arousalPerSecond = 0.10,
    this.dominancePerSecond = 0.010,
    this.curiosityPerSecond = 0.020,
    this.confidencePerSecond = 0.004,
    this.embarrassmentPerSecond = 0.06,
    this.affectionPerSecond = 0.002,
  });

  final double valencePerSecond;
  final double arousalPerSecond;
  final double dominancePerSecond;
  final double curiosityPerSecond;
  final double confidencePerSecond;
  final double embarrassmentPerSecond;
  final double affectionPerSecond;

  double rateFor(String dimension) => switch (dimension) {
    'valence' => valencePerSecond,
    'arousal' => arousalPerSecond,
    'dominance' => dominancePerSecond,
    'curiosity' => curiosityPerSecond,
    'confidence' => confidencePerSecond,
    'embarrassment' => embarrassmentPerSecond,
    'affection' => affectionPerSecond,
    _ => 0,
  };
}

/// Deterministic composition of the character's emotional state (§11).
///
///   next = clamp(decayed(previous) + agent + events + relationship)
///
/// Same inputs always produce the same output — no randomness anywhere.
class EmotionEngine {
  EmotionEngine({
    required CompanionEventBus bus,
    EmotionDecayConfig decayConfig = const EmotionDecayConfig(),
    this.onIllegalSuggestion,
  }) : _bus = bus,
       _decay = decayConfig;

  final CompanionEventBus _bus;
  final EmotionDecayConfig _decay;

  final void Function(EmotionIntent attempt)? onIllegalSuggestion;

  static const double _epsilon = 0.005;

  EmotionVector _state = const EmotionVector();

  EmotionVector get state => _state;

  /// Agent-proposed intent mapped onto vector deltas at intensity 1.
  static EmotionVector deltaFor(EmotionIntent type) => switch (type) {
    EmotionIntent.neutral => EmotionVector.zero,
    EmotionIntent.happy => const EmotionVector(
      valence: 0.55,
      arousal: 0.25,
      affection: 0.08,
    ),
    EmotionIntent.excited => const EmotionVector(
      valence: 0.7,
      arousal: 0.65,
      dominance: 0.2,
    ),
    EmotionIntent.curious => const EmotionVector(
      valence: 0.15,
      arousal: 0.25,
      curiosity: 0.7,
    ),
    EmotionIntent.confused => const EmotionVector(
      valence: -0.05,
      arousal: 0.15,
      confidence: -0.4,
      curiosity: 0.3,
    ),
    EmotionIntent.surprised => const EmotionVector(
      arousal: 0.8,
      dominance: -0.2,
      curiosity: 0.35,
    ),
    EmotionIntent.shy => const EmotionVector(
      valence: 0.25,
      arousal: 0.2,
      dominance: -0.15,
      embarrassment: 0.6,
    ),
    EmotionIntent.concerned => const EmotionVector(
      valence: -0.35,
      arousal: 0.25,
      dominance: 0.1,
    ),
    EmotionIntent.bored => const EmotionVector(
      valence: -0.25,
      arousal: -0.3,
      curiosity: -0.25,
    ),
    EmotionIntent.affectionate => const EmotionVector(
      valence: 0.35,
      arousal: 0.15,
      affection: 0.3,
    ),
  };

  /// Pure composition step — exported for regression tests (persona §23).
  static EmotionVector compose({
    required EmotionVector previous,
    EmotionSuggestion? suggestion,
    EmotionVector eventDelta = EmotionVector.zero,
    double relationshipAffinityBonus = 0,
  }) {
    var next = previous;
    if (suggestion != null && suggestion.type != EmotionIntent.neutral) {
      next =
          next +
          deltaFor(suggestion.type).scaled(suggestion.intensity.clamp(0, 1));
    }
    next = next + eventDelta;
    // A warmer relationship tints positive moments; it can never manufacture
    // positivity out of nothing because it only scales existing valence.
    if (next.valence > 0) {
      next = EmotionVector.fromMap({
        ...next.toMap(),
        'valence': (next.valence * (1 + relationshipAffinityBonus)).clamp(
          -1,
          1,
        ),
        'affection': (next.affection * (1 + relationshipAffinityBonus / 2))
            .clamp(0, 1),
      });
    }
    return next;
  }

  void suggest(EmotionSuggestion suggestion) {
    if (suggestion.type == EmotionIntent.neutral) return;
    if (suggestion.intensity <= 0) {
      onIllegalSuggestion?.call(suggestion.type);
      return;
    }
    apply(suggestion: suggestion);
  }

  /// Raw event nudges, e.g. a startle on barge-in: `{arousal: 0.4}`.
  void applyEvent(Map<String, double> delta) =>
      apply(eventDelta: EmotionVector.fromMap(delta));

  void apply({
    EmotionSuggestion? suggestion,
    EmotionVector eventDelta = EmotionVector.zero,
    double relationshipAffinityBonus = 0,
  }) {
    final next = compose(
      previous: _state,
      suggestion: suggestion,
      eventDelta: eventDelta,
      relationshipAffinityBonus: relationshipAffinityBonus,
    );
    _setState(next);
  }

  /// Advance decay toward baseline; call once per animation frame or timer.
  void tick(Duration elapsed) {
    final seconds = elapsed.inMicroseconds / Duration.microsecondsPerSecond;
    if (seconds <= 0) return;
    final base = const EmotionVector().toMap();
    final current = _state.toMap();
    var changed = false;
    final decayed = <String, double>{};
    current.forEach((dimension, value) {
      final rate = _decay.rateFor(dimension);
      final baseline = base[dimension] ?? 0;
      final target =
          value + (baseline - value) * (rate * seconds).clamp(0.0, 1.0);
      if ((target - value).abs() > _epsilon) changed = true;
      decayed[dimension] = target;
    });
    if (changed) _setState(EmotionVector.fromMap(decayed));
  }

  void reset() => _setState(const EmotionVector());

  void _setState(EmotionVector next) {
    _state = next;
    _bus.emit(CompanionEventType.emotionChanged, _state.toMap());
  }
}
