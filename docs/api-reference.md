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

当前稳定代码包括业务层的 `bad_request`、`unauthorized`、`authentication_failed`、`recent_authentication_required`、`recent_authentication_failed`、`forbidden`、`not_found`、`conflict`、`rate_limited`、`content_violation` 和 `internal_error`，以及 Axum 在进入 handler 前返回的 `validation_failed`、`method_not_allowed`、`payload_too_large`、`unsupported_media_type`。`/api/*` 的框架拒绝也使用上述 JSON 结构；静态 `/uploads/*` 不会被错误中间件改写。

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

返回 access token、refresh token、user id、username、`active_campus_id` 和消息。access token 会携带当前设备会话的校园；新注册用户可以处于该校园的 pending 状态，但受保护写操作仍要求 verified。重复用户名返回 conflict，非法邮箱或弱密码返回 bad request。

### POST `/api/auth/login`

登录用户。错误用户名和错误密码返回同一种认证失败，避免枚举用户。被封禁用户不能登录。

```json
{
  "username": "alice",
  "password": "password123"
}
```

返回结构与 register 类似。

登录和注册签发的 access token 带 `auth_time`，表示用户刚刚完成密码认证。这个字段只用于敏感操作 step-up，不替代 token 的 `exp`、JTI 撤销和数据库角色复核。

### POST `/api/auth/reauth`

[已实现] 需要有效 access token。重新验证当前账号密码，成功后只替换 access token，不旋转 refresh token；新 token 的近期认证窗口为 10 分钟。

```json
{
  "password": "current-password",
  "totp_code": "123456"
}
```

`totp_code` 仅在账号已确认 TOTP MFA 时必需（当前只有平台管理员可注册）。响应：

```json
{
  "token": "new-access-token",
  "recent_auth_expires_at": "2026-07-18T05:30:00Z"
}
```

密码错误返回 `recent_authentication_failed`，客户端不得因此清除整个登录会话。账号已启用 MFA 但未提供验证码时返回 `mfa_required`；验证码错误或已被使用返回 `recent_authentication_failed`。refresh 和切换活动校园签发的 access token 不保留 `auth_time`，因此会重新锁定敏感操作。

### 平台管理员 TOTP MFA

[已实现] 三个接口都要求平台管理员角色（数据库复核）加 10 分钟近期认证：

- `GET /api/auth/mfa/totp` 返回 `{ "enrolled": bool, "confirmed": bool }`。
- `POST /api/auth/mfa/totp/setup` 生成待确认密钥，返回 `secret_base32` 和 `otpauth_uri`（RFC 6238，SHA1/6 位/30 秒）。已确认的因子返回 `409`——活跃因子不可自助更换，防止被劫持会话轮换 MFA。
- `POST /api/auth/mfa/totp/confirm` 提交 `{ "code": "123456" }` 证明持有验证器后激活强制。未确认的注册不会被强制，避免扫码失误把管理员锁死。

确认后，密码 step-up 必须同时提供动态验证码；验证接受 ±1 个时间步的时钟偏差，且每个时间步只能使用一次（数据库水位线防重放，并发提交同一验证码只有一个成功）。

### POST `/api/auth/refresh`

旋转 refresh token。成功时旧 refresh token 被撤销，并返回新 access token、新 refresh token 与 `active_campus_id`；校园上下文沿用原 refresh session，不会重新猜测第一条 membership。

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

### GET `/api/campuses`

[已实现] 无需登录。返回当前启用的校园 seed，包括 `id`、`slug`、中英文名称和允许的邮箱域名。这个接口只用于注册前展示，不代表调用者已经拥有该校园资格。

### GET `/api/user/campus-memberships`

[已实现] 需要登录。返回当前用户的校园资格和当前设备 token 中的 `active_campus_id`。成员状态为 `pending | verified | suspended | revoked`；新注册会话可以把 pending 校园作为浏览/验证上下文，但发布、联系和成交仍只接受 verified。

### POST `/api/user/active-campus`

[已实现] 需要 access token，并提交当前设备的 refresh token。目标校园必须是当前用户已认证且仍启用的 membership。服务端会撤销旧 refresh、签发绑定目标校园的新 token 对并撤销当前 access JTI；客户端成功后必须替换两枚 token 并重连 WebSocket。

```json
{
  "campus_id": "campus-uuid",
  "refresh_token": "current-device-refresh-token"
}
```

响应字段为 `token`、`refresh_token` 和 `active_campus_id`。refresh token 属于其他用户、已过期、已撤销或被重放时统一 unauthorized；不能用请求体覆盖任意校园。

### POST `/api/user/campus-memberships/{id}/verification/request`

[已实现] 需要登录，且 `{id}` 必须属于当前用户。向用户资料中的校园邮箱发送 6 位验证码；只接受该 Campus 配置的邮箱域名。验证码 5 分钟失效，60 秒后才能重发，每个 membership 每小时最多请求 5 次。响应不返回验证码：

```json
{
  "expires_at": "2026-07-12T12:05:00Z",
  "resend_after_seconds": 60
}
```

开发环境未配置投递 webhook 时只把验证码写入后端本地日志。生产环境必须配置 `CAMPUS_VERIFICATION_DELIVERY_URL` 和 `CAMPUS_VERIFICATION_DELIVERY_TOKEN`，否则应用拒绝启动。

