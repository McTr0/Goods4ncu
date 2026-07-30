# 生产路线图：从当前单实例到可信多校园平台

| 项目 | 内容 |
| --- | --- |
| 适用读者 | 产品负责人、技术负责人、工程师、测试、运营和部署维护者 |
| 当前状态 | 路线图描述目标顺序，不代表阶段已经交付；完成必须满足对应退出门槛 |
| 事实来源 | 当前代码、迁移、设计文档、测试现状和生产架构差距 |
| 最后核对范围 | 生产安全、offer/wanted、推荐、Agent、多租户、事件、实时通信和灾备 |

就绪状态的权威汇总（逐门槛证据与部署侧待办清单）见[生产就绪评估报告](production-readiness.md)。

这份路线图以“可以安全交付给真实校园用户”为目标，不按功能数量排序。每个阶段都要先满足前置条件和退出门槛，再扩大下一个风险面。

## 当前基线

[已实现] 当前系统已经具备：

- Rust Axum + Flutter + PostgreSQL/pgvector 模块化单体。
- JWT/JTI、refresh rotation、logout 撤销、封禁和管理员审计。
- offer/wanted 发布、列表、匹配和响应基础能力。
- 分类亲和度、新鲜度和向量相似推荐。
- 联系人 Thread、realtime/mail、消息回复/反应/举报/已读/quote。
- 群组、频道、通话信令和 Secret Chat 原型。
- 多 LLM provider、RAG、市场工具和回复助手。
- 线下成交意向、卖家确认和可选自动下架。
- 同步文本审核、异步媒体审核任务和收款码公开控制。
- ModerationCase、案件事件、用户申诉和平台管理员复核闭环。
- Dockerfile、演示 Compose、Prometheus metrics 和结构化日志。

当前能力还不是生产就绪。主要差距：

- CampusMembership、核心资源校园作用域、后台审核队列、跨校园理由审计和统一 session extractor 已落地。当前 19 张租户表已启用 FORCE RLS（`0042` 及后续领域迁移，`app.campus_id` 事务级 GUC 触发，未设置时放行以保持应用层为主边界），隔离与写拒绝有集成测试；应用侧全请求 GUC 注入（fail-closed）与多副本租户验证仍属 Phase 4。
- Agent 写工具已接入统一 ActionPlan 确认协议（模型只能提出、用户确认才执行，L3 需二次确认）；资源版本快照仍待补。
- WebSocket 跨副本投递已具备（Redis fan-out，双实例端到端验证）；typing/call signaling 多副本化与压测仍待做。outbox 基础与通知推送已持久化，其余事件消费者仍在进程内。
- 媒体隔离、审核公开门槛、缩略图和 Base64 退出不完整；案件事实层已具备，但对象存储隔离仍需生产化。
- API 缺少统一版本和 cursor；[已实现] 未版本化接口已有兼容旧客户端的稳定错误字段、服务端 request ID，以及 listing 发布幂等，其他写接口仍需收敛。
- 首页商品 feed、相似商品、listing wanted matches 与意图撮合均已有统一解释和显式反馈控制；离线质量评估、公平性指标与跨表达软排序仍不足。
- Secret Chat 与服务器可治理通信目标冲突。
- 备份恢复、密钥管理、SLO、告警和事故演练未闭环。

## Phase 0：事实基线与交付纪律

### 目标

让代码、文档、测试和产品语言描述同一个系统，建立后续生产化的可信起点。

### 工作

- 文档使用 `[已实现]`、`[实验中]`、`[目标态]`、`[待弃用]`。
- API 参考与 `src/api/mod.rs` 实际路由逐项核对。
- 数据模型与 migration/service 对齐，修正订单、下架、Secret Chat、UUID 和 offer/wanted 矛盾。
- 用户侧统一“成交记录”语义，不出现支付、发货或平台担保暗示。
- 建立关键旅程测试矩阵：认证、发布、匹配、联系、消息、成交、审核、管理员影响。
- 清理 CI 已知失败，保证格式、check、clippy、Rust tests、Flutter analyze/tests 和 Docker build 有可重复结果。
- 建立设计变更规则：领域、权限、API、配置和 SLO 变化必须同步专题文档。

