# 运行、配置与排错

| 项目 | 内容 |
| --- | --- |
| 适用读者 | 本地开发者、部署维护者、SRE、数据库管理员和事故响应人员 |
| 当前状态 | 当前配置、outbox/embedding 队列和单实例排错已可用；完整 SLO、KMS 与生产级多副本 runbook 仍需完善 |
| 事实来源 | 配置加载代码、环境模板、Docker/Compose、migration、metrics、worker 和实际启动行为 |
| 最后核对范围 | 环境变量、PostgreSQL/pgvector、CORS、Redis、媒体审核、日志、健康检查和常见故障 |

这篇文档面向“系统跑不起来、跑着不对、上线前要确认什么”。它集中维护配置、数据库、迁移、metrics、日志和排错路径。目标拓扑和 SLO 见[生产架构](production-architecture.md)，开发步骤见 [开发指南](development.md)，业务状态见 [业务流程](domain-flows.md)。

> **第一次**对真实学生开放前，先走[首次上线检查清单](first-launch-checklist.md)。本文讲日常运行；那份讲的是只在第一次出现、且会在上线当天爆发的问题。

## 环境变量

密钥和连接串放在 `.env` 或运行环境里，模板见 [.env.example](.env.example)。不要把真实密钥写进 TOML 或提交到仓库。

| 变量 | 必需 | 说明 |
| --- | --- | --- |
| `DATABASE_URL` | 是 | 后端主数据库连接串。 |
| `TEST_DATABASE_URL` | 测试需要 | 数据库测试连接串，必须指向安全测试库。 |
| `JWT_SECRET` | 是 | JWT 签名密钥，至少 32 字符。 |
| `JWT_SECRET_OLD` | 可选 | JWT 密钥轮换期间用于兼容旧 token。 |
| `CAMPUS_VERIFICATION_DELIVERY_URL` | 生产必需 | 校园邮箱验证码投递 webhook；开发省略时验证码只写本地后端日志。 |
| `CAMPUS_VERIFICATION_DELIVERY_TOKEN` | 生产必需 | 调用验证码投递 webhook 的 bearer token。 |
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
| `SHUTDOWN_DRAIN_SECS` | 可选 | 收到 SIGTERM 后继续接受流量的排空秒数，默认 5，期间 `/api/readyz` 已返回 503。 |
| `SHUTDOWN_TIMEOUT_SECS` | 可选 | 关闭监听后等待在途请求和 Worker 的秒数，默认 25。 |
| `REDIS_URL` | 可选 | 设置后启用分布式限流与 WebSocket 跨副本 fan-out；未设置时单机限流、本地投递。Redis 故障时限流降级单机、fan-out 降级本地，不影响启动。 |
| `RATE_LIMIT_MAX_REQUESTS` | 可选 | 每窗口最大请求数。 |
| `RATE_LIMIT_WINDOW_SECS` | 可选 | 限流窗口秒数。 |
| `BLOCKED_KEYWORDS` | 可选 | 逗号分隔本地策略关键词。内置规则已覆盖违禁交易、低俗成人、博彩、诈骗、暴力风险、骚扰、隐私泄露、联系方式和外链。 |
| `SECRET_CHAT_NEW_SESSIONS_ENABLED` | 可选 | Secret Chat 已弃用；默认 `false`，新建会话返回 403。仅迁移窗口可临时置 `true`，历史会话始终可读。 |
| `MODERATION_IMAGE_ENABLED` | 可选 | 是否启用图片审核；生产开启时必须同时提供合法的 provider URL 和 key。 |
| `MODERATION_IMAGE_API_URL` | 生产图片审核开启时必需 | 图片审核 API URL；生产启动会校验为 `http(s)` URL。Worker 发送 `{"image_url":"短期 URL","source":"goods4ncu"}`，使用 Bearer key。 |
| `MODERATION_IMAGE_API_KEY` | 生产图片审核开启时必需 | 图片审核 API key；生产启动会拒绝空值或过短 key。Provider 必须返回 `approved: true/false`，或受文档约束的 `status/result/verdict` 状态词。 |
| `MEDIA_PRIVATE_BUCKET` | 生产必需为 `true` | 私有 bucket + presigned PUT/serving 开关；生产启动会拒绝公开媒体退化路径，并同时要求 OSS endpoint/bucket/凭据。开发和测试可关闭。 |
| `OSS_ENDPOINT`、`OSS_BUCKET` | 可选 | OSS 直传非敏感配置。 |
| `OSS_ROLE_ARN`、`OSS_ACCESS_KEY_ID`、`OSS_ACCESS_KEY_SECRET` | 上传需要 | 获取 OSS STS 临时凭证需要的配置。 |
| `CONFIG_FILE` | 可选 | 指定 TOML 配置文件路径。 |

如果启动时报缺失变量，优先检查 `.env` 是否被加载、变量名是否拼写正确、shell 当前目录是否是项目根目录。生产模式（`APP_ENV=production`）还会拒绝含开发标记或低熵的 `JWT_SECRET`；staging/production 模板见 [.env.staging.example](.env.staging.example) 与 [.env.production.example](.env.production.example)。

验证码投递 webhook 接收 `to`、`template=campus_email_verification`、`code` 和 `expires_in_seconds`。生产模式下 URL 或 token 任一缺失都会 fail fast；投递返回非 2xx 时 challenge 标记为 `failed`，接口不会假装发送成功。日志和第三方投递系统都应把验证码按短期敏感凭据处理，不进入长期检索、分析或告警正文。

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
  > ./goods4ncu.toml        # legacy fallback
  > ./config/goods4ncu.toml # legacy fallback
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

