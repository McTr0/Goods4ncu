# 业务流程与状态机

| 项目 | 内容 |
| --- | --- |
| 适用读者 | 产品、后端、Flutter、测试和运营人员 |
| 当前状态 | 同时记录当前流程与明确标记的生产目标；状态字段以 migration/service 为准 |
| 事实来源 | Axum 路由、service 状态转换、数据库约束、Flutter capabilities 和集成测试 |
| 最后核对范围 | 认证、出收、Feed、用户主页、聊天、空间、Agent、成交、审核和通知 |

这篇文档关心“发生什么、先后关系和失败路径”，不重复每个 JSON 字段。字段见 [API 参考](api-reference.md)，对象定义见[信息模型](information-model.md)。

## 认证、token 与校园资格

### 当前认证

注册和登录返回 access token 与 refresh token。access token 是带 JTI 的 JWT；refresh token hash 后存库并采用旋转策略。

```text
login/register
  -> select verified-first membership (pending allowed for a new registration)
  -> issue access(campus claim) + refresh(campus row)
refresh(old)
  -> revoke old refresh
  -> preserve active campus
  -> issue new access + refresh
switch campus(access + refresh + verified membership)
  -> revoke old refresh and current access JTI
  -> issue token pair bound to selected campus
replay old refresh
  -> revoke all refresh tokens for user
logout
  -> revoke access JTI and refresh tokens
```

错误用户名和错误密码返回同类失败，避免账号枚举。被封禁用户不能登录、refresh 或建立新的 WebSocket 认证上下文。

### 校园资格

[已实现] `Campus`、`CampusMembership`、南昌大学 seed、本人资格查询和学校邮箱 OTP 验证已经落地。历史账号使用 `legacy_backfill` 保持兼容；新注册账号只获得 `pending`，填写学校邮箱不等于完成邮箱所有权验证。

```text
registered
  -> membership pending
  -> request OTP to profile school email
  -> confirm within 5 minutes
  -> verified -> publish/contact/join spaces
  -> suspended | revoked -> read-only access
```

验证码明文不会进入数据库；服务端保存基于 JWT secret 和 challenge ID 的 HMAC，单次 challenge 最多尝试 5 次。重发冷却为 60 秒，每小时最多请求 5 次。开发环境可把验证码写入本地后端日志，生产环境必须配置受 bearer token 保护的投递 webhook。

[已实现] 发布 offer/wanted、响应 wanted、创建联系人会话、创建或加入群组/频道、创建 Secret Chat、创建成交意向，以及小帮的发布/购买意向/议价工具，都在后端 service/handler 边界检查 verified membership。浏览、收藏和读取历史保持可用。用户更换邮箱后，已认证资格会重置为 `pending`。

[已实现] `inventory`、`orders`、`hitl_requests`、`wanted_responses`、`chat_conversations`、`chat_spaces`、`chat_secret_sessions` 和 `notifications` 已写入不可空 `campus_id`。游客的公开商品、推荐和用户页面限制在 NCU；登录用户的这些读取跟随设备活动校园。联系、空间成员、Secret Chat、wanted response、成交与 Agent 写工具要求双方拥有同一 Campus 的 verified membership。订单、议价、wanted response 和商品上下文聊天还通过复合外键阻止跨校园资源拼接。

[已实现] `0031_active_campus_sessions.sql` 把 refresh session 绑定到校园，access JWT 携带可选 campus claim。个人页在拥有多个 verified membership 时可切换当前校园；每台设备独立选择，刷新保持选择，受保护操作会再次查询 membership 状态。登录用户的商品浏览/详情、wanted 匹配、推荐、公开用户页、个人发布、用户发现、通知、直聊、空间和 Agent 工具使用该上下文；游客仍由服务端选择 NCU 首校园。

[已实现] `moderation_jobs` 和 `admin_audit_logs` 也已写入不可空校园归属。校园 operator/admin 可以读取自己当前校园的统计、用户、listing、成交记录、审计和媒体审核队列；平台管理员跨校园读取或写入必须显式提交理由，读取和写入都会留下目标校园审计。

[目标态] `0029` 中 NCU 数据库默认值仍是兼容旧 SQL 的过渡护栏，第二校园启用前必须移除。当前普通用户 handler 已按活动校园过滤，但后续仍应收敛为统一 extractor，避免每个 handler 自行解析；管理员 MFA 和 RLS 仍未完成。近期密码认证与统一审核 case 已实现。

## Offer / Wanted 生命周期

