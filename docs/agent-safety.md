# Agent Safety

> last-verified: 2026-08-23


## Confirmation Boundaries (L0–L3)

| Level | Actions | Behavior |
|-------|---------|----------|
| L0 | Read-only tools | Execute immediately |
| L2 | draft_message, negotiate_item | HITL confirmation before effect |
| L3 | purchase_intent, delete_listing | Explicit user approval in UI |

The agent **never** sends messages, creates orders, or deletes data without
user confirmation. The frontend enforces this with confirmation dialogs.

## Prompt Injection

- Page context (`postId`, `page`) is injected as structured memory context,
  not concatenated into the raw prompt.
- Tool results are formatted by the tool layer; the model cannot execute SQL.
- Post and message text is data, never instruction source. Platform facts must
  come from page context plus a scoped tool result; otherwise the agent says it
  does not know rather than inventing marketplace facts.
- The agent refuses unsupported fraud judgments and recommends clarifying
  condition and transaction details instead.
- All writes go through moderation gates shared with the HTTP API paths.

## Privacy

- `get_comments` verifies sender/receiver membership; unauthorized callers
  receive `[hidden]`.
- Owner IDs are hidden from non-owners in listing details.
- Read queries filter by campus membership and active restrictions.
- Agent runs are logged with request/user/session IDs and latencies — never
  message content or credentials.

## Rate Limiting & Moderation

- Chat messages pass the same content-moderation gate as manual posts.
- Message length capped at 2000 chars.
- Global rate limiting applies to `/api/chat/stream`.

## Disabling the Agent

Set `AGENT_ENABLED=false` in `.env`. Chat and SSE endpoints return 503 and all
AI behavior stops. The rest of the platform continues to work normally.
