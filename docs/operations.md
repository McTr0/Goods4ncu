# 运行、配置与排错

| 项目 | 内容 |
| --- | --- |
| 适用读者 | 本地开发者、部署维护者、SRE、数据库管理员和事故响应人员 |
| 当前状态 | 当前配置和单实例排错已可用；完整 SLO、PITR、KMS、outbox 和多副本 runbook 属于目标态 |
| 事实来源 | 配置加载代码、环境模板、Docker/Compose、migration、metrics、worker 和实际启动行为 |
| 最后核对范围 | 环境变量、PostgreSQL/pgvector、CORS、Redis、媒体审核、日志、健康检查和常见故障 |

这篇文档面向“系统跑不起来、跑着不对、上线前要确认什么”。它集中维护配置、数据库、迁移、metrics、日志和排错路径。目标拓扑和 SLO 见[生产架构](production-architecture.md)，开发步骤见 [开发指南](development.md)，业务状态见 [业务流程](domain-flows.md)。

## 环境变量

密钥和连接串放在 `.env` 或运行环境里，模板见 [.env.example](.env.example)。不要把真实密钥写进 TOML 或提交到仓库。

| 变量 | 必需 | 说明 |
| --- | --- | --- |
| `DATABASE_URL` | 是 | 后端主数据库连接串。 |
| `TEST_DATABASE_URL` | 测试需要 | 数据库测试连接串，必须指向安全测试库。 |
| `JWT_SECRET` | 是 | JWT 签名密钥，至少 32 字符。 |
| `JWT_SECRET_OLD` | 可选 | JWT 密钥轮换期间用于兼容旧 token。 |
| `GEMINI_API_KEY` | 条件必需 | `gemini` provider 必需；其它 chat provider 当前也需要它做 embedding/RAG。 |
| `MINIMAX_API_KEY` | 条件必需 | 使用 MiniMax provider 时需要。 |
| `MINIMAX_API_BASE_URL` | 可选 | MiniMax 自定义 base URL。 |
| `LLM_PROVIDER` | 可选 | `gemini`、`minimax`，或 OpenAI-compatible alias：`openai`、`deepseek`、`groq`、`openrouter`、`xai`、`together`、`openai_compatible`。 |
| `LLM_MODEL` | 条件必需 | Chat model 名称；OpenAI-compatible provider 必须设置。 |
| `LLM_BASE_URL` | 可选 | OpenAI-compatible 自定义 base URL；命名 alias 有默认 base URL，可覆盖。 |
| `LLM_API_KEY` | 条件必需 | OpenAI-compatible 通用 key；也可用 `OPENAI_API_KEY`、`DEEPSEEK_API_KEY`、`GROQ_API_KEY`、`OPENROUTER_API_KEY`、`XAI_API_KEY`、`TOGETHER_API_KEY`。 |
| `VECTOR_DIM` | 可选 | embedding 维度，默认 768，必须与 `documents.embedding` 一致。 |
| `CORS_ORIGINS` | 生产必需 | 逗号分隔允许来源；生产环境不允许空配置或 `*`。 |
| `APP_ENV`、`ENVIRONMENT`、`RUST_ENV` | 可选 | 任一值为 `production` 或 `prod` 时启用生产 CORS 防护。 |
| `SERVER_HOST`、`SERVER_PORT` | 可选 | 覆盖后端监听地址和端口。 |
| `REDIS_URL` | 可选 | 分布式限流后端；不设置时使用本地限流。 |
| `RATE_LIMIT_MAX_REQUESTS` | 可选 | 每窗口最大请求数。 |
| `RATE_LIMIT_WINDOW_SECS` | 可选 | 限流窗口秒数。 |
| `BLOCKED_KEYWORDS` | 可选 | 逗号分隔本地策略关键词。内置规则已覆盖违禁交易、低俗成人、博彩、诈骗、暴力风险、骚扰、隐私泄露、联系方式和外链。 |
| `MODERATION_IMAGE_ENABLED` | 可选 | 是否启用图片审核。 |
| `MODERATION_IMAGE_API_URL` | 图片审核需要 | 图片审核 API URL。 |
| `MODERATION_IMAGE_API_KEY` | 图片审核需要 | 图片审核 API key。 |
| `OSS_ENDPOINT`、`OSS_BUCKET` | 可选 | OSS 直传非敏感配置。 |
| `OSS_ROLE_ARN`、`OSS_ACCESS_KEY_ID`、`OSS_ACCESS_KEY_SECRET` | 上传需要 | 获取 OSS STS 临时凭证需要的配置。 |
| `CONFIG_FILE` | 可选 | 指定 TOML 配置文件路径。 |

