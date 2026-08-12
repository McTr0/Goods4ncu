# 信息模型：意图、匹配与流转事实

| 项目 | 内容 |
| --- | --- |
| 适用读者 | 产品经理、后端工程师、数据工程师、测试工程师和需要理解状态机的移动端工程师 |
| 当前状态 | 统一意图、活动校园 session、审核案件/申诉、管理员 MFA、RLS 与显式信息流反馈均已实现；全请求 fail-closed tenant context 和真实用户质量评估仍待完成 |
| 事实来源 | `migrations/`、repository 查询、service 状态转换和 API JSON 模型 |
| 最后核对范围 | 迁移 `0001` 至 `0055`，商品、意图、信息流、聊天、成交、通知、审核、管理和 Agent 相关代码 |

这篇文档定义平台中“什么是事实、事实如何变化、哪些对象可以互相引用”。API 字段见 [API 参考](api-reference.md)，用户流程见 [业务流程](domain-flows.md)。

## 建模原则

1. 用户输入、系统推断和最终事实必须分开保存。
2. “出”和“收”是同一种信息意图的两个方向，不是两个互不相干的产品。
3. 匹配是可重新计算的结果，不是成交事实。
4. 聊天文本不构成正式报价或成交确认，`DealRecord` 才是平台记录的业务事实。
5. Agent 不能直接创造高风险事实，只能生成计划并调用受权限控制的 service。
6. 所有校园范围数据都必须能回答“属于哪个 campus”。
7. 关系空间中的事实先来自用户动作和确定性领域事件，AI 摘要只是带来源的投影。
8. 校园认证身份、用户自述和角色化外观必须分层，角色不能充当身份验证。
9. 注意力与人格不能从阅读、输入、在线或消息历史中推断为公开事实。

## 领域总图

```mermaid
flowchart LR
    User[User] --> Membership[CampusMembership]
    Membership --> Campus[Campus]
    Membership --> Intent[IntentItem]
    Intent --> Match[Match]
    Match --> Response[Response]
    Response --> Conversation[Conversation / Thread]
    User --> Persona[SocialPersona]
    Conversation --> Relationship[Relationship / Space]
    Persona --> Relationship
    Relationship --> SpaceEvent[SpaceEvent projection]
    SpaceEvent --> Memory[MemoryIndex]
    SpaceEvent --> Shared[SharedObject]
    Conversation --> Deal[DealRecord]
    Intent --> Moderation[ModerationCase]
    Conversation --> Moderation
    User --> AgentRun[AgentRun]
    AgentRun --> ActionPlan[AgentActionPlan]
    ActionPlan --> Intent
    ActionPlan --> Conversation
    ActionPlan --> Deal
    Intent --> Event[Audit / Domain Event]
    Deal --> Event
    Moderation --> Event
```

图中的箭头表示业务关联，不表示每个对象当前都有独立数据库表。下面会明确当前映射和目标映射。

## 核心对象

### Campus 与 CampusMembership

[已实现] `Campus` 是租户与策略边界，当前保存学校标识、展示名称、允许的邮箱域名和启用状态。校园级分类、审核策略版本和时区覆盖仍是目标态。

[已实现] `CampusMembership` 表示一个全局用户在某个校园中的资格：

```text
user_id
campus_id
status: pending | verified | suspended | revoked
role: member | operator | admin
verification_method
verified_at
created_at / updated_at
```

用户可以拥有多个 membership，但每次请求必须有明确的 active campus context。跨校园读取默认禁止；管理员跨租户访问必须带审计原因。

[已实现] `campuses`、`campus_memberships`、学校邮箱 OTP、核心/通知/审核/审计 tenant 字段和设备级 active campus session 已落地；access claim 与 refresh session 保存同一 campus，切换时轮换 token，业务执行时再次验证 membership。推荐、公开用户页面和通知读取使用该校园。后台读权限使用 membership 的 `operator|admin`，平台写权限仍由全局用户角色控制。平台管理员近期认证与 TOTP MFA、关键 tenant 表的 FORCE RLS 也已落地。[目标态] membership 到期/定期刷新和所有应用查询自动注入 fail-closed RLS context 仍未完成。