### POST `/api/user/campus-memberships/{id}/verification/confirm`

[已实现] 需要登录。提交 `{ "code": "123456" }`；最多允许 5 次错误尝试。成功后 membership 变为 `verified`，`verification_method` 为 `campus_email_otp`。服务端只保存验证码 HMAC，不保存明文。更换资料邮箱会把已认证 membership 重置为 `pending`，需要重新验证。

发布 offer/wanted、响应 wanted、创建联系人会话、创建/加入群组或频道、创建 Secret Chat 和创建成交意向均要求 verified membership；小帮发布、购买意向和议价工具执行同一门禁。未认证调用返回 HTTP 403 和稳定错误码 `campus_verification_required`。浏览、收藏、读取历史等低风险能力不受影响。

[已实现] 涉及另一用户或 listing 的写操作还必须处于同一校园，否则返回 HTTP 403 和 `campus_scope_mismatch`。客户端不能在业务请求体覆盖 `campus_id`：发布、成交、直聊、空间、Secret Chat、用户发现和 Agent 工具都从 access token 的活动校园派生并复核 membership。登录用户的商品列表、详情、wanted 匹配、空间、推荐、公开用户页面和通知按活动校园读取；游客仍使用首校园 NCU。后台与审核使用下文单独描述的管理作用域。

### GET `/api/user/profile`

需要登录。返回当前用户资料，包括 `user_id`、`username`、`email`、`student_id`、`avatar_url`、`role`、`created_at`、`discoverability` 和 `payment_qr`。

`student_id` 是只读派生字段：当学校邮箱形如 `{8-12位数字}@email.ncu.edu.cn` 时，后端从邮箱本地部分推断；否则为 `null`。`discoverability.username` 默认 `true`，`discoverability.email` 和 `discoverability.student_id` 默认 `false`。

### PATCH `/api/user/profile`

需要登录。可更新昵称、学校邮箱、头像 URL、查找设置和收款码设置。邮箱更新后会同步重新推断 `student_id`。聊天注意力设置不属于用户资料；连接隐私通过下文的 connection preferences 接口单独管理。