如果 pgvector 没安装，数据库初始化会失败。部署需使用 pgvector `0.8.0` 或更高版本：相似商品查询通过 `hnsw.iterative_scan=strict_order` 在校园、生命周期和用户反馈过滤后继续召回，避免一次近似扫描导致结果不足。可用 `SELECT extversion FROM pg_extension WHERE extname = 'vector';` 核对版本。如果 `VECTOR_DIM` 与 schema 中 `vector(768)` 之类的定义不一致，应用会 fail fast。

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

## 依赖漏洞扫描

[已实现] CI 的 `audit` job 对 `Cargo.lock` 运行 `cargo audit`，任何未在 `.cargo/audit.toml` 中显式论证的公告都会使构建失败。规则：

- ignore 条目必须写清不可达性论证，不接受“暂时忽略”。当前唯一条目是 RUSTSEC-2023-0071（`rsa` crate 的 Marvin 时序侧信道）：`jsonwebtoken` 只以 HS256 HMAC 使用（`from_secret` + `Validation::default()`），RSA 路径不可达。若未来引入非对称 JWT 签名，必须先删除该条目。
- unmaintained/unsound 类公告保持为 warning 可见，不加入 ignore，有修复版本时跟进升级。
- 升级依赖后本地先跑 `cargo audit` 与全量测试再提交；`prometheus` 已关闭默认 protobuf feature（只用文本格式），不要在升级时恢复默认 features。

## 健康探针与优雅停机

[已实现] 后端区分存活与就绪，并在 SIGTERM 后按顺序排空。

| 接口 | 用途 | 检查内容 | 排空期间 |
| --- | --- | --- | --- |
| `GET /api/livez` | liveness | 只确认进程在运行，不查数据库 | 仍返回 200 |
| `GET /api/readyz` | readiness | 排空状态 + 数据库连通性 | 返回 503 `service_unavailable` |
| `GET /api/health` | 旧客户端兼容别名 | 与 `readyz` 相同 | 返回 503 |

liveness 故意不查数据库。如果 liveness 依赖数据库，一次数据库故障会让编排器同时重启所有副本，删掉恢复所需的容量，把局部故障放大成全局故障。依赖健康属于 readiness：它摘流量但不杀进程。

三个探针都在限流白名单里。编排器的探针频率远高于普通客户端，被限流会把健康实例误报为故障并触发重启循环。

停机顺序（SIGTERM 与 SIGINT 走同一条路径）：

```text
1. 收到信号 → 置为 draining，/api/readyz 立即返回 503
2. 等待 SHUTDOWN_DRAIN_SECS（默认 5s）→ 负载均衡器摘除本实例
   期间监听端口仍然接受并完成请求，/api/livez 保持 200
3. 关闭监听 → 等待在途请求自然结束
4. Worker 在两次扫描之间退出，不会中断进行中的事务
5. 关闭数据库连接池 → 进程退出
   整个 3–5 步受 SHUTDOWN_TIMEOUT_SECS（默认 25s）约束
```

编排器的终止宽限期必须大于 `SHUTDOWN_DRAIN_SECS + SHUTDOWN_TIMEOUT_SECS`（默认 30s），否则进程会在排空中途被 SIGKILL，优雅停机等于没做。Compose 默认宽限期只有 10s，仓库里的 `docker-compose.yml` 已显式设置 `stop_grace_period: 40s`；Kubernetes 对应 `terminationGracePeriodSeconds: 40`。

Worker 不再被 `abort()`。HITL 过期、订单、媒体审核、token 清理和会话过期都在两次迭代之间检查停机标志，因此不会出现事务提交到一半被切断。媒体审核的 `processing` 任务由 `0069` 写入 `locked_by/locked_until` lease；进程硬退出后到期可由下一副本重领，不需要人工把任务从 processing 改回 pending。

验证方式：

```bash
SERVER_PORT=3999 SHUTDOWN_DRAIN_SECS=3 cargo run &
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:3999/api/readyz   # 200
kill -TERM <pid>
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:3999/api/livez    # 200，排空中仍存活
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:3999/api/readyz   # 503，已摘流量
```

回归覆盖在 `tests/lifecycle_probes_integration.rs` 和 `src/lifecycle.rs` 单元测试。

## 生产演练（一键）

[已实现] `scripts/production_rehearsal.sh` 在本机以一次通过验证生产拓扑的关键运维性质：

1. 生产模式守卫真实生效（开发级 JWT_SECRET 被拒启动；CORS 与验证码投递 webhook 必须配置）。
2. 双副本对空库完成生产模式引导（迁移、pgvector 扩展带 advisory lock 串行化——该演练发现并修复了双副本并发 `CREATE EXTENSION` 的真实竞态）。
3. Redis 分布式限流与 WS fan-out 激活确认。
4. SLO 负载冒烟（`scripts/load_smoke.sh`，普通 API p95<300ms、Feed<500ms）。
5. 私有 MinIO/OSS bucket 验收：匿名直连拒绝、商品/头像/共享文件的 presigned PUT、presigned serving、`/complete` probe、撤销后的 signed DELETE 与远端清理审计（rehearsal checks 2b–2c）。SocialPersona 角色/皮肤不走用户上传，只验收 `/api/persona/catalog` 的版本和 allow-list。
6. 滚动重启：B 副本排空并回归期间，A 副本承载负载零失败请求。
7. PITR 恢复演练（`scripts/backup_pitr_drill.sh`）。
8. 双副本按序排空。