### 发布

```text
用户表单或 Agent 草稿
  -> 字段校验
  -> 同步文本审核
  -> 同一事务写 inventory(direction=offer|wanted)
     + 推进 content_revision
     + 合并 embedding_jobs desired_revision
     + 可选媒体审核任务
  -> 返回 listing
  -> embedding worker 读取权威 listing/限制状态
  -> 按 revision CAS 写入或删除 documents 投影
```

[已实现] HTTP、Flutter 和 Agent 发布共用数据库触发的不丢任务边界。创建、语义字段变化以及 status/campus 变化都会原子推进 `content_revision` 并登记最新版 projection job；短时间连续更新只保留同一 `listing_id` 的最高 `desired_revision`。限制 effect 的生效、释放、删除或改挂也会推进 revision，所以不依赖某一个管理入口记得手工重建向量。

Embedding provider 调用发生在 listing 提交之后。provider 超时、限流或离线不会回滚已经通过校验和审核的发布；在投影完成前，读取路径使用现有关键词/规则 fallback。Worker 调用 provider 期间如果 listing 再次变化，旧 claim 不能完成新 revision，任务会回到 pending 处理最新版。

`offer`：价格是出售价，成色是当前成色，owner 是提供方。

`wanted`：价格是预算上限，成色是最低可接受成色，owner 是需求方。没有品牌偏好时当前客户端可提交“不限”，生产目标应改为显式可选字段而不是把展示词当真实品牌。

Agent 发布当前是低风险即时动作，并在小帮页提供撤销窗口；它仍必须经过与表单相同的审核和校验。当前 Agent/HTTP 的 listing command 入口尚未完全统一，这是必须收敛的已知缺口。

### 状态

当前 `inventory.status` 支持 active、sold、deleted 与 wanted 专用的 fulfilled，需求完成不会再误写成 sold。

```text
offer:  active -> sold | deleted
        sold/deleted -> relisted/active（满足权限和规则时）

wanted: active -> fulfilled | deleted
        fulfilled/deleted -> active（用户重新开启，lifecycle_epoch + 1）
```

每条 wanted 在 `inventory.lifecycle_epoch` 中保存当前轮次，初始为 1；fulfill/delete 关闭当前轮但不改 epoch，relist 在同一事务中恰好加一。任何非 active 条目都要从普通 Feed、匹配和新联系入口排除；历史 Conversation、Response 和 DealRecord 仍保留。

## Wanted 匹配与响应

当前匹配入口为 `GET /api/listings/{wanted_id}/matches`，只接受 wanted。

```text
active wanted
  -> 排除需求方自己的 offer
  -> active offer
  -> 分类相同
  -> offer price <= wanted budget
  -> offer condition >= wanted minimum
  -> 关键词/embedding + 新鲜度排序
  -> 返回候选
```

[已实现] 所有召回先限定活动校园和生命周期；首页商品 feed、相似商品、listing wanted matches 与 intent feed/matches 均返回排序原因、稳定来源和排序版本，并提供精确隐藏、泛化降权、非个性化排序和清除旧信号。新撮合入口使用稳定 reason code；兼容中的首页商品 feed 仍可返回服务端人话原因。listing wanted matches 的解释只陈述实际执行的分类、预算和成色约束，不公开作者、距离、权重或反馈事实。

提供方调用 responses API 时只能选择自己的 active offer，不能推荐 wanted、sold 或 deleted 条目。response 创建支持 responder 范围的 `Idempotency-Key`：同 key 同规范化内容返回同一 id 和 `replayed=true`，不重复通知；同 key 不同内容冲突。每个 wanted 轮次内，同一 offer 无论此前 response 是否已经终态都只能创建一次；relist 开启新 epoch 后才可再次响应。response 列表和动作在每次请求时重新验证活动校园 verified membership，并按 `campus_id` 隔离；跨校园 response id 与非本人 response id 一样返回 404。

```text
pending response + active wanted + response epoch == current epoch
  -> requester accepts（wanted + offer 均为 active）
  -> requester dismisses（wanted 为 active）
  -> responder withdraws（wanted 为 active；offer 可已关闭）

wanted fulfilled/deleted 或 response epoch != current epoch
  -> round_state=closed
  -> available_actions=[]
  -> 历史只读，三种动作均拒绝
```

`status=pending` 只描述 response 尚未被任何一方终结，不代表它仍可操作。列表用 wanted active 状态和 epoch 相等性派生 `round_state=current|closed`，并返回服务端权威的 `available_actions`；无法证明轮次的 legacy `lifecycle_epoch=NULL` 永远 closed。