### 退出门槛

- 文档链接和 Markdown 检查通过。
- 当前接口没有未标记的文档缺口，目标接口不会混入当前 curl 示例。
- 本地主干验证和 CI 结果一致，失败有 owner 和可解释原因。
- Codex Browser 完成桌面/手机核心路径，发现的问题进入回归测试。
- 当前生产风险清单有优先级、owner 和阶段归属。

## Phase 1：生产安全基线

### 目标

在不扩大用户和校园范围前，建立身份、API、媒体、数据和运维的安全边界。

### 身份与授权

- [已实现] 新增 Campus 与 CampusMembership，南昌大学作为首个 tenant seed；历史账号兼容回填，新注册 membership 为 pending。
- [已实现] 学校邮箱 OTP 所有权验证、限流与生产投递配置；更换邮箱后资格回到 pending。
- [已实现] 关键写接口和 Agent 写工具检查 verified membership；游客可浏览，注册用户可收藏。对象存储 STS 凭证（`GET /api/upload/token`）按写接口收敛，`pending` 成员不再能获取 bucket 写权限。
- [已实现] 核心资源采用 `campus_id`，普通市场读取限制到首校园；跨校园联系、空间成员、需求响应和成交被 service 与复合外键拒绝。
- [部分完成] 设备级 active campus session 已通过 JWT claim、refresh token 绑定和 token 轮换实现；平台管理员敏感写操作的 10 分钟密码 step-up 已实现。平台管理员 TOTP MFA 已实现：`POST /api/auth/mfa/totp/setup|confirm` 完成注册（需 admin 角色 + 10 分钟近期认证），确认后 `POST /api/auth/reauth` 除密码外强制要求单次有效动态验证码（RFC 6238，±1 步时钟容差，步进级防重放），已确认因子不可自助更换。资格定期刷新和校园运营 MFA 仍是目标态。
- [已实现] 校园 `operator/admin` 与平台管理员读写边界已分离：校园角色只读本校后台，平台管理员执行敏感写入；跨校园读取和写入需要理由并审计。
- [已实现] 登录用户的核心市场、推荐、公开用户页、通知、直聊、空间和 Agent 路径已使用 active campus session；游客仍使用 NCU public default。后台统计/列表、审核任务和审计已按校园过滤。普通用户 handler 已收敛为统一 extractor（`src/api/session.rs` 的 `Session`/`OptionalSession`/`VerifiedTenant`），零散的手写 token 解析已移除；仅 auth 生命周期、admin scope、审核 scope 等 5 个单点 helper 保留，均委托同一解码函数。

### API 与数据

- [已实现] 当前 `/api/*` 响应提供 `X-Request-ID`，业务错误和框架拒绝提供稳定 `code/message/trace_id`，同时保留旧 `error` 字符串。
- [已实现] `POST /api/listings` 支持 `Idempotency-Key`，同用户同 key 同内容只创建一次，不同内容返回冲突。
- [已实现] `POST /api/orders/{id}/confirm` 支持卖家范围内的 `Idempotency-Key`；重复确认不会重复下架，同 key 改变确认参数会安全冲突。
- [目标态] 定义 `/api/v1` 嵌套错误对象和 cursor pagination，并把幂等扩展到联系、成交和 Agent confirm 等其余关键写接口。
- 兼容未版本化接口，记录使用量并制定弃用窗口。
- 继续收敛 TEXT/UUID shadow columns：repository 优先 UUID、旧数据兼容、divergence 为零。
- 关键写入添加资源版本或等价冲突检查。

### 媒体与审核

