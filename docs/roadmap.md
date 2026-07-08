# 路线图与架构风险

这篇文档记录当前工程方向和技术债。它不是需求池，也不是承诺清单；它的作用是让后来接手的人知道：哪些工作已经完成，哪些工作现在最重要，哪些风险需要改代码时顺手收敛。

## 当前已完成的硬化工作

认证链路已经从“能登录”推进到更接近真实系统的会话模型：access token 带 JTI，logout 可撤销当前 token，refresh token 采用旋转策略，并在 replay 时撤销用户所有 refresh token。封禁用户不能登录或 refresh，WebSocket 建连也会检查 token 和用户状态。

订单和议价路径已经把关键写入收敛到事务里。创建订单时商品售出和订单插入一起提交；HITL 接受或买家接受 counter 时，锁定请求、创建订单、写系统消息和状态更新也在事务中完成。这样降低了半成功交易的概率。

用户直聊已经从永久好友连接改为会话式沟通：`realtime` 使用 `syn_sent -> syn_ack -> active` 的短期握手，`mail` 使用无需接通的异步留言线程。消息模型同时支持 URL-first 媒体和 Base64 fallback，方便新客户端走对象存储，旧路径继续兼容。

配置系统已经统一为环境变量优先、TOML 补充、默认值兜底。生产 CORS 有 fail-fast 防护，pgvector 维度启动检查可以提前暴露配置错误。

## 本轮本地已闭环的缺陷修复

最近一轮排查围绕“本地能否顺利启动并完成核心浏览路径”展开，已经在本地代码中完成以下修复：

| 问题 | 修复方向 | 验收方式 |
| --- | --- | --- |
| Web 前端默认连错后端地址 | Flutter 平台工具支持 `API_BASE_URL` 和 `WS_BASE_URL` 编译参数，并从 HTTP 地址推导 WebSocket 地址。 | 用 `--dart-define=API_BASE_URL=http://127.0.0.1:3000` 启动前端后，浏览器可以正常请求本地后端。 |
| 联系买家触发 Navigator key assertion | 商品详情页不再直接创建好友式连接，而是打开“现在聊 / 写封留言”模式面板；创建会话后进入 `user-chat`。 | 在商品详情页点击联系卖家/买家，不再出现 `!keyReservation.contains(key)` 断言。 |
| 普通用户能看到管理后台入口 | `ProfilePage` 只在用户 `role == 'admin'` 时渲染管理入口，并补充 Widget 测试。 | 普通用户“我的”页面不可见管理后台；管理员账号仍可见。 |
| 好友式聊天连接不符合交易沟通心理 | 新增 `chat_conversations`、members、events、blocks，统一收件箱和消息 API，废弃旧 `/connect/*` 语义。 | Rust 会话状态机测试覆盖握手、mutual intent、邮件、归档、已读、屏蔽和过期；Flutter 测试覆盖新状态模型。 |

这些修复属于进入可部署 MVP 前的稳定性基线。合并前仍要跑完整验证命令，避免“本地点通了，但 CI 或其他平台退化”的情况。

## 可部署 MVP 修缮计划

当前计划不是继续堆功能，而是把 Good4NCU 收敛到一个可以可靠演示、可以部署、可以继续迭代的 MVP。默认目标是：后端用 Docker 镜像部署，数据库使用支持 pgvector 的 PostgreSQL，Flutter Web 作为静态站点发布，移动端继续通过同一套 HTTP API 访问后端。

### Phase 0：稳定当前修复并建立基线

先把本轮已经改好的缺陷修复整理成一个清晰 PR。这个阶段不引入新业务能力，只确认当前本地开发链路稳定。

验收清单：

1. `cargo fmt -- --check`
2. `cargo check --locked`
3. `cargo test --lib`
4. `cargo test --test chat_transaction_integration -- --nocapture --test-threads=1`
5. `cd mobile && flutter analyze`
6. `cd mobile && NO_PROXY=127.0.0.1,localhost no_proxy=127.0.0.1,localhost flutter test`
7. `git diff --check`
8. 浏览器手工验证：普通用户资料页隐藏管理入口，商品详情页联系用户不会触发路由断言。

如果这一阶段失败，不继续做 UUID 或部署。先修基线，因为后面的工作都依赖这些路径。

### Phase 1：核心 ID 的 UUID adoption

外部 API 暂时保持字符串 ID，不强迫 Flutter 或第三方调用方立刻感知 UUID 类型。内部实现逐步采用 UUID 语义，避免继续把“旧 TEXT id”“新 UUID id”“path 参数”“token claim”混成同一种普通字符串。

建议顺序：

1. 先从 repository 层开始，给用户、商品、订单、聊天、收藏、通知这些核心表建立统一的 ID 读取/写入辅助函数。
2. 新写入路径优先写 UUID shadow column，同时保留旧字段兼容。
3. 查询路径优先用 UUID join；如果遇到旧数据，再走兼容条件。
4. service 层继续接收字符串参数，但进入 repository 前做一次明确解析和兼容处理。
5. handler 和 Flutter model 暂时不改公开字段名，降低前后端同时断裂的概率。
6. 增加混合数据测试：旧 TEXT 数据、新 UUID 数据、旧新交叉 join 都要覆盖。