```json
{
  "username": "alice",
  "email": "2024123456@email.ncu.edu.cn",
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

### POST `/api/users/{id}/report`

`VerifiedTenant` 接口：需要有效登录态和活动校园的 verified membership。用户不能举报自己；目标账号必须是同校已认证成员。`campus_id` 从当前 session 派生，`subject_user_id` 由服务端根据路径中的目标和同校 membership 查询确定；请求体不能指定或覆盖这两个字段。

```json
{
  "reason": "冒充他人或可疑行为",
  "details": "可选补充说明"
}
```

`reason` 去除首尾空白后必须为 1–80 字，`details` 可选且最长 1000 字。响应为 `{ "report_id": "uuid" }`。每个举报人每小时最多新建 10 条资源举报；同一举报人对同一校园、同一目标的未处理举报只保留一条 standing report，重复提交更新原因与说明，不额外占用新建额度。前一条已经 `resolved` 或 `dismissed` 后，新的举报会创建新 report 和新案件，不改写已封存的处理历史。

举报记录、`ModerationCase` 和首个案件事件在同一数据库事务中创建并关联；任一步失败整体回滚。提交举报、开始复核或驳回案件都不会自动封禁账号。

### GET `/api/user/listings`

需要登录。返回当前用户自己的 listing，供“我的发布”和推荐 wanted response 选择器使用。支持 `limit`、`offset` 与 `status=active|sold|deleted|all`；默认只返回 active。Flutter“我的发布”使用 `status=all` 并在本地按 `direction` 分组，因此 fulfilled wanted 离开详情后仍可找到并重新开启。

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

### POST `/api/listings/{id}/report`

举报同校 listing，请求和响应与 `POST /api/users/{id}/report` 相同。该接口使用 `VerifiedTenant`，listing 的校园和 owner 由服务端查询；不存在或跨校目标统一按不存在处理，owner 不能举报自己的发布。限制为 `reason` 1–80 字、`details` 最长 1000 字、每小时最多新建 10 条。举报与 `ModerationCase` 同事务关联，但提交、开始复核和驳回均不改变 listing 的 `active/sold/deleted/fulfilled` 业务状态。

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

需要活动校园的 verified membership 且必须是 owner。事务先按校园和 owner 锁定 listing，再把非 sold 条目标记为 `deleted`；重复删除保持幂等。删除 active wanted 会立即关闭当前响应轮次，已有 Response 继续作为只读历史保留。

### POST `/api/listings/{id}/relist`

需要活动校园的 verified membership 且必须是 owner。把 `sold`、`deleted` 或 `fulfilled` 条目重新设为 `active`，返回 `status: active`。普通 offer 不改变轮次；wanted 每次从非 active 重新开启时，`lifecycle_epoch` 必须在同一事务中恰好加一，因此此前轮次的 Response 不会重新获得操作权限。

### GET `/api/listings/{id}/matches`

无需登录；游客使用默认公开校园，有效登录态使用当前活动校园。`id` 必须指向该校园的 wanted。active wanted 返回满足分类、预算、最低成色、方向和 active 约束的 offer，排除需求方自己的内容；登录查看者还会排除自己的内容。存在 embedding 时结合向量相似度，无 embedding 时回退到条件、关键词和新鲜度。

对 offer 调用返回 bad request，跨校园或不存在的 wanted 返回 not found；inactive wanted 返回带版本的空响应。响应条目包含 `rank_reason=known_slots_compatible`、实际执行过的 `match_summary`、`source=wanted_match` 和 `ranking_version=2026.07-wanted-feedback-v1`；响应 envelope 也带同一版本。登录查看者的三种显式反馈都会精确排除目标；个性化开启时，当前且未重置的 `less_like_this` 还会降低同品牌候选。

### POST `/api/listings/{id}/responses`

需要活动校园的 verified membership。提供方选择自己的 active offer 响应一条 active wanted：

```json
{
  "offer_listing_id": "my-active-offer-id",
  "message": "这台平板符合你的预算，可以看看"
}
```

接口支持 `Idempotency-Key` header，格式与 listing 发布相同。服务端在同一事务中按 `wanted -> offer` 顺序锁行，重新验证双方校园、owner、direction、active 状态，并从锁定的 wanted 派生当前 `lifecycle_epoch`；客户端不能在 body 中指定轮次。成功返回：

```json
{
  "id": "response-uuid",
  "message": "已推荐给需求方",
  "replayed": false
}
```

同一 responder 在同一校园用相同 key 重试相同 wanted、offer 和规范化留言时，返回首次 response id 且 `replayed=true`，不重复写 response 或通知；即使 wanted 后来关闭或重开，该 key 仍重放原结果。同一 key 搭配不同内容返回 `409 conflict`。

不能推荐别人的商品、wanted、sold 或 deleted 内容。一个 offer 在同一 wanted `lifecycle_epoch` 最多响应一次，不因先前 response 已 accepted、dismissed 或 withdrawn 而重新开放；wanted 进入新轮次后，同一 offer 可以再次响应一次。Response 不自动创建聊天或成交记录。

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

用户直聊已经从“永久好友连接”改为“每次联系创建独立会话”。产品语义分为留言和连接两种模式：

- `mail`：异步留言，状态体验是“发送中 → 已发送 → 可选主动确认”；创建后直接 `open`。
- `realtime`：连接请求的握手状态为 `syn_sent -> syn_ack -> active`，产品体验是“请求连接 → 已连接 → 已结束”，不等于全局在线。

`sent` 只表示消息已经持久化到服务器。没有设备 ACK 时，API 不称其为“已送达”。接收端的 `LOCALLY_SEEN` 由设备本地维护，不上传、不广播，也不会产生发送方可查询的 `read_at`。

公共会话字段包括 `id`、`campus_id`、`mode`、`state`、`initiator_id`、`recipient_id`、`other_user_id`、`other_username`、`listing_id`、`subject`、`last_message`、`archived`、`expires_at`、`is_blocked` 和 `capabilities`。新消息提示由接收设备本地维护；服务端不返回阅读位置或 read preference。`capabilities` 告诉移动端当前用户是否可以 `respond`、`ack`、`send`、`close`、`archive` 或 `restart`。

带活动校园的 access token 只能读取或修改该校园中的直聊会话和消息；切换校园后，另一校园的会话按 `campus_scope_mismatch` 拒绝。旧的无校园 claim token 在兼容窗口内仍按成员权限工作，但新客户端应使用带活动校园的 token。

非法状态转换返回 `409 invalid_conversation_state`。重复创建和重复发送依赖客户端 UUID 幂等。

### GET `/api/chat/threads`

需要登录。按 `other_user_id` 聚合收件箱，让同一聊天对象只返回一个 Thread。支持 `mode=all|realtime|mail`。返回对方标识、最近活动/预览、conversation/mail/realtime/pending 数量、active realtime 状态，以及只读的 `relationship_key`。当请求带有服务端推导的活动校园时，key 是该校园内无序用户对的稳定标识；无校园的 legacy 读取使用独立命名空间。新客户端根据设备本地的 `LOCALLY_SEEN` 标记显示“新留言”，不读取服务器未读数。

### GET `/api/chat/threads/{peer_user_id}`

需要登录。返回当前用户与指定对方之间的 Conversation 卡组，按最近活动排序，并在 `thread.relationship_key` 中返回同校园无序用户对的只读稳定标识。只包含当前用户参与的会话，不泄露第三方历史。Thread 是查询聚合，不改变底层 Conversation ID 和状态机，也不产生在线、输入中或已读事实。

### GET `/api/chat/threads/{peer_user_id}/space-events`

需要登录。按 `cursor` 和 `limit` 返回同一 Thread 的只读 Relationship Space 时间轨迹。事件由现有 `chat_conversation_events` 与当前用户可见的 `chat_messages` 确定性投影而来，包含 `source_type/source_id`、事件类型、会话、行动者和发生时间；消息正文、媒体、Pin 与共享对象仍分别通过既有资源接口处理。返回的 `next_cursor` 只用于继续读取，不写入阅读位置，也不会因为打开或滚动而广播注意力状态。

### POST `/api/chat/conversations`

需要登录。创建实时会话或留言线程。不能联系自己；被屏蔽关系不能创建新会话。`realtime` 模式下同一校园的“用户对”如果已有未结束会话，会直接返回已有会话；双方同时发起时视为 mutual intent，直接进入 `active`。陌生人连接须符合接收方的 `allow_strangers`、busy 和联系人权限；重复请求按用户对抑制，不按 listing 分叉。响应额外包含 `notify_recipient`，表示当前联系人静音是否允许打扰通知。

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

需要登录且必须是会话成员。支持 `limit`、`offset`。返回 `conversation_id`、`messages` 和 `total`。消息字段包括 `id`、`client_message_id`、`sender`、`content`、`timestamp`、`image_url`、`audio_url`、Base64 fallback 字段、`reply_to_message_id`、`reply_preview`、`quote`、`reactions`、`acknowledgements`、`status`、`kind` 和 `edited_at`。新客户端看到的 `status` 只有 `sending | sent | failed`；旧数据库中的 `delivered/read` 会映射为 `sent`。消息列表不包含服务器阅读位置。

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
  "image_url": "https://<platform-bucket>.<oss-endpoint>/chat/photo.jpg",
  "audio_url": null,
  "image_base64": null,
  "audio_base64": null
}
```

