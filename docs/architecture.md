# 当前架构与代码分层

| 项目 | 内容 |
| --- | --- |
| 适用读者 | 后端、Flutter、AI 工程师以及需要修改当前代码的贡献者 |
| 当前状态 | 只描述当前仓库已经存在的结构；目标生产架构单独维护 |
| 事实来源 | `src/`、`mobile/lib/`、`migrations/`、Cargo/Flutter 配置和当前路由 |
| 最后核对范围 | Axum AppState、service/repository、HTTP/SSE/WebSocket、workers、LLM provider 和 Flutter 分层 |

这篇文档回答“当前代码怎样工作、改动应该落在哪一层”。多校园、transactional outbox、多副本实时通信和生产 SLO 见[生产架构](production-architecture.md)。

## 当前总体链路

```text
Flutter Web / Mobile
  -> HTTP JSON：认证、出收、用户、成交、管理、普通聊天操作
  -> SSE：小帮流式回复
  -> WebSocket：消息、通知、主动 acknowledgement、会话和通话信令事件
  -> Rust Axum Router
  -> middleware：CORS、body limit、rate limit、token denylist、metrics、安全响应头
  -> handler：解析协议和认证上下文
  -> service：权限、状态机、事务和后台任务规则
  -> repository / sqlx：PostgreSQL + pgvector
  -> LLM / moderation / OSS 等外部 provider
```

当前后端通常作为一个进程运行。PostgreSQL 同时保存账号、信息意图、聊天、成交、审核、通知和 embedding。Redis 只在配置后用于限流；业务事件主要使用进程内 channel，WebSocket 连接也由单实例内存管理。

## 协议边界

### HTTP JSON

HTTP 是持久业务操作的主要入口。创建 offer/wanted、发起 Conversation、写 Message、确认 DealRecord 和管理动作最终都必须先写数据库，再返回成功。

客户端不能因为按钮点击或 socket 收到事件就自行假设业务成功。HTTP 409 等状态冲突是正常业务结果，应展示可恢复提示。

### SSE

SSE 用于 Agent token 流式输出。服务端保存用户消息，调用 LLM/工具并逐段输出；只有正常完成才把完整助手回复作为一条历史消息保存。

中途断开不能把半截内容伪装成完整回复。SSE 失败也不能影响普通搜索、发布表单和用户聊天。

### WebSocket

WebSocket 用于低延迟提示，不是业务事实来源。事件包括 conversation/message、主动 acknowledgement、space、call 和 notification 等；不承载 read、typing 或在线状态。

客户端断线后要通过 HTTP 列表和消息接口补偿。当前连接表是单进程内存结构，因此多副本 fan-out 仍是生产缺口。

## 后端目录和职责

| 目录 | 当前职责 | 修改原则 |
| --- | --- | --- |
| `src/api/` | Axum 路由、请求/响应模型、认证提取和协议适配 | handler 保持薄，不嵌入跨表业务事务 |
| `src/services/` | 成交、通知、审核、ModerationCase、token、后台 worker 和状态转换 | service 是权限和事务的最终边界 |
| `src/repositories/` | 用户、listing、chat、auth 等 SQL 封装 | 统一 ID/tenant/status 过滤，不让 handler 拼 SQL |
| `src/agents/` | IntentRouter、市场工具、议价和 Agent 模型 | 工具调用 service，不信任模型提供的身份 |
| `src/llm/` | Gemini、MiniMax、OpenAI-compatible provider | 隔离 provider 差异、超时和流式实现 |
| `src/middleware/` | rate limit 等横切入口控制 | 只做通用控制，不决定领域状态 |
| `src/config/`、`src/config.rs` | env/TOML/default 配置合并和验证 | 密钥不写日志，生产配置 fail fast |
| `migrations/` | 向前数据库 schema 和数据迁移 | 已合并迁移不修改，新迁移兼容已有数据 |

`AppState` 当前按 secrets、infrastructure 和 agents 分组，并保留具体 repository。它仍是共享应用状态，不等于领域模块已经完全解耦。

### 审核案件的当前链路

