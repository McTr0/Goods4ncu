# Current Architecture Snapshot

This snapshot records the stack and boundaries that 小昌 extends. It describes
the existing demo as implemented; it is not a proposal to replace the platform.

## Stack

| Area | Current implementation |
| --- | --- |
| Frontend | Flutter Web/mobile app under `mobile/lib`, with GoRouter, Provider, HTTP/SSE/WebSocket services, and localized Material UI. |
| Backend | Rust modular monolith using Axum; API handlers live in `src/api`, business rules in `src/services`, data access in `src/repositories` or sqlx call sites, and agent logic in `src/agents`. |
| Database | PostgreSQL plus pgvector. Migrations are numbered files under `migrations`. |
| Auth | JWT access/refresh flow with token storage, rotation/denylist middleware, role/capability checks, and campus-scoped authorization. |
| Realtime | SSE streams assistant tokens/UI actions; WebSocket delivers notifications and message hints. HTTP remains authoritative for writes. |

## Existing Platform Systems

- **Posts/listings:** unified discovery posts project discussions and offer/wanted
  listings; commerce lifecycle actions remain in the listing services.
- **Users/profiles:** account, profile, campus membership, capabilities, and
  public user pages.
- **Messaging/comments:** conversations, direct/user chat threads, listing
  comments/replies, notifications, and explicit contact entry points.
- **Existing APIs:** authenticated REST handlers for auth, posts/listings,
  profiles, messaging, moderation, admin, and health; `/api/chat/stream`
  provides the optional agent stream.

## Agent Extension Points

1. Flutter sends `page_context` on each assistant request so the backend knows
   whether the user is in general chat or inspecting a post/listing.
2. `ToolContext` gives tools the authenticated user, campus scope, database
   pool, and application services—not raw SQL authority in the model.
3. Read tools retrieve real posts/listings/users/comments; `draft_message`
   returns text only. The frontend sends messages only after confirmation via
   the existing `ChatService.sendMessage`.
4. Typed UI actions (`SHOW_POSTS`, `HIGHLIGHT_POST`, `OPEN_MESSAGE_DRAFT`,
   etc.) cross the SSE boundary; Flutter maps them to navigation/result cards,
   while the Live2D brain maps them to intentional motion states.
5. `AGENT_ENABLED=false` disables AI endpoints without affecting normal platform
   flows.

The platform remains authoritative for identity, visibility, moderation, and
writes. Assistant output is untrusted presentation until an existing service
validates and persists it.