`reply_to_message_id` 用于回复同一会话内的历史消息。`quote` 用于引用结构化事实，`kind` 可为 `listing`、`order` 或 `hitl_offer`。前端只提交 `kind/ref_id`，服务端会校验权限并生成快照，例如商品标题、价格、状态和主图；前端传入的伪造快照会被忽略。快照是发送时事实，不会因后续商品价格、订单状态或议价状态变化而改写。

媒体 URL 必须先通过平台上传接口获得，且 host 必须属于配置的 OSS/S3 bucket（支持 virtual-host 和 path-style URL）；任意第三方 URL 返回 `409 media_external_url_blocked`。服务端不会因为 Push、解密、页面打开或媒体播放产生注意力状态。

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

### POST `/api/chat/messages/{id}/acknowledgement`

需要登录且消息对当前用户可见。只有消息接收方可以提交主动确认，`kind` 必须是 `received`（收到）、`will_review`（我会看）或 `completed`（已处理）。同一用户对同一消息最多一条；重复提交幂等，改变 `kind` 会替换原确认。回复、引用和普通 emoji reaction 不会自动创建 acknowledgement。

```json
{
  "kind": "will_review"
}
```

返回完整消息对象及 `acknowledgements`。屏蔽关系、越权、隐藏消息、跨校园消息均拒绝。

### DELETE `/api/chat/messages/{id}/acknowledgement`

撤销当前用户对该消息的主动确认。撤销是幂等的，返回更新后的消息对象。

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

### GET/PUT `/api/chat/connection-preferences`

需要登录。读取或更新当前用户的连接隐私：`allow_strangers` 控制陌生人是否可以发起 realtime 连接，`busy_until` 是可选的忙碌截止时间。busy 期间 realtime 请求被拒绝；mail 留言仍可持久化。

```json
{
  "allow_strangers": false,
  "busy_until": "2026-08-11T18:00:00Z"
}
```

### GET `/api/chat/contacts`

需要登录。返回当前用户显式设置过的联系人权限。每项包含 `peer_user_id`、`allow_connection` 和 `muted_until`。

### PUT/DELETE `/api/chat/contacts/{peer_user_id}`

需要登录且双方必须属于同一已验证校园。PUT 可允许/拒绝该联系人发起 realtime，并设置只抑制通知的 `muted_until`；DELETE 删除显式覆盖，恢复陌生人默认策略。静音不会删除历史，也不会伪造已读。

```json
{
  "allow_connection": true,
  "muted_until": null
}
```

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

### POST `/api/chat/secret-sessions` [待弃用]

[已实现] 默认返回 `403 forbidden`：Secret Chat 与服务器可治理通信目标冲突，新会话创建已停止。仅在迁移窗口内由 `SECRET_CHAT_NEW_SESSIONS_ENABLED=true` 临时恢复。移动端不再提供创建入口。

### GET/POST `/api/chat/secret-sessions/{id}/messages` [待弃用]

读写密文、nonce、公钥指纹和过期时间。服务器不接收明文。历史会话保持可读可写以兼容存量数据；生产迁移方向见[信任与安全](trust-safety.md)。

## Wanted 生命周期与响应动作

[已实现] Phase 2 信息流闭环接口：

- `POST /api/listings/{id}/fulfill` — 所有者把 active wanted 标记为 `fulfilled`；非所有者 403，offer 400，非 active 409。完成后 feed、匹配和新响应全部停止，当前轮次立即变为只读，历史 Thread/Response/成交保留，当前轮 pending 响应者收到 `wanted_fulfilled` 通知。Response 的事实状态仍可保持 `pending`，不能把它误解为仍可操作。
- `DELETE /api/listings/{id}` 与 `POST /api/listings/{id}/relist` — 删除 wanted 同样关闭当前轮次；从 `fulfilled/deleted` 重新开启 wanted 时，服务端原子增加 `inventory.lifecycle_epoch`。旧轮次保持历史，新轮次允许同一 offer 再响应一次。
- `GET /api/wanted-responses?role=requester|responder&status=&wanted_listing_id=&limit=&offset=` — 按角色和指定 wanted 列出自己的推荐。响应 envelope 为 `{items,total,limit,offset}`；接口每次重新校验活动校园 verified membership，并只读取该校园数据。每项除 wanted/offer、双方用户、留言、`status` 和时间外，还返回：

```json
{
  "lifecycle_epoch": 1,
  "current_lifecycle_epoch": 2,
  "round_state": "closed",
  "available_actions": []
}
```

