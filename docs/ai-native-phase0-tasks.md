# Phase 0 工作拆解：撤销基础设施 + 打扰预算

> 依据 [AI-Native 路线图](ai-native-roadmap.md) 第四节 Phase 0。这是所有后续阶段的地基，两块互相独立，可并行。
>
> 迁移编号从 **0044** 起（当前最大为 0043）。

---

## 模块一：撤销基础设施

**目标**：把 ActionPlan 的 L2 动作从"事前弹确认"改为"直接执行 + 撤销窗口"。

### 数据模型（迁移 0044）

```sql
-- 每个可撤销动作记录它的反向操作。
CREATE TABLE reversible_actions (
    id              UUID PRIMARY KEY,
    campus_id       UUID NOT NULL REFERENCES campuses(id),
    actor_user_id   UUID NOT NULL REFERENCES users(id),

    action_kind     TEXT NOT NULL,     -- listing.publish / listing.price_update / ...
    target_type     TEXT NOT NULL,     -- inventory / chat_space_member / ...
    target_id       UUID NOT NULL,

    -- 反向操作所需的完整状态。撤销时只读这里，不重新查当前状态，
    -- 否则并发下会把别人的后续修改一起回滚掉。
    inverse_op      JSONB NOT NULL,
    prior_state     JSONB NOT NULL,

    undo_deadline   TIMESTAMPTZ NOT NULL,
    undone_at       TIMESTAMPTZ,
    undone_reason   TEXT,

    created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_reversible_actions_actor_open
    ON reversible_actions (actor_user_id, undo_deadline)
    WHERE undone_at IS NULL;

-- 与既有租户隔离一致（比照 0042_tenant_rls）
ALTER TABLE reversible_actions ENABLE ROW LEVEL SECURITY;
ALTER TABLE reversible_actions FORCE ROW LEVEL SECURITY;
```

### 代码变更

| 文件 | 变更 |
| --- | --- |
| `src/services/agent_plan.rs` | 动作分级从二元（需确认 / 不需要）改为 L1 / L2 / L3；L2 走"执行 + 登记反向操作"路径 |
| `src/services/undo.rs`（新建） | `register()` / `undo()` / `expire_sweeper()`。撤销必须幂等——重复调用返回同一结果而非报错 |
| `src/api/agent_plans.rs` | 新增 `POST /api/actions/{id}/undo`；L2 响应体带 `undo_token` 与 `undo_deadline` |
| `src/repositories/` | 每个 L2 目标类型实现反向操作（发布↔下架、改价↔还原、加入↔退出） |
| 后台 worker | 到期清理，复用 `tick_or_shutdown`（`src/lifecycle.rs`），不要新起裸循环 |

### 必须写的测试

- **幂等**：同一 `undo_token` 连续调用两次，第二次不产生副作用
- **并发**：撤销与他人的并发修改交错时，只回滚本次动作的字段，不覆盖他人改动
- **过期**：超过 `undo_deadline` 拒绝撤销，返回明确错误而非静默成功
- **越权**：非发起者无法撤销他人动作（且跨校园不可见——RLS 集成测试）
- **回归**：L3（钱 / 身份）仍走事前确认；confirmation token 不出现在模型可见文本中（沿用现有注入回归测试）

### 退出门槛

- L2 动作 100% 可逆，撤销幂等，并发测试通过
- L3 事前确认与防注入测试全绿（不得因本次改动降级）
- 撤销入口在结果卡片上，不是独立待办列表

---

## 模块二：打扰预算

**目标**：主动打扰在**架构层**受限，绕不过去。

### 数据模型（迁移 0045）

```sql
CREATE TABLE interruption_ledger (
    id              UUID PRIMARY KEY,
    campus_id       UUID NOT NULL REFERENCES campuses(id),
    user_id         UUID NOT NULL REFERENCES users(id),

    channel         TEXT NOT NULL,     -- push / in_app / email
    topic           TEXT NOT NULL,     -- match_found / agreement_reminder / space_formed
    reason          TEXT NOT NULL,     -- 给用户看的人话理由
    expected_value  REAL NOT NULL,     -- 低于阈值不发

    delivered_at    TIMESTAMPTZ,       -- NULL = 被预算拦下，仅入收件箱
    accepted_at     TIMESTAMPTZ,       -- 用户点开 / 采纳
    dismissed_at    TIMESTAMPTZ,

    created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_interruption_ledger_budget
    ON interruption_ledger (user_id, delivered_at)
    WHERE delivered_at IS NOT NULL;

CREATE TABLE interruption_preferences (
    user_id         UUID PRIMARY KEY REFERENCES users(id),
    daily_budget    SMALLINT NOT NULL DEFAULT 3,
    muted_topics    TEXT[] NOT NULL DEFAULT '{}',
    quiet_until     TIMESTAMPTZ,       -- “最近别烦我”
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);
```

两表同样 `ENABLE` + `FORCE ROW LEVEL SECURITY`。

### 代码变更

| 文件 | 变更 |
| --- | --- |
| `src/services/interruption.rs`（新建） | **唯一**的主动投递入口。签名强制携带 `reason` + `expected_value`，没有这两项编译不过 |
| `src/services/notification.rs` | 所有主动通知改为经 `interruption` 服务；被动通知（用户自己的动作结果）不受预算约束 |
| `src/api/notifications.rs` | 新增偏好读写、"为什么给我推这条"查询、accept / dismiss 回执 |
| 降权逻辑 | 按 topic 统计接受率，连续被 dismiss 的 topic 自动降 `expected_value` 权重 |

### 必须写的测试

- **架构层强制**：绕过 `interruption` 服务直接调用投递层的路径不存在（用类型系统保证，并加一条测试断言无旁路）
- **预算耗尽**：第 4 条当日打扰不投递，但仍入收件箱可查
- **静音**：`quiet_until` 与 `muted_topics` 生效
- **阈值**：`expected_value` 低于阈值不投递
- **可解释**：任一已投递条目都能查到 `reason`

### 退出门槛

- 日打扰上限有架构层测试
- 用户可查看"为什么给我推这条"
- 接受率统计可用，低于 40% 自动收紧预算

---

## 建议实施顺序

```
1. 迁移 0044 + undo.rs + 反向操作（先只支持 listing.publish 一种，打通链路）
2. 扩展到全部 L2 动作类型
3. 迁移 0045 + interruption.rs
4. notification.rs 改造为经预算投递
5. 前端：撤销按钮内联到结果卡片；通知偏好页
```

第 1 步刻意只做一种动作类型——先把"执行 → 登记 → 撤销 → 过期"整条链路和并发语义验证清楚，再铺开，避免五种动作类型一起返工。

---

## 不能碰的底线

- 已应用的迁移不可修改（sqlx checksum；本项目已因此中断过一次部署）
- L3 事前确认与 confirmation token 不进模型上下文，不因本次改动放宽
- 新表一律 `FORCE ROW LEVEL SECURITY`，应用角色不得为 superuser
- 所有质量门禁保持全绿：`cargo fmt`、`clippy -D warnings`、全部 Rust 套件、`flutter analyze`、Flutter 测试
