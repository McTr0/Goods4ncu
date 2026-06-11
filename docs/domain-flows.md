# 业务流程

这篇文档按业务线解释 Good4NCU 如何运转。它关注状态和因果关系，不展开每个 JSON 字段；字段细节见 [API 参考](api-reference.md)。如果你在修 bug，先找到对应流程，再决定应该改 handler、service、repository、移动端 service 还是页面状态。

## 认证、会话和封禁

注册和登录都返回 access token 与 refresh token。access token 是 JWT，客户端用 `Authorization: Bearer <token>` 调用需要登录的接口。refresh token 存库时会 hash，客户端拿它换新的一对 token。

注册时，后端会校验用户名、密码长度和可选的南昌大学邮箱域名，然后用 Argon2 hash 密码。登录时，错误用户名和错误密码都返回统一的认证失败信息，避免用户枚举。被封禁用户不能登录。

refresh 是旋转式的：客户端提交旧 refresh token，服务端验证它未过期、未撤销、用户未封禁，然后撤销旧 token 并签发新 access token 与新 refresh token。如果同一个 refresh token 被重复使用，系统会视为 replay，撤销该用户所有 refresh token。这个策略的重点是：刷新令牌一旦用过，就不应再次有效。

logout 会撤销当前 access token 的 JTI，并撤销用户 refresh token。这样即使 access token 还没自然过期，也可以被 denylist 拒绝。WebSocket 建连时也会检查 token 是否被撤销、用户是否被封禁。

封禁是管理员动作。封禁后，用户不能继续登录或 refresh；已有 WebSocket 连接在重新认证或后续关键路径中会被拒绝。涉及封禁的修复要同时检查登录、refresh、WebSocket 和管理员接口。

## 商品发布、搜索和收藏

商品发布从移动端表单或 AI 工具进入。后端会校验标题、分类、品牌、成色、价格、缺陷列表和可选图片 URL。文本会先经过内容审核；图片如果使用 URL，会进入异步审核任务。商品写入 `inventory` 后，还需要同步语义检索文档，让 AI 搜索和推荐能找到它。

商品浏览支持分页、分类、搜索、价格区间和排序。详情页对游客开放，但只有认证用户能看到 owner id 用于发起联系。商品 owner 可以更新、删除或 relist 自己的商品。

收藏是用户和商品之间的关系。加入收藏前会确认商品存在，并拦截“收藏自己的商品”。收藏列表只返回 active 商品，避免用户继续看到已经不可交易的旧商品。

推荐和相似商品依赖 pgvector。相似推荐一般从 listing id 出发，找到语义相近的 active 商品；feed 当前偏向最新 active listing。语义搜索失败时，不要只看前端关键词，要检查 `documents` 表、embedding 维度、provider key 和商品状态过滤。

## 用户直聊连接状态机

直聊不是随便给任意用户发消息，而是先建立连接：

```text
requester POST /api/chat/connect/request
  -> pending
receiver POST /api/chat/connect/accept
  -> connected
receiver POST /api/chat/connect/reject
  -> rejected
```

连接处于 `pending` 时，接收方可以接受或拒绝。只有 `connected` 后才能发送消息。连接列表会告诉当前用户对方是谁、状态是什么、是否是接收方，以及未读数量。

消息发送支持文本和媒体。当前协议优先使用 `image_url`、`audio_url`，同时保留 `image_base64`、`audio_base64` fallback。后端会记录消息状态、时间、已读信息，并通过 WebSocket 尝试实时推送。WebSocket 失败不代表消息不存在，因为数据库才是事实来源。

已读有两个粒度：单条消息 read 和整个连接 read。typing indicator 是瞬时事件，适合 WebSocket 推送，不应当被当作持久业务事实。

## AI Agent 搜索、发布、购买和议价

AI 入口分为普通 JSON 聊天和 SSE 流式聊天。请求进入后，系统会先保存用户消息，再做意图路由。明显被禁止的内容会在到达 LLM 前拦截；简单聊天可以直接回复；需要执行动作时会调用 agent tools。