`round_state=current` 仅在 wanted 为 active、response 的非空 `lifecycle_epoch` 等于 wanted 当前 epoch 时成立；其他情况一律为 `closed`。升级前无法证明轮次的 legacy Response 返回 `lifecycle_epoch: null`，始终只读。`available_actions` 是按本次 `role`、response 状态、轮次状态和 offer 状态计算的服务端权威能力：requester 最多获得 `accept/dismiss`，responder 最多获得 `withdraw`；closed 或非 pending 行必须返回空数组。

- `POST /api/wanted-responses/{id}/accept|dismiss`（requester）与 `/withdraw`（responder）— 三种动作都只允许当前 active 轮次的 pending Response。accept 还要求 offer active；offer 已非 active 时 requester 仍可 dismiss；withdraw 不要求 offer active，但绝不允许在 wanted fulfilled/deleted 或旧 epoch 上执行。非本人或跨校园响应统一 404，重复/终态转换为 409，活动校园资格 suspended/revoked 后为 403；关闭轮次统一返回 `409 wanted_response_round_closed`，客户端应冻结该行并刷新 listing/response。对方收到带 wanted `related_listing_id` 的 `wanted_response_accepted|dismissed|withdrawn` 通知，可直接回到需求详情。

所有创建和动作事务使用一致锁序：先 wanted，再按需要锁 offer，最后锁 response；fulfill、delete 和 relist 也先锁 wanted。这样 respond/accept 与 fulfill/relist 并发时只能线性化为一个完整轮次结果，不会把验证发生在旧轮、写入落在新轮。

Flutter 在 wanted 详情按当前用户身份展示“收到的推荐”或“我发出的推荐”，以 `available_actions` 控制 accept/dismiss/withdraw；缺少新字段的旧响应才使用保守兼容逻辑。关闭轮次显示只读提示，`wanted_response_round_closed` 会触发 listing 与 response 刷新，不保留过期按钮。完成 wanted 前有确认弹窗。

`0055_wanted_response_lifecycle_epoch.sql` 使用前向兼容迁移：`inventory.lifecycle_epoch` 非空，`wanted_responses.lifecycle_epoch` 对无法可靠重建轮次的 legacy history 保持 nullable；只有能证明属于当前 active 轮次的旧行才回填。数据库 INSERT trigger 为未写 epoch 的旧应用锁定并派生当前轮次，reopen trigger 让只更新 status 的旧应用也恰好增加一个 epoch。应用 rollback 不要求回滚 migration。

新推荐与匹配接口的每个条目携带稳定的 `rank_reason` 与 `source` code，客户端负责本地化为人话；响应携带 `ranking_version`。兼容中的首页商品 feed 仍可能返回服务端人话 `rank_reason`，其 `source` 保持稳定 code。listing wanted matches 还返回只来自已执行硬约束的 `match_summary`，不返回作者、距离、权重或反馈信号。

## Agent ActionPlan

[已实现] 小帮的商品发布是可恢复的低风险动作：通过校验后立即发布，并在小帮页提供撤销窗口。修改、下架使用 L2 ActionPlan；成交意向和还价使用 L3 ActionPlan。confirmation token 只通过以下认证接口返回，不出现在聊天文本中；带 token 的响应使用 `Cache-Control: no-store`。

- `GET /api/agent/plans` — 只列出当前用户在当前活动校园内、未过期的 `pending` 或 `confirmed_once` 计划，返回 `status`、当前步骤的 `confirmation_token`、`risk_level`、`summary` 和 `expires_at`。
- `POST /api/agent/plans/{id}/confirm` — body `{ "confirmation_token": "..." }`。L2 计划一次确认后执行。L3 第一次必须提交 primary token，响应为 `{ "status": "needs_second_confirmation", "confirmation_token": "<独立的第二步 token>" }`；只有返回的第二步 token 可以执行。primary 请求的传输重试只会重放同一挑战，不会被计为第二次确认。终态重试返回同一执行结果。过期/已取消返回 `409`；错误 token、其他用户、其他校园或不存在统一 `404`（不泄露归属）。执行校验失败返回 `409` 并把计划记为 `failed`。
- `POST /api/agent/plans/{id}/cancel` — 取消当前校园内的 `pending` 或 `confirmed_once` 计划。

确认从锁定计划行、重新校验校园资格/所有权/商品状态/金额，到业务事实、适用时的通知/outbox 和计划终态都位于同一个数据库事务。业务执行使用 savepoint：校验失败不会留下部分事实；进程在 commit 前中断时整笔事务回滚，原 token 可安全重试。升级前遗留的已提交 `executing` 行被迁移为 `interrupted`，必须人工核对，系统绝不自动重放。

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

使用 `Authorization: Bearer <jwt>` 建连。服务端会验证 token 未撤销、用户未封禁和活动校园 membership。连接用于通知推送、聊天消息提示、会话状态和主动 acknowledgement 变更；直聊事件只投递到该会话校园的同校园 socket。WebSocket 的连接本身不表示用户在线，服务端也不发送 read/typing 注意力事件。客户端收到事件后仍应回查 HTTP 列表，因为数据库才是最终事实；`LOCALLY_SEEN` 继续只留在设备。

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
建议携带 `Idempotency-Key` 请求头。相同卖家对同一 key 和相同确认参数的重试会返回同样的确认结果，不会重复下架；同一 key 改变 `auto_delist` 等确认参数会返回 `409 conflict`。

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