`ModerationCaseService` 是机器拒绝、用户举报、人工处置和申诉的事务边界。图片 Worker 在完成拒绝时同时更新 `moderation_jobs`、资源审核状态和案件；聊天消息举报在写入 `chat_message_reports` 的同一事务中创建案件，商品和用户举报则通过 `ContentReportService` 同时写入 `content_reports` 并关联统一案件。举报目标和 `campus_id` 均由服务端解析，不能信任客户端提交。用户 API 只通过 service 查询本人安全摘要，后台 API 先解析校园管理员作用域，再允许平台管理员处置并写入 `admin_audit_logs`。审核队列的校园过滤不能只放在 Flutter 或 handler 查询参数里。

## 请求如何穿过各层

以发布 wanted 为例：

```text
POST /api/listings
  -> handler 解析 JWT、body 和 direction
  -> 文本审核和字段校验
  -> repository/service 写 inventory
  -> 写或更新 documents embedding
  -> 可选提交媒体审核 job
  -> 返回 listing JSON
```

当前已建立 `Campus`/`CampusMembership`、核心资源、通知、审核任务和管理审计的 `campus_id`、同校园写门禁和设备级 active campus session。新 access JWT 带可选 `campus_id`，refresh token 记录同一校园；登录、注册、刷新和切换都会保持二者一致。`CampusService` 在每次受保护操作重新验证 membership，不能只相信 claim。旧 token 缺少 claim 时才回退到首个可用 membership。推荐、公开用户页和通知已跟随活动校园；后台使用独立 `AdminScope` 复核数据库角色，校园运营可读本校，平台管理员跨校园必须给理由并审计。平台管理员写操作还要求 access token 的 `auth_time` 在 10 分钟内；refresh、切换校园和旧 token 会自动回到锁定状态。普通 handler 已收敛为统一 session extractor（`src/api/session.rs`：`Session` 要求有效 token，`VerifiedTenant` 额外要求 verified membership，`OptionalSession` 服务游客可用路径且无效 token 拒绝而非静默降级）。平台管理员已支持 TOTP MFA（确认后 reauth 强制第二因子）；校园运营 MFA 和关键表 RLS 尚未落地，因此不要把当前过渡实现描述成完整多租户。

## 事务边界

事务属于 service 或明确的业务工具适配层，因为只有这些层知道哪些事实必须一起成功。

当前线下成交语义：

- 创建 `intent_pending` 时只创建成交意向，不立即把 listing 标为 sold。
- 卖家确认时，在同一事务更新成交记录；如果选择自动下架，再一起更新 listing。
- HITL 接受或接受 counter 时，锁定请求、检查状态、创建确认的成交记录、写系统消息和更新请求应共同完成。
- 通知可以在事务提交后 best-effort 发送，但生产目标是通过持久 outbox 保证可重试。

旧文档中“创建订单时先把商品标 sold”已经不符合当前线下成交模型，不应继续引用。

## 当前信息和推荐架构

`inventory` 当前同时承载 offer 与 wanted：

```text
direction=offer  -> price 是出售价，condition 是当前成色
direction=wanted -> price 是预算上限，condition 是最低可接受成色
```

`documents` 保存商品/需求的检索文本和 embedding。相似推荐使用 pgvector 距离；首页 Feed 对登录用户结合收藏和买家成交意向的分类亲和度，再按新鲜度排序。游客在 NCU 公开校园内检索，登录用户先从 token 解析活动校园，再在该校园内完成召回和排序。

wanted matches 使用活动 campus、分类、预算、成色和 active 状态等条件，并排除自己的 offer。设备级 active campus session 已实现；首页商品 feed、相似商品、listing wanted matches 与 intent feed/matches 已有稳定解释和反馈控制。wanted matches 在硬分类内用服务端派生的同品牌事实处理 `less_like_this`，不放松预算/成色等资格条件；跨表达软排序、置信度校准和跨入口多样性控制仍属于目标态。

更完整的对象定义见[信息模型](information-model.md)，目标推荐原则见[产品设计](product-design.md)。

## 当前聊天架构

用户直聊的底层事实：