### IntentItem

`IntentItem` 是用户希望信息如何流动的声明。当前 `intents` 是统一事实表，`inventory` 是 goods 意图兼容现有市场浏览面的投影；旧 listing API 继续可用。

| 字段 | 含义 | 当前映射 |
| --- | --- | --- |
| `id` | 意图稳定标识 | `intents.id`（UUID） |
| `campus_id` | 所属校园 | `intents.campus_id`，由活动 tenant context 写入 |
| `author_id` | 声明意图的人 | `intents.author_id`；他人 feed/matches 响应不序列化此字段 |
| `kind` | `goods_offer | goods_seek | companion | help | activity` | 数据库 CHECK 与 service 枚举共同约束 |
| `raw_input` | 用户原始表达 | 原文保存，允许未来重新解析 |
| `slots` | 结构化但允许模糊/缺失的槽位 | JSONB；价格、时间等支持 `whatever/flexible` 语义 |
| `confidence` | 对槽位解析的置信度 | 0–1；这是解析置信度，不是匹配分数 |
| `status` | 生命周期状态 | `draft | active | fulfilled | withdrawn | expired` |
| `visibility` | `campus | private` | 只有 active、未过期、campus 可见意图进入公共撮合池 |
| `valid_until` | 可选失效时间 | 过期后不再进入 feed/matches |
| `projected_listing_id` | goods 投影链接 | 一对一唯一索引指向兼容的 `inventory` 条目 |

新增 kind 或 slot 时仍必须先定义 schema、匹配语义和审核规则，不能把未知结构直接作为公开事实上线。listing 发布幂等继续由 `inventory.idempotency_key/idempotency_hash` 承担。

### Match

`Match` 表示系统在某一时刻计算出的“某条 wanted 与某条 offer 可能适配”。它不是用户承诺，也不是永久关系。

```text
wanted_id
offer_id
campus_id
hard_constraints_passed
score
reason_codes[]
model_version
computed_at
expires_at
```

[已实现] 当前 `/api/listings/{wanted_id}/matches` 实时查询 active offer，并按分类、预算、成色、关键词/向量和新鲜度匹配；`/api/intents/{id}/matches` 对五种 intent kind 先执行校园、生命周期和已声明 slots 的确定性硬约束。

[已实现] wanted 与 offer 必须属于同一 `campus_id`；`wanted_responses` 同时保存 tenant，并用复合外键约束两侧 listing。

[部分完成] intent feed/matches 与 listing wanted matches 已返回稳定 `rank_reason`、`match_summary`、`source` 和 `ranking_version`，原因只来自公开生命周期和双方已声明/实际执行的硬约束。首页与相似商品推荐也返回排序原因和独立版本。短期物化、跨表达软匹配、置信度校准、离线评估和公平性 guardrail 仍待完成；不得保存敏感用户画像作为公开原因。

### FeedFeedback 与 FeedPreferences

[已实现] `feed_feedback` 保存用户对一个 listing 或 intent 的显式指令：`hide | less_like_this | not_relevant`。`campus_id` 和分类/kind `signal_key` 均由服务端根据活动校园和目标资源派生；同一用户、校园和资源只有一条 standing signal，重试或改选 action 使用 upsert。

在首页商品 feed、相似商品、listing wanted matches 与 intent feed/matches 中，三种 action 都会对该用户精确排除该资源；`less_like_this` 还会降低同分类、wanted hard-category 内同品牌或同 kind 候选的顺序。wanted 的品牌信号不是客户端或公开画像提供，而是查询时把该用户自己的 feedback 目标安全连接回同校园 inventory 后派生。`feed_preferences.personalization_enabled=false` 会停用泛化亲和/降权，但保留所有入口的精确排除。`signals_reset_at` 让此前的收藏、买家成交意向和“少推荐这类”不再参与排序，不删除这些业务记录，也不恢复明确反馈过的具体资源。

