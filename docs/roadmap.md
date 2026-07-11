# 生产路线图：从当前单实例到可信多校园平台

| 项目 | 内容 |
| --- | --- |
| 适用读者 | 产品负责人、技术负责人、工程师、测试、运营和部署维护者 |
| 当前状态 | 路线图描述目标顺序，不代表阶段已经交付；完成必须满足对应退出门槛 |
| 事实来源 | 当前代码、迁移、设计文档、测试现状和生产架构差距 |
| 最后核对范围 | 生产安全、offer/wanted、推荐、Agent、多租户、事件、实时通信和灾备 |

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
- Dockerfile、演示 Compose、Prometheus metrics 和结构化日志。

当前能力还不是生产就绪。主要差距：

- 没有完整 CampusMembership 和租户隔离。
- Agent 写工具没有统一 ActionPlan 确认协议。
- 进程内事件和 WebSocket 状态不支持可靠多副本。
- 媒体隔离、审核公开门槛、缩略图和 Base64 退出不完整。
- API 缺少统一版本和 cursor；[已实现] 未版本化接口已有兼容旧客户端的稳定错误字段、服务端 request ID，以及 listing 发布幂等，其他写接口仍需收敛。
- 推荐解释、反馈、评估和公平性指标不足。
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

- 新增 Campus 与 CampusMembership，南昌大学作为首个 tenant seed/config。
- 游客可浏览，注册用户可收藏，verified membership 才能发布、联系、加入空间和参与成交。
- 校园运营与平台管理员分离，管理员启用 MFA/近期认证目标。
- 所有普通查询和写入引入 TenantContext，跨校园默认拒绝。

### API 与数据

- [已实现] 当前 `/api/*` 响应提供 `X-Request-ID`，业务错误和框架拒绝提供稳定 `code/message/trace_id`，同时保留旧 `error` 字符串。
- [已实现] `POST /api/listings` 支持 `Idempotency-Key`，同用户同 key 同内容只创建一次，不同内容返回冲突。
- [目标态] 定义 `/api/v1` 嵌套错误对象和 cursor pagination，并把幂等扩展到联系、成交和 Agent confirm 等其余关键写接口。
- 兼容未版本化接口，记录使用量并制定弃用窗口。
- 继续收敛 TEXT/UUID shadow columns：repository 优先 UUID、旧数据兼容、divergence 为零。
- 关键写入添加资源版本或等价冲突检查。

### 媒体与审核

- 新上传默认进入私有对象存储隔离区。
- 校验文件头、MIME、尺寸和解码，审核通过后生成公开 URL 和缩略图。
- Base64 fallback 加指标和 feature flag，不再作为新客户端主路径。
- 建立 ModerationCase 最小模型，先统一机器决定、人工处理和举报关联。

### 运维

- staging/production 配置和密钥完全隔离。
- 建立备份、PITR、恢复演练、密钥轮换和依赖/镜像扫描。
- 定义核心 SLO dashboard、告警 owner 和事故 runbook。
- 数据库 migration 在空库和升级库都验证。

### 退出门槛

- 未认证用户从后端无法发布和联系，不能只靠隐藏 UI。
- 租户隔离集成测试证明 A 校园无法读取/关联 B 校园数据。
- 重复写请求不会创建重复 listing、conversation、message 或 DealRecord。
- 未审核媒体不会公开原始对象，审核失败和 provider 故障有安全降级。
- 恢复演练达到 RPO 15 分钟、RTO 2 小时目标或记录批准的差距。
- 普通 API、Feed、消息和 Agent 指标可观察并有告警。

## Phase 2：可信智能信息流

### 目标

让“出/收”真正形成双向流通闭环，推荐可解释、可反馈、可评估，而不是只按点击和新鲜度堆内容。

### 信息生命周期

- 明确 `IntentItem kind=goods`，完成 wanted fulfilled/reopen 状态和相应 API/UI。
- Response 支持 accepted/dismissed/withdrawn 用户动作和通知。
- wanted 完成后停止新匹配，已有 Thread、Response 和 DealRecord 保留。
- 品牌“不限”改为结构化空值/偏好，不把展示词当数据事实。

### 召回与排序

- 两阶段推荐：硬约束/召回，再排序/多样性。
- 所有检索先过滤 campus、status、direction 和 visibility。
- 返回稳定 `rank_reason`、`match_summary`、排序版本和来源类型。
- 增加隐藏、减少此类、清除个性化信号和非个性化排序入口。
- 防止重复条目、单一类别垄断和自己内容反复出现。

### 评估