- [已实现] 媒体审核任务继承资源 campus，后台队列按校园和状态读取；Worker 的 processing 状态已纳入数据库约束。
- [已实现] 媒体隔离已覆盖 API 与对象存储两层。API 层（`0041`）：提交审核与资源置 `pending` 同事务；商品图与头像在所有公开读取路径按 `approved` 门槛输出，pending/rejected/failed 返回 null，所有者仍可见自己的待审图。存储层（`src/services/storage.rs`）：bucket 私有，服务端按 SigV4 生成短期 presigned URL，仅对 approved 媒体下发；`MEDIA_PRIVATE_BUCKET=true` 启用。已对真实 S3 实现（MinIO）验证：匿名直连 403、未上传 key 亦拒绝、presigned 可取、签名篡改与过期均被拒（`tests/storage_acl_integration.rs`，并纳入生产演练 check 2b）。
- 校验文件头、MIME、尺寸和解码，审核通过后生成公开 URL 和缩略图。
- Base64 fallback 加指标和 feature flag，不再作为新客户端主路径。
- [已实现] `0034_moderation_cases.sql` 建立案件、状态事件和一次性申诉；机器拒绝和聊天举报自动关联，listing/user 也已有 `VerifiedTenant` 举报入口（同校目标由服务端派生、1–80/1000 字限制、每小时 10 条新举报）并与 ModerationCase 同事务关联。未处理的同一举报会更新 standing report，已处理后的新举报创建新 report/case。当前 intake/start_review/dismiss 不改目标状态；listing/user 的通用 restrict/restore 留待 case-owned 可逆 effect 模型，紧急下架/封禁继续走独立近期认证与审计流程。用户可查看安全摘要，平台管理员可审计分诊。
- [下一步] 把管理员下架与用户自行删除从同一个 `deleted` 语义中拆开；owner 的 `relist` 不得恢复仍受审核限制的 listing，恢复必须由 case-owned 可逆 effect 或明确管理员动作完成。

### 运维

- [已实现] 全链路超时边界：HTTP 层 60s 响应超时（504），LLM provider 客户端连接 10s/读 60s 超时，审核与 STS 外呼有各自超时。挂起的 provider 连接不再无限占用请求，熔断器能收到失败信号。
- [已实现] 进程响应 SIGTERM 并按序排空：readiness 先摘流量，监听器后关闭，在途请求自然结束，Worker 在迭代之间退出而不是被 abort。`/api/livez` 与 `/api/readyz` 分离，liveness 不依赖数据库，避免数据库故障触发全副本重启。排空与超时窗口可配置，Docker/Compose 宽限期已对齐。
- [部分完成] staging/production 密钥隔离已有工程强制：`docs/.env.staging.example` 与 `docs/.env.production.example` 模板分离，生产模式启动时拒绝含开发标记（test/example/changeme 等）或低熵的 JWT_SECRET（单元测试覆盖）。真实环境的三套独立数据库/Redis/存储/密钥仍需在部署平台落实。
- [部分完成] 依赖漏洞扫描已落地：`cargo audit` 进入 CI 强制门槛，已修复 aws-lc-sys、rustls-webpki、crossbeam-epoch、protobuf 等 9 个 RUSTSEC 公告，唯一无修复版本的 RUSTSEC-2023-0071（rsa/Marvin）在 `.cargo/audit.toml` 记录了不可达性论证（本服务仅用 HS256）。PITR 恢复演练已可执行且通过（`scripts/backup_pitr_drill.sh`：真实 base backup + WAL 归档 + recovery_target_time，验证灾难行被排除，本机 ~12s）；生产化仍需在真实备份存储上按季度执行并记录 RPO/RTO。镜像扫描和密钥轮换演练仍待建立。
- 定义核心 SLO dashboard、告警 owner 和事故 runbook。
- 数据库 migration 在空库和升级库都验证。

### 退出门槛

