# 新人导览

这篇文档面向第一次接触 Good4NCU 的同学。它不会把系统说得过分简单，因为真实工程本来就有边界、状态、失败和历史包袱；它的目标是把这些复杂性按顺序摆好，让你知道每一块复杂性为什么存在、在哪里出现、出了问题该往哪一层看。

读完这一章，你应该能回答三个问题：Good4NCU 是什么，一次交易从哪里开始到哪里结束，以及当你接到一个 bug 或需求时该先打开哪类文件。

## Good4NCU 是什么

Good4NCU 是一个校园二手信息与沟通平台。用户可以发布商品、浏览商品、收藏商品、向卖家发起直聊、发起线下成交意向，也可以通过 AI 助手用自然语言完成搜索、发布和议价。平台只记录“买家有意向、卖家确认成交、商品是否自动下架”这些事实，不托管资金、不确认付款、不追踪物流；具体验货、交接和付款由双方在线下自行约定。管理员可以查看平台状态、封禁用户、下架商品、查看审计日志。

从工程角度看，它不是“一个 App 加几个接口”，而是一个完整的小型交易系统：

```text
Flutter App
  -> Rust Axum API
  -> Service 层执行业务规则和事务
  -> Repository 层读写 PostgreSQL
  -> pgvector 支持语义搜索
  -> LLM provider 支持 AI Agent
  -> WebSocket / SSE 支持实时消息和流式 AI 回复
```

这张图里最重要的不是箭头，而是边界。用户看到的是页面和按钮，后端维护的是权限、状态机和数据一致性。很多新人调 bug 时会觉得“页面没显示，所以改页面”；但在交易系统里，页面只是最后一层，真正的问题可能在 token、权限、事务、数据库状态、后台 Worker、WebSocket 推送或 AI 工具调用。

## 四类核心角色

| 角色 | 做什么 | 主要关注点 |
| --- | --- | --- |
| 普通用户 | 浏览商品、收藏、聊天、发起成交意向、查看通知。 | 认证状态、商品状态、成交意向状态和消息是否及时同步。 |
| 卖家 | 发布商品、回复买家、接受或拒绝议价、确认线下成交。 | 商品所有权、内容审核、成交确认、自动下架和议价超时。 |
| 管理员 | 维护平台秩序，查看统计、审计、用户和商品。 | 管理员权限、封禁影响、下架行为和审计日志。 |
| AI 助手 | 理解用户意图，调用工具搜索、发布、发起成交意向或议价。 | 意图路由、工具权限、RAG 数据、LLM provider 和失败降级。 |

同一个人可以在不同流程里扮演不同角色。比如一个用户既可以卖旧书，也可以买别人的耳机。系统判断权限时不能只看“是不是登录用户”，还要看“是不是这个商品的 owner”“是不是这个订单的 buyer 或 seller”“是不是管理员”。

## 一次交易的生命周期

先从最普通的交易看起。卖家登录后发布商品，后端验证字段、内容审核、写入 `inventory` 表，并把商品内容同步成向量文档用于语义搜索。买家浏览或搜索商品，可能先收藏，也可能打开详情页。详情页里如果买家不是卖家，就可以发起直聊或成交意向。

发起成交意向时，后端会检查商品是否仍然 `active`，检查买家不能买自己的商品，并创建 `intent_pending` 记录。商品不会因此立刻变成已售；卖家确认成交后，订单进入 `confirmed`，并可选择自动把商品下架为 `sold`。平台不记录付款是否完成，也不记录物流是否交付，这些由双方在线下自行确认。

议价会多一层 Human-In-The-Loop，也就是 HITL。买家通过 AI 或接口提出价格，系统创建一条待卖家处理的 `hitl_requests`。卖家可以接受、拒绝或 counter。接受会创建已确认的线下成交记录；拒绝会结束；counter 会把选择权交回买家，买家再接受或拒绝。后台 Worker 会定期把超时未处理的请求标记为 expired。

这就是交易系统的基本训练：只要涉及库存、成交记录或双方状态，就不要只想“更新一个字段”。要想“这几个状态是否必须一起成功或一起失败”。这个问题通常由 service 层和数据库事务回答。

## 第一次启动项目

完整配置说明在 [运行、配置与排错](operations.md)。这里先给你一条最短路径，帮助你建立肌肉记忆：

```bash
cp docs/.env.example .env
cp docs/config.toml.example good4ncu.toml
cargo check --locked
cargo run
```

