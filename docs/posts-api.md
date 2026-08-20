# Posts API

The posts domain adds LinuxDO-style topics and replies without replacing the
marketplace API. A product listing is a special post subtype:

- `inventory` remains authoritative for price, condition, direction and the
  listing lifecycle.
- every `inventory` row has exactly one `posts` row with
  `post_type = "listing"` and `listing_id = inventory.id`;
- a database trigger backfills and synchronizes the shared title, body,
  category and visibility, including inventory writes from older workers;
- clients continue to create and edit products through `/api/listings` and use
  `/api/posts/by-listing/{listing_id}` to enter the discussion surface.

This preserves all existing listing request and response shapes.

## Read endpoints

All reads accept guests and resolve either the authenticated active campus or
the default public campus.

### `GET /api/posts`

Query parameters:

- `limit`: 1–50, default 20
- `offset`: non-negative, default 0
- `post_type`: `all`, `discussion`, or `listing`
- `direction`: `all`, `offer`, or `wanted` (applies to listing posts)
- `category`: exact category filter
- `search`: title/body substring, up to 200 characters
- `sort`: `active` (default), `latest`, `replies`, or `for_you`

`for_you` is the explainable unified-post home rank. Authenticated viewers get
category affinity from their recent post replies, listing watchlist and orders;
recent activity and reply count provide a small cold-start boost. Explicit
`hide` feedback always removes the exact post (and legacy listing feedback also
removes its listing post), while `less_like_this` downranks the normalized
category. The existing `/api/feed/preferences` toggle and personalization-clear
endpoint apply to this rank. Guests and viewers without signals receive a
recency/engagement fallback.

Mutual-aid requests are ordinary discussion posts with `post_kind =
"mutual_aid"`. Open mutual-aid posts receive a small ranking boost; resolved
and closed posts remain readable but rank below open requests.

Response:

```json
{
  "items": [
    {
      "id": "0c722551-6fce-4efb-94ed-f3ab28c671dc",
      "post_type": "listing",
      "post_kind": "discussion",
      "category": "electronics",
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
      "mutual_aid_metadata": {},
      "resolution_status": "open",
      "can_update_resolution": false,
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
  "ranking_version": "2026.08-unified-post-v1"
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
Both list and detail responses include `can_update_resolution`; it is `true`
only for the authenticated author of a mutual-aid post, allowing clients to
hide status controls from other viewers without inferring ownership.

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

Creates a discussion topic. Products must still be created with
`POST /api/listings`.

```json
{
  "title": "Graduation move-out tips",
  "body": "Share pickup windows early so people can plan.",
  "category": "campus-life",
  "tags": ["graduation", "guide"],
  "cover_image_url": "https://bucket.example.com/post/image/cover.jpg"
}
```

`cover_image_url` is optional and must point at the configured platform object
storage. Mobile clients should upload the image first, then pass the returned
platform URL. The response is the new post detail; until moderation approves
the image, its `cover_image_url` is `null`.

Set `post_kind` to `"mutual_aid"` to publish a help request in the normal post
feed. Optional `mutual_aid_metadata` accepts `service_direction` (`wanted` or
`offer`), `service_mode`, public pickup/dropoff locations, `time_hint`,
`reward_cents`, `valid_until`, and `notes`. Mutual-aid posts default to
`resolution_status: "open"`. Rewards must be non-negative and no more than
10,000,000 cents; `valid_until` must be an RFC 3339 timestamp within the next
year. The unified list, search, category filters, and `sort=for_you` all include
mutual-aid posts, with open requests ahead of resolved or closed requests.

### `PUT /api/posts/{id}`

Owner-only partial update for discussion posts:

```json
{
  "title": "Updated title",
  "body": "Updated body",
  "category": "campus-life",
  "tags": ["guide"],
  "locked": true
}
```

Listing posts reject this route and direct clients back to the listing API.
Locking preserves read access but rejects new replies.

### `PATCH /api/posts/{id}/resolution`

Owner-only update for mutual-aid posts:

```json
{ "resolution_status": "resolved" }
```

Allowed values are `open`, `resolved`, and `closed`.

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
- Category: 80 Unicode characters
- Tags: at most 5 unique tags, each at most 32 Unicode characters

Listing posts continue to reuse the listing image as their cover. Discussion
posts use the post-specific `post_image` moderation lifecycle described above.
Reactions, bookmarks, post reports and admin topic moderation remain separate
follow-up slices; the current API enforces tenant isolation, text moderation,
owner-only mutation, soft deletion, locking and listing restriction visibility.
