> last-verified: 2026-08-23

# Relationship System

Explicit numeric state in `companion_relationships` (migration 0095):
familiarity/trust/affinity ∈ [0,1], interactionCount, stage ∈ {new,familiar,
close} (goal §13).

Events (§14): user_returns, long_conversation, user_thanks,
user_shares_preference, user_uses_agent_tool (+trust), user_cancels_action
(−trust). Every recorded interaction adds a small familiarity bump.

Anti-farming (§14): affinity gains shrink linearly with remaining headroom
and are hard-capped at 0.10/day/user; single events ≤ 0.05. Cancelling erodes
trust slightly.

Stage thresholds: close needs familiarity>.3 ∧ trust>.35 ∧ affinity>.3;
familiar at familiarity>.12 ∨ affinity>.1.

API: GET/POST `/api/companion/relationship[/events]` (AGENT_ENABLED-gated).
Greetings per stage/absence live in
`CompanionRelationshipService::greeting_for` (§61–62).

Manipulation is forbidden by persona boundaries.md (§15): warmth shapes tone
only — never guilt, exclusivity or dependency framing.
