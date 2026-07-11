# API 参考

| 项目 | 内容 |
| --- | --- |
| 适用读者 | 后端、Flutter、集成测试和需要核对当前/目标接口的工程师 |
| 当前状态 | 未版本化 `/api/*` 为当前实现；单独标记的 `/api/v1/*` 为目标契约 |
| 事实来源 | `src/api/mod.rs` 路由、Rust request/response struct、Flutter service/model 和接口测试 |
| 最后核对范围 | Auth、Users、Listings、Chat/Threads/Spaces、AI、Deals、Admin、Upload、Recommendations、Health/Metrics |

这篇文档记录接口形状、权限要求和行为边界。它不是自动生成的完整 OpenAPI；当前字段以 Rust struct 和 handler 为准。业务状态机见 [业务流程](domain-flows.md)，目标对象见[信息模型](information-model.md)。

接口使用以下状态：

- `[已实现]`：当前 Axum router 已注册。
- `[实验中]`：当前可调用，但没有稳定生产承诺。
- `[目标态]`：设计契约，当前 router 不存在。
- `[待弃用]`：当前为兼容保留，不应有新客户端依赖。

除特别说明外，需要登录的接口都使用：

```http
Authorization: Bearer <access_token>
Content-Type: application/json
```

当前分页接口混合使用 `limit/offset` 和 cursor，具体以各节为准。金额对外多使用 `*_cny`，内部关键逻辑使用 cents 整数。

[已实现] 每个 HTTP 响应包含服务端生成的 `X-Request-ID`；浏览器 CORS 可以读取该 header。当前未版本化错误为兼容旧客户端保留 `error` 字符串，同时增加稳定字段：

```json
{
  "error": "请求错误: 输入无效",
  "code": "bad_request",
  "message": "请求错误: 输入无效",
  "trace_id": "uuid"
}
```

`trace_id` 与响应 `X-Request-ID` 相同，可用于关联日志。客户端应逐步使用 `code` 判断类别、使用 `message` 展示，并继续兼容旧 `error`。目标 `/api/v1` 会在版本边界内切换为嵌套 error envelope。

当前稳定代码包括业务层的 `bad_request`、`unauthorized`、`authentication_failed`、`forbidden`、`not_found`、`conflict`、`rate_limited`、`content_violation` 和 `internal_error`，以及 Axum 在进入 handler 前返回的 `validation_failed`、`method_not_allowed`、`payload_too_large`、`unsupported_media_type`。`/api/*` 的框架拒绝也使用上述 JSON 结构；静态 `/uploads/*` 不会被错误中间件改写。

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

需要登录。返回当前用户资料，包括 `user_id`、`username`、`email`、`student_id`、`avatar_url`、`role`、`created_at`、`chat_read_receipt_mode`、`discoverability` 和 `payment_qr`。

`student_id` 是只读派生字段：当学校邮箱形如 `{8-12位数字}@email.ncu.edu.cn` 时，后端从邮箱本地部分推断；否则为 `null`。`discoverability.username` 默认 `true`，`discoverability.email` 和 `discoverability.student_id` 默认 `false`。

### PATCH `/api/user/profile`

需要登录。可更新昵称、学校邮箱、头像 URL、查找设置、全局聊天已读策略和收款码设置。邮箱更新后会同步重新推断 `student_id`。`chat_read_receipt_mode` 可选 `auto` 或 `manual`，默认 `auto`。

```json
{
  "username": "alice",
  "email": "2024123456@email.ncu.edu.cn",
  "chat_read_receipt_mode": "manual",
  "discoverability": {
    "username": true,
    "email": false,
    "student_id": true
  },
  "payment_qr": {
    "wechat_url": "https://cdn.example.com/payment/wechat.jpg",
    "alipay_url": null,
    "show_wechat": true,
    "show_alipay": false
  }
}
```

`show_wechat/show_alipay` 默认 `false`。URL 为空时不得开启公开展示。收款码只表示用户自愿公开的线下收款信息，不代表平台验证收款人或担保付款。

### GET `/api/users/{id}`

公开用户主页。返回允许公开的用户名、头像、加入时间、active listing 总数和用户主动公开的 `payment_qr` URL。当前计数不拆分出/收。不会返回完整邮箱、学号、发现设置、公开开关或私有收款码。

### GET `/api/user/listings`

需要登录。返回当前用户自己的 listing，供“我的发布”和推荐 wanted response 选择器使用。支持分页；当前客户端可按 `direction` 在本地或接口能力范围内展示出/收分组。

### GET `/api/users/search`