### Response

`Response` 是用户对 Match 或 IntentItem 的明确动作。当前 `wanted_responses` 表保存提供方把自己的 offer 推荐给 wanted 的事实。

核心字段与约束为：

```text
status = pending | accepted | dismissed | withdrawn
lifecycle_epoch = positive bigint | NULL(ambiguous legacy history)
idempotency_key/idempotency_hash = both NULL or both present

pending -> accepted
pending -> dismissed
pending -> withdrawn
```

`inventory.lifecycle_epoch` 是 wanted 当前轮次，初始为 1，并在 wanted 每次从非 active 重新开启时原子加一。Response 创建时从锁定的 wanted 捕获 epoch，不能由客户端指定。数据库对所有非空 epoch 强制 `(wanted_listing_id, lifecycle_epoch, offer_listing_id)` 唯一，因此同一 offer 在一个轮次中终态后也不能再次响应，只能在下一轮重新创建。

Response 的 `status` 与所属轮次的可操作性是两个维度：

```text
round_state = current
  iff wanted.status = active
      AND response.lifecycle_epoch IS NOT NULL
      AND response.lifecycle_epoch = wanted.lifecycle_epoch

round_state = closed
  otherwise
```

`status=pending, round_state=closed` 是合法且必要的历史状态：它表示 wanted 已关闭、重开到下一轮，或 legacy 轮次无法证明，而不是仍可 withdraw。API 根据调用角色和当前事实返回 `available_actions`；closed 或非 pending Response 必须为空。旧轮动作返回稳定的 `409 wanted_response_round_closed`。

升级前可能存在同一 wanted/offer 的多条终态历史，且没有 reopen 事件可重建轮次。因此 `wanted_responses.lifecycle_epoch` 有意保持 nullable：迁移只回填能证明属于当前 active 轮次且满足唯一性的行，其他 legacy history 保持 NULL/read-only。这个 NULL 不是“当前轮未知”，而是明确的保守关闭标记。

创建接口支持 `(campus_id, responder_id, idempotency_key)` 作用域内的幂等。相同 key 和规范化 wanted/offer/message 重试返回原 response id 与 `replayed=true`；key 改变含义时冲突。接受 response 不自动创建成交记录，也不自动发送消息；它只代表需求方认可这条候选信息。

### Conversation 与 Thread

`Conversation` 是一次独立沟通的业务事实，模式为 realtime 或 mail。`Thread` 是按对方用户聚合的产品视图，不合并底层状态机和消息历史。

| 概念 | 是否持久化 | 作用 |
| --- | --- | --- |
| Conversation | 是 | 保存参与者、模式、状态、商品上下文、主题和过期时间 |
| ConversationMember | 是 | 保存成员级归档和迁移期兼容字段；read API 兼容窗口不再写入公开阅读事实 |
| MessageAcknowledgement | 是 | 接收方主动选择的收到/我会看/已处理；每消息每用户最多一条，可替换或撤销 |
| ConversationEvent | 是 | 记录握手、关闭和过期等转换 |
| Thread | 查询聚合 | 让同一聊天对象在收件箱只出现一次 |
| Message | 是 | 保存文本、媒体引用、回复、quote、编辑和审核状态 |
| LocalSeen | 否（设备本地） | 接收端自己的阅读位置，不上传、不广播 |
| Acknowledgement | 是（用户主动） | `received`、`will_review` 或 `completed`，可替换或撤销 |

Conversation 终止后不可复活。重新联系会创建新 Conversation，但仍显示在同一个 Thread 中。

目标态下，`Conversation` 仍然是一次留言或连接的边界；`Thread` 只是关系级查询聚合。服务器只公开消息已成功持久化的技术事实和用户主动发出的 acknowledgement，不从页面打开、Push、解密、媒体播放或键盘活动推导“已读”。多设备可以各自维护 `LocalSeen`，因此设备间的新留言提示允许暂时不同步，以换取更清晰的隐私边界。

