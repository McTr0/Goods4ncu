# 新人导览：跟随一条需求穿过整个系统

| 项目 | 内容 |
| --- | --- |
| 适用读者 | 第一次接触续樟的本科生、实习生、产品与工程协作者 |
| 当前状态 | 以当前实现为基础，必要处明确指出生产目标 |
| 事实来源 | 产品设计、当前架构、业务流程、API 和开发命令 |
| 最后核对范围 | 出/收、匹配、Agent、聊天、成交、审核和本地启动 |

这不是一份“记住所有目录”的清单。它会跟随一位用户发布收物需求，解释请求经过哪些层、哪些数据是事实、失败时应该去哪里找原因。

读完以后，你应该能回答：续樟解决什么问题，一条信息怎样流动，Agent 为什么不能直接替用户成交，以及接到一个 bug 时先查哪一层。

## 续樟是什么

续樟是一个校园智能信息流通平台。当前首要场景是物品的“出”和“收”：

- `offer`：我有一个物品，希望提供给需要的人。
- `wanted`：我有一个需求，希望找到愿意提供的人。

系统帮助用户表达、发现、匹配和沟通。线下验货、交接和付款由双方自行完成；平台只记录成交意向、卖家确认和商品是否自动下架，不托管资金、不判断付款成功、不追踪物流。

工程结构可以先记成一条主链：

```text
Flutter 页面
  -> HTTP / SSE / WebSocket
  -> Axum handler
  -> service 业务规则和事务
  -> repository / PostgreSQL
  -> pgvector、worker、Redis 或外部 provider
```

页面是用户看到的结果，service 和数据库维护真正的业务事实。不要因为问题出现在按钮上，就默认问题属于页面。

## 一条“想收平板”的完整旅程

### 1. 用户表达需求

小林在首页输入：“想收一台能记笔记的平板，预算 1800，成色别太差。”

[已实现] 小昌可以理解自然语言、搜索商品和使用市场工具。[目标态] 对发布这类写操作，Agent 只生成 wanted 草稿：

```text
方向：wanted
标题：想收一台适合记笔记的平板
预算上限：1800 元
最低成色：较好
分类：数码产品
```

用户确认后才能发布。原因很简单：模型推断“较好”不等于用户真的同意这个条件。

工程上，这一步涉及：Flutter 首页或发布页、聊天/Agent handler、IntentRouter、LLM provider、Agent 工具、listing service 和内容审核。

### 2. 系统保存需求

后端校验用户身份、字段、价格和文本内容，把记录写入 `inventory`。虽然表名叫 inventory，领域上它是一条 `IntentItem`；`direction='wanted'` 说明价格表示预算上限，成色表示最低可接受成色。

写入以后还要生成或更新 `documents` 中的可检索文本和 embedding。否则数据库里虽然有需求，语义搜索和匹配却可能找不到它。

如果文本审核拒绝，记录不应公开；如果图片需要异步审核，生产目标是先显示安全占位，而不是先公开原图。

### 3. 系统寻找可出物品

匹配不是让 LLM 浏览全库猜答案。后端先做硬约束：

```text
同一校园
offer 仍然 active
分类相符
价格不高于预算
成色不低于最低要求
不是需求方自己的 offer
```

然后结合关键词、embedding 距离和新鲜度排序。推荐结果应该告诉用户“为什么出现”，例如“预算内、同分类、成色满足”，但不能泄露内部权重或另一个用户的隐私画像。

当前实现已在服务端强制活动校园、状态、方向和已声明槽位等硬约束；首页商品 feed、相似商品、listing wanted matches 与 intent feed/matches 提供可本地化的解释，并支持“隐藏 / 少推荐这类 / 与我无关”、关闭个性化和清除旧排序信号。listing matches 的原因只陈述确实满足的分类、预算和成色条件；跨表达软排序、置信度校准、离线质量集和公平性评估仍需补齐。

### 4. 提供方响应需求

小周有一台 active 平板。他打开 wanted 详情，选择自己的 offer，点击“推荐我的商品”。后端验证：