- 建立带硬约束真值的离线匹配集。
- 评价 NDCG/Recall 之外的预算满足率、成色满足率、有效响应率、无结果质量和多样性。
- 线上同时观察推荐点击、有效响应、会话质量、wanted 关闭和举报率。
- 排序实验使用版本和小流量开关，可回滚，不把未确认 Agent 推断当兴趣事实。

### 退出门槛

- wanted/offer 的创建、匹配、响应、沟通、完成和重新开启端到端通过。
- 硬约束违反率为零；没有 embedding 时关键词和条件 fallback 可用。
- 每条个性化推荐有用户可理解原因和反馈入口。
- 新排序在质量、信任和公平 guardrail 上不劣于基线。
- Feed/Search p95 在目标容量下小于 500ms。

## Phase 3：Agent 行动系统

### 目标

让 Agent 从“可以调用工具”升级为“有权限等级、确认、幂等、审计和评估的受控行动系统”。

### ActionPlan

- 为 L2/L3 动作新增 AgentActionPlan 和短期 confirmation token。
- 发布、更新、联系和推荐使用一次确认；报价、议价接受、成交确认和隐私公开使用二次确认。
- 计划保存输入快照、资源版本、风险文案版本、过期时间和幂等键。
- 执行时重新校验 membership、tenant、owner、状态和价格。

### 工具收敛

- Agent 工具调用与 HTTP 相同的 service，不直接写 SQL 或复制状态机。
- 工具声明 auth、tenant、risk、side effects、idempotency 和 audit category。
- 回复助手继续保持无工具、只读最近文本、只填草稿不发送。
- Provider 能力建立支持矩阵，写动作不因 LLM 超时自动重试。

### 安全与质量

- 建立 prompt injection、间接注入、跨用户/跨校园、虚假承诺和参数污染测试集。
- AgentRun 记录路由、检索、工具、provider、版本、延迟和结果类别，敏感正文脱敏。
- 无 LLM 时搜索、表单、聊天和成交记录仍可用。
- Agent 变更采用 feature flag 和 canary，越权执行有立即 kill switch。

### 退出门槛

- 所有 L2/L3 工具都经过确认或在生产禁用。
- 重复 confirm 只产生一次业务结果，过期/版本冲突安全失败。
- 越权、跨校园和未确认执行测试为零容忍。
- 离线评估覆盖中文口语、错别字、歧义、无结果、provider 和工具故障。
- Agent 首 token p95 小于 3 秒，失败时用户输入和手工路径保留。

## Phase 4：多校园与水平扩展

### 目标

在可信单校园生产基线之上接入第二所校园，并支持 API 多副本和可靠异步处理。

### 持久事件

- 业务事务同时写 transactional outbox。
- 通知、embedding、审核、搜索投影和 WebSocket fan-out 迁入幂等 worker。
- Worker 支持 lease、指数退避、dead-letter、lag metrics 和受审计重放。
- 进程内 mpsc 只保留为优化，不作为唯一事件通道。

### 多副本实时通信

- Redis 用于分布式限流、WebSocket pub/sub、typing 和短期 call signaling。
- 消息和通知先持久化，socket 只做实时投递。
- 断线和跨实例丢事件通过 HTTP cursor 补偿。
- TURN、权限、弱网和 signaling 多副本完成后，通话才从实验进入稳定。

### 校园运营

- 校园级邮箱域名、分类、审核策略、运营角色和开关可配置。
- 校园运营只能访问本 tenant，跨校园由平台管理员处理并审计。
- 建立新校园 onboarding、数据检查、策略批准、灰度和退出手册。

### 容量与灾备

- 以 10 万注册、1 万日活、数千 socket、数百峰值 RPS 压测。
- 验证数据库连接、锁、向量查询、outbox lag、Redis 和对象存储容量。
- 多副本滚动发布、数据库升级、Redis 故障、provider 故障和区域恢复演练。

### 退出门槛

- 第二校园完成接入，租户隔离测试和运营权限审计通过。
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
| Secret Chat | Phase 1 | 停止宣传/新建，历史兼容和迁移说明完成 |
| 进程内事件 | Phase 4 | 关键消费者全部由 outbox 驱动 |
| 单实例 WebSocket | Phase 4 | Redis fan-out 和断线补偿通过压测 |
| Agent 直接写工具 | Phase 3 | 所有 L2/L3 使用 ActionPlan 或生产禁用 |

## 路线图维护规则

- “完成”必须引用测试、指标或演练证据，不以代码合并代替交付。
- 阶段内工作可以并行，但不能绕过退出门槛扩大下一个风险面。
- 新风险必须归属阶段、owner 和可验证完成定义。
- 产品、架构和信任边界变化时，同步更新相关设计文档。
- 真实容量或用户行为推翻假设时，更新路线图而不是隐藏差距。
