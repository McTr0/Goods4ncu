# Companion Runtime — Current State Audit

> last-verified: 2026-08-23


> Phase 0 of the Companion master goal. Facts on the ground as of 2026-08-22,
> gathered from code inspection. This document is the baseline every later
> phase diffs against.

## Stack summary

- **Frontend**: Flutter Web (primary), mobile/lib, go_router + provider.
- **Backend**: Rust + Axum modular monolith (src/api, src/services, src/agents).
- **Streaming**: SSE for chat tokens; WebSocket only for platform notifications.
- **Agent model path**: provider-agnostic (`gemini` / `openrouter` via
  openai_compatible / minimax). Dev model currently
  `nvidia/nemotron-3.5-lightning:free` (reasoning-speed, tool-calling OK).

## What already exists

### Character body
| Piece | Location | Notes |
|---|---|---|
| Rig renderer | `mobile/lib/components/open_rig_renderer.dart` | Custom skeletal-grid rig: bones `root/head/left_action/right_action`, keyframe channels `t/tx/ty/r/sx/sy`, smoothstep interpolation. **This is the body runtime; Cubism moc3 assets exist on disk but are unused.** |
| Motion clips | `assets/avatars/v2/open_rig/<char>/rig.json` | 8 clips per character: idle(loop)/pressed/selected/wave/poke/high_five/encourage/acknowledge. No expression concept in rig. |
| Expressions | PNG overlay swaps in `live2d_character_widget.dart` | idle/happy/thinking/shy/surprised/tongueOut — composited sprites, not rig parameters. |
| Mouth | Image overlay when `mouthOpen > 0.05` | Driven by `Live2DLipSyncDriver`. |
| Micro-motion | `live2d_controller.dart` blink + idle sway timers | **Suspend entirely while any motion is active** (known defect vs goal §31). |

### Character brain (partial state machine)
`xiaochang_brain.dart`: attention{user,input,thinking,speaking,away},
task{conversation,findItem,inspectItem,negotiate,messageSeller,getHelp},
mood{neutral,curious,happy,concerned,sleepy,playful}, single-slot intents,
30 s idle → away/sleepy. Wired to chat page events and tool activity.

Gaps vs goal: no priority scheduler (last-write-wins everywhere), gaze is
instant (no lerp), micro-motion suspends during motions, no emotion vector,
no relationship, no event bus, no proactive engine, no turn-taking/barge-in.

### Agent backend
- Tri-tier intent router → provider tool loop; 13 tools incl.
  search_inventory/get_listing_details/find_related_posts/get_user_posts/
  get_comments/draft_message/draft_comment (+ write tools behind HITL plans).
- UI actions over SSE: SHOW_POSTS/HIGHLIGHT_POST/SCROLL_TO_POST/
  OPEN_POST/OPEN_PROFILE/OPEN_MESSAGE_DRAFT/OPEN_COMMENT_DRAFT.
- Memory: session table (topic + recent listing ids), episodic `agent_memories`
  with vector recall, profile `user_agent_profiles`. History window = last 10
  messages. No relationship counters anywhere.
- Persona lives only as `PREAMBLE` constants in `src/llm/mod.rs`.
- Telemetry: one structured log line per stream (request/user/conversation/
  page/route/tool_calls/ttft/total) + agent_runs DB events.

### Voice reality check
- STT: streaming dictation already wired in composer
  (`speech_dictation_{native,web}.dart`, system recognizer / webkitSpeechRecognition).
- TTS: none anywhere (client or server).
- Recording: interface + `DisabledUserChatAudioRecorder` stub only.
- audio_url in chat payloads is storage-only (no transcription server-side).
- Playback: whole-file `audioplayers`; no chunked/Web-Audio streaming.

### Debug surface
- `?agentDebug=true` overlay on the assistant page: page context, character
  state, emotion label, current tool, tool-call log, UI actions, pending
  confirmations, first-token/turn latency.

## Feature flags
- `AGENT_ENABLED` gates all AI endpoints today.
- `COMPANION_ENABLED` (new, this project) will gate the companion runtime shell;
  both off ⇒ existing marketplace untouched.

## Explicit non-goals carried from the master goal
- No Cubism SDK integration (OpenRig stays the body; swap documented).
- No vector DB additions beyond existing pgvector usage.
- No manipulative relationship mechanics (see boundaries.md once created).
