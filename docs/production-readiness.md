# 生产就绪评估报告

| 项目 | 内容 |
| --- | --- |
| 适用读者 | 决定是否上线的负责人、执行部署的工程师、验收测试者 |
| 当前状态 | 工程门槛已由 CI 自动化；只有目标提交的 CI 全绿才可部署；生产资源开通、真实学生效果/公平性验证与人工运营验收仍待完成 |
| 事实来源 | 本仓库 Rust/Flutter 测试、`scripts/` 下可执行演练（含真实 MinIO/Redis/Postgres）、迁移 0001–0112 |
| 验收方式 | 每一项都给出可执行证据；无证据的项目明确标注为部署侧待办 |

本报告把[生产路线图](roadmap.md)的全部退出门槛折叠为一张就绪矩阵。“代码侧关闭”指该门槛由本仓库的代码、schema、测试或可重复脚本强制并验证；“部署侧待办”指需要真实基础设施、账号或人工运营才能执行的验收步骤，本仓库已为其准备了可直接运行的验收程序。

## 一、代码侧已关闭的门槛（含证据）

### 身份与租户

| 门槛 | 证据 |
| --- | --- |
| 统一 session extractor（Session/OptionalSession/VerifiedTenant） | `src/api/session.rs`；全量回归套件 |
| 平台管理员 TOTP MFA（注册/确认/step-up 强制/防重放） | `tests/admin_auth_regression.rs`（RFC 4226/6238 向量见 `src/services/totp.rs`） |
| 鉴权中间件性能硬化（JTI 30s 与用户状态 15s Moka 本地缓存，消除每请求 DB 读放大） | `src/services/token_denylist.rs`，`src/api/auth.rs`；单元测试覆盖缓存命中、Token 撤销与封禁即时失效 |
| 关键写接口 verified membership 门禁（含 STS 凭证） | `tests/api_regressions.rs::upload_token_requires_verified_campus_membership` |
| 租户表 FORCE RLS（事务级 `app.campus_id` 武装，含 legacy persona asset 表） | `migrations/0042` 及后续领域迁移 + `tests/rls_integration.rs`（读隐藏、写拒绝与 feed controls 隔离） |
| 应用以 NOSUPERUSER 角色运行，RLS 对其真实生效；pgvector 由管理员预装 | `scripts/provision_app_role.sh`（校验两条不变量）+ 生产演练 check 2d；`src/db.rs` 在缺失扩展时给出可执行修复指引 |
| 双校园隔离（市场/推荐/通知/直聊/后台/审核/案件） | `tests/tenant_scope_integration.rs`、`tests/api_regressions.rs`、`tests/admin_auth_regression.rs` |
| 生产密钥卫生（开发标记/低熵 JWT_SECRET 拒绝启动） | `src/config.rs` 单元测试 + `scripts/production_rehearsal.sh` check 0（真实二进制验证） |

### 媒体与内容安全

| 门槛 | 证据 |
| --- | --- |
| API 层媒体隔离：pending/rejected/failed 不经任何公开接口输出 | `migrations/0041` + `tests/api_regressions.rs::unapproved_media_is_not_served_publicly` |
| 存储层媒体隔离：生产强制私有 bucket + presigned PUT/serving（匿名 403/篡改拒绝/过期拒绝，对真实 S3 验证） | `src/config.rs::validate_media_storage_config` fail-fast + `src/services/storage.rs` + `tests/storage_acl_integration.rs` + 生产演练 check 2b |
| 提交审核与资源置 pending 同事务（崩溃不产生“永不审核却公开”） | `tests/api_regressions.rs::image_submission_quarantines_resource_with_job` |
| 生产图片审核配置不完整时 fail-fast | `src/config.rs::validate_image_moderation_config` 单元回归；`scripts/production_rehearsal.sh` 明确关闭未接入的外部 provider |
| SocialPersona 只使用系统角色/皮肤目录 | `0080_system_persona_catalog_only`、`/api/persona/catalog`、`tests/social_persona_integration.rs`；服务端目录与写入白名单一致，旧用户素材撤销、公开引用清空，旧 assets 上传路由不再注册，公开投影只返回静态 token |
| 审核 worker 崩溃恢复与低基数可观测性 | `0069_moderation_job_leases.sql`、`tests/moderation_worker_integration.rs`；`src/api/metrics.rs` 暴露 job outcome、provider latency、pending/processing depth 和 oldest age，且不含 job/campus/provider 高基数标签；`scripts/production_rehearsal.sh` check 1 验证双副本实际暴露队列 gauge |
| listing case-owned 组合限制：紧急 manual case、案件 restrict/restore、申诉单 case 释放、owner relist 门禁、全公开/交易面 fail-closed、并发与跨校园隔离 | `0056_listing_restriction_effects.sql`；`tests/admin_auth_regression.rs::{listing_restrictions_compose_and_never_overwrite_owner_lifecycle,listing_appeal_releases_only_the_appealed_case_effect,admin_listing_restriction_http_contract_gates_public_and_commercial_paths,restricted_wanted_keeps_its_current_epoch_pending_response_frozen,concurrent_manual_restore_and_appeal_review_release_once_without_deadlock}`；`tests/rls_integration.rs::armed_tenant_context_isolates_listing_restriction_effects` |
| Secret Chat 弃用（默认 403 新建、移动端入口移除、历史可读） | `tests/api_regressions.rs::secret_chat_creation_is_disabled_by_default_but_history_stays_readable` |

