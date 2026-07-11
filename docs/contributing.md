# 贡献指南

| 项目 | 内容 |
| --- | --- |
| 适用读者 | 所有提交代码、迁移、设计或运维变更的贡献者与 reviewer |
| 当前状态 | 当前 Git/PR 规则可直接使用；ADR、生产门槛和能力状态规则用于后续生产化变更 |
| 事实来源 | 仓库 Git 历史、AGENTS.md、CI、开发指南和设计文档 |
| 最后核对范围 | 分支、Conventional Commits、PR、review、迁移、兼容、ADR 和文档同步 |

这篇文档说明如何把改动安全地送进项目。命令含义见 [开发指南](development.md)，当前边界见 [当前架构](architecture.md)，目标边界见[生产架构](production-architecture.md)。

## 分支命名

功能分支通常使用：

```text
feat/<description>
fix/<description>
docs/<description>
chore/<description>
```

描述用英文短语，表达改动目标。例如 `feat/watchlist-badge`、`fix/refresh-replay`、`docs/onboarding-handbook`。如果由编码代理创建分支，默认前缀可能是 `codex/`，但仍应让分支名读起来像一个具体任务。

## Conventional Commits

提交信息使用 Conventional Commits，常见格式：

```text
fix(auth): block refresh replay
feat(mobile): add watchlist badge
docs: split handbook by topic
refactor(chat): isolate media sender
test(order): cover paid cancellation
```

scope 应该帮助 reviewer 快速定位影响范围。不要用过大的 scope 掩盖真实改动；如果一个提交同时改 auth、orders 和 chat，通常说明它可以拆得更小，或者需要在正文解释为什么必须一起改。

## PR 内容

PR 描述至少包含：

```markdown
## Summary

- What changed.
- Why it changed.

## Test Plan

- Command or test name.
- Manual verification if any.

## Risk

- Migrations, config changes, compatibility risks, follow-up work.

## Design & Compatibility

- Capability status before/after: target, experimental, implemented, deprecated.
- API/schema/client compatibility and deprecation window.

## Observability & Rollback

- Metrics/logs/alerts affected.
- Feature flag, rollback or kill switch.
```

如果有数据库迁移、配置变更、移动端可见 UI、管理员权限、认证、支付/订单、AI 工具或媒体上传，一定在 PR 里单独说明。移动端 UI 改动应提供截图或录屏。

## 合并前检查

后端常规检查：

```bash
cargo fmt -- --check
cargo clippy --all-targets -- -D warnings
cargo test -- --nocapture --test-threads=1
```

较快的开发中间态可以先跑：

```bash
cargo check --locked
cargo test --lib
```

移动端常规检查：

```bash
cd mobile
flutter analyze
flutter test
```

只改文档时：

```bash
git diff --check
rg --files -g '*.md' -g '*.mdx'
```

不要机械地把所有命令塞进 PR。测试计划应该说明为什么这些验证覆盖了你的改动路径。

## Review 重点

Reviewer 应优先看风险，而不是先挑风格。重点包括：

| 领域 | 需要看什么 |
| --- | --- |
| 认证 | token 是否可撤销，refresh 是否旋转，封禁是否生效。 |
| 权限 | 用户是否只能操作自己的资源，管理员接口是否真的要求 admin。 |
| 事务 | 跨表写入是否同生共死，失败时是否会留下半成功状态。 |
| SQL | 用户输入是否 bind，动态 SQL 是否来自白名单。 |
| 状态机 | 订单、聊天会话、HITL 议价是否只允许合法跳转。 |
| 多租户 | tenant context 是否来自可信认证，查询/关联是否可能跨校园。 |
| Agent | 风险等级、确认、幂等、工具权限和失败降级是否完整。 |
| 推荐 | 硬约束、解释、反馈、公平 guardrail 和排序版本是否可验证。 |
| 审核隐私 | 媒体是否先隔离，敏感数据是否最小访问并可审计。 |
| 异步事件 | 事务、outbox、重复消费、重试和 dead-letter 是否一致。 |
| 移动端 async | 页面销毁、重复请求、token refresh、错误态是否处理。 |
| 协议兼容 | Rust struct、Dart model、service 和测试 fixture 是否同步。 |
| 运维 | 新配置是否有默认值、模板、生产安全边界和排错说明。 |

如果没有发现问题，review 也应该说明残余风险。例如“未发现 blocking issue；没有本地 PostgreSQL，所以数据库迁移只做了静态检查”。

## 新人第一个 PR 建议

第一类适合新人的是文档修正或测试补充。它能帮助你熟悉流程，又不会一开始就碰订单事务或认证链路。

第二类是小型 UI 或文案改动。注意用户可见文案要走 l10n，页面逻辑不要直接拼 HTTP。

第三类是明确边界的小 bug，例如收藏自己的商品提示、列表空状态、分页参数校验。选题时尽量满足三个条件：影响范围清楚，有现成测试位置，失败和成功都容易验证。

不建议把第一个 PR 选成 UUID 迁移、订单状态机、token refresh、AI 工具链或聊天媒体大改。不是因为新人不能做，而是这些路径牵涉太多层，适合作为第二阶段任务，在你已经熟悉测试和 review 节奏之后再上手。

## 文档协作规则

文档结构由 [README](README.md) 串联。新增主题前先确认是否已有专题文件：

- 产品目标和边界进[产品设计](product-design.md)。
- 对象和不变量进[信息模型](information-model.md)。
- Agent 权限和评估进[Agent 系统设计](agent-system.md)。
- 身份、审核和隐私进[信任与安全](trust-safety.md)。
- 当前代码结构进[当前架构](architecture.md)，目标部署进[生产架构](production-architecture.md)。
- API 细节进 [API 参考](api-reference.md)，流程进 [业务流程](domain-flows.md)。
- 配置排错进 [运行、配置与排错](operations.md)，阶段计划进 [生产路线图](roadmap.md)。

所有目标能力必须写 `[目标态]`。只有 migration、后端、客户端、测试和必要运维门槛共同完成后，才改为 `[已实现]`；原型或未稳定能力使用 `[实验中]`。

重大架构决定需要记录 Context、Decision、Consequences、Compatibility、Verification 和 Exit criteria。影响多个模块或需要长期兼容时拆为 ADR，并在相关专题文档链接。

写文档时不要为了“显得简单”而省略真实边界。好的新人文档不是把系统讲成玩具，而是把复杂性分层，让读者知道先理解哪一块、后理解哪一块。