### SocialPersona、RelationshipSpace 与 SpaceEvent

[部分实现] `SocialPersona` 是用户在某个校园中的角色化呈现，不是账号、membership 或 Agent 身份。当前迁移 `0063_social_personas` 已落地每用户每校园一条记录：

```text
id / user_id / campus_id
representation_mode: trait_mapped | role_character
style_version: v1
appearance_config             # palette / silhouette / accessory / outfit 白名单
self_descriptions[]           # 最多三个用户主动选择的标签
contact_posture               # leave_message | connection_allowed | busy | later
status: draft | published | archived
published_at / created_at / updated_at
```

`contact_posture` 可以表达可留言、可请求连接、忙或稍后，但不能保存或派生 online、last seen、typing 或 read。角色素材复用媒体隔离与审核；`representation_mode` 只是展示披露，不证明外貌真实性。用户未发布分身时继续使用普通头像和文字资料，核心联系能力不能被 AI 生成服务绑架。

当前 API 通过 `VerifiedTenant` 只允许活动校园的 verified member 创建、编辑、发布和归档；草稿只对本人返回，公开接口只返回同一校园中已发布的配置。每次创建、编辑、发布和归档都写入 `social_persona_audits`。`archived` 会恢复普通头像展示。图片候选、照片风格化、资产审核和 `approved_asset_id` 仍是后续迁移，不应在当前客户端自行假设。

`Relationship` 表示同一校园内两个人之间的长期入口；`RelationshipSpace` 是它的交互投影。当前没有必要立刻新增权威关系表：`campus_id + 无序用户对` 的 Thread 聚合可以作为迁移桥梁，屏蔽、membership 和可见性依旧由现有事实控制。当前 API 已在活动校园作用域返回只读 `relationship_key`（`relationship:v1:{campus}:{lo}:{hi}`）；它只用于投影缓存和未来 cursor 的关联，不授予权限，也不代表在线或注意力状态。

```text
RelationshipSpace
├── Participants / SocialPersona refs
├── Conversations / Sessions
├── SpaceEvents
├── SharedObjects
└── MemoryIndex projections
```

`SpaceEvent` 统一描述可以回放的空间变化，例如 `message.sent`、`connection.started`、`connection.ended`、`file.shared`、`link.shared`、`memory.pinned`、`acknowledgement.changed` 和 `shared_object.updated`。首阶段它只是从 `chat_messages`、`chat_conversation_events`、quote、reaction 和领域对象派生的只读投影，不另建一套可能与原表分叉的事实。若后续成为通用写模型，必须具备全局事件 id、aggregate/version、campus、actor、source reference、幂等键和 cursor，并与业务写入同事务提交。

`SharedObject` 是双方围绕某件事互动的稳定入口，可以引用商品、文件、链接、地点或约定。它不复制权威业务状态：listing 价格与状态从 `IntentItem/inventory` 读取，成交从 `DealRecord` 读取，双方共识必须记录谁明确采纳。模型从对话抽取出的地点、时间或价格只能先形成 proposal，不能直接写成 agreed value。

`MemoryIndex` 有两层：

- 确定性索引：时间、连接起止、文件、链接、结构化 quote、用户 Pin 和 SharedObject 变更，可由原始事件完全重建。
- 可选语义索引：主题、摘要和自然语言检索结果，每条必须保存 `source_event_ids`、模型/规则版本与生成时间。

源事件删除、隐藏、跨校园、权限变化或审核限制后，对应投影必须失效或重建。语义摘要不能反向成为消息、约定、成交或用户人格事实；LLM 是索引，不是 source of truth。

### DealRecord

当前数据库和 API 仍使用 `orders`，产品语义已经是线下成交记录。文档统一称为 `DealRecord`，避免暗示平台支付或履约。

```text
intent_pending -> confirmed
intent_pending -> cancelled
confirmed -> cancelled
```