阶段验收标准：

1. 新创建用户、商品、订单、聊天会话时 UUID 字段完整写入。
2. 旧测试 fixture 仍能被读取。
3. `orders`、`chat_conversations`、`watchlist`、`notifications`、管理员列表没有 UUID/TEXT decode panic。
4. API JSON 中的 `id`、`user_id`、`listing_id` 等字段仍是字符串。
5. UUID divergence 视图或等价检查结果为零。

### Phase 2：URL-first 媒体路径稳定化

媒体路径的目标不是马上删除 Base64，而是先让 URL-first 成为默认、可测、可排错的主路径。Base64 只作为兼容 fallback 存在，并且要有明确边界。

建议顺序：

1. 统一消息发送、商品图片、语音消息使用 `image_url`、`audio_url` 一类 URL 字段。
2. 上传失败时给用户明确反馈，不把大 Base64 静默塞进普通 JSON 请求。
3. 内容审核优先读取 URL 媒体；Base64 fallback 只在旧数据或旧客户端场景启用。
4. 给 fallback 加日志或指标，确认真实使用量。
5. 当 fallback 使用量接近零后，再讨论数据库字段清理和迁移。

阶段验收标准：

1. 新客户端默认发送 URL 媒体。
2. URL 媒体和 Base64 fallback 都有测试。
3. 文档把 URL-first 写成推荐路径，Base64 写成兼容路径。
4. 大图、大音频不会造成明显请求体膨胀或 Flutter 内存压力。

### Phase 3：前端体验和模块拆分

这个阶段解决“功能能用但维护压力开始变大”的问题。优先拆最容易牵连其他功能的大文件，而不是为了整洁做无收益重构。

建议顺序：

1. 先给 `user_chat_page.dart` 建立行为测试或最小回归用例，再拆 composer、message list、media sender、reply assistant 和会话状态 banner。
2. 再拆 `src/api/user_chat/message.rs`，优先分出媒体、已读、编辑、typing 相关处理；状态转换继续集中在 `ChatConversationService`。
3. 明确 Web token storage 策略，区分 Web 和移动端的安全边界。
4. 继续补齐普通用户路径受管理员动作影响的回归测试，例如封禁后登录、refresh、WebSocket、聊天发送。

阶段验收标准：

1. 拆分后用户聊天、AI 聊天、媒体发送和已读状态行为不变。
2. `flutter analyze` 和 Flutter Widget 测试保持通过。
3. 后端 user chat 相关集成测试保持通过。
4. 新文件按职责命名，不把复杂度从一个大文件搬到另一个大文件。

### Phase 4：部署 MVP

部署阶段先追求可重复、可观察、可回滚，不追求一次性做完支付、结算、对象存储、CDN 全量生产化。

建议默认部署形态：

1. 后端：使用现有 `Dockerfile` 构建 Rust 服务镜像。
2. 数据库：使用 PostgreSQL 16/18 加 pgvector，生产库和测试库分离。
3. 前端：`flutter build web --dart-define=API_BASE_URL=https://你的后端域名`，构建产物放到静态托管或 Nginx。
4. CORS：生产环境显式设置允许的前端域名，不使用通配。
5. 配置：从 `.env` 或平台密钥注入 `DATABASE_URL`、`JWT_SECRET`、LLM key、CORS origin、pgvector 维度。
6. 观测：上线后至少检查 `/api/health`、Prometheus metrics、结构化日志。

阶段验收标准：

1. 新环境可以从空库自动应用迁移并启动。
2. 健康检查返回成功。
3. 浏览器能完成注册/登录/刷新资料/浏览商品/联系用户。
4. 普通用户看不到管理入口，管理员能进入后台。
5. 不在生产环境运行 seed 测试账号。
6. 回滚方案明确：可以回滚镜像，不破坏已应用迁移的数据兼容性。

## Now：核心表 UUID 应用读写 adoption

当前最重要的方向是让应用层逐步采用核心表 UUID 读写，而不是继续扩散旧 TEXT id 假设。迁移已经引入 shadow columns 的方向，下一步要把 Rust repository、service、handler、Flutter model 和测试里的 ID 假设逐步收敛到稳定的 UUID 语义。

这项工作不能只改数据库。验收时要证明：新数据写入 UUID 字段，旧数据仍能被读取，跨表 join 不丢数据，API 返回字段对客户端兼容，订单、聊天、收藏、通知和管理员路径都能正常工作。

建议顺序是：

1. 先确认所有核心表的 UUID shadow column 和索引存在，并有 backfill 路径。
2. 再让 repository 优先读写 UUID，同时兼容旧 TEXT id。
3. 然后收敛 service 和 handler 中对 id 类型的假设。
4. 最后同步 Flutter model、测试 fixture 和文档。

