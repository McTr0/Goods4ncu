# ADR: Agent Runtime v2

## Status

Accepted — 2026-08-24

## Context

The companion agent (小昌) currently runs on a Rig SDK + custom runtime that
grew organically. Three LLM providers (Gemini, MiniMax, OpenAI-compatible)
each carry their own agent loop, tool registration set, and UI-action
string protocol. `api/chat.rs` mixes HTTP transport with business
orchestration, persistence, and agent-run lifecycle. There is no turn
budget, no loop detection, no cancellation token, and no structured event
protocol — the Flutter client infers progress by counting text tokens.

### Baseline (2026-08-24)

| Metric | Value |
|---|---|
| Rust test suites passing | 42 |
| Flutter tests passing | 493 |
| Provider LOC (3 files) | 1 305 |
| tools.rs LOC | 2 629 |
| chat.rs LOC | 1 240 |
| Tool registrations per provider | 12 × 3 = 36 total |
| String protocol sites | DRAFT_MESSAGE / DRAFT_COMMENT / extract_listing_ids |
| Max model steps | unlimited (`loop`) |
| Loop detection | none |
| Cancellation | SSE connection drop only; no user-initiated cancel |
| Heartbeat | none |

## Decision

Rebuild the agent execution layer in-place as **Agent Runtime v2**:

1. **Single AgentRuntime** owns the model/tool loop. Providers become thin
   `ModelDriver` adapters that translate provider streams into typed
   `ModelEvent`s and nothing else.
2. **Versioned event protocol** (`AgentEvent` tagged enum) replaces raw
   token counting. Every event carries `protocol_version`, `turn_id`,
   `conversation_id`, monotonic `seq`, and structured data.
3. **Execution budgets** are configurable per turn: max model steps,
   max tool calls, timeouts, result size caps.
4. **Loop detection** via canonicalized tool-name + args digest; warning
   at second identical call, hard stop at third.
5. **ToolRegistry** is the single registration point; tools declare risk
   level, parallel safety, timeout, and schema version.
6. **HookChain** provides compile-time fixed-order hooks for policy,
   moderation, metrics, and observation. Hooks can reject but never grant.
7. **ActionPlan** remains the final permission boundary for L2/L3 writes.
8. **Category immutability** after publish; tags remain freely editable.

## What we do NOT do

- Do not migrate to Python/Node sidecar (Hermes, Pi).
- Do not upgrade Rig SDK beyond 0.33 this phase.
- Do not store full prompts, reasoning traces, or complete tool arguments
  in the database (privacy constraint preserved).
- Do not introduce shell/file-system access or self-modifying skills.
- Do not run v1 and v2 simultaneously for the same user request.

## Reference designs consulted

| Project | Adopted | Rejected |
|---|---|---|
| Hermes Agent | interruption, budgets, parallel tools, loop detection, progressive disclosure | shell, file-system access, auto-memory write |
| Claude Agent SDK | max_turns, permission modes, hooks, structured tool inputs | Claude CLI binding, coding-specific tools |
| Grok Build (xAI) | Rust modularity, Runtime/Tool/UI separation, permissions vs sandbox split | workspace management, plugin marketplace |
| OpenAI Codex | submission/event queue, turn/item lifecycle, approval requests | file modification sandbox |
| DeepSeek Harness | append-only events, trajectory replay concept | full prompt/trace storage (violates privacy) |

## Rollout

Feature flag `AGENT_RUNTIME=legacy|v2` with user allowlist. Gradual:
local → dev → allowlist → read-only → full → delete legacy.

## Consequences

- Provider files shrink to adapter-only (~150 lines each from ~440).
- `tools.rs` splits into domain modules under `src/agents/tools/`.
- `api/chat.rs` shrinks to transport-only; orchestration moves to
  `AgentChatService`.
- Flutter consumes structured events; the send button becomes a stop
  button during active turns.
- Legacy code paths are deleted only after v2 is stable across all users.