- [已实现] 未认证用户从后端无法发布、联系、响应需求、加入空间或创建成交意向，不只依赖隐藏 UI。
- [部分完成] 集成测试已证明 NCU 公开市场无法读取 B 校园 listing、跨校园用户不能创建直聊、子业务事实不能关联另一校园 listing；active session 测试覆盖 token claim、refresh 绑定、切换轮换和旧 access 撤销；推荐、公开主页、通知、校园后台、审核队列和案件/申诉的双校园隔离也有回归覆盖。近期认证测试证明旧/刷新 token 不能执行后台敏感写入。统一 extractor 已落地（`src/api/session.rs`，迁移由全量回归套件验证）。平台管理员 TOTP MFA 已落地并有注册/强制/防重放回归覆盖（`tests/admin_auth_regression.rs`）。RLS 策略已安装并在非超级用户角色下验证隔离与写拒绝（`tests/rls_integration.rs`）；生产应用角色绝不可为 superuser（superuser 完全绕过 RLS）。尚需补充浏览器多运营角色验收矩阵。
- 重复写请求不会创建重复 listing、conversation、message 或 DealRecord。
- [部分完成] API 层已保证未审核媒体不通过任何公开接口返回（回归覆盖 pending/rejected/approved 三态与所有者例外）；对象存储直链的私有化仍需 bucket ACL。审核失败和 provider 故障有安全降级（failed 状态同样不公开）。
- [部分完成] PITR 恢复流程已脚本化并本地演练通过（含验收断言）；对生产级数据量与真实备份存储的 RPO 15 分钟 / RTO 2 小时验证仍需生产环境执行。
- 普通 API、Feed、消息和 Agent 指标可观察并有告警。
- [已实现] SIGTERM 后 readiness 立即失败、liveness 保持通过、在途请求不被截断、Worker 不在事务中途退出；`tests/lifecycle_probes_integration.rs` 覆盖探针状态机。滚动发布的多副本验证仍属 Phase 4。

## Phase 2：可信智能信息流

### 目标

让“出/收”真正形成双向流通闭环，推荐可解释、可反馈、可评估，而不是只按点击和新鲜度堆内容。

### 信息生命周期

- [已实现] wanted fulfilled/reopen：`POST /api/listings/{id}/fulfill` 由所有者把收物需求置为 `fulfilled`（条件状态转移，`0040` 同时为 `inventory.status` 建立 CHECK 并归一化旧 `takedown` 值）；`relist` 可重新开启。移动端详情页在确认后完成需求，“我的发布”读取 `status=all`、标记非 active 状态，使用户离开详情后仍能找回并重开。
- [已实现] Response 用户动作：requester 可在 wanted 详情查看并 accept/dismiss，responder 可查看 sent history 并 withdraw（`/api/wanted-responses/{id}/*`）。动作事务内锁定 response/wanted/offer 并从 `pending` 单赢转移；accept 要求 wanted+offer active，dismiss 要求 wanted active，withdraw 保持 pending-only。列表和动作都由 `VerifiedTenant` 限定活动校园；动作通知携带 wanted 目标，可从通知回到详情。
- [已实现] wanted 完成后停止新匹配（feed/匹配/响应均按 `active` 过滤），已有 Thread、Response 和 DealRecord 保留并有回归覆盖；pending 响应者会收到完成通知。
- [下一步] 给 wanted reopen 引入 lifecycle epoch：关闭时冻结旧 pending response，重开后旧轮次只读，同时允许同一 offer 在新轮次重新响应；response 创建加入幂等 key，并与 wanted active 校验在同一事务完成。
- 品牌“不限”改为结构化空值/偏好，不把展示词当数据事实。

### 召回与排序

- 两阶段推荐：硬约束/召回，再排序/多样性。
- 所有检索先过滤 campus、status、direction 和 visibility。
- [部分完成] 首页商品 Feed 返回 `2026.07-feedback-v2`、服务端人话 `rank_reason` 与稳定 `source`；相似商品返回稳定解释 code 和 `2026.07-similar-feedback-v1`。listing wanted matches 返回 `known_slots_compatible`、只来自已执行硬约束的 `match_summary`、`source=wanted_match` 和 `2026.07-wanted-feedback-v1`。意图 feed/matches 返回稳定解释与 `2026.07-intent-hard-v1`。移动端把稳定 code 本地化为人话，并兼容已有服务端人话原因；不序列化作者、距离、权重或反馈信号。跨表达软排序与置信度校准仍待补。
- [已实现] `feed_feedback`/`feed_preferences` 与未版本化 API 提供隐藏、少推荐这类、不相关、个性化开关和重置。目标与校园由服务端派生；重复反馈幂等更新。在首页商品、相似商品、listing wanted matches 与 intent feed/matches 中，三种 action 精确排除对应资源；`less_like_this` 分别降低同分类、wanted hard-category 内同品牌或同 kind 候选。关闭个性化或重置只停用泛化旧信号，明确反馈仍保留。Flutter 当前推荐与匹配入口均有本地化理由和反馈控件。
- 防止重复条目、单一类别垄断和自己内容反复出现。
- [下一步] 普通 HTTP/Flutter listing 发布也写入 embedding outbox；当前只有 Agent 发布路径保证生成向量，浏览器创建的 wanted/offer 仍可能退化到规则/新鲜度 fallback。