不要在一个 PR 里试图切完所有层。UUID 迁移适合小步、强测试、可观测推进。

## Next：Base64 media fallback cleanup

聊天媒体当前处于 URL-first 加 Base64 fallback 阶段。下一步不是立刻删除 Base64，而是先让新路径足够稳：上传 token、OSS 直传、消息发送、消息展示、图片审核、失败重试和测试都优先覆盖 URL 字段。

等 URL 路径稳定后，再统计 Base64 fallback 是否仍有使用。如果没有真实客户端依赖，可以逐步减少 Base64 存储和传输，降低数据库体积、请求大小和移动端内存压力。

验收标准包括：新客户端默认走 URL；Base64 fallback 有明确开关或兼容边界；媒体消息测试覆盖 URL 和 fallback；文档不再把 Base64 当推荐路径。

## Later：后续方向

| 方向 | 为什么重要 |
| --- | --- |
| 头像审核 UX | 用户头像也属于可见内容，需要审核状态、失败反馈和默认占位体验。 |
| 缩略图 | 列表页不应加载大图，移动端流量和滚动性能都依赖缩略图。 |
| Web token storage | Web 平台 token 存储策略不同于移动端 secure storage，需要明确安全边界。 |
| 线下成交记录 | 平台只记录成交意向和卖家确认，不做资金托管、付款确认或物流追踪；后续重点是把风险提示、自动下架和纠纷证据链做清楚。 |
| `user_chat_page.dart` 拆分 | 用户聊天页面承担输入、媒体、消息列表、会话状态 banner 和 Reply Assistant，继续变大后维护成本会快速上升。 |
| `user_chat/message.rs` 拆分 | 后端消息文件密度较高，媒体、已读、编辑、typing 可以逐步拆到更清晰模块。 |

## UUID 迁移专项

### 已完成方向

迁移层已经出现 shadow column 思路，说明团队已经意识到不能直接把主键类型一刀切。测试中也有 UUID shadow migration integration，说明迁移安全性开始被纳入验证。

### 未完成风险

最大风险是应用层仍把 id 当普通字符串自由传递。字符串本身不是问题，问题是它隐藏了语义：有些字符串是旧 TEXT id，有些是 UUID，有些来自 path 参数，有些来自 token claim，有些来自数据库 join。迁移期如果不明确每条路径读写哪个字段，就容易出现“新数据能写但旧数据查不到”或“某个 join 仍用旧字段”的问题。

第二个风险是测试 fixture。很多测试会手写 id，如果测试数据只覆盖旧格式，就无法发现 UUID 路径坏掉；如果只覆盖 UUID，又可能漏掉兼容旧数据的问题。

### 安全护栏

新迁移必须可重复运行，并能在已有数据上安全 backfill。repository 应优先封装兼容逻辑，不要让 handler 到处判断新旧 id。涉及订单、聊天、收藏和通知的查询要特别检查 join 条件。

测试上至少覆盖：新用户/商品/订单写入，旧数据读取，混合数据 join，管理员列表，移动端解析。日志中如果打印 id，要避免泄漏敏感信息，但保留足够上下文排查迁移问题。

### 验收标准

UUID adoption 不能只以“编译通过”为标准。更合理的验收是：

1. 新写入路径使用目标 UUID 字段。
2. 旧数据通过兼容查询仍可读取。
3. 核心 API 返回对客户端稳定。
4. 订单、聊天、收藏、通知、管理员路径都有测试覆盖。
5. 迁移和回填过程有可观测日志。
6. 文档更新，说明当前 ID 语义和剩余兼容期。

## 架构风险清单

| 风险 | 表现 | 应对 |
| --- | --- | --- |
| 核心 ID 迁移 | TEXT 与 UUID 假设混用，join 或 path 解析容易漏。 | 小步迁移，repository 封装兼容，测试覆盖混合数据。 |
| AI 聊天页面过大 | 一个页面处理太多状态，修一个功能影响另一个功能。 | 拆 controller、composer、media sender、message list 和 agent panel。 |
| Base64 fallback 长期存在 | 请求体变大、数据库膨胀、移动端内存压力高。 | URL-first 稳定后逐步收敛 fallback。 |
| `user_chat/message.rs` 密度高 | 消息发送、媒体、已读、编辑、typing 混在一起。 | 按职责拆文件，保持 handler 薄、service 清晰。 |
| AI 工具跨层复杂 | prompt、工具、权限、SQL、LLM provider 混合排错。 | 工具保持可测试，权限不交给 LLM，RAG 写入和查询可观测。 |
| 管理员动作影响普通路径 | 封禁、下架、撤销 token 只测管理员成功，漏普通用户行为。 | 管理员测试必须带一个受影响普通路径。 |

路线图会变化，但风险清单应该保持诚实。每次大改动后，如果你发现新的系统性风险，不要只在 PR 描述里提一句，应该更新这里。
