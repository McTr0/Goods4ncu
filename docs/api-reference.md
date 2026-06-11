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

### POST `/api/chat/connect/request`

需要登录。发起直聊连接。不能给自己发起连接。

```json
{
  "receiver_id": "seller-user-id",
  "listing_id": "optional-listing-id"
}
```

返回：

```json
{
  "connection_id": "connection-id",
  "status": "pending"
}
```

### POST `/api/chat/connect/accept`

需要登录且必须是接收方。接受 pending 连接。

```json
{
  "connection_id": "connection-id"
}
```

返回 `status` 和 `established_at`。

### POST `/api/chat/connect/reject`

需要登录且必须是接收方。拒绝 pending 连接。

```json
{
  "connection_id": "connection-id"
}
```

### GET `/api/chat/connections`

需要登录。返回当前用户所有连接，包括 `other_user_id`、`other_username`、`status`、`unread_count`、`is_receiver`。

### GET `/api/chat/conversations/{connection_id}/messages`

需要登录且必须属于该连接。支持 `limit`、`offset`。返回 `conversation_id`、`messages` 和 `total`。消息字段包括 `id`、`sender`、`content`、`timestamp`、`read_at`、`image_url`、`audio_url`、Base64 fallback 字段和 `status`。

### POST `/api/chat/conversations/{connection_id}/messages`

需要登录且连接必须是 connected。优先使用 URL 媒体字段。

```json
{
  "content": "你好，这个还在吗？",
  "image_url": "https://example.com/photo.jpg",
  "audio_url": null,
  "image_base64": null,
  "audio_base64": null
}
```

返回字段兼容移动端 `ConversationMessage.fromJson`，消息 id 字段名为 `id`。

### POST `/api/chat/messages/{id}/read`

需要登录。标记单条消息已读，返回 `message_id` 和 `read_at`。

### PATCH `/api/chat/messages/{id}`

需要登录且必须是发送者。发送后 15 分钟内可以编辑内容。

```json
{
  "content": "更新后的内容"
}
```

### POST `/api/chat/typing`

需要登录。发送 typing indicator。

```json
{
  "conversation_id": "connection-id"
}
```

### POST `/api/chat/connection/{id}/read`

需要登录。批量标记一个连接内的消息为已读。

## AI Chat

### POST `/api/chat`

单轮 JSON AI 请求。会持久化用户消息，经过意图路由后调用工具或 LLM。

### GET `/api/chat/stream`

SSE 兼容路径，使用 query 参数传递文本。用于旧客户端或简单调试。

### POST `/api/chat/stream`

推荐的 SSE 路径，使用 JSON body，适合认证上下文和移动端流式显示。

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

需要登录。直接按报价创建订单。买家不能买自己的商品，报价必须在建议价的正负 50% 范围内。

```json
{
  "listing_id": "listing-id",
  "offered_price_cny": 99.9
}
```

返回：

```json
{
  "id": "order-id"
}
```

### POST `/api/orders/{id}/pay`

需要登录且必须是 buyer。`pending -> paid`。

### POST `/api/orders/{id}/ship`

需要登录且必须是 seller。`paid -> shipped`。

### POST `/api/orders/{id}/confirm`

需要登录且必须是 buyer。`shipped -> completed`。

### POST `/api/orders/{id}/cancel`

需要登录且必须属于订单。允许在 `pending` 或 `paid` 等早期状态取消。

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
