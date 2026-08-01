# 开发指南

| 项目 | 内容 |
| --- | --- |
| 适用读者 | 后端、Flutter、AI、测试工程师和准备提交代码的新人 |
| 当前状态 | 命令和当前分层可直接使用；多租户、crash-safe ActionPlan 和 outbox 已有实现，剩余目标按设计文档实施 |
| 事实来源 | Cargo/Flutter 配置、AGENTS.md、CI workflow、目录结构和现有测试 |
| 最后核对范围 | 本地启动、验证命令、常见开发任务、协议兼容、SQL、async 和设计同步 |

这篇文档回答“怎么开发”。它不重复解释每个状态机，也不列完整 API 字段；业务语义见 [业务流程](domain-flows.md)，接口形状见 [API 参考](api-reference.md)，配置排错见 [运行、配置与排错](operations.md)，目标架构见[生产架构](production-architecture.md)。

## 本地环境

后端需要 Rust toolchain、PostgreSQL 和 pgvector。数据库测试需要单独的测试库，并通过 `TEST_DATABASE_URL` 指向安全数据库。项目里有测试安全护栏：会清理数据的测试不应该连接到生产库或普通开发库。

移动端需要 Flutter SDK。第一次拉取后先运行 `flutter pub get`，然后再 analyze、test 或 run。移动端连接本地后端时，通常通过 `--dart-define=API_BASE_URL=http://127.0.0.1:3000` 指定 API 地址。

推荐先复制配置模板：

```bash
cp docs/.env.example .env
cp docs/config.toml.example goods4ncu.toml
```

`.env` 放密钥和连接串，`goods4ncu.toml` 放非敏感配置。两者的完整解释见 [运行、配置与排错](operations.md)。

## 常用命令和含义

| 命令 | 用途 | 什么时候用 |
| --- | --- | --- |
| `cargo check --locked` | 快速检查 Rust 是否能编译，不生成完整测试结果。 | 后端改动后的第一道门。 |
| `cargo fmt -- --check` | 检查 Rust 格式。 | 提 PR 前必须跑。 |
| `cargo clippy --all-targets -- -D warnings` | 静态检查 Rust 代码质量，并把 warning 当错误。 | 提 PR 前或较大后端改动后跑。 |
| `cargo test --lib` | 跑 Rust library 测试，速度较快。 | 改 service、repository、工具函数时常用。 |
| `cargo test -- --nocapture --test-threads=1` | 跑完整 Rust 测试，并串行执行。 | 合并前或数据库相关改动后。 |
| `cargo run` | 启动本地后端。 | 手动联调或移动端连本地后端时。 |
| `flutter analyze` | 检查 Dart/Flutter 静态问题。 | 移动端改动后。 |
| `flutter test` | 跑移动端测试。 | 改 service、provider、页面状态后。 |
| `git diff --check` | 检查 diff 中的空白错误。 | 文档和代码改动都适用。 |

CI 期望的后端合并前检查通常是：

```bash
cargo fmt -- --check
cargo clippy --all-targets -- -D warnings
cargo test -- --nocapture --test-threads=1
```

移动端合并前检查通常是：

```bash
cd mobile
flutter analyze
flutter test
```

## 按改动类型选择测试

| 改动类型 | 最小可信验证 |
| --- | --- |
| 只改文档 | `git diff --check`，再检查 Markdown 链接。 |
| 改 Rust handler 参数或返回 | `cargo check --locked`，相关 API/回归测试。 |
| 改 service 状态机 | 相关 service/integration/regression 测试，必要时完整 `cargo test`。 |
| 改 repository 或 migration | 数据库集成测试，确认测试库安全，检查旧数据迁移路径。 |
| 改认证、封禁、refresh、logout | 认证回归测试，手动关注 token rotate、denylist 和 banned 用户。 |
| 改聊天、WebSocket、媒体 | 聊天 integration/e2e 测试，移动端相关 service/page 测试。 |
| 改 Flutter 页面 | `flutter analyze`，相关 widget/controller/service 测试。 |
| 改前后端协议 | 后端测试、Dart model/service 测试、手动确认字段名兼容。 |
| 改 tenant/membership | A/B 校园隔离、未认证写入拒绝、管理员范围和审计测试。 |
| 改推荐/匹配 | 硬约束、fallback、解释字段、离线评估和 Feed GUI 验收。 |
| 改 Agent 工具 | tool/service 单测、ActionPlan/确认/幂等、越权评估和故障降级。 |
| 改 outbox/worker | 事务一致性、重复消费、重试、dead-letter 和 lag 指标。 |

