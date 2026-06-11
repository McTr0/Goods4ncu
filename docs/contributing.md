# 贡献指南

这篇文档说明如何把改动安全地送进项目。它不代替代码审查，也不重复开发命令细节；命令含义见 [开发指南](development.md)，架构边界见 [架构与分层](architecture.md)。

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
| 状态机 | 订单、聊天连接、HITL 议价是否只允许合法跳转。 |
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

文档结构由 [README](README.md) 串联。新增主题前先确认是否已有专题文件。API 细节进 [API 参考](api-reference.md)，流程进 [业务流程](domain-flows.md)，配置排错进 [运行、配置与排错](operations.md)，路线图进 [路线图与架构风险](roadmap.md)。

写文档时不要为了“显得简单”而省略真实边界。好的新人文档不是把系统讲成玩具，而是把复杂性分层，让读者知道先理解哪一块、后理解哪一块。