如果启动时报缺失变量，优先检查 `.env` 是否被加载、变量名是否拼写正确、shell 当前目录是否是项目根目录。

## Docker Compose 本地栈

根目录 `docker-compose.yml` 提供演示级两服务栈：`db`（`pgvector/pgvector:pg16`）和 `api`（本仓库 `Dockerfile`）。Compose 会把 `DATABASE_URL` 指到服务名 `db`，因此即使 `.env` 写了 localhost 也能在容器网络内连通。

```bash
cp docs/.env.example .env
# 至少填入 JWT_SECRET（≥32 字符）和可用的 LLM/embedding key
docker compose up --build
curl -s http://127.0.0.1:3000/api/health
```

这不替代生产编排（密钥管理、HTTPS 终止、静态站点与备份仍需单独配置），但能缩短“空环境到可演示 API”的路径。

## TOML 配置搜索顺序

非敏感配置可以放在 `goods4ncu.toml`，模板见 [config.toml.example](config.toml.example)。加载优先级是：

```text
环境变量
  > CONFIG_FILE 指定路径
  > ./goods4ncu.toml
  > ./config/goods4ncu.toml
  > ./good4ncu.toml        # legacy fallback
  > ./config/good4ncu.toml # legacy fallback
  > 代码默认值
```

TOML 适合放 server、LLM provider、限流、event bus、worker 扫描间隔、token TTL、marketplace 参数、审核开关、CORS origin 和 OSS endpoint/bucket。真实 API key、JWT secret、数据库连接串和 OSS secret 必须留在环境变量。

## PostgreSQL 和 pgvector

Goods4ncu 使用一个 PostgreSQL 实例同时保存业务数据和向量数据。启动时会执行：

```text
CREATE EXTENSION IF NOT EXISTS vector
运行 migrations/
检查 documents.embedding 的 vector 维度
```

如果 pgvector 没安装，数据库初始化会失败。如果 `VECTOR_DIM` 与 schema 中 `vector(768)` 之类的定义不一致，应用会 fail fast。这种失败是好的，因为它避免系统运行到某个语义搜索请求时才暴露问题。

数据库相关测试必须使用测试库。测试基础设施会拒绝清理明显不是测试库的连接，除非显式设置 override。不要为了省事把 `TEST_DATABASE_URL` 指到真实开发库。

## 迁移启动行为

迁移文件位于 `migrations/`，使用递增编号。应用启动时会初始化数据库并运行迁移，因此部署环境中的数据库用户需要具备执行迁移所需权限。

迁移失败应该阻止应用继续启动。不要吞掉迁移错误后继续提供服务；半初始化 schema 会造成更难排查的数据不一致。

修改 migration 时遵守两条规则：已经合并过的迁移不要改，新增迁移要兼容已有数据。涉及大表、核心 ID、订单、聊天和用户状态时，需要给出验收测试和回滚思路。

## CORS 生产要求

开发环境如果没有 `CORS_ORIGINS`，后端会使用较宽松的默认行为并输出 warning。生产环境不同：当 `APP_ENV`、`ENVIRONMENT` 或 `RUST_ENV` 表示 production/prod 时，如果允许任意来源，应用会拒绝启动。

生产部署时明确设置：

```bash
CORS_ORIGINS=https://your-app.example.com
```

多个来源用逗号分隔。不要在生产使用 `*`。

## Metrics 和结构化日志

`GET /api/metrics` 暴露 Prometheus 文本格式指标。当前指标覆盖请求计数和延迟、限流拒绝、聊天消息、媒体消息、LLM 调用和错误、WebSocket dropped/pruned、订单创建和状态变化等行为。指标名称以 `src/api/metrics.rs` 中 `MetricsService` 为准。

日志使用结构化字段。排错时优先看带字段的日志，例如 `user_id`、`listing_id`、`order_id`、`err`、`provider`、`vector_dim`。不要只看最后一行错误文本；上下文字段往往能直接说明是哪个用户、哪条订单或哪次 provider 调用失败。

每个 HTTP 响应包含 `X-Request-ID`。错误 JSON 的 `trace_id` 与该 header 相同；用户报告问题时优先收集这个 ID，再在结构化日志中关联。每条请求完成日志还包含相同的 `request_id`、HTTP method、归一化 path、status 和 `duration_ms`。服务端总是生成 ID，不信任客户端自报的 request id，也不会把请求体或 token 写入访问日志。

