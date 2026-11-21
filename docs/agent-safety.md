# Agent Safety

> last-verified: 2026-11-21


## Confirmation Boundaries

Risk levels come from `RiskLevel` in `src/agents/tools/registry.rs`. The
legacy L0/L2/L3 labels used in `agent-tools.md` map L0 → ReadOnly and
L2/L3 → the two write tiers; `draft_message`/`draft_comment` are `ReadOnly`
risk because they only generate text — sending is always a separate user
action.

| RiskLevel | Tools | Behavior |
|-----------|-------|----------|
| ReadOnly | search_inventory, get_listing_details, get_my_listings, get_user_posts, find_related_posts, get_comments, draft_message, draft_comment | Execute immediately; draft tools produce text only and never send |
| Recoverable | create_listing | Execute immediately with an undo window; moderation gate + owner check |
| RequiresConfirmation | update_listing, delete_listing, purchase_item, negotiate_item | HITL confirmation before any effect |

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