### 评估

- 建立带硬约束真值的离线匹配集。
- 评价 NDCG/Recall 之外的预算满足率、成色满足率、有效响应率、无结果质量和多样性。
- 线上同时观察推荐点击、有效响应、会话质量、wanted 关闭和举报率。
- 排序实验使用版本和小流量开关，可回滚，不把未确认 Agent 推断当兴趣事实。

### 退出门槛

- [已实现] wanted/offer 的创建、匹配、响应（含 accept/dismiss/withdraw）、完成和重新开启已有后端端到端回归。真实双账号浏览器已完成：结构化创建 wanted → seller 从校园 feed 发现 → 推荐三件 active offer → withdraw → requester 从通知进入并 accept/dismiss → 打开 accepted offer → 确认 fulfill → 从“个人→我的发布”找回 fulfilled wanted → reopen → seller 从状态通知回到详情。Flutter 组件另以 `390x844`、200% 文字缩放覆盖动作换行，无溢出。
- 硬约束违反率为零；没有 embedding 时关键词和条件 fallback 可用。
- [已实现] 商品首页、相似商品、listing wanted matches 与意图 feed/matches 的当前移动端路径都有用户可理解原因和反馈入口；未知机器 code 不直接展示。
- 新排序在质量、信任和公平 guardrail 上不劣于基线。
- Feed/Search p95 在目标容量下小于 500ms。

## Phase 3：Agent 行动系统

### 目标

让 Agent 从“可以调用工具”升级为“有权限等级、确认、幂等、审计和评估的受控行动系统”。

### ActionPlan

- [已实现] `0038_agent_action_plans.sql` + `AgentPlanService`：五个写工具（create/update/delete listing、purchase、negotiate）不再直接执行，而是生成 pending 计划（输入快照、L2/L3 风险级、10 分钟过期、单次 confirmation token）。token 只经认证的 `/api/agent/plans` 返回，绝不进入模型可见文本——prompt 注入无法确认模型自己提出的计划。
- [已实现] 确认时通过条件状态转移（pending→executing）保证并发确认只执行一次；重复确认幂等返回原结果；执行体重新校验 membership、owner、商品状态和价格区间，世界状态变化后的确认安全失败。移动端小帮页内提供待确认操作卡片（确认/取消）。
- [已实现] L3 二次确认：purchase/negotiate 计划第一次确认仅置为 confirmed_once 并返回 `needs_second_confirmation`，第二次确认才执行；两步都是条件状态转移，并发无法跳步。移动端弹出高风险二次确认对话框。[目标态] 资源版本快照比对和风险文案版本化。

### 工具收敛

- Agent 工具调用与 HTTP 相同的 service，不直接写 SQL 或复制状态机。
- 工具声明 auth、tenant、risk、side effects、idempotency 和 audit category。
- 回复助手继续保持无工具、只读最近文本、只填草稿不发送。
- Provider 能力建立支持矩阵，写动作不因 LLM 超时自动重试。

### 安全与质量

- [部分完成] 工具层滥用测试集已落地（`tests/agent_injection_regression.rs`）：跨校园购买/议价、参数污染（空/超长标题、越界成色、非正/天价价格、越界出价）、自买自卖、未认证用户提案全部被拒并有零副作用断言；确认 token 与模型文本隔离、跨用户确认拒绝在计划测试中覆盖。execute 体已补齐与 HTTP 相同的输入校验，工具路径不再是校验旁路。针对真实 LLM 的间接注入与虚假承诺评估仍需线上评测集。
- AgentRun 记录路由、检索、工具、provider、版本、延迟和结果类别，敏感正文脱敏。
- 无 LLM 时搜索、表单、聊天和成交记录仍可用。
- Agent 变更采用 feature flag 和 canary，越权执行有立即 kill switch。

