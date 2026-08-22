# 小昌 Character System

小昌 is a Live2D character with a brain that gives every motion intent.

## Files

| File | Purpose |
|------|---------|
| `xiaochang_brain.dart` | Attention/mood state machine — the "why" behind motion. |
| `live2d_controller.dart` | Maps brain state to expressions, gaze, drag physics. |
| `live2d_character_widget.dart` | Renders character, particles, ambient bubbles. |
| `live2d_effects.dart` | Particle system (hearts/stars/bubbles) + ambient bubbles. |
| `live2d_lipsync_driver.dart` | Mouth animation during SSE streaming. |

## Attention States

| Attention | Trigger | Behavior |
|-----------|---------|----------|
| `user` | Idle <30s | Neutral gaze at user |
| `input` | User typing | Leans forward, looks down |
| `thinking` | Message sent | Gaze up-left, thinking pose |
| `speaking` | SSE tokens arriving | Looks at user, lip-sync active |
| `away` | No activity >30s | Sleepy, looks down |

## Task Context

The brain also tracks whether the current request is conversation, item
discovery, post inspection, negotiation, seller messaging, or help/safety.
This changes gaze and posture: search results are reviewed to the right,
focused posts receive a shared-reference gaze, safety/negotiation requests use
a careful posture, and successful approved messages end with a happy nod.

## Mood → Expression Mapping

| Mood | Expression |
|------|-----------|
| neutral | idle |
| curious (typing) | thinking |
| happy (response done) | happy |
| concerned (error) | surprised |
| playful (tap/drag) | tongueOut |
| sleepy (away) | idle |

## Physical Interactions

- **Tap head** → shy expression, heart particles, tilt-into-touch gaze
- **Poke belly** → surprised, bubble particles, giggle
- **Drag** → surprised when pulled far; on release: spring-back, happy,
  sparkle burst, speech bubble
- **Search results appear** (`SHOW_POSTS`) → curious, gaze right toward results
- **Focused / related posts** → inspecting posture and shared reference gaze
- **Approved message sent** → happy nod; delivery failure → concerned apology

## Asset Notes

The character image is `assets/live2d/doro/icon.png`. The original had a
"by 0x462B4" watermark in the top 100px which was cropped out. The fallback
is `assets/characters/xiaochang.png`.
