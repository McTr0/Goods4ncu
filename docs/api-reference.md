# API 参考

这篇文档记录常用接口的请求形状、权限要求和行为边界。它不是完整 OpenAPI 描述，字段以当前 Rust request/response struct 为准。业务状态机请看 [业务流程](domain-flows.md)。

除特别说明外，需要登录的接口都使用：

```http
Authorization: Bearer <access_token>
Content-Type: application/json
```

分页接口通常使用 `limit` 和 `offset`，后端会限制最大 `limit`。金额对外多使用 `*_cny`，内部交易逻辑使用 cents 整数。

## Auth

### POST `/api/auth/register`

注册普通用户。用户名不能为空且不超过 50 字符，密码 8 到 128 字符，可选邮箱如果提供必须是 `@email.ncu.edu.cn`。

```json
{
  "username": "alice",
  "email": "alice@email.ncu.edu.cn",
  "password": "password123"
}
```

返回 access token、refresh token、user id、username 和消息。重复用户名返回 conflict，非法邮箱或弱密码返回 bad request。

### POST `/api/auth/login`

登录用户。错误用户名和错误密码返回同一种认证失败，避免枚举用户。被封禁用户不能登录。

```json
{
  "username": "alice",
  "password": "password123"
}
```

返回结构与 register 类似。

### POST `/api/auth/refresh`

旋转 refresh token。成功时旧 refresh token 被撤销，并返回新 access token 与新 refresh token。

```json
{
  "refresh_token": "uuid-refresh-token"
}
```

如果 refresh token 过期、已撤销、被重放或用户被封禁，返回 unauthorized。重放会撤销该用户所有 refresh token。

### POST `/api/auth/logout`

需要 access token。撤销当前 access token 的 JTI，并撤销 refresh token。即使 body 中只传一个 refresh token，当前实现也会撤销该用户所有 refresh token。

```json
{
  "refresh_token": "uuid-refresh-token"
}
```

返回：

```json
{
  "message": "已退出登录"
}
```

### POST `/api/auth/change-password`

需要登录。校验当前密码后更新新密码，新密码至少 8 字符且不超过 128 字符。

```json
{
  "current_password": "old-password",
  "new_password": "new-password"
}
```

## Users

### GET `/api/user/profile`

需要登录。返回当前用户资料，包括 `user_id`、`username`、`email`、`student_id`、`avatar_url`、`role`、`created_at`、`chat_read_receipt_mode` 和 `discoverability`。

`student_id` 是只读派生字段：当学校邮箱形如 `{8-12位数字}@email.ncu.edu.cn` 时，后端从邮箱本地部分推断；否则为 `null`。`discoverability.username` 默认 `true`，`discoverability.email` 和 `discoverability.student_id` 默认 `false`。

### PATCH `/api/user/profile`

需要登录。可更新昵称、学校邮箱、头像 URL、查找设置和全局聊天已读策略。邮箱更新后会同步重新推断 `student_id`。`chat_read_receipt_mode` 可选 `auto` 或 `manual`，默认 `auto`。

```json
{
  "username": "alice",
  "email": "2024123456@email.ncu.edu.cn",
  "chat_read_receipt_mode": "manual",
  "discoverability": {
    "username": true,
    "email": false,
    "student_id": true
  }
}
```

### GET `/api/users/lookup`

需要登录。用于“找同学并发起会话”，不会返回当前用户自己。query：

| 参数 | 说明 |
| --- | --- |
| `q` | 必填。用户名片段、完整邮箱或完整学号。 |
| `method` | `auto`、`username`、`email`、`student_id`，默认 `auto`。 |
| `limit` | 默认 10，最大 10。 |

用户名支持模糊匹配，但只返回开启 `discover_by_username` 的用户。邮箱和学号只支持完整精确匹配，并分别要求对方开启对应查找。被屏蔽关系返回空结果，避免泄露屏蔽状态。

返回：

```json
{
  "items": [
    {
      "user_id": "target-user-id",
      "username": "alice",
      "matched_by": "student_id",
      "masked_identifier": "2024****",
      "listing_count": 3,
      "can_start_conversation": true
    }
  ]
}
```

### GET `/api/users/{id}/listings`

