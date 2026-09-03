> last-verified: 2026-08-31

# Posts API

Unified post structure (migration 0109): one `posts` table covers
公告、出(offer)、收(wanted)、分享、提问、讨论、召集和组队。
**`category` IS the kind.**

- `post_type` / `post_kind` are gone; the inventory→post mirror trigger was
  removed. Listings are optional references (`listing_id`, SET NULL on listing
  delete).
- Tags must come from the curated `post_tag_catalog` (location and TTL groups);
  each group allows at most one tag. There is no errand-specific metadata or
  lifecycle.
- `space_id` scopes a post to one chat space: member-only visibility in feeds,
  detail reads and replies; NULL means campus-wide.
- All posts (discussions and marketplace goods) are published via `POST /api/posts`
  in a single atomic transaction. For marketplace items, supply the nested
  `marketplace` payload. External `listing_id` input is not accepted.

## Read endpoints

All reads accept guests and resolve either the authenticated active campus or
the default public campus.

### `GET /api/posts`

Query parameters:

- `limit`: 1–50, default 20
- `offset`: non-negative, default 0
- `category`: `all` or one enabled `post_categories` key
- `space_id`: group scoping (viewer must be an unbanned member)
- `search`: title/body substring, up to 200 characters
- `tags`: comma-separated catalog keys; a post matches when it carries any one
  of them
- `sort`: `active` (default), `latest`, `replies`, or `for_you`

`for_you` is the explainable unified-post home rank. Authenticated viewers get
category affinity from their recent post replies, listing watchlist and orders;
recent activity and reply count provide a small cold-start boost. Explicit
`hide` feedback always removes the exact post (and legacy listing feedback also
removes its listing post), while `less_like_this` downranks the normalized
category. The existing `/api/feed/preferences` toggle and personalization-clear
endpoint apply to this rank. Guests and viewers without signals receive a
recency/engagement fallback.

Response:

```json
{
  "items": [
    {
      "id": "0c722551-6fce-4efb-94ed-f3ab28c671dc",
      "category": "offer",
      "space_id": null,
      "title": "Dorm monitor",
      "body_excerpt": "24-inch monitor in good condition",
      "tags": [],
      "listing_id": "listing-123",
      "cover_image_url": "https://signed.example/item.jpg",
      "listing": {
        "id": "listing-123",
        "content_revision": 2,
        "title": "Dorm monitor",
        "category": "electronics",
        "brand": "Brand",
        "direction": "offer",
        "condition_score": 8,
        "suggested_price_cny": 100.0,
        "status": "active",
        "image_url": "https://signed.example/item.jpg",
        "created_at": "2026-08-15T12:00:00Z"
      },
      "author": {
        "id": "user-123",
        "username": "alice",
        "avatar_url": null
      },
      "reply_count": 3,
      "status": "active",
      "fertilizer_count": 2,
      "is_locked": false,
      "created_at": "2026-08-15T12:00:00Z",
      "updated_at": "2026-08-15T12:30:00Z",
      "last_activity_at": "2026-08-15T12:30:00Z",
      "rank_reason": "与你互动过的“electronics”内容相关",
      "rank_source": "category_affinity",
      "ranking_score": 6.25
    }
  ],
  "total": 1,
  "limit": 20,
  "offset": 0,
  "ranking_version": "2026.08-post-v2"
}
```

Only active/locked topics are returned. Listing posts are additionally hidden
when the listing is inactive or has an active moderation restriction. Cover
images and avatars are returned only after their existing moderation status is
approved; private-bucket deployments receive signed URLs.

Discussion posts may use the same `cover_image_url` field. The value is
returned only after the `post_image` moderation job is approved, so a newly
published image can briefly be absent from the feed while it is reviewed.

### `GET /api/posts/{id}`

Returns the core topic fields from a list item, except `body` contains the
full topic body and `body_excerpt` is absent. The feed-only ranking fields
(`rank_reason`, `rank_source`, `ranking_score`) are not included because a
direct detail lookup does not run the viewer-specific ranker.

### `GET /api/posts/by-listing/{listing_id}`

Returns the listing's post detail. This is the stable reverse lookup between
the compatible listing API and the post API.

### `GET /api/posts/{id}/replies`

Accepts `limit` and `offset` with the same bounds as the post feed. Replies are
chronological:

```json
{
  "items": [
    {
      "id": "9d57a36e-dfc5-4fca-a6cb-50146124e45a",
      "post_id": "0c722551-6fce-4efb-94ed-f3ab28c671dc",
      "body": "Is pickup available this afternoon?",
      "reply_to_id": null,
      "author": {
        "id": "user-456",
        "username": "bob",
        "avatar_url": null
      },
      "created_at": "2026-08-15T12:30:00Z",
      "updated_at": "2026-08-15T12:30:00Z"
    }
  ],
  "total": 1,
  "limit": 20,
  "offset": 0
}
```

## Write endpoints

All writes require a valid session and a currently verified active-campus
membership. Text passes through the same synchronous moderation rules used by
listings and chat.

The existing `POST /api/feed/feedback` endpoint also accepts
`resource_type: "post"` with a post UUID. `listing` remains valid for legacy
clients and is applied to the linked listing post by the unified ranker.

### `POST /api/posts`

Unified post creation endpoint. Creates discussion topics or marketplace listings
within a single atomic database transaction. Supports optional `Idempotency-Key` header
for safe retry semantics (identical retries replay the created post; conflicting payloads return 409 Conflict).
Both top-level and nested payloads reject unknown fields (`deny_unknown_fields`).

For ordinary discussions (`share`, `question`, `discussion`, `team_up`, `announcement`):
The `marketplace` object is strictly forbidden (must be null or omitted).

```json
{
  "title": "Graduation move-out tips",
  "body": "Share pickup windows early so people can plan.",
  "category": "share",
  "tags": ["urgent"],
  "cover_image_url": "https://bucket.example.com/post/image/cover.jpg"
}
```

For goods / marketplace items (category `offer` or `wanted`):
The `marketplace` object is strictly required. For `offer`, `brand` is required. If `direction` is provided, it must match the post `category`.

```json
{
  "title": "Dorm monitor",
  "body": "24-inch monitor in good condition",
  "category": "offer",
  "tags": [],
  "marketplace": {
    "category": "electronics",
    "brand": "Dell",
    "condition_score": 8,
    "suggested_price_cny": 100.0,
    "direction": "offer"
  },
  "cover_image_url": "https://bucket.example.com/post/image/cover.jpg"
}
```

In both cases, `marketplace detail -> post -> moderation job` execute within
a single database transaction and commit atomically.

Help requests are not a special API shape: publish them in the same endpoint
with a suitable category (for example `wanted`, `question`, or `discussion`)
and catalog tags. The unified list, search, category filter, tag filter, and
`sort=for_you` all include them as ordinary posts.

### `PUT /api/posts/{id}`

Owner-only partial update for discussion posts:

```json
{
  "title": "Updated title",
  "body": "Updated body",
  "tags": ["longterm"],
  "locked": true
}
```

Listing posts reject this route and direct clients back to the listing API.
Locking preserves read access but rejects new replies.

### `DELETE /api/posts/{id}`

Owner-only soft delete for discussion posts. Listing posts must be deleted via
the listing API.

### `POST /api/posts/{id}/replies`

```json
{
  "body": "Thanks for the guide.",
  "reply_to_id": "9d57a36e-dfc5-4fca-a6cb-50146124e45a"
}
```

`reply_to_id` is optional. When supplied, the database and repository both
require that the parent is an active reply in the same post and campus.

### `PUT /api/posts/{post_id}/replies/{reply_id}`

Owner-only reply edit with `{ "body": "..." }`.

### `DELETE /api/posts/{post_id}/replies/{reply_id}`

Owner-only reply soft delete. The parent topic's `reply_count` is maintained by
a database trigger.

## Limits and follow-ups

- Topic title: 300 Unicode characters
- Topic body: 50,000 Unicode characters
- Reply body: 20,000 Unicode characters
- Category: one enabled `post_categories` key
- Tags: catalog keys, at most one per group, each at most 32 Unicode characters

Listing posts continue to reuse the listing image as their cover. Discussion
posts use the post-specific `post_image` moderation lifecycle described above.
Reactions, bookmarks, post reports and admin topic moderation remain separate
follow-up slices; the current API enforces tenant isolation, text moderation,
owner-only mutation, soft deletion, locking and listing restriction visibility.
