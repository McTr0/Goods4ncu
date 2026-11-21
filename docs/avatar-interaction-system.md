# Avatar interaction system

> last-verified: 2026-11-21

## Product contract

Avatar actions are explicit presentation feedback, not presence facts. The UI
may play an action after a local tap, character selection, publish success, or
another user-visible event. It must not turn `online`, `read`, `typing`, push
delivery, or inferred emotion into character motion.

Callers send semantic cues (`wave`, `celebrate`, `thinking`, `poke`,
`highFive`, …) through `AvatarActionController`
(`mobile/lib/components/social_persona_renderer.dart`). Each call carries a
monotonically increasing local revision, so the same action can be replayed
without briefly switching to an unrelated state. Renderers map those cues to
their own frames, bones, or parameters; feature pages never address animation
frames directly.

## Current rendering reality

There is one shipped renderer: a static Doro PNG portrait
(`assets/live2d/doro/icon.png`) that plays cue-driven motion above the
`size >= 96` threshold and stays static below `32` px
(`social_persona_renderer.dart`). There are no WebP posters, no sprite
atlas/manifest layer, and no Rive dependency in `pubspec.yaml`.

The full Live2D Cubism rig (`Doro.moc3`, physics, expressions, idle motion)
belongs to the **companion stage** (`mobile/web/live2d_stage.js`,
`mobile/lib/companion/cubism/`) — not to social-avatar surfaces. See
`docs/companion-architecture.md` for that stack.

## Cue catalogue

| User-visible event | Cue | Rendering |
| --- | --- | --- |
| Tap or press | `pressed` | quick squash |
| Choose character | `selected` | short lift |
| Tap “打招呼” | `wave` | side-to-side greeting |
| Publish or finish a task | `celebrate` / `published` | jump and bounce |
| Tap “思考” or assistant is locally composing | `thinking` | slow tilted bob |
| User confirms an action | `confirmedByUser` / `acknowledge` | small affirmative lift |
| Interaction with a contact | `poke`, `highFive`, `encourage` | one-shot gesture |

`AvatarChoreographyController`
(`mobile/lib/components/avatar_choreography_controller.dart`) decides when
cues fire and never subscribes to presence, read, or typing state — the
product-contract boundary is enforced in code, not convention.

## Persisted interactions

Avatar interactions between contacts are recorded as `avatar_interaction`
chat messages (migration `0091_avatar_interactions.sql`) with per-contact
recipient policies (`wave` / `poke` / `high_five` / `encourage`) and contact
overrides. Replaying an interaction re-runs the same cue on both sides
instead of inventing motion from chat state.

## Catalog rules (SocialPersona)

Avatars are SocialPersona-only: the server catalog restricts characters to
`doro` (`src/services/social_persona.rs`) and forbids user uploads or
arbitrary avatar URLs; the client resolves legacy avatar tokens to `doro`
(`social_persona_renderer.dart`). Multi-character poster/sprite premises from
the 2026-08 design are retired until a second character actually ships.

## Performance budgets

- Static portrait is a single PNG; no decode-bucket pipeline exists yet.
- Motion plays only on surfaces ≥ 96 px and is suppressed below 32 px.
- At most one continuously animated avatar per screen; off-screen and route
  background avatars stop ticking.
- `MediaQuery.disableAnimations` always selects the static frame. Battery
  saver and low-memory hooks can force the same static path later.

## Future upgrade paths (not built)

Poster/decode-bucket layers, versioned sprite atlases, and a rigged flagship
layer (Rive or bundled Cubism) remain design options behind the same cue
contract. Bundling the Cubism runtime for avatar surfaces still requires
recording redistribution/runtime licences first — the companion stage's
licensing status is tracked in `docs/companion-architecture.md`.