### Agent 行动系统（Phase 3）

| 门槛 | 证据 |
| --- | --- |
| 可恢复发布立即执行并可撤销；update/delete L2 与 purchase/negotiate L3 才经 ActionPlan，提案保存 listing 版本并在确认时防止 stale write，未确认计划零执行 | `tests/agent_action_plan_integration.rs`、`tests/undo_integration.rs`、`tests/agent_tools_auth_regression.rs` |
| confirmation token 与模型可见文本隔离（prompt 注入不可自确认） | 同上（token 不出现于模型回复的断言） |
| L3 独立两步 token；primary 重试不执行；并发 second token 单赢且终态稳定 | `tests/agent_action_plan_integration.rs::{l3_plan_requires_two_confirmations_before_any_write,retrying_the_primary_l3_token_never_executes_and_replays_the_same_second_token,concurrent_second_token_confirms_share_one_stable_terminal_result}` |
| 计划绑定原校园；终态写失败时业务事实与计划状态原子回滚，可用同一 second token 重试 | `tests/agent_action_plan_integration.rs::{plans_are_not_visible_or_confirmable_from_another_campus,terminal_plan_update_failure_rolls_back_the_domain_fact_and_is_safely_retryable}` |
| 工具层滥用测试集（跨校园/参数污染/自买自卖/未认证） | `tests/agent_injection_regression.rs` |
| AgentRun 安全 envelope（trace 幂等、租户隔离、路由/provider/版本/检索/工具/终态聚合、SSE TTFT、取消结案、无正文事件、有界 token 计数、stale-run durable reconciliation） | `migrations/0077_agent_runs.sql`、`0078_agent_runs_campus_cleanup.sql`、`tests/agent_run_integration.rs`；provider 侧 TTFT、设备/重新认证绑定、版本化风险文案和对账界面仍为后续门槛 |
| Agent 记忆语义检索 HNSW 索引 | `migrations/0112_agent_memories_hnsw_idx.sql`；pgvector 余弦相似度加速（`<=>`） |

### 信息流闭环（Phase 2）

| 门槛 | 证据 |
| --- | --- |
| wanted fulfill/delete/reopen epoch 生命周期（匹配停止、旧轮冻结、epoch 增量、同 offer 新轮一次、响应者通知） | `tests/api_regressions.rs::wanted_fulfill_and_reopen_lifecycle`、`wanted_response_creation_serializes_with_close_and_same_round_duplicates` |
| Response accept/dismiss/withdraw（当前轮单赢转移、closed 轮稳定 409、对方通知、无归属泄露） | `tests/api_regressions.rs::wanted_response_actions_transition_once_and_notify`、`wanted_response_http_journey_lists_statuses_and_gates_actions` |
| Response 幂等与客户端 fail-closed（`Idempotency-Key/replayed`、nullable legacy、`available_actions`、coded 409 刷新） | `tests/api_regressions.rs::wanted_fulfill_and_reopen_lifecycle`；`mobile/test/models/wanted_response_test.dart`、`mobile/test/pages/listing_detail_page_test.dart`、`mobile/test/services/listing_service_wanted_response_test.dart` |
| 首页、相似商品与 wanted matches 带版本化解释、消费反馈并在移动端展示 | `tests/api_regressions.rs::recommendation_feed_explains_ranking`、`similar_recommendations_apply_feedback_to_vector_and_recency_paths`、`wanted_matches_are_versioned_private_and_feedback_aware`；`mobile/test/components/recommendation_carousel_test.dart`、`mobile/test/pages/listing_detail_page_test.dart` |

### 运行与可靠性

