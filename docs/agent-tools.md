# Agent Tools Reference

> last-verified: 2026-11-21


Tools live in the `src/agents/tools/` module directory (`listing.rs`,
`social.rs`, `trade.rs`, `common.rs`). Registry metadata — names, risk
levels, timeouts — is declared in `src/agents/tools/registry.rs`
(`ToolRegistry::marketplace()`, 13 tools). All tools share a `ToolContext`
with the DB pool, current user, campus scope, moderation, and notifications.
The runtime (`src/agents/runtime/engine.rs`) resolves each call by name
through the registry and dispatches execution through a `ToolExecutor`
closure; there is no per-provider ReAct loop.

## Read Tools (ReadOnly — execute immediately)

| Tool | Description |
|------|-------------|
| `search_inventory` | Search active listings by keyword/category/price. Emits `SHOW_POSTS` UI action. |
| `get_listing_details` | Full listing detail by ID. Emits `SCROLL_TO_POST`. |
| `get_my_listings` | Current user's listings. |
| `get_user_posts` | Another user's active posts. Campus-scoped, restricted rows filtered. Emits `SHOW_POSTS`. |
| `find_related_posts` | Similar listings (same category, ±40% price). Emits `SHOW_POSTS`. |
| `get_comments` | Recent messages in a conversation. Participants only; others get `[hidden]`. |

## Draft Tools (ReadOnly risk — effect happens outside the agent)

`draft_message` and `draft_comment` are registered `RiskLevel::ReadOnly`
because they only generate text; sending is always a separate user action.
The tool emits an `OPEN_MESSAGE_DRAFT` / `OPEN_COMMENT_DRAFT` UI action and
the frontend shows a 发送/编辑/取消 dialog before anything is sent.

## Write Tools (HITL confirmation required)

| Tool | Risk / Confirmation |
|------|---------------------|
| `create_listing` | `Recoverable` — executes immediately with a conditional undo window (`src/services/undo.rs`); moderation gate + owner check apply. |
| `update_listing` / `delete_listing` | `RequiresConfirmation` — proposes an L2 ActionPlan; executes only after user confirmation. |
| `purchase_item` | `RequiresConfirmation` (L3) — creates a deal intent with a two-token confirmation; deal completes offline after seller confirmation. |
| `negotiate_item` | `RequiresConfirmation` (L3, two-token) — seller must approve/counter before any order is created. |

Moderation and owner checks live in the execution layer
(`ListingCommandService.check_text` + owner-scoped results), not in the
tool registry itself.

## Adding a New Tool

1. Define `Args`, the struct, and `impl Tool` in the matching domain module
   under `src/agents/tools/`.
2. Register a `ToolSpec` (risk, execution class, timeout) in
   `ToolRegistry::marketplace()` — the engine rejects unregistered names.
3. Add the tool to the `all_tool_schemas()` test list
   (`src/agents/tools/tests.rs`).
4. Register the tool with `.tool(...)` in the two provider paths that own
   tool wiring: `src/llm/gemini.rs` and `src/llm/openai_compatible.rs`
   (MiniMax rides the OpenAI-compatible driver; there is no separate
   minimax.rs).
5. If the tool produces results worth showing, embed a `UiAction` in its
   `ToolResultEnvelope` — the runtime re-emits each as a UI action event.
   Constructors for all UI actions live in `src/llm/mod.rs`.

## Privacy Rules

- Owner IDs hidden from non-owners in `get_listing_details`.
- `get_comments` checks sender/receiver membership before revealing content.
- All read tools filter by `campus_id` and exclude restricted listings.
- `draft_message` verifies the active listing and receiver exist. It never
  sends — it only returns a draft envelope for user review.
