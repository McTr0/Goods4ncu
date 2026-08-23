> last-verified: 2026-08-23

# Emotion System

State = 7-D vector (§10): valence(-1..1), arousal/dominance/curiosity/
confidence/embarrassment/affection (0..1). Separate from the behavioural
CompanionState — SPEAKING while worried is valid.

Composition is deterministic (§11):
next = clamp(decayed(previous) + agentSuggestion×intensity + eventDelta),
with a relationship bonus that only amplifies *existing positive* valence.

Decay (§12) approaches baselines exponentially per dimension — arousal fast,
embarrassment medium, affection extremely slow. The state always advances;
listeners are notified only when movement exceeds ε since the last emission.

Agent suggestions are hints, never commands: zero-intensity suggestions are
rejected via callback, neutral is a no-op.