| 门槛 | 证据 |
| --- | --- |
| SIGTERM 有序排空（readiness 先摘流、worker 迭代间退出、监听后关） | `tests/lifecycle_probes_integration.rs` + rehearsal check 5 |
| 全链路超时（HTTP 60s→504；LLM 连接 10s/读 60s；外呼各自超时） | `src/llm/mod.rs`、`src/api/mod.rs`（运行验证见 operations.md） |
| Transactional outbox（原子入队/至少一次/退避/死信/租约/重放/Lag 指标/管理员重放接口） | `tests/outbox_integration.rs`；通知推送已迁入；`src/api/metrics.rs`（暴露 queue depth 与 oldest age）；`GET/POST /api/admin/outbox/*`（带审计重试） |
| Redis WS fan-out 跨副本投递（双真实进程 + 真实 WebSocket 客户端） | `tests/ws_fanout_integration.rs`（`REDIS_TEST_URL`/`FANOUT_E2E` 门控） |
| 依赖漏洞门禁（cargo audit 进 CI；唯一 ignore 附不可达论证） | `.cargo/audit.toml`、`.github/workflows/ci.yml` |
| 空库/升级库迁移均验证（含真实升级库上的 legacy 值归一化） | CI migration job 对 `0001`–`0112` 从空库顺序执行；历史升级路径由 0040/0041 回归覆盖，AgentRun、ActionPlan、统一帖子模型和 runtime v2 outcomes 的领域回归覆盖后续迁移；生产 rehearsal 继续作为发布前真实 Postgres/Redis/MinIO 验收。 |

### 多校园与规模（Phase 4 工程部分）

| 门槛 | 证据 |
| --- | --- |
| 校园 onboarding 全旅程（创建暗启动→激活→域名路由注册→OTP→本校发布→零泄露→停用关写） | `tests/admin_auth_regression.rs::second_campus_onboarding_journey_end_to_end` |
| 双副本生产模式引导（含并发建扩展竞态修复）、滚动重启零失败、SLO、PITR、一键复验 | `scripts/production_rehearsal.sh`（两次连续通过） |
| 10 万注册规模容量验证（列表 p95 57ms / Feed 15ms，SLO 300/500ms） | `scripts/capacity_drill.sh` |
| PITR 恢复演练（base backup + WAL 归档 + 目标时间恢复 + 验收断言） | `scripts/backup_pitr_drill.sh` |
| 多租户基础设施隔离：两套独立 Postgres 集群 + 每校园独立 bucket/受限凭据（跨租户读拒绝、跨租户 presign 拒绝、匿名 403） | `scripts/tenant_isolation_drill.sh`（真实 Postgres×2 + MinIO IAM，6 项断言全通过） |
| **持久部署 + 两个已实例化校园**：常驻双副本、NOSUPERUSER 角色、Redis、每校园私有 bucket；第二校园经 admin API 创建并激活，两校成员按邮箱域路由注册并认证、各自发布，跨校园隔离经 **HTTP API** 验证 | `scripts/deploy_local.sh`（幂等；重启后状态与校园/成员/商品不重复，实测两校成员互不可见、公开面不泄露） |

## 二、部署侧待办（本仓库无法代为执行，已备好验收程序）

| 待办 | 为什么必须在部署环境 | 就绪的验收程序 |
| --- | --- | --- |
| 生产角色目录发布 | 需平台运营确认目录版本、标签、下线和回滚流程；当前角色/皮肤不依赖用户上传或 CDN，媒体 bucket 只服务商品、头像和共享对象 | `/api/persona/catalog` 快照 + 目录 token 回归；任何未知 token、URL 或图片输入都应被拒绝 |
| 真实图片审核 provider 开通与回写验收 | 仍适用于商品、头像和共享对象；不再为 SocialPersona 角色/皮肤开放用户图片上传 | `MODERATION_IMAGE_ENABLED=true` + 现有媒体回归；Persona 使用目录选择验收 |
| staging/production 独立实例的生产开通 | 需部署平台的实例与 secret manager；隔离模型本身已用两套真实独立集群 + 每校园独立 bucket 验证 | `scripts/tenant_isolation_drill.sh`（对生产端点重跑即验收）+ `.env.staging.example` / `.env.production.example` |
| 生产级持续压测（数百 RPS、真实行为分布） | 需生产硬件与真实流量形态 | `scripts/load_smoke.sh` / `scripts/capacity_drill.sh` 作为基线与门槛 |
| 真实第二校园运营接入 | 需要该校的邮箱域、运营人员与政策批准；接入机制已在持久部署上以两个已实例化校园实跑验证 | `scripts/deploy_local.sh` 的校园创建/激活/成员认证段即为运营接入手册 |
| 季度恢复演练、密钥轮换、事故演练 | 人工运营流程 | `backup_pitr_drill.sh` + operations.md runbook |
| 浏览器端多角色验收矩阵 | 人工验收 | 旅程清单见 roadmap Phase 0/1 |
| 上线合规复核（政策/隐私/法务） | 人的判断与签字 | trust-safety.md 明确不自称合规 |

## 三、结论

工程门槛已由测试、脚本和 CI 固定；单次历史通过不代表任意新提交可发布，目标提交必须先取得完整 CI 成功结论，部署 workflow 才会运行。`scripts/production_rehearsal.sh` 与 `scripts/capacity_drill.sh` 是发布验收的一部分。上线决定所需的剩余工作属于第二节——基础设施开通与人工运营验收；在真实环境重跑并全部通过之前，不应宣布对真实用户开放。