公开查看某个用户的 active 在售商品。支持 `limit` 和 `offset`，返回结构与商品列表相同的 `items/total/limit/offset` envelope。这个接口用于“找同学”结果里的“查看TA的在售”，不会返回 deleted 或 sold 商品。

## Listings

### GET `/api/listings`

公开浏览商品。支持 query：

| 参数 | 说明 |
| --- | --- |
| `limit`、`offset` | 分页，limit 会被限制在 1 到 100。 |
| `category` | 单分类过滤。 |
| `categories` | 多分类逗号分隔，例如 `electronics,books`。 |
| `search` | 文本搜索，最长 200 字符。 |
| `sort` | `newest`、`price_asc`、`price_desc`、`condition_desc`。 |
| `min_price_cny`、`max_price_cny` | CNY 价格区间。 |

返回：

```json
{
  "items": [
    {
      "id": "listing-id",
      "title": "二手教材",
      "category": "books",
      "brand": "高等教育出版社",
      "condition_score": 8,
      "suggested_price_cny": 29.9,
      "status": "active",
      "defect_hint": "封面轻微磨损"
    }
  ],
  "total": 1,
  "limit": 20,
  "offset": 0
}
```

### GET `/api/listings/{id}`

公开查看商品详情。未登录用户可以看基本信息；登录用户会额外拿到 `owner_id`，用于发起直聊。返回 `defects`、`description`、`owner_username`、`status`、`created_at` 等字段。

### POST `/api/listings`

需要登录。创建商品，走字段校验和文本审核。可选 `image_url` 必须以 `http://` 或 `https://` 开头，并会进入图片审核任务。

```json
{
  "title": "iPhone 13",
  "category": "electronics",
  "brand": "Apple",
  "condition_score": 8,
  "suggested_price_cny": 3200,
  "defects": ["边框轻微磕碰"],
  "description": "自用，无拆修",
  "image_url": "https://example.com/item.jpg"
}
```

返回：

```json
{
  "id": "listing-id",
  "message": "商品发布成功"
}
```

### PUT `/api/listings/{id}`

需要登录且必须是 owner。支持局部更新：`title`、`category`、`brand`、`condition_score`、`suggested_price_cny`、`defects`、`description`。状态更新不走这个通用接口。

### DELETE `/api/listings/{id}`

需要登录且必须是 owner。删除或标记商品不可用，返回商品 id 和消息。

### POST `/api/listings/{id}/relist`

需要登录且必须是 owner。把已售或已删除商品重新上架，返回 `status: active`。

### POST `/api/listings/recognize`

需要登录。使用 Gemini Vision 从 Base64 图片中识别商品草稿。

```json
{
  "image_base64": "base64-image-data"
}
```

返回识别出的 `title`、`category`、`brand`、`condition_score`、`defects` 和 `description`。

### GET `/api/categories`

返回合法分类，例如 `electronics`、`books`、`digitalAccessories`、`dailyGoods`、`clothingShoes`、`other`。

## User Chat

用户直聊已经从“永久好友连接”改为“每次联系创建独立会话”。会话有两种模式：

- `realtime`：TCP 式三次握手，`syn_sent -> syn_ack -> active`，只显示本次沟通。
- `mail`：异步留言，创建后直接 `open`，不展示在线、typing 或已读给发件人。

公共会话字段包括 `id`、`mode`、`state`、`initiator_id`、`recipient_id`、`other_user_id`、`other_username`、`listing_id`、`subject`、`last_message`、`unread_count`、`read_receipt_mode`、`effective_read_receipt_mode`、`expires_at`、`is_blocked` 和 `capabilities`。`read_receipt_mode` 是本会话覆盖项，可为 `inherit`、`auto` 或 `manual`；`effective_read_receipt_mode` 是后端合并全局默认后的实际行为。`capabilities` 告诉移动端当前用户是否可以 `respond`、`ack`、`send`、`close`、`archive` 或 `restart`。

非法状态转换返回 `409 invalid_conversation_state`。重复创建和重复发送依赖客户端 UUID 幂等。

### POST `/api/chat/conversations`