- `chat_conversations`：realtime/mail、参与者、状态、主题和过期时间。
- `chat_conversation_members`：成员级归档；新留言的 `LOCALLY_SEEN` 由设备本地维护，不写入服务器。
- `chat_conversation_events`：握手、关闭和过期时间线。
- `chat_messages`：正文、媒体 URL/Base64 fallback、reply、quote、编辑和审核状态。
- `chat_message_acknowledgements`：接收方主动选择的 `received`、`will_review` 或 `completed`，每用户每消息最多一条，可替换或撤销。
- `chat_blocks`：屏蔽关系。

收件箱的 Thread 是按对方用户聚合的查询视图，不会合并底层 Conversation。群组、频道、message reaction/hide/report、call signaling 和 Secret Chat 原型位于 user_chat 模块。

[实验中][待弃用] Secret Chat 使用服务器不可读密文，不属于生产方向。治理和迁移见[信任与安全](trust-safety.md)。

当前 `src/api/user_chat/message.rs` 和部分 Flutter 聊天页面职责密度较高。拆分时保持 Conversation 状态转换集中在 service，不要把复杂度从一个大文件搬到另一个大文件。

### 目标投影：Relationship Space 与 Memory Rail

关系空间采用“事实写入一次，多种可重建投影”的架构：

```text
现有业务事实
Message / ConversationEvent / Quote / Listing / Acknowledgement
        |
        +--> 消息与会话投影（当前 UI）
        +--> Relationship Space 投影
        +--> 确定性 Memory Rail
        +--> 可选语义索引（带 source_event_ids）
```

迁移不先建万能事件表。第一步由查询层为同校园无序用户对生成稳定的 relationship key，并从现有表按 cursor 返回规范化事件（当前已由 Thread 与 `space-events` 只读接口提供）；客户端据此实现时间、最近连接恢复点和共享对象引用。显式 Pin 通过 `0064_relationship_space_pins` 作为单独的用户动作事实保存，file/link 通过 `0065_chat_shared_objects`/`0066_shared_object_upload_lifecycle`/`0067_shared_object_storage_cleanup` 保存平台权威引用、上传审核和远端清理状态；文件只有在服务端 probe 和必要审核完成后才进入共享投影，撤销后的远端 DELETE 由可重试 worker 执行。它们都不是消息副本，也不是自动事件。只有证明回放一致、双写原子、旧客户端兼容和重建成本可控后，通用 `SpaceEvent` 才能成为新的权威写入口。

投影必须可丢弃重建，不能保存模型生成的无来源“事实”。语义摘要或主题索引保存来源事件、模型版本和权限范围；源内容删除、隐藏、审核限制或 membership 变化时触发失效。LLM/embedding 故障只移除语义增强，不影响留言、连接、时间轨迹、Pin、文件和商品对象。

Flutter 的空间布局保持稳定的“对方左上 / 自己右下”映射，但角色尺寸由本地视口、滚动密度和无障碍设置决定，绝不订阅 typing/read/online。连接开始时可以缩细 Rail、弱化角色；这是本地投影状态，不是对外 presence 事件。

`SocialPersona` 是独立的受审核展示资源。校园认证徽标仍从 membership 读取，公开接近方式从用户显式设置读取；`0070_social_persona_assets` 与 `0071_social_persona_asset_upload_expiry` 的图片候选必须经过服务器对象探测、必要审核和用户显式选择，撤销或上传超时后由私有 bucket cleanup worker 清理。Agent 头像、Agent 参与提示与用户角色资产使用不同组件和事件，避免把“用户分身出现”误解为“AI 已进入私聊”。

## 当前 Agent 与 RAG

自然语言入口先经过内容审核和 IntentRouter，再根据意图直接回答、检索或调用 Agent。Provider 支持 Gemini、MiniMax 和 OpenAI-compatible chat；embedding 当前仍主要依赖 Gemini 客户端和配置维度。

市场 Agent 已挂载发布、搜索、详情、更新、删除、成交意向、议价和“我的发布”等工具。发布立即执行并进入撤销窗口；更新/删除使用 L2 ActionPlan，成交意向/议价使用独立两步 token 的 L3 ActionPlan。确认与业务事实已原子提交，listing 工具和 HTTP 已共享 command/审核入口；四类关键动作会在提案时保存 `inventory.content_revision`，确认时在锁内比较，HTTP 更新/删除也支持 body 版本或 `If-Match`。提案 `Idempotency-Key` 已按用户/校园和动作参数哈希去重；版本化风险文案、typed outcome 和完整行动审计仍待补齐。新增写工具前必须阅读[Agent 系统设计](agent-system.md)。