response 创建和动作统一按 `wanted -> offer -> response` 顺序锁行；fulfill、delete 和 relist 也先锁 wanted，避免资格检查和状态写入之间的竞态。动作通知关联 wanted，移动端从通知进入详情即可看到本地化状态和操作。Response 不自动创建 Conversation 或 DealRecord。接受后界面提供查看 offer，由用户决定是否实时沟通或留言。fulfilled/deleted wanted 保留 response 历史；“我的发布”包含非 active 条目，因此用户离开详情后仍可找回并重新开启。

迁移期允许 `wanted_responses.lifecycle_epoch` 为 NULL，只对能证明属于当前 active 轮次的 legacy 行回填。INSERT trigger 让省略 epoch 的旧应用仍从锁定 wanted 派生正确轮次，reopen trigger 让旧应用只更新 status 时也自动增加 epoch；因此滚动部署和应用 rollback 不依赖回滚已执行 migration。

## Feed、搜索与收藏

当前首页商品 Feed 支持 `direction=offer|wanted|all`。匿名 Feed 以 active 和新鲜度为主；登录用户的 Feed 结合重置时间之后的收藏和买家成交意向分类亲和度，并排除自己的条目、仍有效的已收藏内容和显式反馈过的资源。

[部分完成] Feed 流程：

```text
tenant / visibility / status hard filter
  -> lexical + vector candidate retrieval
  -> relevance + freshness + completeness + trust
  -> diversity and repetition control
  -> rank_reason / match_summary
  -> user feedback
```

当前首页商品 feed、相似商品、listing wanted matches 与 intent feed/matches 已完成 tenant/visibility/status 硬过滤、排序原因/版本和反馈控制。三种反馈都会在这些入口精确隐藏原资源；`less_like_this` 在首页/相似商品降低同分类、在 wanted matches 降低同品牌、在意图流降低同 kind 候选。关闭个性化或重置会停用泛化旧信号，但不撤销精确隐藏。lexical/vector 的统一两阶段召回、多样性、完整度/信任特征、置信度校准和评估闭环仍是目标态。

收藏自己的条目会被拦截。收藏列表只展示仍可见的 active 内容；删除收藏不删除 listing，也不应抹掉已有审计或聚合统计。

语义结果异常时检查 `documents`、embedding 维度和状态过滤，不要把 LLM 回答当搜索事实。

## 用户主页、发现与收款码

公开用户主页展示必要身份、在出/在收内容和用户主动公开的收款码。头像点击进入个人公开主页，个人设置页不再用重复菜单卡片代替这一入口。

发现设置当前支持：

- 用户名：默认可查找，可关闭。
- 完整邮箱：默认关闭，只做精确匹配并返回脱敏结果。
- 学号：从符合规则的学校邮箱派生，默认关闭，只做精确匹配。

查找不返回自己。屏蔽、对方不存在或不可联系使用中性结果，不泄露关系。

收款码流程：

```text
选择微信/支付宝图片
  -> 校验文件头和 MIME
  -> 上传 URL-first
  -> 图片审核
  -> 更新个人资料
  -> 用户主动打开对应公开开关
  -> 公开主页展示风险提示
```

默认不公开。上传接口返回 HTML 错误页时，客户端不能把它当图片解码；应检查状态码、Content-Type 和 URL。Agent 不得自动公开或转发收款码。

## 联系人线程与独立会话

消息首页第一层按 `peer_user_id` 聚合为 Thread，同一个聊天对象只显示一次。Thread 聚合最近活动、联系人级新留言、Conversation 数量和待回应状态；新留言标记完全来自设备本地 `LOCALLY_SEEN`。

进入 Thread 后按 Conversation 卡组展示多次 realtime、mail 和历史。Conversation 仍然是独立事实，不跨卡混排成没有边界的消息流。

### Realtime 握手

```text
syn_sent
  -> recipient accepts -> syn_ack
  -> recipient declines -> declined
  -> initiator cancels -> cancelled
  -> 10 min -> expired

syn_ack
  -> initiator opens/acks/sends -> active
  -> either closes -> closed
  -> 5 min -> expired

active
  -> either closes -> closed
  -> 24h silence -> expired
```

SYN 带完整首条文本，接收方接通前可读但不能回复。双方同时发起视为 mutual intent，只保留一个 live realtime。

