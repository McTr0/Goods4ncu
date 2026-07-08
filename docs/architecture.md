# 架构与分层

Good4NCU 的架构目标不是把代码分成很多目录，而是让每一层承担稳定的责任。对新人来说，最重要的能力不是背目录名，而是看到一个需求时能判断它属于“展示、协议、业务规则、数据访问、后台任务、AI 工具、运维配置”中的哪一类。

## 总体链路

```text
Flutter App
  pages / components
  providers / controllers
  services
        |
        | HTTP JSON, SSE, WebSocket
        v
Rust Axum Backend
  api handlers
  middleware
  services
  repositories
  agents / llm
        |
        | SQL + transactions + vector queries
        v
PostgreSQL + pgvector
```

Flutter 负责交互和本地状态，Rust 后端负责可信业务规则，PostgreSQL 保存事实。pgvector 没有引入一个单独的向量数据库，而是和关系型数据放在同一个 PostgreSQL 实例里。这让部署简单，但也要求启动时检查 `documents.embedding` 的维度与配置一致，否则语义搜索会在运行时才失败。

## HTTP、SSE 和 WebSocket

HTTP JSON 是主协议。注册、登录、商品、订单、收藏、通知、管理员操作和大多数聊天动作都走普通 HTTP。它适合明确的请求/响应：客户端发一个动作，服务端完成校验、写库并返回结果。

SSE 用于 AI 流式回复。AI 生成文本可能耗时较长，如果只用普通 HTTP，用户只能等到最终答案；SSE 可以让服务端一段段推送，移动端逐步显示“正在生成”。本项目的 AI 单轮和流式入口在 `src/api/chat.rs`。

WebSocket 用于实时通知推送。客户端连接 `GET /api/ws`，用 `Authorization: Bearer <jwt>` 认证。连接建立后，通知服务可以把 JSON payload 推送给该用户的所有在线设备。WebSocket 不是数据库，它只是投递通道；真正的通知仍然落在 `notifications` 表里。

## 后端分层

| 层 | 目录 | 职责 |
| --- | --- | --- |
| API handler | `src/api/` | 定义路由、解析请求、提取认证、做轻量参数校验、把工作交给 service 或 repository、映射 HTTP 错误。 |
| Middleware | `src/middleware/` | 处理跨接口逻辑，例如管理员权限、限流、请求指标、CORS 相关行为。 |
| Service | `src/services/` | 承载业务规则、状态机、事务边界、后台 worker 和跨 repository 的协调。 |
| Repository | `src/repositories/` | 封装 SQL 查询和写入，让上层不直接拼接数据库细节。 |
| Agents | `src/agents/` | 处理 AI 意图路由和工具调用，例如搜索商品、创建 listing、购买或议价。 |
| LLM providers | `src/llm/` | 封装 Gemini、MiniMax 等 provider 差异，负责 prompt、stream、embedding 和熔断。 |
| Config / DB | `src/config.rs`、`src/db.rs` | 加载配置、初始化数据库、启用 pgvector、运行迁移、检查 embedding 维度。 |

handler 可以拒绝明显非法输入，比如空标题、过长字段、缺少 token。但当一个行为需要同时改多个表，或者需要遵守状态机，它就应该进入 service。比如创建订单不仅插入 `orders`，还要把商品从 `active` 改成 sold；议价接受不仅更新 `hitl_requests`，还可能创建订单、写系统消息、发通知。这些动作必须放在同一个事务里思考。

## 为什么事务边界属于 service

事务的本质是业务语义：哪些事情必须一起成功。Repository 知道“怎样执行一条 SQL”，但不应该决定“创建订单时是否也必须锁定商品”；handler 知道“这是一个 POST 请求”，但不应该决定“哪些表一起提交”。这些决策属于 service。

以订单为例，`OrderService` 会在事务里调用 listing repository 和 order repository：先把 active 商品标为 sold，再插入 pending 订单。如果中间任何一步失败，事务回滚。这样不会出现“商品已经卖掉但订单没创建”或“订单创建了但商品仍然可买”的半成功状态。

同理，HITL 议价接受 counter 时，也必须在同一事务中锁定议价请求、确认状态仍然是 `countered`、创建订单、写系统消息、更新状态。通知推送可以在事务提交后 best-effort 执行，因为通知失败不应回滚已经达成的交易事实。

## 移动端分层

| 层 | 目录 | 职责 |
| --- | --- | --- |
| Pages | `mobile/lib/pages/` | 页面结构和用户交互，例如首页、详情页、聊天页、订单页、管理页。 |
| Components | `mobile/lib/components/` | 可复用 UI 组件，例如价格标签、推荐轮播、聊天面板。 |
| Services | `mobile/lib/services/` | HTTP、SSE、WebSocket、token storage 和后端协议封装。 |
| Providers / Controllers | `mobile/lib/providers/`、部分 `pages/*_controller.dart` | 管理页面状态、异步加载、刷新、错误态和跨组件数据流。 |
| Models | `mobile/lib/models/` | Dart 数据模型，与 API JSON 字段保持同步。 |
| l10n | `mobile/lib/l10n/` | 用户可见文案和多语言资源。 |