回复助手是受限 agent，只生成三个不超过限制的草稿，不读取媒体，不自动发送，也不挂载成交工具。

## Flutter 分层

| 层 | 目录 | 职责 |
| --- | --- | --- |
| Pages | `mobile/lib/pages/` | 页面布局、路由响应和用户交互 |
| Components | `mobile/lib/components/` | 可复用视觉和交互组件 |
| Providers / Controllers | `mobile/lib/providers/` 和部分 controller | 异步状态、刷新、缓存和跨组件数据流 |
| Services | `mobile/lib/services/` | HTTP、SSE、WebSocket、token 和协议封装 |
| Models | `mobile/lib/models/` | API JSON 与本地展示需要的数据模型 |
| Theme / Responsive | `mobile/lib/theme/` | 色彩、间距、深色模式和布局断点 |
| l10n | `mobile/lib/l10n/` | 所有用户可见中英文文案 |

判断原则：service 负责“怎样调用后端”，provider/controller 负责“页面当前是什么状态”，page 负责“如何展示和响应”。页面可以根据 capabilities 隐藏按钮，但不能自己认定状态转换合法。

所有异步 `setState`、SnackBar 和导航前检查 `mounted`。桌面与移动布局共享领域状态，不能实现两套不同业务逻辑。

## 当前数据主地图

| 表 | 当前作用 |
| --- | --- |
| `users` | 账号、角色、状态、邮箱、发现设置、头像和收款码 |
| `refresh_tokens` / `revoked_access_tokens` | token 轮换、replay、logout 和撤销 |
| `inventory` | offer/wanted 信息意图 |
| `documents` | RAG 文档和 pgvector embedding |
| `wanted_responses` | offer 对 wanted 的用户响应 |
| `orders` | 线下成交意向与确认记录 |
| `hitl_requests` | 议价 Human-In-The-Loop 状态 |
| `chat_*` | 直聊、线程基础、群组/频道、通话、反应、举报和 Secret Chat 原型 |
| `watchlist` | 收藏关系 |
| `notifications` | 持久通知事实 |
| `moderation_jobs` | 带 campus_id 的异步媒体审核任务；状态含 pending/processing/approved/rejected/failed，并可保存服务器对象 `storage_key` 以便私有 worker 每次领取时重新签发短期 provider URL |
| `admin_audit_logs` | 带 campus_id 和跨校园 scope_reason 的管理员关键操作审计 |

完整关系和目标对象见[信息模型](information-model.md)。

## 当前生产风险

| 风险 | 当前表现 | 目标方向 |
| --- | --- | --- |
| 过渡期首校园默认值 | `0029` 为兼容旧 SQL 保留 NCU default；session、通知、后台和审核已显式带校园 | 第二校园前移除 DB default，把普通 handler 收敛到统一 TenantContext，并评估关键表 RLS |
| 进程内事件 | 崩溃可能丢失异步动作 | transactional outbox |
| 单实例 WebSocket | 多副本无法直接 fan-out | Redis pub/sub + HTTP 补偿 |
| 媒体兼容路径 | URL-first 与 Base64、静态 uploads 并存 | 私有隔离对象存储和 CDN |
| Agent listing 写工具 | ActionPlan 已 crash-safe，HTTP 与 Agent 已共享 ListingCommandService；关键动作已有 `content_revision` 快照和冲突保护；提案按用户/校园和动作参数哈希幂等 | 版本化风险文案与完整审计 |
| Secret Chat | 服务器不可读，治理边界冲突 | 停止生产承诺并迁移 |
| TEXT/UUID 并存 | join 和 fixture 可能只覆盖一类 ID | repository 兼容封装和分阶段收敛 |
| 大模块 | user_chat 和页面承担多种职责 | 先补行为测试，再按领域拆分 |

这些风险的顺序和验收见[生产路线图](roadmap.md)。