终止态不可复活。重新联系会创建新 Conversation，并继续显示在同一 Thread。

### Mail

Mail 创建后进入 open，主题 1–120 字、正文 1–2000 字，无需接受即可发送。发送成功只表示消息已持久化到服务器；没有设备 ACK 时不宣称“已送达”。Mail 不向发件人展示 typing 或对方 read 状态，接收端可以本地记录 `LOCALLY_SEEN`，也可以主动发送 `received`、`will_review` 或 `completed`。

归档是成员级状态，不影响对方和底层历史。

## 消息、已读、回复与 Quote

### 已读、确认与注意力隐私

服务器不再保存阅读位置、read preference 或 typing 状态；旧数据库字段已在迁移中删除，旧 read/typing 路由也不再注册。`LOCALLY_SEEN` 只存在于接收端设备，不写入发送方可见事实，也不由服务器推断。公开消息状态收敛为 `sending | sent | failed`；只有接收者主动选择 `received | will_review | completed` 才产生可见 acknowledgement。打开会话、查看通知、接收 Push、解密内容、播放媒体、回复或普通 reaction 都不自动生成 acknowledgement。

realtime 的 `active` 只表示这一段会话已经接通，不是全局在线、last seen 或注意力证明。移动端不发送 read/typing，WebSocket 也不广播这些事件。连接隐私由 `allow_strangers`、busy 截止时间和联系人权限控制；静音只抑制打扰通知，不改变历史或生成已读事实。

### Reply 与结构化 Quote

`reply_to_message_id` 引用同一 Conversation 的消息，响应返回 reply preview。跨 Conversation reply 拒绝。

结构化 quote 支持 listing、order/deal record 和 hitl_offer。客户端只提交 kind/ref_id，服务端验证参与者和可见性并生成事实快照。客户端传入的价格、状态或标题快照必须被忽略。

展示顺序固定为：消息回复预览在上，结构化 quote 卡片在下，正文最后。Secret Chat 实验路径不支持结构化 quote。

### 反应、隐藏与举报

- 每个用户对同一消息最多一个 reaction，重新选择会替换。
- “删除”只对自己隐藏，不 hard delete 对方历史。
- 可见消息可以举报，重复举报被拦截。
- 被隐藏消息仍可按审核和安全策略保留。

## 群组、频道与通话

[实验中] `chat_spaces` 支持 group/channel：

- Group：owner/admin/member/banned，成员可按权限发言。
- Channel：只有 owner/admin 发言，订阅者可读、reaction 和举报。
- 创建成功后必须进入消息列表；移动端点击空间直接进入页面，不用临时弹窗代替主导航。
- 消息页统一通过右上角“+”提供找同学、建群和建频道；移动端使用下拉刷新。

[实验中] 一对一 WebRTC 由后端转发 invite/offer/answer/ICE/end 信令，不处理媒体。只有 active realtime 成员可发起。生产还需要 TURN、弱网恢复、权限和多实例 signaling。

[实验中][待弃用] Secret Chat 服务端不可读，不进入生产方向。现有历史兼容和迁移见[信任与安全](trust-safety.md)。

## Agent 请求与确认

当前小帮支持普通 JSON 和 SSE。请求先经过审核和意图路由，需要工具时进入 LLM provider/Agent。

[已实现] 当前市场 Agent 动作流：

```text
用户意图
  -> L0/L1：解释、搜索、匹配、草拟，可直接返回
  -> 可恢复发布：校验后立即执行，展示撤销窗口
  -> L2 更新/下架：生成一次确认 ActionPlan
  -> L3 成交意向/议价：生成使用独立两步 token 的 ActionPlan
  -> 用户确认；L3 primary 只解锁 second token
  -> 原校园内重新校验并把业务事实、适用时的通知/outbox、计划终态原子提交
```

ActionPlan 过期、membership 失效、权限或商品状态变化时安全失败。模型不能用聊天中的“已经同意”绕过 confirmation token；primary 请求重试也不能变成第二次确认。通用资源版本快照和统一 Agent 审计仍是目标态。

Provider 失败时保留用户输入，提供关键词搜索、普通表单和手工聊天；不能让整个市场不可用。

## 线下成交记录

当前 `orders` 的产品语义是 DealRecord：

```text
intent_pending -> confirmed
intent_pending -> cancelled
confirmed -> cancelled
```

创建 intent 不改变 listing。卖家确认后可以选择自动把 offer 标为 sold。旧 pending 兼容为 intent_pending，旧 paid/shipped/completed 兼容为 confirmed；新业务不再产生支付或物流状态。