- 这条 wanted 存在且 active。
- offer 属于小周且 active。
- offer 不是另一条 wanted。
- 同一 offer 在这条需求的当前 `lifecycle_epoch` 尚未响应过，即使上一条已是终态也不能在同轮重复创建。

成功后写入带当前 epoch 的 `wanted_responses` 并通知需求方。请求支持 `Idempotency-Key`，网络重试返回同一 response id 和 `replayed=true`，不会重复通知。Response 只代表“我有这个候选”，不会自动创建聊天或成交记录。

### 5. 双方开始沟通

小林可以选择：

```text
现在聊 -> realtime，会经过 syn_sent -> syn_ack -> active
写封留言 -> mail，主题和正文提交到服务器
```

每次联系仍是独立 Conversation，但收件箱按聊天对象聚合成 Thread。因此同一个 `seller2` 不应在首页重复出现很多次；进入联系人线程后，用户才能看到多段实时、留言和历史卡组。

屏蔽后双方不能继续新建或发送；终止的 realtime 不会复活，重新联系会创建新 Conversation 并留在同一 Thread。

### 6. Agent 帮助回复

用户主动点击“帮我回复”时，回复助手读取最近 12 条纯文本，提供直接、温和、保留余地的草稿。点击草稿只填入输入框，不自动发送。

回复助手不能读取媒体，不能挂载搜索、成交或议价工具，不能替用户承诺价格、付款和成交。

### 7. 双方线下完成

需求方可以发起成交意向。创建 `intent_pending` 不会立刻把 offer 标为 sold。卖家确认后进入 `confirmed`，并选择是否自动下架。

这条记录不是支付订单。收款码即使在用户主页公开，也只是一项用户自愿展示的信息，不能证明收款人身份或付款状态。

### 8. 需求关闭与重开

[已实现] 小林完成需求后把 wanted 标为 fulfilled。系统停止新的匹配和 response，但保留已有会话、成交和审核历史。当前轮尚为 pending 的推荐显示为 closed/read-only，不能再 accept、dismiss 或 withdraw。

小林重新开启 wanted 时，服务端把 `lifecycle_epoch` 加一。旧轮仍只读；小周可以用同一 offer 在新轮重新响应一次。

这一步说明状态机为什么重要：删除需求、完成需求、下架 offer 和取消成交记录是不同事实，不能都写成一个 `deleted=true`。

## 谁在系统里做什么

| 角色 | 主要动作 | 不能越过的边界 |
| --- | --- | --- |
| 游客 | 浏览公开信息 | 不能发布、联系和收藏 |
| 注册用户 | 收藏、设置隐私 | 生产目标下需校园认证才能发布和联系 |
| 校园成员 | 出、收、聊天、响应、确认成交 | 只能访问允许的校园范围和自己的资源 |
| 校园运营 | 审核和管理所属校园 | 不能无理由读取私聊或跨校园处理 |
| 平台管理员 | 系统安全与跨校园事件 | 所有高风险动作必须审计 |
| Agent | 搜索、解释、草拟和确认后调用工具 | 不能自己获得用户权限或跳过 service |

当前代码同时区分全局账号角色和校园资格角色。普通用户通过 `CampusMembership` 获得某校园的 verified 资格；校园 `operator/admin` 可以读取本校后台，全局平台管理员才可执行封禁、下架、代登录等敏感写操作。跨校园后台访问必须提供理由并留下审计。

## 关键术语