需要登录。创建实时会话或留言线程。不能联系自己；被屏蔽关系不能创建新会话。`realtime` 模式下同一“用户对 + 商品”如果已有未结束会话，会直接返回已有会话；双方同时发起时视为 mutual intent，直接进入 `active`。

```json
{
  "client_request_id": "uuid-from-client",
  "recipient_id": "seller-user-id",
  "listing_id": "optional-listing-id",
  "mode": "realtime",
  "subject": null,
  "content": "你好，我想问下这个还在吗？"
}
```

邮件必须填写 `subject`，长度 1 到 120 字；正文长度 1 到 2000 字。实时模式不使用主题。

### GET `/api/chat/conversations`

需要登录。收件箱分页，默认返回全部未归档会话。query：

| 参数 | 说明 |
| --- | --- |
| `mode` | 可选 `realtime` 或 `mail`；不传表示全部。 |
| `cursor` | 上一页最后一条会话 id。 |
| `limit` | 1 到 50，默认 30。 |

返回 `items` 和 `next_cursor`。客户端按 `last_activity_at` 排序展示，等待当前用户处理的实时邀请应置顶。

### GET `/api/chat/conversations/{id}`

需要登录且必须是会话成员。返回会话状态、倒计时、成员上下文、商品上下文和能力。

### POST `/api/chat/conversations/{id}/respond`

需要登录且必须是接收方。只适用于 `realtime/syn_sent`。

```json
{
  "decision": "accept"
}
```

`accept` 将状态改为 `syn_ack`，等待发起方 ACK；`decline` 将状态改为 `declined`。

### POST `/api/chat/conversations/{id}/ack`

需要登录且必须是发起方。只适用于 `realtime/syn_ack`，成功后进入 `active`。发起方在 `syn_ack` 状态直接发消息时，后端会在同一事务中完成 ACK 和消息写入。

### POST `/api/chat/conversations/{id}/close`

需要登录且必须是会话成员。`syn_sent` 发起方关闭会变成 `cancelled`；`syn_ack` 或 `active` 关闭会变成 `closed`。终态会话不能继续发送。

### POST `/api/chat/conversations/{id}/archive`

需要登录且必须是会话成员。归档是成员级状态，不影响对方。

```json
{
  "archived": true
}
```

### GET `/api/chat/conversations/{id}/messages`

需要登录且必须是会话成员。支持 `limit`、`offset`。返回 `conversation_id`、`messages` 和 `total`。消息字段包括 `id`、`client_message_id`、`sender`、`content`、`timestamp`、`read_at`、`image_url`、`audio_url`、Base64 fallback 字段、`reply_to_message_id`、`reply_preview`、`quote`、`status`、`kind` 和 `edited_at`。

### POST `/api/chat/conversations/{id}/messages`

需要登录且必须是会话成员。邮件 `open` 时可发送；实时会话只有 `active` 可发送，但发起方在 `syn_ack` 直接发送会自动完成 ACK。优先使用 URL 媒体字段。

```json
{
  "client_message_id": "uuid-from-client",
  "content": "你好，这个还在吗？",
  "reply_to_message_id": "optional-message-id",
  "quote": {
    "kind": "listing",
    "ref_id": "listing-id"
  },
  "image_url": "https://example.com/photo.jpg",
  "audio_url": null,
  "image_base64": null,
  "audio_base64": null
}
```

`reply_to_message_id` 用于回复同一会话内的历史消息。`quote` 用于引用结构化事实，`kind` 可为 `listing`、`order` 或 `hitl_offer`。前端只提交 `kind/ref_id`，服务端会校验权限并生成快照，例如商品标题、价格、状态和主图；前端传入的伪造快照会被忽略。快照是发送时事实，不会因后续商品价格、订单状态或议价状态变化而改写。

### POST `/api/chat/conversations/{id}/read`

需要登录且必须是会话成员。批量标记当前用户收到的未读消息，返回 `conversation_id` 和 `marked_count`。邮件不会向发件人推送已读事件；实时 `active` 会话会通过 WebSocket 推送 `message_read`。

### POST `/api/chat/conversations/{id}/read-preference`

需要登录且必须是会话成员。设置单个会话的已读策略覆盖项。

