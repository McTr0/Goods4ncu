# Companion Architecture

> last-verified: 2026-08-23


The companion is a **runtime**, not a chat window: a persistent Dart-side
system that owns attention, emotion, timing, motion, voice, and platform
agency around the existing campus marketplace.

```text
                       USER
                         │
                Voice / Touch / UI
                         ▼
                 Companion Runtime        mobile/lib/companion/
                         │
             ┌───────────┼───────────┐
             │           │           │
      TurnTaking    Environment   WorkingMemory
         Engine       Tracker        (session)
             │           │           │
             └───────────┼───────────┘
                         ▼
                  CompanionEventBus ──► Timeline Debugger (/companion/timeline)
                         │
                 CompanionRuntimeHost
              machine · emotions · attention
                         │
            CharacterDirector (scheduler+planner)
                         │
        ┌────────────────┼────────────────┐
        │                │                │
   AnimationScheduler  GazeSmoother   VoiceProvider(TTS)
        │                │                │
  CubismCharacterRenderer ◄──── LipSync pulses
        │
     COMPANION (小昌)
```

## Module map

| Concern | File | Spec |
|---|---|---|
| Event bus + timeline | `companion_events.dart` | §67, §69 |
| State machine (18 states) | `state_machine.dart` | §9 |
| Emotion vector + decay | `emotion_engine.dart` | §10–12 |
| Attention + locks | `attention.dart` | §40–42 |
| Motion tags / plans | `motion_library.dart` | §27–28 |
| Priority arbitration | `animation_scheduler.dart` | §29–31 |
| Intent → plan | `behavior_planner.dart` | §26 |
| Gaze smoothing, idle tiers | `gaze.dart` | §32–35, §42 |
| Body adapter (web) | `cubism/cubism_body.dart` + `cubism_renderer.dart`; legacy sprite fallback in `fallback_body_adapter.dart` | §71–72, §74 |
| Environment | `environment.dart` | §49–52 |
| Working memory | `working_memory.dart` | §17 |
| Voice in/out, barge-in | `turn_taking_engine.dart`, `voice_*.dart`, `voice_controller.dart` | §5–8, §46–48 |
| Proactive engine | `proactive_engine.dart` | §36–39 |

Server side: persona layers (`persona/*.md`, `src/agents/persona.rs`),
relationship state (`src/services/companion_relationship.rs`, table 0095),
agent tools (`src/agents/tools.rs`), session/episodic/profile memory
(`src/services/agent_memory.rs`).

## Body renderer

Web renders the real Cubism model (`Doro.moc3`) through pixi-live2d-display
inside an HtmlElementView; the self-built OpenRig sprite engine was removed.
Non-web platforms fall back to the sprite body. Gaze maps to ParamAngleX/Y +
BodyAngleZ + focusController; states pick expression choreography (smile/
brows/tilt); mouth rides ParamMouthOpenY from the shared lip-sync pipeline;
breath and blink run on an internal JS ticker. Pointer gaze is scoped to the
character stage and returns to center after 1.6 seconds without mouse movement
or 0.9 seconds after touch release; the sprite fallback follows the same reset
behaviour.

## Flags

- `COMPANION_ENABLED=false` (dart-define) removes the runtime shell entirely.
- `AGENT_ENABLED=false` (env) disables AI endpoints server-side.
Both off ⇒ the original marketplace, byte-for-byte.