匿名限流默认使用 TCP peer IP；服务必须通过 `into_make_service_with_connect_info` 启动才能向中间件提供可信地址。代理部署时仍以网关层限流和可信代理配置为主，不要直接信任客户端提交的 `X-Forwarded-For`。

## 数据库表地图

| 表 | 排错时常看什么 |
| --- | --- |
| `users` | 用户 status、role、email、password_hash 是否正常。 |
| `refresh_tokens` | refresh token 是否过期、revoked_at 是否被设置。 |
| `revoked_access_tokens` | logout 或管理员撤销后的 JTI 是否存在。 |
| `inventory` | 商品 status、owner_id、价格、分类、更新时间；重复发布时检查 `idempotency_key/idempotency_hash`。 |
| `documents` | RAG 文档是否存在，embedding 是否非空，维度是否匹配。 |
| `wanted_responses` | wanted/offer/responder/requester 是否一致，pending 是否重复。 |
| `orders` | 状态、buyer/seller、listing、金额和时间戳。 |
| `hitl_requests` | pending/countered/expired 状态、counter_price、expires_at。 |
| `chat_conversations` | mode、state、initiator/recipient、listing、subject、过期时间、close_reason。 |
| `chat_conversation_members` | 每个成员的 unread_count、last_read_message_id、archived_at。 |
| `chat_conversation_events` | 握手、ACK、关闭、过期等状态事件时间线。 |
| `chat_blocks` | blocker/blocked 屏蔽关系。 |
| `chat_messages` | conversation_id、direct_conversation_id、sender、receiver、read_at、media URL/Base64、edited_at。 |
| `chat_spaces` 及成员/消息表 | group/channel、owner、成员角色、发言权限和更新时间。 |
| `chat_secret_sessions` 及消息表 | [实验中][待弃用] 密文、参与者、过期时间和兼容读取。 |
| `watchlist` | 用户和商品关系，是否收藏自己的商品。 |
| `notifications` | unread、event_type、related_order/listing、是否已推送但未读。 |
| `admin_audit_logs` | 管理员操作是否有审计记录。 |
| `moderation_jobs` | 图片审核任务是否 pending、failed 或 completed。 |

[目标态] 新增 `campuses`、`campus_memberships`、`moderation_cases`、`agent_runs`、`agent_action_plans` 和 `outbox_events` 后，应同步更新本表与对应 runbook。

## 内容审核策略

文本审核由后端 `ModerationService` 同步执行，商品发布/更新、用户名修改、用户直聊、留言主题和 AI 聊天入口都会先过审再持久化或调用 LLM。内置规则只覆盖校园二手交易里明显高风险的安全和合规类别：违禁或管制物品、低俗成人内容、博彩、诈骗灰产、暴力/极端风险、骚扰开盒、隐私泄露、联系方式和外部链接。

本地政策词、校内临时专项词或法务要求的词不要写死进源码，优先通过 `BLOCKED_KEYWORDS` 或 `[moderation].blocked_keywords` 配置。返回给用户的错误只说明类别，不暴露具体命中词，避免教用户绕过。

图片审核仍是异步任务：业务接口保存媒体 URL 后写入 `moderation_jobs`，后台 Worker 调外部图片审核 API 并回写资源状态。生产环境应配置 `MODERATION_IMAGE_API_URL` 和 `MODERATION_IMAGE_API_KEY`，否则只能完成文本审核。

## 常见排错

### 后端无法启动

按顺序检查：`.env` 是否存在，`DATABASE_URL` 是否正确，PostgreSQL 是否运行，pgvector extension 是否可用，迁移是否失败，`JWT_SECRET` 是否至少 32 字符，LLM key 是否至少设置一个，`VECTOR_DIM` 是否与数据库一致，生产环境是否设置了明确 CORS。

如果报 TOML 解析错误，应用会退回 env/default 配置并记录 warning；但如果缺少必需 env，仍会 fail fast。

### 注册或登录失败

注册失败先看用户名是否重复、密码长度、邮箱域名。登录失败先确认用户存在、密码正确、用户未被封禁。为了防止枚举，错误用户名和错误密码会返回同类认证失败，不要期待接口告诉你是哪一个错了。

### Refresh 失败

refresh token 是一次性旋转。失败常见原因：客户端重复使用旧 refresh token，token 已过期，logout 已撤销，用户被封禁，或者数据库中 token hash 不匹配。如果怀疑 replay，检查该用户是否所有 refresh token 都被撤销。

