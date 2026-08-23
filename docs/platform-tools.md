> last-verified: 2026-08-23

# Platform Tools

13 tools over the unified post model (see docs/agent-tools.md for the recipe):

Read-safe: search_inventory, get_listing_details, find_related_posts,
get_user_posts, get_comments (participant-gated), get_my_listings.
Draft-only: draft_message, draft_comment — never send without confirmation.
Writes behind HITL plans: update_listing, delete_listing (L2),
purchase_item, negotiate_item (L3, rotated second token).
Immediate-with-undo: create_listing (L2 + reversible window, documented
trade-off vs spec §30).

Tool activity reaches the character: TOOL_STARTED emits `tool_using_<name>`;
the BehaviourPlanner maps retrieval tools to a looping toolWorking plan at
SPEECH_GESTURE priority, with friendly progress copy ("正在翻帖子…" >500 ms).

UI actions: SHOW_POSTS, HIGHLIGHT_POST, SCROLL_TO_POST, OPEN_POST,
OPEN_PROFILE, OPEN_MESSAGE_DRAFT, OPEN_COMMENT_DRAFT — dispatched through
ChatPage._handleUiAction, never DOM access from the agent (§56). Highlighting
a post also moves ATTENTION and gaze (§57 triple-sync).