共享文件撤销清理由 `shared_object_cleanup` worker 执行：`DELETE` 使用平台 bucket 签名，HTTP 404 视为幂等成功；失败会写入 `cleanup_attempts`、`cleanup_next_attempt_at` 和截断后的 `cleanup_last_error`，按 30 秒到 1 小时退避重试。若日志显示 worker idle，先检查 `OSS_ACCESS_KEY_ID`/`OSS_ACCESS_KEY_SECRET` 是否存在；不要手动把 `cleanup_completed_at` 改成成功，必须让平台删除或由运维确认远端对象已不存在。

全部资源（演练库、独立 Redis、mock webhook）为一次性并自动清理。生产部署把同一清单跑在真实基础设施上即可作为发布验收。

## 容量与端口注意事项

[已实现] `scripts/capacity_drill.sh` 在一次性数据库播种 10 万注册规模（用户/资格/双校园商品/通知/收藏），对真实服务执行 SLO 冒烟；本机通过（列表 p95 57ms、Feed 15ms）。索引回归应在提交涉及核心查询的迁移后重跑本演练。

本机演练排错经验（已写入脚本防护）：桌面应用可能占用 127.0.0.1 高位端口（实测 QQ 占用 4301——服务绑 0.0.0.0 成功但回环流量被更精确的绑定截走）；HTTP(S) 代理环境变量会把回环请求送进代理并以 502/000 假装应用故障。所有演练脚本已强制 NO_PROXY 并预检端口。

## 数据库角色与 pgvector（上线前必读）

[已实现] 应用角色**必须不是 superuser**：superuser 会完全绕过 RLS，租户策略（`0042`）会静默失效——应用看起来正常，隔离却是关的。但创建扩展需要 superuser，因此扩展由管理员一次性安装，应用永不需要该权限：

```bash
DB_NAME=goods4ncu APP_PASSWORD=<secret> ./scripts/provision_app_role.sh
```

该脚本幂等，创建 NOSUPERUSER 应用角色与其拥有的数据库、安装 pgvector，并**校验**这两条不变量后才返回。若扩展缺失且角色无权创建，应用启动会给出可直接执行的修复命令而不是含糊的权限错误。

本机验证记录：以 superuser 运行时 RLS 无效（armed context 仍可见全部行）；换为 NOSUPERUSER 角色后同一查询可见 0 行，且应用正常启动与服务。生产演练 check 2d 每次都会复验这一点。

## 本机持久部署（两校园实例）

[已实现] `scripts/deploy_local.sh` 在本机拉起一个**常驻**部署，而非一次性演练：状态持久化在 `~/.goods4ncu-deploy`（密钥一次生成后复用），使用 NOSUPERUSER 数据库角色、常驻 Redis、常驻 MinIO 并为每个校园建立私有 bucket 与受限凭据，启动两个生产模式副本；随后通过 admin API 创建并激活第二校园、按邮箱域注册并认证两校成员、各自发布商品，并**通过 HTTP API** 验证跨校园隔离（成员只见本校、公开面不泄露、校园凭据不能写他校 bucket）。

```bash
./scripts/deploy_local.sh            # 启动/复验（幂等）
./scripts/deploy_local.sh --stop     # 停进程，保留数据
./scripts/deploy_local.sh --destroy  # 连数据一起清除
```

上线时把数据库/Redis/对象存储端点换成生产实例即为同一套流程；该脚本的校园创建与成员认证段可直接作为新校园接入手册。

## 多租户隔离演练

[已实现] `scripts/tenant_isolation_drill.sh` 用真实服务验证生产的隔离模型，而不是共享单实例：两套**独立** PostgreSQL 集群（各自数据目录/端口）代表 staging 与 production，MinIO 中每校园独立 bucket 并配受限 IAM 凭据。断言：跨集群不可见、应用只写自己的集群、校园凭据可读本校 bucket、不可读他校 bucket、以他校对象签发 presign 被拒、两个 bucket 均拒绝匿名读。

上线时把端点与凭据换成生产实例重跑该脚本即为隔离验收。两条纪律不变：应用角色非 superuser（否则绕过 RLS）；每校园/每环境使用各自的 bucket 与受限凭据，不共享根凭据。

## Transactional Outbox

[已实现] `outbox_events` 表承载“业务事务内入队、worker 异步投递”的持久事件。当前唯一 topic 是 `notification.push`：通知行和推送事件同事务提交，outbox worker（500ms 轮询）投递 WebSocket，因此进程崩溃不会丢已提交通知的推送。

排错要点：

- 投递语义是至少一次；消费者必须幂等（通知按 id 去重，重复投递无害）。
- `attempts/last_error/available_at` 显示重试与退避（2^n 秒，封顶 5 分钟，默认 8 次）。
- 超限进入 `dead_lettered_at`，worker 不再认领；修复根因后用 `services::outbox::replay_dead_lettered`（或等价 SQL 置空 `dead_lettered_at` 并重置 `attempts`）受控重放。
- `locked_by/locked_until` 是 60 秒租约；worker 崩溃后租约到期事件自动可被重新认领。堆积排查先看最老未处理事件的 `available_at` 和 `last_error`。
- 多副本通过已实现的 Redis pub/sub 把推送路由到持有连接的实例；异常时同时检查 outbox、Redis fan-out 和客户端 HTTP 补拉，不能只看当前副本的连接表。

## Listing Embedding Jobs

[已实现] `0057_versioned_embedding_jobs.sql` 建立独立于通知 outbox 的 `embedding_jobs`。listing INSERT、语义字段/status/campus 变化，以及 restriction effect 生效或结束，都在原业务事务内推进 `inventory.content_revision` 并合并同一 `listing_id` 的 `desired_revision`。迁移会为全部既有 inventory 建立 pending job；它不在 migration 内调用 provider。

状态与恢复语义：