### WebSocket 连不上

WebSocket 只从 `Authorization` header 取 Bearer token。检查 access token 是否有效、JTI 是否被撤销、用户是否被封禁。连接建立后如果收不到通知，先确认 `notifications` 表是否已有记录，再看 WebSocket 在线连接和 dropped/pruned 指标。

### 聊天消息异常

先确认 `chat_conversations.mode` 和 `state`。`mail/open` 可以异步发送；`realtime` 只有 `active` 可发送，但发起方在 `syn_ack` 直接发送时会自动 ACK。`syn_sent`、`declined`、`cancelled`、`expired`、`closed` 都不应允许普通发送。

如果消息看起来丢了，先查 `chat_messages.direct_conversation_id` 是否等于会话 id，再查 sender/receiver 是否是会话成员。未读数量来自 `chat_conversation_members.unread_count`，不是全局字段。排查状态跳转时看 `chat_conversation_events`，它能说明会话是被接通、关闭、屏蔽还是 worker 过期。

如果实时信号异常，确认 WebSocket 收到的是 `conversation_created`、`conversation_state_changed`、`new_message`、`message_read` 或 `typing`。邮件不会向发件人发送 typing/read 事件。媒体问题仍按 URL-first 检查 `image_url`、`audio_url`，Base64 字段只是兼容 fallback。

### 语义搜索或推荐异常

检查 `documents` 表是否有对应商品文档，embedding 是否非空，`VECTOR_DIM` 是否与 schema 一致，商品是否 active，LLM/embedding provider key 是否可用，pgvector 索引是否存在。语义搜索问题通常横跨 provider、文档写入和 SQL 过滤三层。

### 订单状态不对

先查 `orders.status`、`confirmed_at`、`auto_delist` 和 `auto_delisted_at`，再查商品 `inventory.status`。创建成交意向只应写入 `intent_pending`，不应立即把商品改为 sold；卖家确认且 `auto_delist = true` 时，订单确认和商品下架必须在同一事务中完成。常规状态只允许 `intent_pending -> confirmed`、`intent_pending -> cancelled`，管理员可按后台规则处理异常记录。

### HITL 议价卡住

查看 `hitl_requests.status`、`expires_at`、`counter_price` 和 `buyer_action`。pending 等卖家处理，countered 等买家处理，expired 由后台 Worker 扫描设置。检查 Worker 是否启动、扫描间隔和过期小时数是否符合 TOML 配置。

### Flutter async 问题

页面销毁后请求返回会导致常见 mounted 问题。连续刷新或搜索会导致旧请求覆盖新请求。token refresh 失败要集中由 service/token storage 处理，不要在多个页面各自补一套临时逻辑。

## 生产上线检查 [目标态]

### 环境和密钥

- development、staging、production 使用不同数据库、Redis、对象存储、provider key 和 JWT/KMS 密钥。
- 密钥由部署平台 secret manager 注入，不写入镜像、TOML、日志或备份说明。
- 生产 `CORS_ORIGINS`、public base URL、WebSocket URL 和 callback URL 使用 HTTPS/WSS 正式域名。
- 管理员和校园运营启用 MFA/近期认证策略。
- Seed 测试账号和本地测试图片不进入生产数据库。

### 数据库和 migration

- 在空库运行全部 migration，证明新环境可启动。
- 在生产快照脱敏副本运行升级，记录锁时间、表扫描和磁盘增长。
- 先部署兼容 schema，再部署应用读写，最后单独清理旧字段。
- 应用 rollback 不依赖回滚已执行 migration。
- 核心 TEXT/UUID shadow column divergence 检查为零或有批准的兼容清单。

### 核心用户旅程

- 游客浏览；注册用户收藏；校园认证成员发布和联系。
- offer/wanted 发布、匹配、响应、联系人线程和线下成交确认。
- 普通用户看不到管理入口，校园运营不能跨 tenant。
- Agent provider 故障时仍可使用搜索、表单和手工聊天。
- 媒体审核 pending/failed 不公开原始对象。

## SLO、告警和错误预算 [目标态]

生产默认目标见[生产架构](production-architecture.md)：月可用性 99.9%，普通 API p95 小于 300ms，Feed/Search p95 小于 500ms，在线消息投递 p95 小于 1s，Agent 首 token p95 小于 3s。

告警必须面向用户影响，而不是单个瞬时 CPU 峰值：