移动端的判断原则是：service 负责“怎么和后端说话”，provider/controller 负责“当前页面处于什么状态”，page 负责“怎么展示和响应点击”。不要把 HTTP 拼接散落在 page 里，也不要在 page 里实现订单状态机。

如果新增用户可见文案，应走 `mobile/lib/l10n/`。如果新增 API 字段，需要同步更新 Dart model、service 解析和相关测试。

## AI 与 RAG 数据流

AI 相关流程有两条线：自然语言交互和语义检索。

自然语言交互从 `src/api/chat.rs` 进入。后端先持久化用户消息，再进行意图路由。明显违规或可直接回答的请求可以不调用 LLM；需要工具执行时进入 `src/agents/`；需要模型生成时进入 `src/llm/`。LLM provider 负责把不同供应商的 API 差异包起来，外层尽量只依赖统一接口。

移动端收件箱中的“小帮”是虚拟系统会话，不应伪装成普通用户，也不写入 `chat_conversations`。客户端只认识 `__agent__`，后端把它映射为 `agent:<当前用户 ID>` 后再读写 `chat_messages`。这个映射必须发生在认证之后，保证两个用户即使都使用相同公共标识，也不会进入同一段模型上下文。SSE 正常完成时才持久化完整助手回复。

语义检索依赖 `documents` 表。商品发布或更新后，应把可搜索文本写成 document，并生成 embedding。推荐和相似搜索用 pgvector 的距离计算找到相近商品。这个路径常见失败点包括：文档没有写入、embedding 维度不匹配、provider key 不可用、向量索引异常、商品状态过滤不正确。

AI 不是可信权限边界。AI 工具要像普通 API 一样校验用户、商品 owner、价格范围、商品状态和订单约束。模型说“帮我买这个”并不代表可以绕过 service 层。

## 数据模型的主地图

| 表 | 作用 |
| --- | --- |
| `users` | 用户账号、密码 hash、角色、状态、邮箱和头像等身份数据。 |
| `refresh_tokens`、`revoked_access_tokens` | refresh token 轮换、logout、token replay 保护和 access token 撤销。 |
| `inventory` | 商品 listing，是搜索、详情、订单和收藏的核心表。 |
| `documents` | 商品语义检索文档和 pgvector embedding。 |
| `orders` | 订单事实，包含 buyer、seller、listing、价格和状态时间戳。 |
| `hitl_requests` | HITL 议价请求，记录 pending、approved、rejected、countered、expired 等状态。 |
| `chat_conversations` | 用户直聊会话事实，保存 `realtime`/`mail` 模式、状态、参与者、主题、过期时间和版本。 |
| `chat_conversation_members` | 每个会话成员自己的未读数、归档状态和最后阅读位置。 |
| `chat_conversation_events` | 会话创建、接通、ACK、关闭、过期等状态事件时间线。 |
| `chat_blocks` | 用户屏蔽关系；屏蔽后不能新建会话或继续发送。 |
| `chat_messages` | 用户消息、AI/system 消息、直聊 `direct_conversation_id`、媒体 URL/Base64 兼容字段和已读状态。 |
| `watchlist` | 用户收藏商品。 |
| `notifications` | 可持久化通知，WebSocket 只是实时推送通道。 |
| `admin_audit_logs` | 管理员关键操作审计。 |
| `moderation_jobs` | 图片等异步审核任务。 |

更详细的运维视角见 [运行、配置与排错](operations.md)。

## 当前维护注意事项

第一，核心 ID 正处在 UUID 迁移方向上。新代码要优先兼容 UUID 读写，不要把 TEXT 旧 ID 假设继续扩散。专项计划见 [路线图与架构风险](roadmap.md)。

第二，移动端 `user_chat_page.dart` 和后端 `src/api/user_chat/message.rs` 承担了较多职责。改聊天功能时要格外注意不要把媒体、已读、编辑、typing、WebSocket 刷新全揉成一个更大的函数。状态转换必须留在 `ChatConversationService`，handler 不应直接写会话状态 SQL。

第三，聊天媒体正在从 Base64 fallback 走向 URL-first。新路径应优先使用 `image_url`、`audio_url`，Base64 字段只是兼容旧客户端或失败兜底。

第四，AI 工具调用会跨越很多层。修 AI bug 时不要只改 prompt；先确认工具、权限、数据库状态和 provider 行为。

如果你准备动手开发，下一章是 [开发指南](development.md)。如果你想按业务理解系统，读 [业务流程](domain-flows.md)。
