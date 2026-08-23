# Agent Tools Reference

> last-verified: 2026-08-23


Tools are defined in `src/agents/tools.rs`. All tools share a `ToolContext`
with the DB pool, current user, campus scope, moderation, and notifications.

## Read Tools (L0 — no confirmation)

| Tool | Description |
|------|-------------|
| `search_inventory` | Search active listings by keyword/category/price. Emits `SHOW_POSTS` UI action. |
| `get_listing_details` | Full listing detail by ID. Emits `SCROLL_TO_POST`. |
| `get_my_listings` | Current user's listings. |
| `get_user_posts` | Another user's active posts. Campus-scoped, restricted rows filtered. Emits `SHOW_POSTS`. |
| `find_related_posts` | Similar listings (same category, ±40% price). Emits `SHOW_POSTS`. |
| `get_comments` | Recent messages in a conversation. Participants only; others get `[hidden]`. |

## Write Tools (L2/L3 — HITL confirmation required)

| Tool | Confirmation |
|------|-------------|
| `draft_message` | Generates a draft without sending. Frontend shows 发送/编辑/取消 dialog. |
| `negotiate_item` | Seller must approve before order creation. |
| `purchase_item_intent` | Creates deal intent; requires offline deal confirmation. |
| `create_listing` / `update_listing` / `delete_listing` | Moderation gate + owner check. |

## Adding a New Tool

1. Define `Args`, the struct, and `impl Tool` in `src/agents/tools.rs`.
2. Add to `all_tool_schemas()` test list.
3. Register in each LLM provider (`src/llm/gemini.rs`, `minimax.rs`,
   `openai_compatible.rs`) with `.tool(...)`.
4. For ReAct dispatch: add variant to `StepActionType` and match arm in
   `execute_action`.
5. If the tool produces results worth showing, emit a `UiAction` from the
   Gemini stream handler.

## Privacy Rules

- Owner IDs hidden from non-owners in `get_listing_details`.
- `get_comments` checks sender/receiver membership before revealing content.
- All read tools filter by `campus_id` and exclude restricted listings.
- `draft_message` verifies the active listing and receiver exist. It never
  sends — it only returns a draft envelope for user review.