不要用“我只改了一行”来判断测试范围。应该问：这行影响哪条业务路径，是否改变权限、状态、事务、协议或 UI 生命周期。

## 常见任务步骤

### 新增后端接口

先在 [API 参考](api-reference.md) 里确认是否已有相近接口。然后在 `src/api/` 新增或扩展 handler，把路由注册到 `src/api/mod.rs`。handler 只做协议层工作：解析 JSON/query/path/header，提取用户，做明显的字段校验，然后调用 service 或 repository。

如果接口涉及跨表写入、状态转换、订单、议价、封禁、通知或后台任务，先写 service 方法，再让 handler 调 service。最后补测试：纯参数校验可以单元测试，真实数据库行为应放到 `tests/` 的 integration 或 regression 测试。

新增接口后更新 [API 参考](api-reference.md)。如果它改变业务流程，也更新 [业务流程](domain-flows.md)。

生产目标的新接口优先进入 `/api/v1`，但不要直接删除当前 `/api/*`。写接口先定义幂等行为和稳定错误 code；列表先定义 cursor 的排序稳定性。普通业务接口必须从认证上下文得到用户和 tenant，不能信任 body 中的 `user_id`/`campus_id`。

### 修改数据库

新增迁移文件放在 `migrations/`，文件名使用递增编号，例如 `0018_add_example.sql`。迁移要只向前执行，不要修改已经合并过的旧迁移。

修改 schema 前先想清楚三件事：已有数据如何填充，新旧代码是否会短暂共存，索引和约束是否会影响启动迁移时间。涉及核心 ID、订单、用户、聊天消息的迁移要格外谨慎，并补回归测试。

本项目启动时会初始化 pgvector extension 并运行迁移。迁移失败应该阻止应用继续启动，而不是让应用在半初始化 schema 下继续跑。

### 修 bug

先把 bug 归类。是协议参数错、权限错、业务状态错、SQL 查询错、移动端状态没刷新，还是配置问题？归类后再找文件，而不是先全文搜索一个字段然后到处改。

修复时最好先写或定位一个能失败的测试。回归测试名称要表达行为，例如 `refresh_replay_revokes_all_sessions` 或 `self_watchlist_is_rejected`。修完以后让这个测试变绿，再跑必要的上层验证。

### 改 Flutter 页面

先确认页面是否已经有 service 和 provider/controller。页面里不要直接拼 HTTP，也不要把后端状态机搬到 Dart。页面负责展示状态和触发动作，service 负责请求，provider/controller 负责异步状态、刷新和错误态。

异步加载时要注意 widget 生命周期。`await` 之后如果要使用 `context` 或更新 state，先确认 widget 仍然 mounted。Controller/provider 里要避免让旧请求覆盖新请求，尤其是聊天、通知和搜索页面。

用户可见文案应该进入 `mobile/lib/l10n/`，不要散落硬编码。

### 改前后端协议

协议改动要同时考虑四个位置：Rust request/response struct，Dart model，Dart service，测试 fixture。字段改名比新增字段危险，因为旧客户端可能还在发旧字段。能兼容时优先新增字段并保留旧字段一段时间。

如果协议涉及媒体，优先使用 URL 字段，例如 `image_url` 和 `audio_url`。Base64 字段只作为 fallback，不应成为新功能的主路径。

协议文档必须标明 `[已实现]` 或 `[目标态]`。目标字段可以先进入设计文档，但只有 router、struct、客户端解析和测试完成后才能改为已实现。

### 新增或修改 Agent 工具

先在 [Agent 系统设计](agent-system.md) 判断风险等级。L0/L1 可以直接回答或草拟；只有满足原子、条件式撤销的可恢复 L2 才能立即执行，其他 L2/L3 必须使用 ActionPlan 或在生产配置中禁用。

工具只做协议适配：身份、tenant、owner、状态、金额和事务仍由 service 校验。为工具声明输入 schema、side effects、幂等、审计类别和失败类型，并覆盖 prompt injection、跨用户/校园、资源状态变化和 provider timeout。

不要通过修改 prompt 修复本应由权限或数据库约束处理的问题。

### 新增后台任务

当前 worker 可以使用现有运行方式，但生产关键副作用必须规划迁入 transactional outbox。新增任务时定义：

- 事件 schema 和版本。
- 事务内何时写 outbox。
- 消费幂等键。
- 可重试/不可重试错误。
- 最大尝试、退避、dead-letter 和重放权限。
- lag、成功、重试和失败 metrics。

