# 路线图与架构风险

这篇文档记录当前工程方向和技术债。它不是需求池，也不是承诺清单；它的作用是让后来接手的人知道：哪些工作已经完成，哪些工作现在最重要，哪些风险需要改代码时顺手收敛。

## 当前已完成的硬化工作

认证链路已经从“能登录”推进到更接近真实系统的会话模型：access token 带 JTI，logout 可撤销当前 token，refresh token 采用旋转策略，并在 replay 时撤销用户所有 refresh token。封禁用户不能登录或 refresh，WebSocket 建连也会检查 token 和用户状态。

订单和议价路径已经把关键写入收敛到事务里。创建订单时商品售出和订单插入一起提交；HITL 接受或买家接受 counter 时，锁定请求、创建订单、写系统消息和状态更新也在事务中完成。这样降低了半成功交易的概率。

聊天与媒体路径已经开始从 Base64 迁移到 URL-first。消息模型同时支持 `image_url`、`audio_url` 和 Base64 fallback，方便新客户端走对象存储，旧路径继续兼容。

配置系统已经统一为环境变量优先、TOML 补充、默认值兜底。生产 CORS 有 fail-fast 防护，pgvector 维度启动检查可以提前暴露配置错误。

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
| 支付和结算 | 当前订单状态机模拟交易流程，真实支付/托管/结算会引入更严格的一致性要求。 |
| `chat_page.dart` 拆分 | 聊天页面承担输入、媒体、消息列表、AI 面板和连接状态，继续变大后维护成本会快速上升。 |
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
