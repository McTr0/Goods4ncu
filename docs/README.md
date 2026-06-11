# Good4NCU 文档入口

Good4NCU 是一个面向南昌大学校园二手交易场景的全栈工程：Flutter 移动端负责用户界面，Rust Axum 后端负责 API、实时消息和业务事务，PostgreSQL 与 pgvector 同时承载关系型数据和语义检索，AI Agent 帮助用户搜索、发布、议价和理解商品。

这份 README 不是一本完整手册，而是整套文档的入口。新人应该从这里开始，根据自己的任务进入对应章节；同一主题只在一个专题文件中维护，其他地方只链接，避免同一件事在多个文档里慢慢分叉。

## 推荐阅读路径

| 你现在想做什么 | 建议路线 |
| --- | --- |
| 第一次接触项目 | 先读 [新人导览](onboarding.md)，再读 [架构与分层](architecture.md)，最后按需要进入 [开发指南](development.md)。 |
| 写后端功能 | 先确认 [架构与分层](architecture.md) 的边界，再按 [开发指南](development.md) 选择测试，接口细节查 [API 参考](api-reference.md)。 |
| 改 Flutter 页面 | 先看 [新人导览](onboarding.md) 的产品角色，再看 [架构与分层](architecture.md) 的移动端分层，协议字段查 [API 参考](api-reference.md)。 |
| 排查线上或本地问题 | 从 [运行、配置与排错](operations.md) 开始，再跳到对应的 [业务流程](domain-flows.md)。 |
| 准备 PR | 读 [贡献指南](contributing.md)，然后回到 [开发指南](development.md) 选择最小但可信的验证命令。 |
| 判断当前工程方向 | 读 [路线图与架构风险](roadmap.md)，尤其是 UUID 迁移、媒体上传和大文件拆分部分。 |

## 文档地图

| 文档 | 职责 |
| --- | --- |
| [新人导览](onboarding.md) | 像教材第一章一样解释 Good4NCU 是什么、有哪些角色、一次交易怎样发生，以及新人常见术语。 |
| [架构与分层](architecture.md) | 解释 Flutter、Rust Axum、PostgreSQL、pgvector、WebSocket、SSE、AI/RAG 的结构关系和代码边界。 |
| [开发指南](development.md) | 说明本地启动、常用命令、测试选择、常见开发任务、SQL 安全和 Flutter async 生命周期。 |
| [业务流程](domain-flows.md) | 串联认证、商品、直聊、AI Agent、订单、HITL 议价、内容审核和媒体上传的业务状态流。 |
| [API 参考](api-reference.md) | 记录常用接口的请求形状、响应边界、权限要求和行为约束。 |
| [运行、配置与排错](operations.md) | 说明环境变量、TOML 搜索顺序、数据库要求、迁移、CORS、metrics、日志、表地图和排错路径。 |
| [路线图与架构风险](roadmap.md) | 记录当前工程重点、UUID 迁移专项、下一步清理方向和需要持续关注的架构风险。 |
| [贡献指南](contributing.md) | 说明分支命名、Conventional Commits、PR 内容、合并前检查和新人第一个 PR 的选择。 |

## 配置模板和仓库规则

[环境变量模板](.env.example) 和 [TOML 配置模板](config.toml.example) 继续独立存在。它们是可复制的样例，不并入叙述性文档：`.env` 负责密钥和连接串，`good4ncu.toml` 负责非敏感运行参数。

根目录 [AGENTS.md](../AGENTS.md) 也继续独立存在。它面向编码代理和仓库协作规则，不是新人学习项目的主线文档；人类读者需要理解工程时，以 `docs/README.md` 为入口。

## 文档维护规则

同一主题只在一个文件维护。API 字段只写在 [API 参考](api-reference.md)，状态机只写在 [业务流程](domain-flows.md)，配置和排错只写在 [运行、配置与排错](operations.md)，路线图只写在 [路线图与架构风险](roadmap.md)。其他文件需要提到时，只描述上下文并链接过去。

新增文档前先问一个问题：它是否真的有新的职责？如果只是补充某个已有主题，应该更新对应专题文件，而不是再开一个入口。文档可以长，但职责要窄；可以详细，但不要复制粘贴同一段解释。

## 快速启动索引

完整说明见 [开发指南](development.md) 和 [运行、配置与排错](operations.md)。第一次本地启动通常只需要记住这个顺序：

```bash
cp docs/.env.example .env
cp docs/config.toml.example good4ncu.toml
cargo check --locked
cargo run
```

移动端依赖和运行见 [开发指南](development.md)。如果你还不知道每条命令背后的含义，不要急着背命令，先读 [新人导览](onboarding.md)：理解系统地图以后，命令会变得非常自然。
