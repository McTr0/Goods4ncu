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
  -> issue access + refresh
refresh(old)
  -> revoke old refresh
  -> issue new access + refresh
replay old refresh
  -> revoke all refresh tokens for user
logout
  -> revoke access JTI and refresh tokens
```

错误用户名和错误密码返回同类失败，避免账号枚举。被封禁用户不能登录、refresh 或建立新的 WebSocket 认证上下文。

### 校园资格

[目标态] 注册账号不自动获得发布和联系权限：

```text
registered
  -> submit campus verification
  -> membership pending
  -> verified -> publish/contact/join spaces
  -> suspended | expired -> read-only public access
```

邮箱域名、派生学号和发现设置当前已存在，但 `CampusMembership` 尚未落地。客户端隐藏按钮不是权限控制，后端必须在写接口检查 active membership 和 campus scope。

## Offer / Wanted 生命周期

### 发布

```text
用户表单或 Agent 草稿
  -> 字段校验
  -> 同步文本审核
  -> 写 inventory(direction=offer|wanted)
  -> 写/更新 documents embedding
  -> 可选媒体审核任务
  -> 返回 listing
```

`offer`：价格是出售价，成色是当前成色，owner 是提供方。

`wanted`：价格是预算上限，成色是最低可接受成色，owner 是需求方。没有品牌偏好时当前客户端可提交“不限”，生产目标应改为显式可选字段而不是把展示词当真实品牌。

Agent 不能绕过表单使用的审核和校验。[目标态] Agent 发布先生成 L2 ActionPlan，用户确认后才执行。

### 状态

当前 `inventory.status` 主要包含 active、sold、deleted 等历史语义。[目标态] 对 wanted 明确支持 fulfilled，避免把“需求完成”误写成 sold。

```text
offer:  active -> sold | deleted
        sold/deleted -> relisted/active（满足权限和规则时）

wanted: active -> fulfilled | deleted
        fulfilled -> active（用户重新开启时创建审计）
```

任何非 active 条目都要从普通 Feed、匹配和新联系入口排除；历史 Conversation、Response 和 DealRecord 仍保留。

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

[目标态] 先限定 campus，再执行召回；结果增加稳定 reason codes、排序版本和用户反馈入口。

提供方调用 responses API 时只能选择自己的 active offer，不能推荐 wanted、sold 或 deleted 条目。重复 pending response 返回已有记录或明确冲突，不重复通知。

```text
pending response
  -> requester accepts
  -> requester dismisses
  -> responder withdraws
```

Response 不自动创建 Conversation 或 DealRecord。接受后界面可以建议联系，但由用户决定实时沟通或留言。

## Feed、搜索与收藏

当前列表和推荐支持 `direction=offer|wanted|all`。匿名 Feed 以 active 和新鲜度为主；登录用户的推荐结合收藏和买家成交意向的分类亲和度，并排除自己的条目和已收藏内容。

[目标态] Feed 流程：

```text
tenant / visibility / status hard filter
  -> lexical + vector candidate retrieval
  -> relevance + freshness + completeness + trust
  -> diversity and repetition control
  -> rank_reason / match_summary
  -> user feedback
```

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

消息首页第一层按 `peer_user_id` 聚合为 Thread，同一个聊天对象只显示一次。Thread 聚合最近活动、总未读、Conversation 数量和待回应状态。

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

Mail 创建后进入 open，主题 1–120 字、正文 1–2000 字，无需接受即可送达。Mail 不向发件人展示 typing 或对方 read 状态；成员本地未读仍可清零。

归档是成员级状态，不影响对方和底层历史。

## 消息、已读、回复与 Quote

### 已读策略

用户全局设置为 auto/manual，Conversation 可以 inherit/auto/manual 覆盖。

- effective auto：active realtime 页面加载后可调用 read。
- effective manual：加载和收到新消息不自动 read，用户从会话设置或上下文动作标记。
- Mail：本地 unread 可清零，但不向发件人广播 read。
- 单条已读图标只根据消息事实显示，不用“整个会话已读”代替发送方反馈。

已读策略属于具体设置菜单，不常驻占用聊天主界面。

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

[目标态] Agent 动作流：

```text
用户意图
  -> L0/L1：解释、搜索、匹配、草拟，可直接返回
  -> L2：发布、更新、联系、推荐，生成 ActionPlan
  -> L3：报价、议价接受、成交、隐私公开，生成二次确认 ActionPlan
  -> 用户确认
  -> service 重新校验并幂等执行
  -> audit + domain event
```

ActionPlan 过期、资源版本变化、membership 失效或权限变化时安全失败。模型不能用聊天中的“已经同意”绕过确认 token。

Provider 失败时保留用户输入，提供关键词搜索、普通表单和手工聊天；不能让整个市场不可用。

## 线下成交记录

当前 `orders` 的产品语义是 DealRecord：

```text
intent_pending -> confirmed
intent_pending -> cancelled
confirmed -> cancelled
```

创建 intent 不改变 listing。卖家确认后可以选择自动把 offer 标为 sold。旧 pending 兼容为 intent_pending，旧 paid/shipped/completed 兼容为 confirmed；新业务不再产生支付或物流状态。

成交确认事务包含 DealRecord 状态和可选 listing 下架。通知失败不应回滚已确认事实，但当前 best-effort 通知仍有丢失风险，生产目标使用 transactional outbox。

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

当前文本在持久化或调用 LLM 前同步审核，图片进入异步 `moderation_jobs`。本地可配置关键词用于学校或运营策略。

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

## 通知与实时提示

通知先写数据库，再尝试 WebSocket 推送。WebSocket 成功不等于已读，推送失败也不等于通知丢失。

生产目标使用 outbox 可靠产生通知和 fan-out。客户端重连后按游标拉取缺失通知，不能依赖 socket 保存历史。

通知按紧急度分级：安全和待确认动作优先，普通推荐和活动聚合，typing 不持久化。

## 管理和审计

当前管理员可以查看统计、用户、listing、成交记录和审计日志，执行封禁、解封、角色修改、token 撤销、下架和成交状态操作。

管理动作必须同时验证受影响普通路径：封禁后登录/refresh/WebSocket 失败，下架后 Feed/收藏/匹配不可见，撤销 token 后接口拒绝。

[目标态] 校园运营只能管理本 campus；平台管理员跨校园操作需要强认证、理由和审计。人工解密、收款码处理和高风险审核不能成为普通后台列表中的无门槛按钮。