需要登录的兼容用户搜索接口。新“找同学”体验优先使用权限和脱敏语义更明确的 `/api/users/lookup`。

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
| `direction` | `offer`、`wanted`、`all`；默认 `offer` 保持旧客户端兼容。 |

返回：

```json
{
  "items": [
    {
      "id": "listing-id",
      "title": "二手教材",
      "category": "books",
      "brand": "高等教育出版社",
      "direction": "offer",
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

需要登录。创建 offer 或 wanted，走字段校验和文本审核。`direction` 默认 `offer`。可选 `image_url` 必须以 `http://` 或 `https://` 开头，并会进入图片审核任务。

[已实现] 客户端可以发送 `Idempotency-Key` header，值为 1–128 个不含空格的 ASCII 字符。相同用户用同一 key 重试完全相同的规范化发布内容时，接口返回第一次创建的 listing id，不会再建条目或重复提交图片审核；同一 key 搭配不同内容返回 `409 conflict`。没有该 header 的旧客户端保持原行为。

```json
{
  "direction": "offer",
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

wanted 使用同一请求形状，但价格解释为预算上限、成色解释为最低可接受成色。当前 V1 信息类型固定为物品，不接受任意 `kind`。

返回：

```json
{
  "id": "listing-id",
  "message": "商品发布成功",
  "replayed": false
}
```

`replayed=true` 表示本次响应复用了先前成功结果。Flutter 发布页会为一次表单内容生成 UUID；网络失败后原样重试复用该 UUID，用户修改发布内容后生成新 UUID。

### PUT `/api/listings/{id}`

需要登录且必须是 owner。支持局部更新：`title`、`category`、`brand`、`condition_score`、`suggested_price_cny`、`defects`、`description`。状态更新不走这个通用接口。

### DELETE `/api/listings/{id}`

需要登录且必须是 owner。删除或标记商品不可用，返回商品 id 和消息。

### POST `/api/listings/{id}/relist`

需要登录且必须是 owner。把已售或已删除商品重新上架，返回 `status: active`。

### GET `/api/listings/{id}/matches`

需要登录。`id` 必须指向 active wanted。返回满足分类、预算、最低成色和 active 约束的 offer，排除需求方自己的内容。存在 embedding 时结合向量相似度，无 embedding 时回退到条件、关键词和新鲜度。

对 offer 调用返回 bad request。当前响应还没有生产目标中的 `rank_reason` 和 `match_summary` 稳定契约。

### POST `/api/listings/{id}/responses`

需要登录。提供方选择自己的 active offer 响应一条 wanted：

```json
{
  "offer_listing_id": "my-active-offer-id",
  "message": "这台平板符合你的预算，可以看看"
}
```

不能推荐别人的商品、wanted、sold 或 deleted 内容。同一 responder/offer/wanted 不会产生重复 pending response；成功后写入通知。Response 不自动创建聊天或成交记录。

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

## Legacy Conversation History

### GET `/api/conversations` [待弃用]

需要登录。按旧 `chat_messages.conversation_id` 语义列出用户参与的历史，使用 `limit/offset`。它不等同于新的联系人 Thread，也不承载 realtime/mail 状态机。

### GET `/api/conversations/{id}/messages` [待弃用]

需要登录。只有当当前用户是该旧会话至少一条消息的 sender/receiver 时才可读取，避免 IDOR。返回 sender、sender_username、content、is_agent 和 timestamp 等旧字段。

新直聊使用 `/api/chat/threads` 与 `/api/chat/conversations/*`，小帮使用 `/api/chat/assistant`。新增客户端不应依赖这两个旧接口。

## User Chat

用户直聊已经从“永久好友连接”改为“每次联系创建独立会话”。会话有两种模式：

- `realtime`：TCP 式三次握手，`syn_sent -> syn_ack -> active`，只显示本次沟通。
- `mail`：异步留言，创建后直接 `open`，不展示在线、typing 或已读给发件人。

公共会话字段包括 `id`、`mode`、`state`、`initiator_id`、`recipient_id`、`other_user_id`、`other_username`、`listing_id`、`subject`、`last_message`、`unread_count`、`read_receipt_mode`、`effective_read_receipt_mode`、`expires_at`、`is_blocked` 和 `capabilities`。`read_receipt_mode` 是本会话覆盖项，可为 `inherit`、`auto` 或 `manual`；`effective_read_receipt_mode` 是后端合并全局默认后的实际行为。`capabilities` 告诉移动端当前用户是否可以 `respond`、`ack`、`send`、`close`、`archive` 或 `restart`。

非法状态转换返回 `409 invalid_conversation_state`。重复创建和重复发送依赖客户端 UUID 幂等。

### GET `/api/chat/threads`

需要登录。按 `other_user_id` 聚合收件箱，让同一聊天对象只返回一个 Thread。支持 `mode=all|realtime|mail`。返回对方标识、最近活动/预览、总未读、conversation/mail/realtime/pending 数量和 active realtime 状态。

### GET `/api/chat/threads/{peer_user_id}`

需要登录。返回当前用户与指定对方之间的 Conversation 卡组，按最近活动排序。只包含当前用户参与的会话，不泄露第三方历史。Thread 是查询聚合，不改变底层 Conversation ID 和状态机。

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

### POST `/api/chat/messages/{id}/reaction`

需要登录且消息对当前用户可见。设置或替换当前用户的单个 emoji reaction。

```json
{
  "emoji": "👍"
}
```

### DELETE `/api/chat/messages/{id}/reaction`

移除当前用户对该消息的 reaction，不影响其他用户。

### POST `/api/chat/messages/{id}/hide`

“仅对自己删除”。消息从当前用户列表隐藏，对方仍可见，数据库原文和必要审核记录保留。当前接口不提供用户 hard delete。

### POST `/api/chat/messages/{id}/report`

举报当前用户可见的消息：

```json
{
  "reason": "harassment",
  "details": "可选补充说明"
}
```

同一用户不能重复举报同一消息。普通用户不会通过该接口获得审核处理细节。

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

### GET/POST `/api/chat/spaces` [实验中]

GET 返回当前用户可见的 group/channel；POST 创建空间，body 包含 `kind=group|channel`、名称和可选描述。创建者成为 owner。

### GET `/api/chat/spaces/{id}` [实验中]

返回空间详情、当前用户角色和能力。非成员或被 banned 用户按可见性规则拒绝。

### POST `/api/chat/spaces/{id}/members` [实验中]

owner/admin 添加成员。成员角色和跨校园限制仍需生产硬化。

### DELETE `/api/chat/spaces/{id}/members/{user_id}` [实验中]

owner/admin 移除成员，或按 handler 规则处理退出。不能让普通成员提升角色或移除 owner。

### GET/POST `/api/chat/spaces/{id}/messages` [实验中]

Group 成员按角色发言；Channel 只有 owner/admin 发言，成员可读、reaction 和举报。支持 `reply_to_message_id`。

### POST `/api/chat/calls` [实验中]

在 active realtime 一对一会话中创建 WebRTC call signaling。后端只转发信令，不处理媒体流。

### POST `/api/chat/calls/{id}/answer` [实验中]

会话成员接听并提交 answer。非成员或非 active realtime 拒绝。

### POST `/api/chat/calls/{id}/end` [实验中]

任一通话成员结束 signaling，会产生 `call_ended` 事件。

### POST `/api/chat/secret-sessions` [实验中][待弃用]

创建服务器不可读的客户端密文会话。该能力不进入生产承诺，不应有新功能依赖。

### GET/POST `/api/chat/secret-sessions/{id}/messages` [实验中][待弃用]

读写密文、nonce、公钥指纹和过期时间。服务器不接收明文。生产迁移方向见[信任与安全](trust-safety.md)。

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

## Deal Records（当前路径仍为 Orders）

### GET `/api/orders`

需要登录。列出当前用户参与的线下成交记录。query：

| 参数 | 说明 |
| --- | --- |
| `role` | 可选 `buyer` 或 `seller`，不传则返回用户参与的全部订单。 |
| `limit`、`offset` | 分页。 |

### GET `/api/orders/{id}`

需要登录且必须是 buyer 或 seller。返回成交详情、商品标题、双方用户名、状态和各状态时间戳。

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

### POST `/api/orders/{id}/pay` [待弃用]

兼容旧客户端入口。平台不负责资金中转，调用会返回明确错误提示，不改变订单状态。

### POST `/api/orders/{id}/ship` [待弃用]

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
| `GET /api/admin/orders` | 线下成交记录列表。 |
| `GET /api/admin/audit-logs` | 管理员审计日志。 |
| `POST /api/admin/users/{id}/ban` | 封禁用户。 |
| `POST /api/admin/users/{id}/unban` | 解封用户。 |
| `POST /api/admin/listings/{id}/takedown` | 下架商品。 |
| `POST /api/admin/users/{id}/impersonate` | 生成目标用户 JWT，用于排查。 |
| `POST /api/admin/tokens/{jti}/revoke` | 撤销 access token。 |
| `POST /api/admin/users/{id}/role` | 修改用户角色。 |
| `POST /api/admin/orders/{id}/status` | 管理员按允许状态处理成交记录。 |

改管理员接口时要同时检查审计日志和普通用户路径的影响。

## Upload、Recommendations、Health 和 Metrics

`GET /api/upload/token` 返回 OSS 直传临时凭证，要求 OSS 相关配置存在。

推荐路径：

- `GET /api/recommendations/similar?listing_id=...` 用 pgvector 余弦距离返回相似 active 商品；无 embedding 时回退到最新 active 列表。
- `GET /api/recommendations/feed?direction=offer|wanted|all` 对匿名用户按 `created_at` 返回最新 active 内容。若请求带有效 Bearer token，则按收藏与买家成交意向的分类亲和度排序，排除自己的内容和已收藏内容。

`GET /api/health` 返回健康状态，常用于启动检查。`GET /api/stats` 返回公开平台统计。`GET /api/metrics` 暴露 Prometheus 文本格式指标，包括请求、限流、聊天、LLM、WebSocket 和订单相关指标。

## 目标生产契约 [目标态]

本节是已经确定的接口方向，不代表当前 router 已注册。实现时先增加 `/api/v1`，保留未版本化 `/api/*` 兼容窗口，不直接替换旧接口。

### 版本、错误和幂等

所有 v1 错误使用统一 envelope：

```json
{
  "error": {
    "code": "invalid_state",
    "message": "当前状态不能执行此操作",
    "trace_id": "uuid",
    "details": {}
  }
}
```

`code` 是客户端稳定判断依据，`message` 可本地化，`details` 只包含安全的字段级信息。不得返回 SQL、provider 原始错误、屏蔽关系或审核规则。

发布、联系、消息、wanted response、Agent confirm 和成交写接口接受 `Idempotency-Key`。同一用户、路径和 key 的重复请求返回首次结果；相同 key 配不同 body 返回冲突。

列表统一使用：

```json
{
  "items": [],
  "next_cursor": "opaque-or-null"
}
```

cursor 对客户端不透明，绑定 tenant、过滤条件和稳定排序；不能用可篡改 offset 冒充 cursor。

### Campus 与 Membership

```text
GET  /api/v1/campuses
GET  /api/v1/memberships
POST /api/v1/memberships/verification
GET  /api/v1/memberships/{id}
POST /api/v1/memberships/{id}/refresh
```

普通业务请求从 token/session 获取 active campus；不能仅依赖 body 中的 `campus_id`。verification 响应不泄露其他账号或 membership 是否存在。

### Intent Feed 与解释

```text
GET  /api/v1/feed?direction=all|offer|wanted&cursor=...
POST /api/v1/feed/feedback
POST /api/v1/intents/{id}/complete
POST /api/v1/intents/{id}/reopen
```

Feed item 在当前 listing 字段之外增加：

```json
{
  "rank_reason": "within_budget",
  "match_summary": ["同分类", "预算内", "成色满足"],
  "source": "wanted_match",
  "ranking_version": "feed-v1"
}
```

`rank_reason` 使用稳定枚举，不暴露内部权重、敏感画像或另一个用户的私有行为。

Feedback 支持 hide、less_like_this、not_relevant 和 clear_personalization 等用户控制，写入行为信号前明确目的和保留策略。

### Agent ActionPlan

```text
POST /api/v1/agent/plans
GET  /api/v1/agent/plans/{id}
POST /api/v1/agent/plans/{id}/confirm
POST /api/v1/agent/plans/{id}/cancel
```

创建计划返回 `plan_id`、`action_type`、`risk_level`、`summary`、`preview`、`expires_at`、`idempotency_key` 和 `confirmation_mode`。L2 使用一次确认，L3 使用二次确认并写审计。

Confirm 时服务端重新验证 tenant、membership、owner、资源版本、状态和金额。过期、上下文变化和重复执行返回稳定冲突，不静默更新计划输入。

### Moderation 与申诉

```text
GET  /api/v1/moderation/cases/{id}
POST /api/v1/moderation/cases/{id}/appeals
GET  /api/v1/moderation/appeals/{id}
```

普通用户只能读取自己的案件摘要和提交申诉，不获得举报人、审核者身份、命中词和内部阈值。校园运营使用独立 tenant-scoped 管理接口；平台管理员跨校园处理需要理由和审计。

### Secret Chat 弃用

当前 `/api/chat/secret-sessions*` 进入弃用后：

1. 首先禁止生产新建并从默认 UI 移除。
2. 在兼容窗口保留授权用户的只读历史能力。
3. 发布弃用 metrics、客户端版本门槛和截止时间。
4. 最终移除发送和创建路由，不把服务器不可读 E2EE 迁入 `/api/v1`。

新的加密消息仍使用普通 Conversation API，只改变服务端存储和授权解密实现，不向客户端承诺服务器不可读。