```json
{
  "mode": "inherit"
}
```

`inherit` 表示跟随用户全局 `chat_read_receipt_mode`，`auto` 表示打开 active realtime 会话后自动标记已读，`manual` 表示只有显式调用 read API 才标记已读。返回更新后的会话对象。

### PATCH `/api/chat/messages/{id}`

需要登录且必须是发送者。只有 `realtime/active` 中普通 `message` 可在发送后 15 分钟内编辑；邮件和开场消息不可编辑。

```json
{
  "content": "更新后的内容"
}
```

### POST `/api/chat/conversations/{id}/typing`

需要登录且必须是会话成员。只适用于 `realtime/active`。邮件不发送 typing 事件。

### POST `/api/chat/conversations/{id}/reply-suggestions`

需要登录且必须是会话成员。读取最近 12 条纯文本消息，返回三条草稿：`direct`、`warm`、`reserved`。Reply Assistant 不挂载搜索、下单或议价工具，不会自动发送。

### GET `/api/chat/blocks`

需要登录。返回当前用户屏蔽列表。

### POST `/api/chat/blocks`

需要登录。屏蔽某用户。屏蔽后双方不能新建会话或继续发送；旧历史保持只读。

```json
{
  "user_id": "blocked-user-id"
}
```

### DELETE `/api/chat/blocks/{id}`

需要登录。取消屏蔽指定用户。

## AI Chat

移动端把“小帮”作为收件箱中的虚拟系统会话，但它不属于 `chat_conversations` 的 `realtime` 或 `mail` 状态机。客户端使用公共会话标识 `__agent__`；后端根据 JWT 将它映射到当前用户专属的内部会话，因此不同账号不会共享历史。

### GET `/api/chat/assistant`

需要登录。读取当前用户最近的小帮消息。支持 `limit`（1–100，默认 50）和 `offset`。返回 `conversation_id: "__agent__"`、`messages` 和 `total`；每条消息包含 `id`、`role`（`user` 或 `assistant`）、`content`、可选媒体 URL 和 `timestamp`。

### POST `/api/chat`

单轮 JSON AI 请求。会持久化用户消息，经过意图路由后调用工具或 LLM。

### GET `/api/chat/stream`

SSE 兼容路径，使用 query 参数传递文本。用于旧客户端或简单调试。

### POST `/api/chat/stream`

推荐的 SSE 路径，使用 JSON body，适合认证上下文和移动端流式显示。小帮请求必须携带 `conversation_id: "__agent__"`。服务端先读取该用户此前的最近历史，再保存当前用户消息；流式响应正常结束后保存完整 AI 回复。中断或 provider 失败时不保存不完整的 AI 回复，但已经提交的用户消息仍会保留。

## WebSocket

### GET `/api/ws`

使用 `Authorization: Bearer <jwt>` 建连。服务端会验证 token 未撤销、用户未封禁。连接用于通知推送、聊天消息提示、typing 等实时事件。客户端收到 WebSocket 事件后仍应回查 HTTP 列表，因为数据库才是最终事实。

## Orders

### GET `/api/orders`

需要登录。列出当前用户订单。query：

| 参数 | 说明 |
| --- | --- |
| `role` | 可选 `buyer` 或 `seller`，不传则返回用户参与的全部订单。 |
| `limit`、`offset` | 分页。 |

### GET `/api/orders/{id}`

需要登录且必须是 buyer 或 seller。返回订单详情、商品标题、双方用户名、状态和各状态时间戳。

### POST `/api/orders`

需要登录。按报价创建线下成交意向。买家不能买自己的商品，报价必须在建议价的正负 50% 范围内。创建后状态为 `intent_pending`，商品仍然保持原状态，等待卖家确认。

```json
{
  "listing_id": "listing-id",
  "offered_price_cny": 99.9
}
```

返回：

```json
{
  "id": "order-id",
  "status": "intent_pending",
  "message": "成交意向已发送，等待卖家确认"
}
```

### POST `/api/orders/{id}/pay`

兼容旧客户端入口。平台不负责资金中转，调用会返回明确错误提示，不改变订单状态。

### POST `/api/orders/{id}/ship`