- `pending`：等待 `available_at`；失败按 2^attempts 秒退避，封顶 5 分钟。
- `processing`：由 `locked_by/locked_until` 持有 lease；进程退出后到期可重领。
- `completed`：该行当时的 `desired_revision` 已完成。新 revision 会重新置为 pending。
- `dead_lettered`：达到 `max_attempts`，保留 `last_error/dead_lettered_at` 等待人工确认后重放。
- processing 期间新版本不会抢走现有 lease，而是只推进 `desired_revision`。旧 worker success/failure 时通过 claimed revision CAS 发现 superseded，并把最新版立即重新排队。

Provider 故障不会回滚 listing 发布或更新。用户先得到已提交的 listing，向量缺失期间搜索与匹配走既有 fallback；恢复 provider/worker 后队列自动补齐。不要为了“强一致”把 provider HTTP 调用重新放回 inventory 数据库事务。

## Agent ActionPlan 中断恢复

[已实现] 新确认协议从计划行锁、业务写入、通知/outbox 到计划终态只使用一个外层数据库事务；动作校验位于 savepoint。新请求的 `executing` 因此只在未提交事务内存在：进程在 commit 前退出会整笔回滚，客户端可用当前步骤 token 重试；commit 成功后业务事实与 `executed` 同时可见。

升级时发现的旧协议 `executing` 无法证明业务副作用是否已经提交。`0058_agent_plan_atomic_confirmation.sql` 将它们标为 `interrupted`，不自动重放。值班排查先只读列出异常行：

```sql
SELECT id, campus_id, user_id, action, status, args, result, updated_at
FROM agent_action_plans
WHERE status IN ('interrupted', 'executing')
ORDER BY updated_at;
```

- `interrupted`：建立人工事件，按 `action/args` 核对 inventory、orders、hitl_requests、notifications/outbox 和审计事实，再联系用户确认；在没有 plan-scoped receipt 前绝不能猜测后重放。
- 新迁移之后若能从另一个连接持续读到 `executing`，它不是正常中间态，而是协议不变量被破坏。立即关闭 Agent L2/L3 写入开关、保留行和日志并升级处理。
- confirmation token 不写日志、不进模型上下文，token-bearing API 响应必须保持 `Cache-Control: no-store`。
- 事务内只允许数据库副作用。新增外部调用必须先写 transactional outbox，由幂等 worker 在 commit 后投递，不能把网络请求塞进确认事务。

当前没有自动化 `interrupted` 对账/结案界面；首版 `agent_runs`/`agent_run_events` 已把活动校园聊天的路由、provider/model、版本、检索聚合、工具类别、SSE TTFT、耗时和 typed outcome 放入安全 envelope，并由 `GET /api/agent/runs` 提供只读视图。SSE 客户端丢弃生成器后，进程内 reconciliation task 会在有界 grace period 后把仍为 `started` 的运行标记为 `cancelled`；正常结束会提前终止该任务，独立 worker 还会定期关闭跨进程遗留的 stale `started` 行。服务端保存有界 input/output token 计数，但安全视图不暴露它们。ActionPlan 的 typed terminal outcome 已落地；`agent_action_audits` 记录行动级 receipt（提案、重放/冲突、确认、执行、失败、取消、过期），与计划终态同事务提交，并明确不保存正文、token、args 或完整错误；聊天提案在同一 trace 下可通过 `agent_run_id` 显式关联。listing 关键动作的资源版本快照与冲突保护、Agent 提案按用户/校园和动作参数哈希的幂等已经落地。provider 侧 TTFT、设备/重新认证绑定和版本化风险文案仍需补齐。

只读排查可按 trace 或计划串起行动链路；事件元数据只用于安全运营，不应被当成消息阅读、在线或注意力信号：

```sql
SELECT trace_id, agent_run_id, plan_id, action, risk_level, event_type,
       outcome_code, duration_ms, created_at
FROM agent_action_audits
WHERE campus_id = '<active-campus-uuid>'
  AND user_id = '<authenticated-user-id>'
ORDER BY created_at DESC
LIMIT 100;
```

AgentRun 只读排查使用同一租户和用户边界；不要为了追查失败去读取 prompt 或拼接聊天正文：

```sql
SELECT trace_id, route, provider, model, status, outcome_code,
       retrieval_count, tool_call_count, duration_ms, created_at, completed_at
FROM agent_runs
WHERE campus_id = '<active-campus-uuid>'
  AND user_id = '<authenticated-user-id>'
ORDER BY created_at DESC
LIMIT 100;
```

常用只读检查：

```sql
-- 队列状态、数量与最老请求
SELECT status, count(*) AS jobs, min(requested_at) AS oldest_requested_at
FROM embedding_jobs
GROUP BY status
ORDER BY status;

-- 可执行、退避中和 lease 已过期的工作
SELECT
  count(*) FILTER (WHERE status = 'pending' AND available_at <= now()) AS due,
  count(*) FILTER (WHERE status = 'pending' AND available_at > now()) AS retry_wait,
  count(*) FILTER (WHERE status = 'processing' AND locked_until < now()) AS expired_leases
FROM embedding_jobs;

-- dead-letter 明细；不要把 listing_id 做 Prometheus label
SELECT listing_id, campus_id, desired_revision, attempts,
       dead_lettered_at, last_error
FROM embedding_jobs
WHERE status = 'dead_lettered'
ORDER BY dead_lettered_at;

-- active 且未受限 listing 的当前投影覆盖率/陈旧量
SELECT
  count(*) AS eligible,
  count(*) FILTER (
    WHERE document.source_revision = listing.content_revision
      AND document.embedding IS NOT NULL
  ) AS current,
  count(*) FILTER (
    WHERE document.id IS NULL
       OR document.source_revision IS DISTINCT FROM listing.content_revision
       OR document.embedding IS NULL
  ) AS missing_or_stale
FROM inventory AS listing
LEFT JOIN documents AS document ON document.id = listing.id
WHERE listing.status = 'active'
  AND NOT EXISTS (
    SELECT 1 FROM listing_restriction_effects AS effect
    WHERE effect.listing_id = listing.id AND effect.released_at IS NULL
  );
```