AI 搜索商品通常会结合关键词、分类、价格和语义检索。语义检索依赖 `documents` 表中的 embedding，而不是直接让 LLM 猜数据库里有什么。AI 发布商品需要走与表单发布相同的校验和审核，不应该绕过分类、价格、owner 或审核规则。

AI 购买不能跳过交易约束。无论用户是点击按钮还是对 AI 说“帮我买”，最终都要进入订单 service，检查商品 active、买家不是卖家、价格在允许范围内，并用事务创建订单。

AI 议价也不能替卖家做决定。买家提出价格后，AI 工具创建 HITL 请求，卖家通过通知看到请求，再由卖家接受、拒绝或 counter。

## 订单状态机和后台 Worker

订单的常规状态流是：

```text
pending -> paid -> shipped -> completed
pending -> cancelled
paid -> cancelled
```

`pending` 表示订单已经创建但尚未付款。付款后进入 `paid`，卖家发货后进入 `shipped`，买家确认收货后进入 `completed`。取消只允许在部分早期状态发生，不能从 `completed` 回退。

创建订单时最重要的动作是“把商品售出”和“插入订单”要在同一事务中完成。否则会出现库存和订单不一致。状态转换同样要由 service 控制，不能由移动端按钮自己决定是否合法。

后台 Worker 负责周期性任务，例如 HITL 议价过期扫描和内容审核任务处理。Worker 的设计原则是幂等：重复扫描不应造成重复订单、重复通知或错误状态跳转。

## HITL 议价

HITL 议价由 `hitl_requests` 表保存。核心状态包括：

| 状态 | 含义 |
| --- | --- |
| `pending` | 等待卖家处理。 |
| `approved` | 卖家接受，或买家接受 counter 后达成交易。 |
| `rejected` | 卖家拒绝，或买家拒绝 counter。 |
| `countered` | 卖家提出还价，等待买家接受或拒绝。 |
| `expired` | 超过配置时间未处理，由后台扫描标记过期。 |

卖家处理 pending 请求时有三种动作：approve、reject、counter。approve 会用买家的报价创建订单；reject 会结束请求；counter 会保存 `counter_price` 并通知买家。买家面对 counter 时可以 accept 或 reject。accept 会用 counter price 创建订单，reject 会结束请求。

所有会创建订单的议价动作都必须在事务中完成：锁定 HITL 行、确认状态仍然合法、创建订单、写系统消息、更新请求状态。通知可以在提交后 best-effort 发送。

## 内容审核、上传和媒体

文本审核发生在商品发布和更新等入口。标题、品牌、描述和缺陷信息会组合成待审核文本，命中 blocked keywords 或审核规则时拒绝持久化。AI 意图路由也会在进入 LLM 前检查禁止内容，减少不必要的 provider 调用。

图片上传采用 URL-first 思路。客户端可以先通过 `GET /api/upload/token` 获取 OSS 直传临时凭证，把媒体上传到对象存储，再把 URL 传给业务接口。业务接口保存 URL，并把图片审核任务写入后台队列。

聊天媒体当前保留 Base64 fallback。它适合兼容旧客户端或对象存储暂不可用的场景，但不是长期主路径。新功能、文档和测试都应优先覆盖 URL 字段。

## 管理员和审计

管理员接口覆盖统计、用户列表、商品列表、订单列表、封禁/解封、下架商品、撤销 token、修改用户角色和审计日志。管理员动作不仅改变业务数据，也要留下审计记录，方便追踪谁在什么时候做了什么。

封禁和下架会影响普通用户流程。封禁影响认证和实时连接，下架影响商品浏览、收藏、购买和推荐。改管理员功能时，不要只测管理员页面成功提示，还要测普通用户路径是否被正确影响。

接口字段和路径见 [API 参考](api-reference.md)。配置、metrics 和排错见 [运行、配置与排错](operations.md)。