### 退出门槛

- [已实现] 所有 L2/L3 写工具经过 ActionPlan 确认；无确认不执行有回归覆盖（`tests/agent_action_plan_integration.rs`）。
- [已实现] 重复 confirm 只产生一次业务结果（幂等返回原结果），过期/取消/跨用户/错误 token 安全失败，确认后状态变化（如商品已售出）不产生业务写入；L3 单次确认不产生任何写入有回归覆盖。
- 越权、跨校园和未确认执行测试为零容忍。
- 离线评估覆盖中文口语、错别字、歧义、无结果、provider 和工具故障。
- Agent 首 token p95 小于 3 秒，失败时用户输入和手工路径保留。

## Phase 4：多校园与水平扩展

### 目标

在可信单校园生产基线之上接入第二所校园，并支持 API 多副本和可靠异步处理。

### 持久事件

- [部分完成] transactional outbox 基础设施已落地（`0037_outbox_events.sql` + `src/services/outbox.rs`）：业务事务内 `enqueue_in_tx`，worker 支持 lease（`FOR UPDATE SKIP LOCKED` + 到期回收）、指数退避、dead-letter 和 `replay_dead_lettered`；原子入队、至少一次投递、租约互斥和重放均有集成测试（`tests/outbox_integration.rs`）。
- [部分完成] 通知推送已迁入 outbox：`NotificationService::create` 与通知行同事务入队 `notification.push`，由 worker 投递 WS，进程崩溃不再丢推送。embedding、审核投影和其余 fan-out 仍待迁移；多副本时 WS 投递还需 Redis pub/sub 把消息路由到持有连接的实例。
- [目标态] lag metrics 告警与 dead-letter 的管理端受审计重放接口。
- 进程内 mpsc 只保留为演示/优化路径，不再承载通知投递。

### 多副本实时通信

- [部分完成] Redis WebSocket pub/sub fan-out 已实现（`redis` feature 默认开启，设置 `REDIS_URL` 即激活）：所有 `broadcast_to_user` 经 Redis 频道路由，每个副本向自己持有的 socket 投递恰好一次；发布失败降级为本地投递。分布式限流在设置 `REDIS_URL` 时启用（Redis 故障降级为单机限流而不是拒绝启动）。跨进程投递已用双实例端到端测试验证：两个真实服务进程共享 Redis+Postgres，A 实例上的真实 WebSocket 客户端收到来自 A 进程之外发布的消息（`tests/ws_fanout_integration.rs`，需 `REDIS_TEST_URL`/`FANOUT_E2E`）。typing 与 call signaling 的多副本化仍待做。
- 消息和通知先持久化，socket 只做实时投递（outbox 已保证通知推送持久）。
- 断线和跨实例丢事件通过 HTTP cursor 补偿。
- TURN、权限、弱网和 signaling 多副本完成后，通话才从实验进入稳定。

### 校园运营

- [部分完成] 校园级邮箱域名已可配置并驱动注册路由：`POST /api/admin/campuses` 由平台管理员创建校园（默认 inactive、审计），`activate/deactivate` 独立审计切换；注册与改邮箱按域名匹配活动校园并落入对应 pending membership，NCU 硬编码已移除。校园级分类/审核策略/运营角色配置仍待做。
- 校园运营只能访问本 tenant，跨校园由平台管理员处理并审计。
- [部分完成] 新校园 onboarding 全旅程已可执行并有端到端回归（`tests/admin_auth_regression.rs::second_campus_onboarding_journey_end_to_end`）：创建（暗启动）→ 激活 → 校园邮箱注册 → OTP 认证 → 本校发布 → NCU 公开面零泄露 → 停用即关闭写入。同一流程已在本机**持久部署**上实跑并可幂等复验（`scripts/deploy_local.sh`：两个已实例化校园、各自私有 bucket、跨校园隔离经 HTTP API 验证）。数据检查/策略批准/退出手册仍属运营文档。