修复根因并记录变更单/事故编号后，可用服务 API `services::embedding_jobs::replay_dead_lettered`，或在受控数据库会话执行等价的单条重放：

```sql
UPDATE embedding_jobs
SET status = 'pending', attempts = 0, available_at = now(),
    locked_by = NULL, locked_until = NULL, last_error = NULL,
    completed_at = NULL, dead_lettered_at = NULL, requested_at = now()
WHERE listing_id = '<listing-id>' AND status = 'dead_lettered'
RETURNING listing_id, campus_id, desired_revision;
```

当前没有 embedding dead-letter 管理端，也没有自动写入管理员审计；直接 SQL 重放必须依赖外部变更记录，不能宣称为产品内受审计操作。`/api/metrics` 目前也未暴露 embedding queue depth、oldest pending、retry/dead-letter、provider latency 或 current-revision 覆盖率；上线前应补低基数 Prometheus 指标和告警。已完成 job 的归档/保留清理尚未实现，高量环境还需制定 retention，避免表和索引持续增长。

部署与 backfill 顺序：

1. 先部署 0057 schema；迁移只登记已有 inventory，不访问 provider。
2. 部署能消费 versioned jobs 的 worker，再观察 pending、expired lease、dead-letter 与 provider 429/timeout。
3. 对大库按校园限速消化 migration backfill；可以停止并重启 worker，按 listing 合并使过程幂等。
4. 用上述覆盖率查询确认 active/unrestricted listing 的 `documents.source_revision = inventory.content_revision`，并抽查 deleted/sold/fulfilled/restricted 内容已删除投影。
5. 模型/维度变化先双写或新建兼容的向量列/表并重建，完成读切换后再清理旧版本；固定 `vector(768)` 不能直接装入不同维度。

## Metrics 和结构化日志

`GET /api/metrics` 暴露 Prometheus 文本格式指标。当前指标覆盖请求计数和延迟、限流拒绝、聊天消息、媒体消息、LLM 调用和错误、WebSocket dropped/pruned、订单创建和状态变化，以及图片审核任务结果、provider 延迟、pending/processing 队列深度和最老任务年龄。指标名称以 `src/api/metrics.rs` 中 `MetricsService` 为准。审核队列 gauge 是每个副本从同一数据库读取的快照，跨副本聚合应取 `max` 而不是 `sum`；counter/直方图才按副本求和。

日志使用结构化字段。排错时优先看带字段的日志，例如 `user_id`、`listing_id`、`order_id`、`err`、`provider`、`vector_dim`。不要只看最后一行错误文本；上下文字段往往能直接说明是哪个用户、哪条订单或哪次 provider 调用失败。

每个 HTTP 响应包含 `X-Request-ID`。错误 JSON 的 `trace_id` 与该 header 相同；用户报告问题时优先收集这个 ID，再在结构化日志中关联。每条请求完成日志还包含相同的 `request_id`、HTTP method、归一化 path、status 和 `duration_ms`。服务端总是生成 ID，不信任客户端自报的 request id，也不会把请求体或 token 写入访问日志。

匿名限流默认使用 TCP peer IP；服务必须通过 `into_make_service_with_connect_info` 启动才能向中间件提供可信地址。代理部署时仍以网关层限流和可信代理配置为主，不要直接信任客户端提交的 `X-Forwarded-For`。

[已实现] 请求与外呼超时边界：

- HTTP 层有 60 秒全局响应超时，超时返回 `504`（不是 408，避免客户端盲目重试可能已提交的写入）。该超时只约束“产生响应”的时间，不约束响应体：SSE 流式聊天和 WebSocket 会话先返回响应再持续输出，不受影响。
- 所有 LLM provider 的 HTTP 客户端统一经 `llm_http_client()` 构建：连接超时 10 秒、单次读超时 60 秒。`reqwest` 默认没有任何超时；没有这层边界时，provider 挂起会无限占住用户请求，且熔断器永远收不到失败信号。用整请求超时是错的——带工具的长流式补全会被误杀，读超时只杀停滞的流。
- 图片审核外呼 8 秒超时，STS 换取凭证 10 秒超时。

## 数据库表地图