- 创建 `intent_pending` 不改变 offer 状态。
- 卖家确认时可以选择自动把 offer 标为 sold。
- 平台不保存“已付款”“已发货”作为新业务状态；旧状态只做兼容映射。
- 聊天消息、收款码展示和 Agent 回复都不能替代卖家确认。

### ModerationCase

[已实现] `ModerationCase` 统一承载机器图片拒绝、聊天消息举报、商品举报、用户举报、人工处置和申诉：

```text
open -> reviewing -> actioned | dismissed
actioned -> appealed -> resolved
appealed -> resolved
```

Case 保存校园、资源引用、来源引用、机器或人工判断、公开理由、受限的内部证据、处置结果和事件时间线。`moderation_appeals` 保存一次性申诉和独立复核结果；普通用户接口不返回举报人身份或 `internal_details`。`content_reports` 承载商品/用户举报，`chat_message_reports` 承载消息举报，两者都在同一事务中关联统一案件，并在案件流转时同步举报状态。

listing 已使用 case-owned、可组合的 `listing_restriction_effects`：effect 保存 campus、listing、唯一 case、创建人/时间和释放人/时间；有效性由 `released_at IS NULL` 表示。`inventory.status` 不承载审核含义。一个 case 的 restore 或 appeal overturn 只能释放自己的 effect，所有 active effect 都释放后 listing 才解除限制。紧急下架先建立 manual case 再建立其 effect，显式管理员恢复也只释放该 manual case。user 多来源限制仍是后续工作。

### AgentRun 与 AgentActionPlan

[已实现] AgentRun 的部分事实仍分散在聊天消息、LLM metrics、工具结果和日志中；统一 `AgentRun` 仍是目标态。需要事前确认的修改、删除、成交意向和议价形成 `AgentActionPlan`；低风险发布立即执行并进入撤销窗口：

```text
AgentRun: request -> routing -> retrieval -> model/tool steps -> outcome
ActionPlan: pending -> confirmed_once (L3) -> executing (transaction-local) -> executed | failed
            pending | confirmed_once -> cancelled | expired
            legacy executing -> interrupted
```

ActionPlan 保存待执行输入快照、风险级、短期 confirmation capability 和执行结果，不是已执行事实。L2 一次确认；L3 primary token 只能进入 `confirmed_once`，服务端随后才公开独立的第二步 token。primary 重试只重放挑战，不能执行。计划归属创建时的 campus，list/cancel/confirm 都按当前认证用户和活动校园过滤。

新协议中的 `executing` 只存在于未提交事务内：计划行锁、业务写入、通知/outbox 和 `executed` 结果一起 commit；动作失败先回滚 savepoint，再在同一外层事务记录 `failed`。因此 commit 前崩溃不会留下业务事实或持久 `executing`。迁移发现的旧协议 `executing` 无法安全判断副作用是否已提交，只能标记 `interrupted` 并人工核对，绝不自动重放。通用资源版本快照、提案幂等和统一审计事件仍待补齐。

### AuditEvent 与 DomainEvent

两者不能混为一谈：

- `AuditEvent` 面向责任追踪，回答谁在何时因何理由做了什么。
- `DomainEvent` 面向系统协作，回答哪个业务事实已经发生，需要哪些异步消费者处理。

目标公共事件信封：

```json
{
  "event_id": "uuid",
  "event_type": "intent.published.v1",
  "aggregate_type": "intent_item",
  "aggregate_id": "uuid-or-compatible-id",
  "campus_id": "uuid",
  "actor_id": "uuid",
  "schema_version": 1,
  "occurred_at": "RFC3339 timestamp",
  "trace_id": "request correlation id",
  "payload": {}
}
```

业务写入与 outbox event 必须在同一数据库事务提交。日志或进程内 channel 不能替代事件事实。

### Listing embedding 投影版本

[已实现] `inventory.content_revision` 是 listing 可检索内容与可见性的单调版本。数据库 trigger 在 INSERT，以及 title/category/brand/condition/defects/description/direction、status 或 campus 变化时维护版本；`listing_restriction_effects` 的生效、释放、删除和改挂也会使对应 listing 失效并推进版本。

