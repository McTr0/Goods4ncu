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

## 用户直聊会话状态机

直聊不是“加好友”，而是每次联系创建一个独立会话。用户在商品详情页点击“联系卖家”后先选择沟通方式：

```text
现在聊 -> realtime 会话
写封留言 -> mail 会话
```

用户也可以从消息页“找同学”发起一次会话。查找方式包括用户名、完整邮箱和完整学号，但是否能被找到由被查找用户在设置页控制：用户名默认开启，邮箱和学号默认关闭。学号不是手填字段，而是从 `{8-12位数字}@email.ncu.edu.cn` 形式的学校邮箱推断。查找成功只代表可以发起本次会话，不会建立好友关系。

`realtime` 像 TCP 建连，只服务本次沟通：

```text
syn_sent
  -> 接收方接通 -> syn_ack
  -> 接收方现在不方便 -> declined
  -> 发起方取消 -> cancelled
  -> 10 分钟未回应 -> expired

syn_ack
  -> 发起方打开会话或直接发送消息 -> active
  -> 任一方结束 -> closed
  -> 5 分钟未 ACK -> expired

active
  -> 任一方结束 -> closed
  -> 24 小时无消息 -> expired
```

实时会话的 SYN 携带完整首条文本。接收方接通前可以读这条开场，但不能回复。发起方在 `syn_ack` 直接发送消息时，后端会在同一事务里完成 ACK 和消息写入。双方同时发起实时联系时视为 mutual intent，只保留一个会话并直接进入 `active`，避免重复对话。

`mail` 是异步留言线程。它创建后直接进入 `open`，必须有 1 到 120 字主题和 1 到 2000 字正文。邮件没有“在线”“输入中”或给发件人展示的已读状态；双方可以异步回复，归档只影响自己的收件箱。

收件箱统一展示 `realtime` 和 `mail`，按最新活动排序，并可按模式筛选。`chat_conversation_members` 保存每个成员自己的未读数、归档状态和最后阅读位置。`chat_conversation_events` 追加记录创建、接通、ACK、关闭和过期，方便排查“为什么这个会话不能发消息”。

消息发送支持文本和媒体。当前协议优先使用 `image_url`、`audio_url`，同时保留 `image_base64`、`audio_base64` fallback。后端会记录消息状态、时间、已读信息，并通过 WebSocket 尝试实时推送。WebSocket 失败不代表消息不存在，因为数据库才是事实来源。

typing indicator 只属于 `realtime/active`，是瞬时事件，不应当持久化或展示为“对方在线”。邮件不发送 typing/read WebSocket 事件。屏蔽用户后，双方都不能创建新会话或继续发送；旧历史保持只读。

终止态实时会话不会复活。`declined`、`cancelled`、`expired`、`closed` 只保留历史；如果双方未屏蔽，客户端可以显示“重新联系”，重新选择 `realtime` 或 `mail` 并创建新的 `chat_conversations` 记录。

## AI Agent 搜索、发布、购买和议价

AI 入口分为普通 JSON 聊天和 SSE 流式聊天。主页快捷输入和消息收件箱中的“小帮”进入同一段用户专属历史；小帮在“全部”列表置顶，但不属于实时或留言筛选。客户端发送公共标识 `__agent__`，服务端根据已认证用户映射到独立会话，避免账号之间共享上下文。

请求进入后，系统先做轻量意图路由。明显被禁止的内容会在到达 LLM 前拦截；简单聊天可以直接回复并保存双方消息。需要模型或工具时，系统读取此前最近历史、保存当前用户消息，再调用 LLM 或 agent tools。流式生成正常结束后保存完整助手回复；如果生成失败或连接中断，只保留用户已经提交的消息，不把半截回复当成完整历史。

AI 搜索商品通常会结合关键词、分类、价格和语义检索。语义检索依赖 `documents` 表中的 embedding，而不是直接让 LLM 猜数据库里有什么。AI 发布商品需要走与表单发布相同的校验和审核，不应该绕过分类、价格、owner 或审核规则。

AI 发起成交意向不能跳过业务约束。无论用户是点击按钮还是对 AI 说“帮我买”，最终都要进入订单 service，检查商品 active、买家不是卖家、价格在允许范围内，并用事务创建一条 `intent_pending` 记录。平台不替用户付款、不确认收款、不追踪物流。