| 表 | 排错时常看什么 |
| --- | --- |
| `users` | 用户 status、role、email、password_hash 是否正常。 |
| `refresh_tokens` | refresh token 是否过期、revoked_at 是否被设置、campus_id 是否与 access claim 和用户 membership 一致。 |
| `revoked_access_tokens` | logout 或管理员撤销后的 JTI 是否存在。 |
| `campuses` / `campus_memberships` | Campus status、用户资格、verification_method、verified_at；pending/suspended 不能执行受保护写操作。 |
| `inventory` | 商品 campus_id、生命周期 status、owner_id、价格、分类、更新时间与 `content_revision`；重复发布时检查 `idempotency_key/idempotency_hash`；wanted 重开异常时检查 `lifecycle_epoch` 是否只增加一次。审核限制不写入 status。 |
| `documents` | RAG 文档、embedding、维度，以及 campus/source_revision/content_hash/provider/model/version/embedded_at 是否与当前 listing 投影一致。 |
| `embedding_jobs` | desired_revision、pending/processing/completed/dead-letter、attempt/backoff、lease owner/expiry 和 last_error。 |
| `wanted_responses` | campus_id 与 wanted/offer 是否一致，responder/requester 是否同校园；`lifecycle_epoch` 为 NULL 的 legacy 行必须只读；同 wanted/epoch/offer 是否唯一；重试问题检查 `idempotency_key/idempotency_hash`。 |
| `orders` | campus_id、状态、buyer/seller、listing、金额和时间戳。 |
| `hitl_requests` | campus_id、pending/countered/expired 状态、counter_price、expires_at。 |
| `chat_conversations` | campus_id、mode、state、initiator/recipient、listing、subject、过期时间、close_reason。 |
| `chat_conversation_members` | 每个成员的 `archived_at`；新消息提示的本地查看位置不在数据库。 |
| `chat_conversation_events` | 握手、ACK、关闭、过期等状态事件时间线。 |
| `chat_blocks` | blocker/blocked 屏蔽关系。 |
| `chat_messages` | conversation_id、direct_conversation_id、sender、receiver、媒体 URL/Base64、edited_at；`read_at/read_by` 已由 `0068_remove_chat_attention_compat_shadow` 删除。 |
| `chat_message_acknowledgements` | 每条消息每个用户最多一条主动确认，`received/will_review/completed` 及创建/更新时间。 |
| `chat_spaces` 及成员/消息表 | group/channel、owner、成员角色、发言权限和更新时间。 |
| `chat_secret_sessions` 及消息表 | [实验中][待弃用] 密文、参与者、过期时间和兼容读取。 |
| `watchlist` | 用户和商品关系，是否收藏自己的商品。 |
| `notifications` | `campus_id`、unread、event_type、related_order/listing、是否已推送但未读。 |
| `admin_audit_logs` | campus_id、管理员操作、target、scope_reason；跨校园读取和写入是否都有审计。 |
| `agent_runs` / `agent_run_events` | Agent 请求的安全运行 envelope 与事件；按 campus/user 隔离，保存路由、provider/model、版本、计数、受限资源 ID、耗时、typed outcome 和有界 input/output token 计数，不保存 prompt、正文或完整 provider 错误；安全只读视图不返回 token 计数。 |
| `moderation_jobs` | campus_id、资源归属、pending/processing/approved/rejected/failed 状态，以及 processing 期间的 `locked_by/locked_until` lease；平台对象另外保存稳定 `storage_key`，私有 bucket worker 每次领取都重新签发短期 provider URL，旧任务仍可用 `image_url` fallback；到期任务可重领，终态会清空 lease。 |
| `social_persona_assets` | legacy persona/user/campus 归属和远端清理字段，仅用于历史回滚；`0080` 后既有行撤销、`selected_asset_id` 清空，当前公开 Persona 不读取图片。新的角色/皮肤由 `/api/persona/catalog` 的静态 token 提供。 |
| `chat_shared_objects` | file/link 权威对象、`pending_upload`/审核/撤销状态；文件撤销后的远端清理请求、尝试次数、下一次重试、错误与完成时间也保存在同一行。 |
| `moderation_cases` | campus_id、subject、来源、状态、公开原因、resolution 和 pending appeal；普通用户接口不得返回 internal_details。 |
| `moderation_case_events` | 案件创建、复核、处置、恢复和申诉状态转换的时间线。 |
| `moderation_appeals` | 每个案件每个当事人一次申诉、独立复核者、决定和公开说明。 |
| `listing_restriction_effects` | 每个 listing/case 的独立限制；`released_at IS NULL` 表示 active。排查时核对 campus、case、创建/释放 actor，不能只看 `inventory.status`。 |

[已实现] `0029_core_tenant_scope.sql` 给核心市场与通信事实增加 `campus_id` 和关联约束，`0031_active_campus_sessions.sql` 给 refresh session 增加活动校园并回填旧会话，`0032_notification_tenant_scope.sql` 给通知建立校园归属，`0033_admin_moderation_tenant_scope.sql` 给管理审计和媒体审核任务建立校园归属并修正 Worker 的 `processing` 状态约束，`0069_moderation_job_leases.sql` 为 processing 任务增加可回收 lease。当前 NCU default 仅为单校园兼容；第二校园接入前仍必须移除数据库默认值、完成空库/升级库隔离演练并评估 RLS。

[已实现] `0030_normalize_money_bigint.sql` 修复历史升级库可能遗留的 `INT4` 金额列，将商品价格、成交价和议价金额统一为 `BIGINT`。若空库测试正常但现有环境列表接口出现金额 decode 错误，先检查 migration 是否已经执行到 0030，不要在应用层把金额退回 32 位。

[已实现] `0034_moderation_cases.sql` 新增 `moderation_cases`、`moderation_case_events`、`moderation_appeals`，并把媒体拒绝任务和聊天举报回填为案件；`0053_content_reports.sql` 为商品和用户举报增加同校园 intake，并在同一事务中关联统一案件。`0037_outbox_events.sql` 已新增 `outbox_events`（见 Transactional Outbox 一节），`0038_agent_action_plans.sql` 已实现需确认的 Agent 写动作计划，`0075_agent_action_audit.sql`/`0076_agent_action_audit_campus_cleanup.sql` 已实现租户隔离的行动 receipt，`0077_agent_runs.sql`/`0078_agent_runs_campus_cleanup.sql`/`0079_agent_action_audit_run_link.sql` 已实现首版安全运行 envelope、SSE TTFT、bounded cancellation reconciliation 和聊天提案的可空显式 receipt 关联；`0080_system_persona_catalog_only.sql` 将角色/皮肤收敛为系统目录并撤销旧导入资产；AgentRun 服务端有界 token 计数和 stale-run durable reconciliation 已实现，provider 侧 TTFT、设备绑定和统一版本化 API 仍是目标态。