需要登录。默认只返回当前设备活动校园中的未读通知；传 `include_read=true` 返回该校园历史。支持 `limit`、`offset`。返回 `items`、`total`、`unread_count`，每个 item 包含服务端确定的 `campus_id`。

### POST `/api/notifications/{id}/read`

需要登录。只有通知同时属于当前用户和活动校园时才能标记已读，返回 `{ "ok": true }`；另一校园的通知按不存在处理。

### POST `/api/notifications/read-all`

需要登录。只标记活动校园中的全部未读通知，返回 `marked_count`。

## Admin

[已实现] 后台读取具有校园作用域。全局 `users.role=admin` 是平台管理员；`campus_memberships.role=operator|admin` 且 membership 为 verified 的用户可以读取自己当前校园的后台数据，但不能执行平台级写操作。服务端会复核数据库中的账号状态与角色，不只信任 JWT claim。

所有后台 GET 响应都返回实际使用的 `campus_id`。默认使用 access token 的活动校园。只有平台管理员可以通过 `?campus_id=<uuid>&reason=<非空理由>` 查看另一所启用校园；缺少理由返回 bad request，成功的跨校园读取会写入该校园的 `admin_audit_logs`。校园运营传入另一校园 ID 返回 scope mismatch。

关键路径包括：

| 方法和路径 | 行为 |
| --- | --- |
| `GET /api/admin/stats` | 平台管理统计。 |
| `GET /api/admin/capabilities` | 返回当前校园的后台读取、复核、跨校园和近期认证状态；校园运营可读但不能处置。 |
| `GET /api/admin/users` | 用户列表；支持 `q` 按用户名或用户 ID 字面量包含检索，以及 `limit`、`offset` 分页。 |
| `GET /api/admin/listings` | 商品列表；同时返回 lifecycle `status`、组合后的 `restriction_state`、后台可见的 `restriction` 摘要、`active_restriction_count` 与权威 `available_admin_actions`；`restricted` 保留为兼容布尔值。 |
| `GET /api/admin/orders` | 线下成交记录列表。 |
| `GET /api/admin/audit-logs` | 管理员审计日志。 |
| `GET /api/admin/moderation/jobs` | 按校园与可选 `status` 查看异步媒体审核任务。 |
| `GET /api/admin/moderation/cases` | 按校园和可选 `status` 查看案件队列；包含内部证据，仅限后台角色。 |
| `POST /api/admin/moderation/cases/{id}/review` | 平台管理员开始复核、驳回、限制或恢复案件资源。listing 的 `restrict` 创建该 case 自己的 effect；`restore` 只释放该 case 的 effect。所有动作、effect 和审计同事务写入。 |
| `POST /api/admin/moderation/appeals/{id}/review` | 由非原决定人员独立复核申诉，支持维持或改判。 |
| `POST /api/admin/users/{id}/ban` | 封禁用户。 |
| `POST /api/admin/users/{id}/unban` | 解封用户。 |
| `POST /api/admin/listings/{id}/takedown` | 紧急下架：幂等创建或复用一个 manual ModerationCase 及其 case-owned effect，不改 listing lifecycle `status`。 |
| `POST /api/admin/listings/{id}/restore` | 明确管理员恢复：只释放紧急 manual case 的 effect，不释放举报/其他案件的 effect，也不把 deleted/sold/fulfilled 改回 active。 |
| `POST /api/admin/users/{id}/impersonate` | 生成目标用户 JWT，用于排查。 |
| `POST /api/admin/tokens/{jti}/revoke` | 撤销 access token。 |
| `POST /api/admin/users/{id}/role` | 修改用户角色。 |
| `POST /api/admin/orders/{id}/status` | 管理员按允许状态处理成交记录。 |

POST 写接口仍只允许平台管理员，并且 access token 必须带 10 分钟内的 `auth_time`；过期或旧 token 返回 HTTP 403 与 `recent_authentication_required`。`ban/unban/role/impersonate` 的目标用户、takedown/restore 的 listing 和成交状态操作的 order 必须属于所选校园，否则按不存在处理。跨校园写操作同样必须提供 `campus_id` 与 `reason`，审计记录保存目标校园和该理由。代登录 token 绑定目标校园，不能借此获得另一个校园的上下文。

listing 的生命周期和可用性是两个正交维度：`inventory.status` 继续只表示 `active|sold|deleted|fulfilled`；`listing_restriction_effects` 中任何一条 `released_at IS NULL` 的记录都会把有效状态派生为 restricted。普通 feed、搜索、推荐、详情、收藏、联系、议价、成交与 wanted response 创建/动作全部 fail closed。owner/admin 可读取安全摘要；非 owner 的 detail 按不存在处理。owner 删除不会清除 effect，owner relist 在仍有任一 active effect 时返回 `409`、`code=listing_restricted`。

`POST /api/admin/listings/{id}/takedown` 的公开处置理由固定使用安全文案；query `reason` 不会进入 `ModerationCase.public_reason`，只在跨校园操作时作为必填的作用域/审计说明，同校园可省略。成功返回 `{message, case_id, restricted: true}`；相同 listing 的并发/重试复用当前 manual case/effect。`POST /api/admin/listings/{id}/restore` 必须提供非空 query `reason` 作为恢复与审计理由，成功返回 `{message, case_id, restricted}`；其中 `restricted` 是释放 manual effect 后重新计算的组合状态，因此另一 case 仍有效时仍为 `true`。两者都保持 `inventory.status` 原值。