兼容旧客户端入口。平台不追踪物流或交接，调用会返回明确错误提示，不改变订单状态。

### POST `/api/orders/{id}/confirm`

需要登录且必须是 seller。确认线下成交，状态从 `intent_pending` 进入 `confirmed`。请求体可选 `auto_delist`，默认 `true`；开启时会在同一事务中把商品下架为 `sold`。

```json
{
  "auto_delist": true
}
```

### POST `/api/orders/{id}/cancel`

需要登录且必须属于订单。普通用户只能取消 `intent_pending`；管理员可按后台规则取消异常记录。

```json
{
  "reason": "双方协商取消"
}
```

## Negotiation

### GET `/api/negotiations`

需要登录。列出当前用户相关的议价请求。卖家看到 pending/expired，买家看到 countered/approved/rejected/expired。当前 handler 使用空 JSON body 参数，客户端联调时应按现有实现发送空对象，后续可考虑改成纯 query 接口。

```json
{}
```

### PATCH `/api/negotiations/{id}/respond`

需要登录且必须是卖家。处理 pending 议价。

```json
{
  "action": "approve"
}
```

或：

```json
{
  "action": "counter",
  "counter_price": 180000
}
```

`counter_price` 当前按 cents 整数传入。`approve` 会创建订单，`reject` 会结束请求，`counter` 会等待买家处理。

### PATCH `/api/negotiations/{id}/accept`

需要登录且必须是买家。接受卖家的 counter，创建订单。

### PATCH `/api/negotiations/{id}/reject`

需要登录且必须是买家。拒绝卖家的 counter，结束议价。

更完整状态解释见 [业务流程](domain-flows.md)。

## Watchlist

### GET `/api/watchlist`

需要登录。返回 active 收藏商品，支持 `limit`、`offset`。

### POST `/api/watchlist/{listing_id}`

需要登录。加入收藏。不能收藏自己的商品。

### DELETE `/api/watchlist/{listing_id}`

需要登录。移除收藏。

### GET `/api/watchlist/{listing_id}`

需要登录。返回：

```json
{
  "watched": true,
  "listing_id": "listing-id"
}
```

## Notifications

### GET `/api/notifications`

需要登录。默认只返回未读通知；传 `include_read=true` 返回历史。支持 `limit`、`offset`。返回 `items`、`total`、`unread_count`。

### POST `/api/notifications/{id}/read`

需要登录。标记单条通知已读，返回 `{ "ok": true }`。

### POST `/api/notifications/read-all`

需要登录。标记全部未读通知为已读，返回 `marked_count`。

## Admin

管理员接口需要管理员角色。关键路径包括：

| 方法和路径 | 行为 |
| --- | --- |
| `GET /api/admin/stats` | 平台管理统计。 |
| `GET /api/admin/users` | 用户列表。 |
| `GET /api/admin/listings` | 商品列表。 |
| `GET /api/admin/orders` | 订单列表。 |
| `GET /api/admin/audit-logs` | 管理员审计日志。 |
| `POST /api/admin/users/{id}/ban` | 封禁用户。 |
| `POST /api/admin/users/{id}/unban` | 解封用户。 |
| `POST /api/admin/listings/{id}/takedown` | 下架商品。 |
| `POST /api/admin/users/{id}/impersonate` | 生成目标用户 JWT，用于排查。 |
| `POST /api/admin/tokens/{jti}/revoke` | 撤销 access token。 |
| `POST /api/admin/users/{id}/role` | 修改用户角色。 |
| `POST /api/admin/orders/{id}/status` | 管理员强制设置订单状态。 |

改管理员接口时要同时检查审计日志和普通用户路径的影响。

## Upload、Recommendations、Health 和 Metrics

`GET /api/upload/token` 返回 OSS 直传临时凭证，要求 OSS 相关配置存在。推荐路径包括 `GET /api/recommendations/feed` 和 `GET /api/recommendations/similar`，依赖 pgvector 和 active 商品过滤。

`GET /api/health` 返回健康状态，常用于启动检查。`GET /api/stats` 返回公开平台统计。`GET /api/metrics` 暴露 Prometheus 文本格式指标，包括请求、限流、聊天、LLM、WebSocket 和订单相关指标。