后端默认监听 `0.0.0.0:3000`，健康检查是 `GET /api/health`。如果启动失败，不要慌，通常是这些原因之一：`.env` 没填必需项，`DATABASE_URL` 指向的 PostgreSQL 不可连，`JWT_SECRET` 少于 32 字符，LLM key 没有设置，pgvector extension 不可用，或者 `VECTOR_DIM` 与数据库里的 `documents.embedding` 维度不一致。

移动端第一次运行通常是：

```bash
cd mobile
flutter pub get
flutter analyze
flutter test
flutter run --dart-define=API_BASE_URL=http://127.0.0.1:3000
```

如果你只是改文档，不需要跑 Rust 或 Flutter 测试。如果你改了后端逻辑，至少跑相关 Rust 测试；如果你改了页面、service 或 provider，至少跑 `flutter analyze` 和对应 Dart 测试。

## 新人常用术语

| 术语 | 在本项目里的意思 |
| --- | --- |
| Handler | Axum 路由处理函数，通常在 `src/api/`。负责解析请求、提取 token、返回 HTTP 响应，但不应该塞进复杂业务规则。 |
| Service | 业务逻辑层，通常在 `src/services/`。负责状态机、跨表一致性、事务边界和后台任务。 |
| Repository | 数据访问层，通常在 `src/repositories/`。负责封装 SQL，把数据库细节隔离在较低层。 |
| JWT | 访问令牌。客户端带 `Authorization: Bearer <token>` 调接口，后端从 token 里解析用户 id、角色和过期时间。 |
| Refresh Token | 刷新令牌。访问令牌过期后用它换新 token；本项目会旋转 refresh token，并检测重放。 |
| JTI | JWT ID。每个新 access token 有一个唯一 id，logout 或管理员撤销时可加入 denylist。 |
| Denylist | 已撤销 token 的拒绝列表。即使 token 还没自然过期，也可以被拒绝。 |
| HITL | Human-In-The-Loop。AI 或系统不直接替卖家决定议价结果，而是创建请求等待卖家处理。 |
| pgvector | PostgreSQL 的向量扩展。Good4NCU 用它存储商品 embedding，支持语义搜索和推荐。 |
| Embedding | 把文本变成向量。相似文本的向量距离更近，AI 搜索可以用它找到语义相关商品。 |
| Transaction | 数据库事务。一组写入要么全部成功，要么全部回滚，订单和议价尤其依赖它。 |
| Regression Test | 回归测试。专门保护修过的 bug，防止未来改动把同类问题重新带回来。 |

## 如何判断一个问题属于哪一层

如果请求根本进不来，先看路由、CORS、token、rate limit 和中间件。对应目录通常是 `src/api/`、`src/middleware/` 和移动端 `mobile/lib/services/`。

如果请求进来了但业务结果不对，先看 service。比如订单状态跳错、议价接受后没创建订单、封禁后还能刷新 token，这些都不是页面问题，也不应该只靠 handler 里的 if 解决。

如果业务规则正确但数据不对，去 repository、migration 和 SQL。比如分页 total 不对、查询漏了 status 条件、UUID 字段没有同步、向量搜索没有结果，这些更像数据访问或 schema 问题。

如果后端返回正确但 UI 不更新，去移动端 service、provider/controller 和 page。Flutter 页面应当展示状态，不应重新实现后端业务规则。

如果 AI 回复不稳定，至少同时检查四层：意图路由是否把请求分到正确工具，工具是否正确执行，RAG 文档是否已写入并能检索，LLM provider 是否超时、熔断或返回了异常内容。

## 新人最容易踩的坑

第一，不要把 handler 当作万能层。handler 可以做输入解析和简单校验，但“创建订单时同时锁定商品库存”这种规则属于 service 和事务。

第二，不要在 Flutter 页面里复制后端状态机。页面可以根据 `status` 决定按钮是否显示，但最终合法性必须由后端判断。

第三，不要把金额当浮点数长期存储。接口里常用 `*_cny` 给前端友好展示，数据库和关键逻辑应尽量使用 cents 的整数形式。

第四，不要把 Base64 媒体路径当成长期目标。当前聊天支持 URL-first，同时保留 Base64 fallback；新功能应该优先使用 URL 字段，把 Base64 视为兼容路径。

第五，不要忽略封禁和 token 撤销。登录、refresh、WebSocket 和管理员 impersonation 都要尊重用户状态和 token denylist。

第六，不要随意写迁移。迁移文件只向前走，名字要编号，数据迁移要考虑已有数据、索引、回滚策略和测试库安全。

下一步建议读 [架构与分层](architecture.md)。如果你已经要开始改代码，直接跳到 [开发指南](development.md)。