## 内容审核策略

文本审核由后端 `ModerationService` 同步执行，商品发布/更新、用户名修改、用户直聊、留言主题和 AI 聊天入口都会先过审再持久化或调用 LLM。内置规则只覆盖校园二手交易里明显高风险的安全和合规类别：违禁或管制物品、低俗成人内容、博彩、诈骗灰产、暴力/极端风险、骚扰开盒、隐私泄露、联系方式和外部链接。

本地政策词、校内临时专项词或法务要求的词不要写死进源码，优先通过 `BLOCKED_KEYWORDS` 或 `[moderation].blocked_keywords` 配置。返回给用户的错误只说明类别，不暴露具体命中词，避免教用户绕过。

图片审核仍是异步任务：listing 首次 commit 和共享对象完成上传会把媒体 URL、资源 `pending` 状态和 `moderation_jobs` 原子写入，并从 listing、conversation 或用户 session 继承校园，客户端不能提交校园。Persona 角色/皮肤只走系统目录，不产生图片审核任务；`0080` 只把历史素材撤销并交给已有清理 worker。平台对象同时保存服务器生成的 `storage_key`；私有 bucket 的 worker 在每次领取时重新签发短期 provider URL，不把可能过期的 presigned URL 当作长期任务事实，legacy job 或公开 bucket 才使用持久 `image_url`。管理员队列读取也会按 `storage_key` 重新生成短期 URL，不把历史签名直接暴露给运营页面。后台 Worker 调外部图片审核 API 并回写资源状态；拒绝结果与资源状态、ModerationCase 在同一事务中提交。`0069` 之后，Worker 认领任务时写入唯一 `locked_by` 和过期时间 `locked_until`；只有持有 lease 的副本能重试或提交终态，租约到期的 processing 行才会被下一副本回收。生产环境开启图片审核时，启动会 fail-fast 校验 `MODERATION_IMAGE_API_URL` 和 `MODERATION_IMAGE_API_KEY`，避免 provider 缺失时任务静默失败；本地生产 rehearsal 明确关闭该外部依赖，不代表真实 provider 已验收。校园运营可以在 `GET /api/admin/moderation/jobs?status=pending` 和 `GET /api/admin/moderation/cases?status=open` 查看本校积压；排查时同时观察 `locked_by/locked_until` 和 `last_error`；平台管理员跨校排查或处置必须同时提交 `campus_id` 和 `reason`。

## 常见排错

### 后端无法启动

按顺序检查：`.env` 是否存在，`DATABASE_URL` 是否正确，PostgreSQL 是否运行，pgvector extension 是否可用，迁移是否失败，`JWT_SECRET` 是否至少 32 字符，LLM key 是否至少设置一个，`VECTOR_DIM` 是否与数据库一致，生产环境是否设置了明确 CORS。

如果报 TOML 解析错误，应用会退回 env/default 配置并记录 warning；但如果缺少必需 env，仍会 fail fast。

### 注册或登录失败

注册失败先看用户名是否重复、密码长度、邮箱域名。登录失败先确认用户存在、密码正确、用户未被封禁。为了防止枚举，错误用户名和错误密码会返回同类认证失败，不要期待接口告诉你是哪一个错了。

### Refresh 失败

refresh token 是一次性旋转。失败常见原因：客户端重复使用旧 refresh token，token 已过期，logout 已撤销，用户被封禁，数据库中 token hash 不匹配，或 token 绑定的校园 membership 已被暂停/撤销。切换校园还要求目标 membership 为 verified，并会撤销当前 access JTI。如果怀疑 replay，检查该用户是否所有 refresh token 都被撤销，再核对 `refresh_tokens.campus_id`。

### WebSocket 连不上

WebSocket 只从 `Authorization` header 取 Bearer token。检查 access token 是否有效、JTI 是否被撤销、用户是否被封禁。连接建立后如果收不到通知，先确认 `notifications` 表是否已有记录且 `campus_id` 等于当前 session，再看 WebSocket 在线连接和 dropped/pruned 指标。切换校园后客户端必须用新 token 重连，HTTP 补拉只返回新校园通知。

### 聊天消息异常

先确认 `chat_conversations.mode` 和 `state`。`mail/open` 可以异步发送；`realtime` 只有 `active` 可发送，但发起方在 `syn_ack` 直接发送时会自动 ACK。`syn_sent`、`declined`、`cancelled`、`expired`、`closed` 都不应允许普通发送。

如果消息看起来丢了，先查 `chat_messages.direct_conversation_id` 是否等于会话 id，再查 sender/receiver 是否是会话成员。新留言徽标来自接收设备的 `LOCALLY_SEEN`，服务器没有可查询的阅读位置。排查状态跳转时看 `chat_conversation_events`，它能说明会话是被接通、关闭、屏蔽还是 worker 过期。

如果实时信号异常，确认 WebSocket 收到的是 `conversation_created`、`conversation_state_changed`、`new_message` 或 `message_acknowledgement_changed`。服务端不广播 `message_read`、`typing` 或在线状态。媒体问题先确认 `image_url`、`audio_url` 属于平台 bucket 或代理，Base64 字段只是兼容 fallback。

如果共享文件已显示 `revoked` 但 bucket 仍有对象，先查 `chat_shared_objects.cleanup_attempts/cleanup_next_attempt_at/cleanup_last_error` 和 `shared-object cleanup worker` 日志，再用平台 CLI 以同一 bucket 凭据确认对象是否存在。不要从消息 quote 或客户端 URL 反推清理状态；数据库完成时间只会在 signed DELETE 成功或平台返回 404 后写入。