AI 议价也不能替卖家做决定。买家提出价格后，AI 工具创建 HITL 请求，卖家通过通知看到请求，再由卖家接受、拒绝或 counter。

## 线下成交意向状态机和后台 Worker

订单表现在记录的是线下成交意向，而不是平台资金流。常规状态流是：

```text
intent_pending -> confirmed
intent_pending -> cancelled
confirmed -> cancelled
```

`intent_pending` 表示买家已经表达成交意向，等待卖家确认。卖家确认后进入 `confirmed`；确认时可以选择自动下架商品。`cancelled` 表示这条成交记录被取消或作废。旧数据中的 `pending` 会按兼容逻辑视为 `intent_pending`，旧 `paid`、`shipped`、`completed` 会迁移为 `confirmed`。

创建成交意向时不会立刻把商品售出；只有卖家确认成交并选择自动下架时，service 才会在同一事务中更新订单和商品状态。状态转换同样要由 service 控制，不能由移动端按钮自己决定是否合法。

后台 Worker 负责周期性任务，例如 HITL 议价过期扫描、聊天会话过期和内容审核任务处理。订单生命周期 worker 在离线成交模式下保持 no-op，因为平台不再运行旧版资金或交付自动流转逻辑。Worker 的设计原则仍然是幂等：重复扫描不应造成重复记录、重复通知或错误状态跳转。

## HITL 议价

HITL 议价由 `hitl_requests` 表保存。核心状态包括：

| 状态 | 含义 |
| --- | --- |
| `pending` | 等待卖家处理。 |
| `approved` | 卖家接受，或买家接受 counter 后达成交易。 |
| `rejected` | 卖家拒绝，或买家拒绝 counter。 |
| `countered` | 卖家提出还价，等待买家接受或拒绝。 |
| `expired` | 超过配置时间未处理，由后台扫描标记过期。 |

卖家处理 pending 请求时有三种动作：approve、reject、counter。approve 会用买家的报价创建已确认的线下成交记录，并可自动下架商品；reject 会结束请求；counter 会保存 `counter_price` 并通知买家。买家面对 counter 时可以 accept 或 reject。accept 会用 counter price 创建已确认的线下成交记录，reject 会结束请求。

所有会创建订单的议价动作都必须在事务中完成：锁定 HITL 行、确认状态仍然合法、创建订单、写系统消息、更新请求状态。通知可以在提交后 best-effort 发送。

## 内容审核、上传和媒体

文本审核发生在商品发布/更新、用户名修改、直聊首条消息、直聊普通消息、消息编辑、留言主题和 AI 聊天入口。标题、品牌、描述、缺陷、聊天正文和主题会先过 `ModerationService`，命中内置高风险类别或本地 `BLOCKED_KEYWORDS` 时拒绝持久化；AI 聊天会在进入 LLM 前拦截，减少不必要的 provider 调用。

内置文本规则覆盖校园二手交易里明显高风险的类别：违禁或管制物品、低俗成人内容、博彩、诈骗灰产、暴力/极端风险、骚扰开盒、隐私泄露、联系方式和外部链接。本地政策词、校内专项词和需要频繁调整的词不写死在源码里，通过环境变量或 TOML 配置维护。

图片上传采用 URL-first 思路。客户端可以先通过 `GET /api/upload/token` 获取 OSS 直传临时凭证，把媒体上传到对象存储，再把 URL 传给业务接口。业务接口保存 URL，并把图片审核任务写入后台队列。

聊天媒体当前保留 Base64 fallback。它适合兼容旧客户端或对象存储暂不可用的场景，但不是长期主路径。新功能、文档和测试都应优先覆盖 URL 字段。

## 管理员和审计

管理员接口覆盖统计、用户列表、商品列表、订单列表、封禁/解封、下架商品、撤销 token、修改用户角色和审计日志。管理员动作不仅改变业务数据，也要留下审计记录，方便追踪谁在什么时候做了什么。

封禁和下架会影响普通用户流程。封禁影响认证和实时连接，下架影响商品浏览、收藏、购买和推荐。改管理员功能时，不要只测管理员页面成功提示，还要测普通用户路径是否被正确影响。

接口字段和路径见 [API 参考](api-reference.md)。配置、metrics 和排错见 [运行、配置与排错](operations.md)。