| 告警 | 触发信号 | 第一检查点 |
| --- | --- | --- |
| API 错误预算快速消耗 | 5xx/timeout 持续上升 | 最近发布、DB、依赖、rate limit |
| 数据库饱和 | pool wait、连接、锁和慢查询 | 每实例 pool、长事务、缺索引 |
| 消息投递退化 | DB 已写但 fan-out 延迟/失败 | Redis、实例连接表、HTTP 补偿 |
| 审核积压 | pending age 和队列长度 | provider、worker lease、dead-letter |
| Outbox 积压 | oldest unprocessed age | worker、不可重试事件、数据库锁 |
| Agent 退化 | 首 token、错误、熔断 | provider、模型、工具循环、配额 |
| 媒体错误 | 上传/解码/公开失败率 | STS、bucket policy、MIME、CDN |

错误预算耗尽时暂停扩大风险的新功能，优先处理可靠性、安全和容量。维护窗口和 provider 故障不能无限排除在 SLO 外。

## 备份与恢复 Runbook [目标态]

### 备份

1. PostgreSQL 开启满足 RPO 15 分钟的连续归档/PITR 或等价能力。
2. 定期全量备份并验证校验值，备份账号不能写生产业务表。
3. 对象存储开启版本/生命周期，CDN 缓存不算备份。
4. KMS 密钥和数据备份分开保护，文档记录恢复依赖但不记录密钥材料。
5. 备份 metrics 包括成功、持续时间、大小、最近可恢复时间和失败告警。

### 恢复演练

1. 在隔离环境创建空数据库和对象存储目标。
2. 恢复到指定时间点，记录开始、可连接、应用可用和完整验收时间。
3. 启动兼容版本应用，禁止连接生产 Redis/provider 写路径。
4. 验证账号、membership、offer/wanted、聊天、成交、审核、审计和 outbox。
5. 重建可重建的 embedding/cache，并验证没有把 deleted/sold 内容重新公开。
6. 对比目标 RPO/RTO，形成差距、owner 和截止日期。

恢复演练至少按季度执行，并在重大 schema、对象存储或 KMS 变更后额外执行。

## 密钥轮换 Runbook [目标态]

- JWT 使用新旧 secret 兼容窗口：先验证新旧、只签新，再等待旧 token 过期并移除旧 secret。
- Provider/OSS key 先创建新 key、灰度验证、切换引用，再撤销旧 key。
- KMS 数据密钥轮换不要求一次重写全库；新写使用新版本，后台受控重包旧数据密钥。
- 轮换过程监控认证失败、上传失败、解密失败和 provider 错误。
- 紧急泄漏时优先撤销和限制影响，再进行正常兼容迁移。

## 审核积压 Runbook [目标态]

1. 检查 `moderation_jobs`/ModerationCase 的 oldest pending、重试和 last_error。
2. 判断是 provider、网络、格式、配额还是 worker lease 问题。
3. 保持媒体 pending 和私有隔离，不因积压自动公开。
4. 可安全重试的任务使用指数退避；不可解码内容直接进入拒绝/人工队列。
5. 超过阈值进入 dead-letter，并提供受审计的批量重放。
6. 用户界面显示“审核中/稍后重试”，不暴露 provider 或内部规则。

## 事故响应 Runbook [目标态]

| 阶段 | 要做什么 |
| --- | --- |
| 发现 | 记录时间、用户影响、告警和初始 trace，不急于猜根因 |
| 限制 | 撤销 token、关闭上传/Agent 写工具、暂停校园发布或回滚应用 |
| 保全 | 保存必要日志、审计和事件，避免无边界复制用户数据 |
| 修复 | 处理根因并增加自动检测/回归测试 |
| 恢复 | 分阶段开放，观察错误预算、队列和关键旅程 |
| 沟通 | 按批准流程通知负责人和受影响用户，不夸大或隐瞒 |
| 复盘 | 记录时间线、系统原因、检测缺口、修复 owner 和截止时间 |

高风险 kill switch 至少覆盖 Agent L2/L3、媒体公开、Secret Chat 新建、跨校园能力和管理员 impersonation。

## 文档级验证

只改文档时通常不跑 Rust/Flutter 测试。推荐检查：

```bash
git diff --check
rg --files -g '*.md' -g '*.mdx'
```

还应该检查本地 Markdown 链接能解析，并确认旧的分散说明没有被重新引入。当前文档体系以 [README](README.md) 为唯一入口。