普通 owner detail 的规范新增字段是 `restriction_state=clear|restricted`、可选嵌套 `restriction`（只含公开原因、限制时间和可申诉 case，不含举报人/内部证据）以及服务端权威 `available_actions`。过渡期同时返回 `restricted` 与扁平 `restriction_reason`；客户端遇到缺失、冲突或未知 restriction state 必须 fail closed。

`GET /api/admin/capabilities` 的附加字段为 `recent_authentication_required`、`recent_authentication_valid` 和 `recent_authentication_expires_at`。Flutter 后台据此锁定处置按钮并展示密码验证入口，但服务端校验仍是最终边界。

平台管理员校园管理：`POST /api/admin/campuses` 创建校园（slug/中英文名/邮箱域名，默认 `inactive` 暗启动），`POST /api/admin/campuses/{id}/activate|deactivate` 切换状态；三者均要求平台管理员近期认证并写审计。注册与改邮箱按邮箱域名路由到对应活动校园的 pending membership；不属于任何活动校园的域名被拒绝。

改管理员接口时要同时检查审计日志和普通用户路径的影响。近期密码认证与平台管理员 TOTP MFA 已实现；案件通知 SLA 和统一 `/api/v1` 版本前缀仍未实现。未版本化的案件/申诉接口已在当前 router 中实现。

## Upload、Recommendations、Health 和 Metrics

`GET /api/upload/token` 返回 OSS 直传临时凭证，要求 OSS 相关配置存在。凭证授予对象写权限，因此按写接口处理：调用方必须是当前活动校园的 verified 成员，`pending` 成员返回 `403 campus_verification_required`，游客返回 `401`。

推荐路径：

- `GET /api/recommendations/similar?listing_id=...` 要求源条目本身是当前校园的 active offer；missing、inactive、wanted 或跨校园源统一返回 not found。接口用 pgvector 余弦距离返回同校园有 embedding 的相似 active offer；源无 embedding 时回退到同校园最新 active offer。游客使用公开校园基础排序；有效登录态会在 LIMIT 前排除自己的商品和三种显式反馈目标，`less_like_this` 在个性化开启且信号未被重置时降低同分类候选。条目返回 `vector_similarity|recency` 稳定原因，响应版本为 `2026.07-similar-feedback-v1`。
- `GET /api/recommendations/feed?direction=offer|wanted|all` 对匿名用户在 NCU 公开校园内按 `created_at` 返回最新 active 内容。若请求带有效 Bearer token，则切换到设备活动校园，按仍有效的收藏与买家成交意向分类亲和度排序，并排除自己的内容、仍有效的已收藏内容和用户明确反馈过的条目。每项包含 `rank_reason`、`source`，响应包含 `ranking_version=2026.07-feedback-v2`。
- `GET /api/listings/{wanted_id}/matches` 保留分类、预算上限、最低成色、校园、方向和 active 状态硬约束，返回 `rank_reason=known_slots_compatible`、`match_summary`、`source=wanted_match` 与 `ranking_version=2026.07-wanted-feedback-v1`。有效登录态会精确排除三种显式反馈目标；`less_like_this` 还会在个性化开启且信号未重置时，根据被反馈商品的服务端品牌事实降低同品牌候选。关闭或重置只停用泛化品牌降权，不恢复明确排除。
- `GET /api/intents/feed` 返回当前校园内其他人的 active 公开意图；`GET /api/intents/{id}/matches` 先执行校园、状态、方向和已声明槽位的硬约束，再返回候选。两者的条目都包含稳定的 `rank_reason`、`match_summary`、`source` 和 `ranking_version`；理由只来自已知约束，不包含作者 ID，也不让 LLM 猜测用户画像。

当前未版本化信息流控制接口均要求当前活动校园的 verified membership：

| 方法和路径 | 行为 |
| --- | --- |
| `POST /api/feed/feedback` | body 为 `resource_type=listing|intent`、`resource_id`、`action=hide|less_like_this|not_relevant`。服务端解析同校园 active 目标并派生分类/意图类型信号；缺失、跨校园和自己的目标统一按不存在处理。同一用户对同一资源重复提交只更新一条记录。 |
| `GET /api/feed/preferences` | 返回 `personalization_enabled` 与可选 `signals_reset_at`；没有设置时默认开启。 |
| `PUT /api/feed/preferences` | body 为 `{ "personalization_enabled": true|false }`。关闭后，首页商品 feed、相似商品、listing wanted matches 与 intent feed/matches 使用非个性化排序，但仍排除明确反馈过的具体条目。 |
| `POST /api/feed/personalization/clear` | 让清除时间之前的收藏、买家成交意向和“少推荐这类”泛化信号不再参与排序；不删除业务记录，也不在已接入的推荐/匹配入口恢复已经明确反馈过的具体条目。 |

三种 feedback action 都会立刻从该用户后续的首页商品 feed、相似商品、listing wanted matches 或 intent feed/matches 中排除对应资源；`less_like_this` 还会分别降低同分类商品、wanted matches 中同品牌商品或同 kind 意图的排序。泛化降权受个性化开关和清除时间控制，所有入口的精确排除不受影响。