### 容量与灾备

- [部分完成] 容量验证已在 10 万注册量级执行：`scripts/capacity_drill.sh` 以 set-based SQL 播种 10 万用户+资格、6 万双校园商品、10 万通知、3 万收藏（18 秒），对该数据量启动真实服务并跑 SLO 冒烟——列表 p95 57ms（SLO 300ms）、Feed p95 15ms（SLO 500ms）全部通过，证明查询路径与索引在目标注册规模下成立。数百 RPS 持续压测与真实用户行为分布仍需生产硬件。
- 验证数据库连接、锁、向量查询、outbox lag、Redis 和对象存储容量。
- [部分完成] 多副本滚动发布已本机演练通过（`scripts/production_rehearsal.sh`：双生产模式副本、滚动重启零失败、空库引导、SLO 冒烟、PITR，一次通过；并借此发现并修复了双副本并发建 pgvector 扩展的引导竞态）。数据库升级、Redis 故障注入、provider 故障与区域恢复演练仍待生产环境执行。

### 退出门槛

- [部分完成] 第二校园接入路径已实现并端到端验证（创建/激活/注册路由/认证/发布/隔离/停用，全程审计）。基础设施级租户隔离也已用真实服务验证：两套独立 Postgres 集群互不可见、每校园独立 bucket + 受限 IAM 凭据（跨租户读与跨租户 presign 均被拒、匿名 403），见 `scripts/tenant_isolation_drill.sh`。真实第二校园的生产接入与其运营验收仍需实际执行。
- 任一 API replica 下线不丢持久消息、通知或 outbox event。
- 在线消息持久化后投递 p95 小于 1 秒，断线补偿无重复用户可见消息。
- 月度 99.9% SLO 有 dashboard、错误预算和处理流程。
- 备份、恢复、密钥轮换、canary 和 rollback 完成演练。

## 暂不进入当前阶段

以下方向不在首个生产交付中，只有在核心闭环和治理指标稳定后重新评审：

- 平台托管支付、结算、退款、物流和赔付。
- 服务、技能、活动、互助和知识等新 IntentItem kind。
- 大型公开群、机器人平台、群组通话和 SFU。
- 无人监督的 Agent 主动联系、议价或成交。
- 服务器不可解密的生产私聊。
- 因“未来可能很大”而提前拆分微服务或独立搜索集群。

## 跨阶段技术债

| 技术债 | 所属阶段 | 完成定义 |
| --- | --- | --- |
| TEXT/UUID 并存 | Phase 1 | 新写 UUID、旧数据兼容、核心 join 和 divergence 检查通过 |
| Base64 fallback | Phase 1 | 新客户端零使用、指标验证后再迁移/删除 |
| user_chat 大模块 | Phase 0–3 | 行为测试后按消息、媒体、状态和空间拆分 |
| Secret Chat | Phase 1 | [已实现] 新建默认 403（`SECRET_CHAT_NEW_SESSIONS_ENABLED` 仅迁移窗口可开），移动端入口已移除，历史会话可读有回归覆盖 |
| 进程内事件 | Phase 4 | [部分完成] outbox 基础设施与通知推送已迁移并有回归覆盖；embedding/搜索投影等其余消费者仍待迁移 |
| 单实例 WebSocket | Phase 4 | [部分完成] Redis fan-out 已实现并通过双实例端到端测试；断线补偿依赖既有 HTTP 拉取，压测仍待做 |
| Agent 直接写工具 | Phase 3 | [已实现] 五个 L2/L3 写工具全部经 ActionPlan 确认执行，工具级与计划级回归覆盖 |

## 路线图维护规则

- “完成”必须引用测试、指标或演练证据，不以代码合并代替交付。
- 阶段内工作可以并行，但不能绕过退出门槛扩大下一个风险面。
- 新风险必须归属阶段、owner 和可验证完成定义。
- 产品、架构和信任边界变化时，同步更新相关设计文档。
- 真实容量或用户行为推翻假设时，更新路线图而不是隐藏差距。