Worker 重复执行不能创建重复通知、消息、embedding 或状态转换。

## 测试应该放在哪里

| 测试类型 | 位置 | 适合内容 |
| --- | --- | --- |
| Rust 单元测试 | 对应 `src/` 文件的 `#[cfg(test)]` 模块 | 纯函数、参数校验、状态转换、小型 helper。 |
| Rust 集成测试 | `tests/*_integration.rs` | 需要真实数据库、HTTP 路径或跨模块协作的行为。 |
| Rust 回归测试 | `tests/*_regression.rs` | 已修复 bug 的保护，尤其是认证、权限、订单、AI 工具。 |
| Flutter service 测试 | `mobile/test/services/*_test.dart` | API service、token storage、WebSocket/SSE client 行为。 |
| Flutter page/controller 测试 | `mobile/test/pages/*_test.dart` | 页面状态、按钮逻辑、异步生命周期和 controller 行为。 |
| Flutter provider 测试 | `mobile/test/providers/*_test.dart` | 状态管理、刷新、错误态、缓存和通知。 |

测试名称应该说清楚“什么行为被保证”，而不是只写函数名。例如 `banned_user_cannot_refresh_token` 比 `test_refresh` 更有价值。

## SQL 安全基线

优先使用 `sqlx::query` 或 repository 方法的 bind 参数：

```rust
let row = sqlx::query("SELECT owner_id FROM inventory WHERE id = $1")
    .bind(&listing_id)
    .fetch_optional(&pool)
    .await?;
```

避免把用户输入拼到 SQL 字符串里：

```rust
let sql = format!("SELECT * FROM inventory WHERE title = '{}'", title);
```

有些场景会动态选择固定 SQL 片段，例如订单列表按 buyer/seller 选择不同 where clause。这种做法只有在片段来自白名单、用户输入仍然通过 bind 参数传递时才安全。

金额字段要小心。接口里可以使用 `suggested_price_cny: 99.99` 方便前端，但数据库和交易逻辑应转成 cents 的整数，避免浮点误差污染订单。

## Flutter async 生命周期

Flutter 中最常见的异步 bug 是：请求发出时页面还在，请求回来时页面已经销毁。`await` 之后如果要 `setState`、导航或读 `context`，先检查 `mounted`。

第二类问题是竞态。用户连续搜索、快速切换聊天会话、下拉刷新同时触发自动刷新，都可能让旧请求晚于新请求返回。provider/controller 应该记录当前请求上下文，必要时忽略过期结果。

第三类问题是 token refresh。移动端 service 遇到 401 时要明确区分 access token 过期、refresh 失败、用户被封禁和本地 token 缺失。不要在页面里各自实现一套刷新逻辑。

## 文档同步

代码改动影响接口字段时更新 [API 参考](api-reference.md)。影响业务状态机时更新 [业务流程](domain-flows.md)或[信息模型](information-model.md)。影响 Agent 权限和工具时更新[Agent 系统设计](agent-system.md)。影响身份、审核、隐私和管理员边界时更新[信任与安全](trust-safety.md)。影响启动、配置、部署、metrics 或排错时更新 [运行、配置与排错](operations.md)。影响生产阶段和技术债时更新 [生产路线图](roadmap.md)。

能力状态改动遵循：

```text
[目标态]
  -> migration / backend / client / tests 完成
  -> [实验中]
  -> 真实用户与生产门槛验证
  -> [已实现]
```

不要因为某张表或某个 endpoint 已存在就直接标记稳定；如果权限、UI、故障降级和测试尚未完成，仍应是实验中。

## 架构决策记录

重大决策先记录在对应专题文档，内容至少包括：

| 项目 | 要回答的问题 |
| --- | --- |
| Context | 当前问题、约束、容量和风险是什么？ |
| Decision | 选择什么，明确不选择什么？ |
| Consequences | 得到什么，付出什么维护成本？ |
| Compatibility | 对 schema、API、客户端和历史数据有什么影响？ |
| Verification | 用什么测试、指标或演练证明有效？ |
| Exit criteria | 哪些真实信号出现时需要重新评审？ |

当同一决策影响三个以上模块、需要长期兼容或存在多个合理替代方案时，再在后续 PR 拆为独立 ADR。ADR 只记录决定和后果，不复制完整 API 或运维手册。

文档不是 PR 的装饰品。它是下一位同学接手时的地图。