公开用户搜索、`GET /api/users/{id}` 和 `GET /api/users/{id}/listings` 采用相同规则：游客使用 NCU 公开校园，有效登录态使用设备活动校园。目标用户没有该校园 verified membership 时不返回其主页或在售内容。

健康探针（均无需认证，且不受限流）：

- `GET /api/livez` 返回 `{"status":"alive"}`，只表示进程存活，不查数据库。用作 liveness probe。
- `GET /api/readyz` 就绪时返回 `{"status":"ready"}`；进程排空中或数据库不可达时返回 `503` 和 `code=service_unavailable`。用作 readiness probe 和负载均衡摘流依据。
- `GET /api/health` 是 `readyz` 的旧客户端兼容别名，就绪时返回纯文本 `OK`，排空中同样返回 `503`。

探针语义和停机顺序见[运行、配置与排错](operations.md#健康探针与优雅停机)。

`GET /api/stats` 返回公开平台统计。`GET /api/metrics` 暴露 Prometheus 文本格式指标，包括请求、限流、聊天、LLM、WebSocket 和订单相关指标。

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

发布、wanted response 和成交确认已实现 `Idempotency-Key`。聊天创建/消息发送使用请求体中的客户端 UUID 幂等；Agent confirm 以 plan + 当前步骤 token 重放稳定挑战或终态结果。其他关键写接口、Agent proposal 的客户端幂等键及统一 `/api/v1` 幂等错误契约仍属于目标态。同一作用域、key 和请求内容的重试返回首次结果；相同 key 配不同 body 必须冲突。已返回 `replayed` 的接口用该字段区分首次执行和结果重放。

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

以上仍是目标版本化契约。当前未版本化接口包括 `/api/campuses`、`/api/user/campus-memberships`、`/api/user/active-campus` 及 verification 子路径。[已实现] 新 access/refresh session 已携带活动校园，核心业务请求不依赖 body 中的 `campus_id`；后台读取、审核任务、管理员审计和敏感操作近期密码认证也已落地。[已实现] 平台管理员 TOTP MFA 已落地。[目标态] `/api/v1` 和校园资格续期仍未完成。verification 响应不得泄露其他账号或 membership 是否存在。

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

[当前未版本化已实现] `/api/feed/feedback` 支持 `hide`、`less_like_this`、`not_relevant`；偏好开关和 clear 使用独立的 `/api/feed/preferences`、`/api/feed/personalization/clear`。目标 `/api/v1` 版本仍需补统一错误、cursor 与明确的数据保留策略。

### Agent ActionPlan

```text
POST /api/v1/agent/plans
GET  /api/v1/agent/plans/{id}
POST /api/v1/agent/plans/{id}/confirm
POST /api/v1/agent/plans/{id}/cancel
```

这是目标 `/api/v1` 形态，不等同于上方当前未版本化接口。目标创建协议还应返回 `idempotency_key`、`confirmation_mode`、版本化预览和风险文案；L3 继续使用相互独立的两步 token。

当前 confirm 已重新验证 tenant、membership、owner、状态和金额，并把业务事实与计划终态原子提交。通用资源版本快照、提案幂等键、稳定错误 code 和完整审计信封仍是 `/api/v1` 收敛项。

### Moderation 与申诉

[已实现] 当前版本提供以下未版本化接口：

```text
GET  /api/moderation/cases
GET  /api/moderation/cases/{id}
POST /api/moderation/cases/{id}/appeals
GET  /api/moderation/appeals/{id}
```

用户接口只返回本人当前活动校园的案件安全摘要；申诉每个案件只能提交一次。后台案件接口见上方 Admin 表格。媒体和消息案件处置会同步对应审核状态；listing 案件通过 case-owned effect 限制和恢复，并与案件事件、审计同事务落库。

listing effect 按 case 归属并可组合：恢复或申诉改判只释放目标 case 的 effect；另一案件或 manual 紧急 case 仍有效时 listing 继续 restricted。紧急 `takedown` 也通过 manual case/effect 表达，显式 `restore` 只处理这类 manual effect。任何释放都只改变 effect，不改 lifecycle，所以 deleted/sold/fulfilled 绝不会被审核恢复动作“复活”。user ban 的多来源 effect 仍是后续工作。

```text
GET  /api/v1/moderation/cases/{id}
POST /api/v1/moderation/cases/{id}/appeals
GET  /api/v1/moderation/appeals/{id}
```

普通用户只能读取自己的案件摘要和提交申诉，不获得举报人、审核者身份、命中词和内部阈值。校园运营使用独立 tenant-scoped 管理接口；平台管理员跨校园处理需要理由和审计。

### Secret Chat 弃用

当前 `/api/chat/secret-sessions*` 进入弃用后：

1. [已实现] 禁止生产新建（默认 403，仅迁移开关可恢复）并从默认 UI 移除。
2. 在兼容窗口保留授权用户的只读历史能力。
3. 发布弃用 metrics、客户端版本门槛和截止时间。
4. 最终移除发送和创建路由，不把服务器不可读 E2EE 迁入 `/api/v1`。

新的加密消息仍使用普通 Conversation API，只改变服务端存储和授权解密实现，不向客户端承诺服务器不可读。