`embedding_jobs` 每个 `listing_id` 一行，保存 `campus_id`、最新 `desired_revision`、pending/processing/completed/dead-letter 状态、attempt/backoff、lease 和错误。新的 revision 通过 UPSERT 合并；processing 中的行保持当前 lease，但提升 desired revision。Worker 必须重新读取权威 inventory 与 restriction 状态，决定 upsert embedding 还是删除投影，不能把 job payload 当业务事实。

`documents.source_revision`、`content_hash`、embedding provider/model/version 和 `embedded_at` 描述已生成投影。Worker 在 provider I/O 后以 claimed revision 做 CAS：只有仍然匹配的结果才能完成；被更新取代的 attempt 将最新 revision 重新置为 pending。历史 document 的真实 source revision 无法证明时保持 NULL，并由 backfill 重建，不能用迁移时间伪造为“最新”。

## 信息生命周期

### 发布与公开

```text
draft
  -> submitted
  -> text screening
  -> persisted as pending/active
  -> media moderation
  -> publicly discoverable
```

当前文本在写入前同步审核，媒体使用异步任务。[目标态] 未通过媒体审核的图片进入隔离区，listing 可以先以安全占位图公开，也可以按校园策略保持 pending；不能先公开原图再等待撤回。

### wanted 与 offer 匹配

```text
wanted(active) + offer(active)
  -> campus/category/budget/condition hard filters
  -> lexical/vector retrieval
  -> ranking and diversity
  -> Match with reason codes
  -> optional Response
  -> optional Conversation
  -> optional DealRecord
```

每一步都是独立事实。系统不能因为用户打开匹配卡片就创建联系，也不能因为双方聊天就自动确认成交。

### 删除、关闭与保留

- listing 删除应从公开检索和向量召回中移除，但审计和法定保留数据按策略处理。
- wanted fulfilled 或 deleted 后停止新匹配并立即关闭当前 response 轮次；已有 response 和 conversation 保留历史，旧 pending 不可继续 accept/dismiss/withdraw。
- wanted relist 开启新 `lifecycle_epoch`；旧轮始终只读，同一 offer 在新轮最多重新响应一次。
- 用户对消息“删除”当前只对自己隐藏，举报和审核记录仍保留。
- 账号删除、内容保留和安全事件保全的冲突由[信任与安全](trust-safety.md)定义。

## 多租户不变量

[目标态] 所有实现必须满足：

1. IntentItem、Space、Conversation、ModerationCase、Notification 和 AuditEvent 有明确 `campus_id`。
2. repository 查询默认要求 tenant context，不提供无范围的普通用户查询。
3. 用户之间跨校园联系默认返回不可联系，不泄露对方 membership。
4. 外键和复合唯一约束防止把 A 校园的 response 关联到 B 校园的 intent。
5. 管理员跨校园操作必须使用平台角色、理由和审计事件；强认证仍是上线前目标。
6. 向量和全文检索必须先限定 campus，再计算相似度。

## ID 与兼容策略

当前系统处在 TEXT id 与 UUID shadow column 并存阶段。公开 API 继续把 ID 序列化为字符串，内部逐步采用 UUID 语义。

- 不在文档中把“字符串”误写成“任意字符串”。
- 新目标表使用 UUID 主键。
- repository 封装兼容解析，不让 handler 自行拼接新旧 join。
- API 版本迁移期间保持旧字段名，直到有明确弃用窗口。
- 任何 backfill 都要有 divergence 检查和混合数据测试。

## 事实来源优先级

发生冲突时按以下顺序判断当前实现：

1. 已应用 migration 和数据库约束。
2. service 中的事务与状态转换。
3. repository 查询和 handler 权限校验。
4. API 响应模型与 Flutter 解析。
5. 文档和 UI 文案。

发现文档与更高优先级事实不一致时，应先修文档并记录是否需要后续代码整改，不能为了让文档“正确”而假装目标能力已经存在。