成交确认事务包含 DealRecord 状态和可选 listing 下架。确认接口支持卖家范围内的 `Idempotency-Key`，网络超时后的相同请求不会重复下架；同 key 改变确认参数会安全失败。通知行与 `notification.push` outbox event 同事务提交；WebSocket 投递失败不会回滚已确认事实，并由至少一次投递与 HTTP 补拉恢复。

普通用户主页不保留“我的订单”主入口；历史记录仍可从通知、相关会话或明确的成交记录入口访问。管理后台使用“成交记录”而不是“订单”。

## HITL 议价

```text
pending
  -> seller approve -> approved + confirmed DealRecord
  -> seller reject -> rejected
  -> seller counter -> countered

countered
  -> buyer accept -> approved + confirmed DealRecord
  -> buyer reject -> rejected
  -> timeout -> expired
```

所有会创建成交记录的动作必须在事务中锁定 HITL、检查状态、创建记录、写系统消息并更新请求。Agent 不能替卖家或买家自动接受；L3 目标确认协议必须覆盖这些动作。

## 审核、举报与申诉

当前文本在持久化或调用 LLM 前同步审核，图片进入异步 `moderation_jobs`。任务从 listing、conversation 或用户当前校园继承 `campus_id`，Worker 可使用 `processing` 作为领取中的状态。校园运营通过 `/api/admin/moderation/jobs` 只能查看本校园队列。本地可配置关键词用于学校或运营策略。

[目标态] 流程为：

```text
sync text screening
  -> private media quarantine
  -> machine moderation
  -> human review when uncertain
  -> publish/reject
  -> user appeal
  -> independent review
```

举报消息和管理员动作进入统一 ModerationCase/AuditEvent。用户只看到原因类别和可行动步骤，不看到举报人、具体规则或内部阈值。

listing 的 lifecycle 与 restriction 分开保存。`inventory.status` 只表达 active/sold/deleted/fulfilled；每个会限制 listing 的 ModerationCase 拥有自己的 `listing_restriction_effects` 行。存在任一未释放 effect 即为 restricted：公开读取、推荐、联系、议价、成交和 wanted 动作都关闭，owner/admin 仍能看到安全摘要。恢复案件、申诉改判和紧急人工恢复只释放各自拥有的 effect；两个 effect 不能被一次恢复清空。owner delete 保留 effect，owner relist 在任一 effect 仍有效时返回 `listing_restricted`，因此审核恢复永远不会把 deleted/sold/fulfilled 自动改成 active。

## 通知与实时提示

通知先写数据库，再尝试 WebSocket 推送。WebSocket 成功不等于已读，推送失败也不等于通知丢失。

[已实现] 每条通知保存 `campus_id`。通知列表、未读计数、单条已读和全部已读同时匹配当前用户与设备活动校园；切换校园不会暴露或修改另一校园的通知。历史通知优先按关联订单、商品或会话回填校园，无法关联时才按用户 membership 回填。

生产目标使用 outbox 可靠产生通知和 fan-out。客户端重连后按游标拉取缺失通知，不能依赖 socket 保存历史。

通知按紧急度分级：安全和待确认动作优先，普通推荐和活动聚合，typing 不持久化。

## 管理和审计

当前校园 operator/admin 可以查看自己当前校园的统计、用户、listing、成交记录、审计日志和媒体审核队列。平台管理员执行封禁、解封、角色修改、token 撤销、下架和成交状态操作；校园运营不能执行这些全局账号或业务事实写操作。

管理动作必须同时验证受影响普通路径：封禁后登录/refresh/WebSocket 失败，下架后 Feed/详情/收藏/匹配/联系/议价/成交不可用，wanted 当前轮冻结，撤销 token 后接口拒绝。

[已实现] 校园运营读取限定本 campus；平台管理员跨校园读取/操作需要理由并写审计。目标用户或资源不属于所选校园时按不存在处理，避免枚举另一校园数据。

[已实现] 平台管理员敏感写操作要求近期密码认证；Flutter 后台在认证过期后隐藏处置能力并提供密码解锁，服务端返回稳定的 `recent_authentication_required`。校园运营继续只读。

[目标态] 平台管理员和校园运营仍需要 MFA；校园运营的细粒度处置权限应建立在 ModerationCase 上，而不是放开当前全局封禁和角色接口。人工解密、收款码处理和高风险审核不能成为普通后台列表中的无门槛按钮。