| 术语 | 在续樟里的意思 |
| --- | --- |
| Handler | Axum 路由入口，解析请求和返回 HTTP，不承载复杂状态机 |
| Service | 业务规则、权限和事务边界，决定一个动作是否合法 |
| Repository | 封装 SQL 和数据映射，不替 service 决定业务状态 |
| IntentItem | 领域中的信息意图；当前持久化在 `inventory` |
| offer / wanted | 我在出 / 我想收，是 IntentItem 的两个方向 |
| Match | 系统计算的候选关系，不是用户承诺或成交 |
| Response | 用户明确把一个 offer 推荐给 wanted 的事实 |
| Thread | 按聊天对象聚合的收件箱视图 |
| Conversation | 一次 realtime 或 mail 沟通，拥有独立状态机 |
| DealRecord | 当前 `orders` 的产品语义，只记录线下成交意向与确认 |
| HITL | Human-In-The-Loop，关键决定回到人类确认 |
| ActionPlan | Agent 为需要事前确认的写操作生成的短期计划；当前 L2 一次确认、L3 使用独立两步 token |
| JWT / JTI | access token 及其唯一标识，用于认证和撤销 |
| Refresh rotation | refresh token 使用一次后立即换新，重复使用视为 replay |
| pgvector / Embedding | 向量扩展和文本向量，用于语义召回 |
| Transaction | 一组数据库写入全部成功或全部回滚 |
| Outbox | 与业务事务一起提交的持久事件，属于生产目标 |
| SLO | 面向用户能力的可靠性目标，例如 API 可用性和消息延迟 |

## 第一次启动

完整配置见[运行、配置与排错](operations.md)。最短后端路径：

```bash
cp docs/.env.example .env
cp docs/config.toml.example goods4ncu.toml
cargo check --locked
cargo run
```

后端默认监听 `0.0.0.0:3000`，健康检查为 `GET /api/readyz`。

Flutter：

```bash
cd mobile
flutter pub get
flutter analyze
flutter test
flutter run --dart-define=API_BASE_URL=http://127.0.0.1:3000
```

如果 Codex 或终端环境重启，长时间运行的进程可能已经失效。GUI 验收前不仅要看端口，还要实际请求健康检查，并在 Codex Browser 加载前端。

## 如何定位问题

| 现象 | 先看哪里 | 原因 |
| --- | --- | --- |
| 请求没到后端 | API base URL、CORS、路由、token、rate limit | 入口层问题 |
| 状态转换不合法 | service 和事务 | 业务事实由 service 决定 |
| 查询漏数据或 join 错 | repository、migration、tenant/status 条件 | 数据访问问题 |
| 后端正确但页面没更新 | Flutter service、provider/controller、page | 客户端状态问题 |
| 消息存在但没实时显示 | DB、notification、WebSocket fan-out | 数据事实与实时提示是两层 |
| 搜索没有结果 | `documents`、embedding、过滤、provider | 可能是索引或范围问题 |
| Agent 行为不对 | 路由、检索、tool、policy、service、provider | 不应只改 prompt |
| 图片加载成 HTML | URL、响应 Content-Type、对象权限和错误页 | 图片组件拿到了非图片响应 |
| 管理动作成功但用户仍可操作 | token、普通用户路径和缓存 | 管理员成功提示不是完整验收 |

## 新人最容易踩的坑

1. 把页面文案当成业务事实，例如把 `intent_pending` 显示成“支付成功”。
2. 在 handler 或 Flutter 页面复制状态机，而不是调用 service。
3. 让 Agent 工具直接信任模型提供的 owner、user_id 或价格。
4. 忘记商品状态变化后同步 embedding，导致已删除内容仍被召回。
5. 把 WebSocket 失败理解成消息丢失；数据库才是消息事实来源。
6. 把 Base64 当长期媒体方案，导致请求和内存膨胀。
7. 在目标设计里写了 campus_id，就误以为当前代码已经多租户隔离。
8. 修改已合并 migration，而不是新增向前兼容迁移。
9. 只测管理员操作，不测受影响普通用户路径。
10. 只跑脚本，不用 Codex Browser 模拟真实点击和响应式布局。

## 下一步阅读

- 先理解现在代码怎样运行：[当前架构与分层](architecture.md)。
- 进一步理解对象和状态：[信息模型](information-model.md)。
- 准备改功能：[业务流程](domain-flows.md)和[开发指南](development.md)。
- 规划生产化：[生产架构](production-architecture.md)和[路线图](roadmap.md)。