### 语义搜索或推荐异常

先比较 `inventory.content_revision`、`embedding_jobs.desired_revision/status/last_error` 与 `documents.source_revision`。再检查 embedding 是否非空、`VECTOR_DIM` 是否与 schema 一致、商品是否 active/未受限、provider key 是否可用、pgvector 索引是否存在。Provider 故障时 listing 已提交是预期行为；应恢复 worker 并等待投影追平，不要删除业务 listing。语义搜索问题通常横跨 provider、版本化投影和 SQL 过滤三层。

首页商品 feed、相似商品、listing wanted matches 或 intent feed/matches 的个性化顺序/条目缺失异常，还要检查当前用户/校园的 `feed_preferences.personalization_enabled/signals_reset_at` 和 `feed_feedback.resource_type/resource_id/action/signal_key/updated_at`。重置只让旧收藏、买家成交意向和 `less_like_this` 泛化信号失效；所有入口仍精确隐藏显式 feedback 的原资源。相似商品使用分类泛化降权；wanted matches 因分类已是硬约束，查询会把 feedback 目标连接回 inventory 并用规范化品牌降低同品牌候选。不要为排查排序直接删除 watchlist/order 等业务事实。

### 审核案件异常

先确认当前校园，再检查 `moderation_jobs` 的 `campus_id/status/retry_count` 和 `moderation_cases` 的 `status/source_type/source_ref_id`。图片 provider 超时进入重试或 failed，不应自动创建违规案件；只有 rejected 会创建 `source_type=machine` 的 actioned 案件。聊天举报应同时存在 `chat_message_reports.case_id` 和对应的 `source_type=user_report` 案件。商品或用户举报还应存在 `content_reports.case_id`，对应案件的 `source_ref_id` 必须使用 `content_report:<report_id>` 前缀；缺少前缀会和聊天举报的 UUID 命名空间混淆。

如果 listing 案件已经恢复但资源仍不可见，先查该 listing 是否还有其它 `listing_restriction_effects.released_at IS NULL`，再查 lifecycle status；任一 effect 或非 active status 都足以保持隐藏。case restore/appeal 只能释放自己的 effect，manual emergency restore 也不能清除举报案件 effect。若 lifecycle 是 deleted/sold/fulfilled，释放全部 effect 仍不会重新上架，必须由 owner 在规则允许时显式 relist。

紧急下架重试应复用同一个 manual case/effect，不应增加重复 active effect 或重复通知。若 takedown、case event、effect 与 audit 数量不一致，按事务完整性事故处理：保留现场、停止手工改表，先核对同一 target/case 的时间线。跨校园记录必须与 listing campus 一致；RLS 武装测试下另一校园既看不到也写不了 effect。

其它媒体/账号案件仍检查 `moderation_case_events` 的最后事件、资源的 `images_moderation_status`/`moderation_status`/`avatar_moderation_status`，以及管理员审计中的 `campus_id` 和 `scope_reason`。申诉只能由案件当事人提交一次，复核必须由不同于原决定者的管理员完成；不要通过数据库直接改状态绕过事件和审计。

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
- 校园验证码投递 URL 与 bearer token 已配置，投递失败有指标/告警，日志不会长期保留验证码。
- [已实现] 平台管理员敏感写入使用 10 分钟密码近期认证，且已确认 TOTP MFA 的管理员在 step-up 时强制第二因子（注册接口见 API 参考）。生产上线前应为全部平台管理员完成 TOTP 注册；校园运营 MFA 仍是目标态。
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
| Embedding 投影落后 | oldest pending、current-revision 覆盖率 | worker lease、provider 配额、dead-letter |
| Agent 退化 | 首 token、错误、熔断 | provider、模型、工具循环、配额 |
| 媒体错误 | 上传/解码/公开失败率 | STS、bucket policy、MIME、CDN |

错误预算耗尽时暂停扩大风险的新功能，优先处理可靠性、安全和容量。维护窗口和 provider 故障不能无限排除在 SLO 外。

## 备份与恢复 Runbook [部分完成]

[已实现] `scripts/backup_pitr_drill.sh` 在一次性本地集群上完整演练恢复路径：initdb（开启 WAL 归档）→ `pg_basebackup` → 记录 T1 → 写入“灾难”行 → 以 `recovery_target_time = T1` 恢复 → 断言好状态存在、灾难行被排除。脚本幂等、自清理、以退出码表示演练结果，可直接进 CI 或 cron。生产化差异：归档目标换为对象存储、备份调度化、按季度对生产快照演练并记录实际 RPO/RTO。

另注意：当前所有已声明的租户表（包括 `agent_runs`/`agent_run_events`）已启用 FORCE RLS（`0042` 及后续领域迁移）。策略在 `app.campus_id` GUC 未设置时放行（应用层为主边界），事务内 `SET LOCAL app.campus_id = '<uuid>'` 即可武装隔离。两条纪律：生产应用角色绝不可是 superuser（superuser 完全绕过 RLS）；备份/迁移以未武装会话运行即可看到全量数据。

### 原 Runbook 目标（生产化仍需执行）


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

1. 先确认活动校园，再检查该 `campus_id` 下 `moderation_jobs`/ModerationCase 的 oldest pending、processing 卡住时长、`locked_by/locked_until`、重试和 last_error。
2. 判断是 provider、网络、格式、配额还是 worker lease 问题；未到期的 processing 不得被人工抢占，已过期行会由下一轮自动认领。
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
