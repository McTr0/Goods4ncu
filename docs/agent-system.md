# Agent 系统设计：从理解意图到受控行动

| 项目 | 内容 |
| --- | --- |
| 适用读者 | AI/后端工程师、产品经理、安全工程师、测试工程师和 Agent 工具维护者 |
| 当前状态 | 已有意图路由、耐久 RAG 投影、多个 LLM provider 和市场工具；ActionPlan 已 crash-safe，统一 AgentRun/审计与 ListingCommandService 仍是目标态 |
| 事实来源 | `src/agents/`、`src/llm/`、聊天 API、工具测试、LLM metrics 和 Flutter 小帮入口 |
| 最后核对范围 | 搜索、发布、更新、删除、成交意向、议价、回复建议和流式回复 |

Agent 的价值是把用户意图翻译为可理解、可检查、可撤销的系统动作。它不是新的权限主体，也不是绕过产品流程的快捷通道。

## 设计目标

1. 用户可以先说目标，不需要先学会页面结构和数据库字段。
2. Agent 说明自己理解了什么、准备做什么、哪些信息仍不确定。
3. 高风险动作必须停在确认边界前，不能用一段自然语言代替授权。
4. LLM、embedding 或外部 provider 故障时，核心市场和聊天功能继续可用。
5. 每个工具调用可追踪、可测试、可重放分析，但不能泄漏密钥或无关隐私。

## 当前实现

[已实现] 当前后端支持 Gemini、MiniMax 和多种 OpenAI-compatible provider。聊天模型可以通过 Rig 调用搜索、详情、发布、更新、删除、成交意向、议价和“我的发布”等工具。

[已实现] 商品事务推进 `content_revision` 并合并 `embedding_jobs`；worker 在事务外调用 provider，以 revision CAS 重建或删除 `documents` 投影。provider 故障不回滚发布，pgvector 缺失时由关键词/规则路径降级。回复助手使用独立的受限 agent，不挂载搜索、下单或议价工具。

[已实现] 小帮历史按认证用户隔离，客户端公共标识 `__agent__` 在服务端映射到用户专属会话。SSE 正常完成后才保存完整助手回复。

[已实现] 可恢复的发布会立即执行并提供撤销窗口；更新/删除生成 L2 ActionPlan，成交意向/议价生成使用独立两步 token 的 L3 ActionPlan。确认锁、业务事实、适用时的通知/outbox 和计划终态原子提交，commit 前中断可安全重试。

[风险] Agent listing 创建/更新与 HTTP 路径仍未收敛到同一 command service，文本审核、分类/空白规范化和金额类型存在漂移。资源版本快照、提案幂等、版本化风险文案和统一 AgentRun/审计也仍待补齐。

## 权限等级

| 等级 | 典型动作 | 执行规则 |
| --- | --- | --- |
| L0 | 解释平台规则、总结公开信息、比较候选 | 可以直接回答，不得编造数据库事实 |
| L1 | 搜索、匹配、生成发布草稿、生成礼貌回复 | 可以自动执行只读检索和草拟，不向外发送 |
| L2 可恢复 | 当前的商品发布 | 校验后立即执行，向用户展示有期限、条件式撤销入口 |
| L2 需确认 | 当前的商品更新/下架；未来不可安全撤销的外部动作 | 生成绑定输入的预览，用户一次确认后执行 |
| L3 | 报价、接受议价、确认成交、公开收款码或其他隐私信息 | 二次确认，重新认证敏感操作，写入审计 |

“用户说了请帮我”不自动等于 L2/L3 授权。授权必须绑定具体动作、具体资源、输入快照和短期有效期。

## 运行链路

```mermaid
sequenceDiagram
    participant U as User
    participant UI as Flutter
    participant R as Intent Router
    participant A as Agent Orchestrator
    participant P as Policy Engine
    participant T as Service-backed Tool
    participant DB as PostgreSQL/pgvector

    U->>UI: 自然语言请求
    UI->>R: message + campus context
    R->>R: moderation and deterministic routing
    R->>A: normalized intent + recent context
    A->>DB: retrieval with tenant scope
    A->>P: proposed action
    alt L0/L1
        P-->>A: allow
        A-->>UI: answer or draft
    else recoverable L2
        P-->>A: allow with undo
        A->>T: execute validated action
        T->>DB: commit fact + register undo affordance
        T-->>UI: result + undo window
    else confirmed L2/L3
        P-->>A: require confirmation
        A-->>UI: AgentActionPlan preview
        U->>UI: confirm
        opt L3
            T-->>UI: independent second-step token
            U->>UI: confirm high-risk step
        end
        UI->>T: confirm plan with current-step token
        T->>DB: lock plan, revalidate, atomically transact
        T-->>UI: committed result
    end
```

意图路由优先使用确定性规则识别禁止内容、明确搜索和常见动作，避免所有输入都调用模型。模型负责理解开放表达，不负责最终授权。

## AgentActionPlan

[已实现] 当前 update/delete listing 使用 L2 计划，purchase/negotiate 使用 L3 计划。创建计划的内部事实形态为：

```json
{
  "plan_id": "uuid",
  "action_type": "purchase_item",
  "risk_level": "L3",
  "summary": "以 1800 元向卖家提出成交意向",
  "args": {
    "listing_id": "...",
    "offered_price": 180000
  },
  "campus_id": "...",
  "user_id": "...",
  "status": "pending",
  "expires_at": "RFC3339 timestamp",
  "confirmation_token": "primary capability",
  "second_confirmation_token": "server-held capability"
}
```

计划状态：

```text
pending -> confirmed_once (L3) -> executing (transaction-local) -> executed | failed
pending | confirmed_once -> cancelled | expired
legacy executing -> interrupted
```

当前执行协议：

- plan 绑定创建时的用户、campus 和过期时间；list/cancel/confirm 都按认证用户与活动校园过滤。
- L3 primary 与 second token 独立。primary 只能进入 `confirmed_once`；primary 的网络重试重放同一 second-token challenge，不能执行。
- plan 行从 token 校验到业务结果一直持锁。业务写入位于 savepoint，业务事实、适用时的通知/outbox 与 `executed` 终态由同一外层事务 commit。
- plan 只能成功执行一次；second confirm 的并发与成功响应丢失都返回同一个终态结果，不产生第二个业务事实。
- 执行前重新校验 campus membership、资源 owner、状态和金额；上下文变化安全失败且不留下部分事实。
- token 不进入模型文本或缓存响应；`args` 只保存执行所需字段，不复制无关聊天历史。
- 旧协议中无法判断副作用的 durable `executing` 迁移为 `interrupted`，必须人工核对，永不自动重放。

[目标态] 补资源版本快照、proposal idempotency key、设备/重新认证绑定、版本化风险文案、typed outcome 和统一审计事件。当前与目标 `/api/v1` 的区别见 [API 参考](api-reference.md)。

## 工具设计

Agent 工具是 service 的受控适配器，不应自己成为新的业务层。

每个工具必须声明：

```text
name
description
input schema
required auth context
campus scope
risk level
idempotency behavior
side effects
possible errors
audit category
```

实现约束：

1. 工具不直接信任模型提供的 `user_id`、`campus_id` 或 owner。
2. 写工具与普通 HTTP API 必须调用同一个 command service 和事务入口。
3. 工具输出使用小而稳定的结构，不把数据库行或内部错误原样交给模型。
4. 只读工具也要做 tenant、状态和可见性过滤。
5. 工具错误分为用户可修复、状态冲突、权限拒绝、依赖故障和内部错误。
6. 工具描述不能承诺 service 实际不支持的行为。

当前成交/议价的核心约束已复用事务内执行函数；listing 创建、更新和下架现已通过统一 `ListingCommandService` 进入规范化、文本审核和事务入口。资源版本快照、提案幂等和完整审计仍是后续工作。

## 记忆与上下文

### 会话记忆

短期上下文默认读取当前用户最近的必要消息，并设置 token 和条数上限。回复助手最多读取最近 12 条纯文本消息，不读取媒体，不自动发送。

### 用户偏好

[部分完成] 长期偏好只使用用户明确产生的收藏、成交意向和信息流反馈；Agent 推断不会写入用户事实。用户可以关闭个性化并清除旧排序信号，明确隐藏的具体内容仍保持隐藏。逐项查看、撤销或修正信号的界面仍是目标态。

### 业务事实

商品价格、状态、成交记录、membership 和屏蔽关系必须在执行前实时读取。聊天摘要或模型记忆不能作为这些事实的来源。

### 隐私边界

- 不把另一个用户的私聊历史放入当前用户上下文。
- 不把完整邮箱、学号、收款码或管理员审计内容发送给 LLM，除非动作明确需要且策略允许。
- provider 请求日志不保存原始敏感 prompt；调试样本需要脱敏和访问控制。
- Secret Chat 实验数据不进入 Agent 或 RAG。

## RAG 与检索

RAG 流程必须先做访问范围过滤，再计算相关性：

```text
campus/status/visibility filter
  -> lexical and vector retrieval
  -> deduplicate and rank
  -> compact factual context
  -> model generation with source ids
```

Embedding 文档应保存可重建的 `embedded_text`、模型名、维度、版本和更新时间。商品更新、删除、售出或 wanted 完成后，要同步更新或移除可检索文档。

生成回复时，模型只能引用检索结果中的公开字段。找不到结果时应明确说没有合适候选，并建议调整预算或条件，不能虚构商品。

## Prompt injection 与不可信内容

商品描述、用户名、群组内容、网页文本和用户上传内容都是不可信数据。它们可能包含“忽略规则”“调用某个工具”等指令。

防护基线：

- 检索内容放在明确的数据区，不拼进系统指令。
- 工具允许列表由服务端根据场景和风险等级决定。
- 模型不能动态注册工具、修改 tool schema 或选择任意 URL。
- 所有 URL fetch 使用域名 allowlist、请求大小和超时限制，并防 SSRF。
- 高风险动作由 policy engine 和 service 校验，prompt 防护不是唯一边界。
- 安全测试包含间接注入、多语言混淆、工具参数污染和跨用户数据诱导。

## Provider 与降级

Provider 层统一 chat、streaming、tool calling 和 embedding 能力，但不能假设不同供应商完全等价。

生产策略：

1. 每种能力声明支持矩阵，例如某 provider 只支持 chat，不支持可靠 tool calling。
2. 设置连接、首 token、总响应和工具循环超时。
3. 使用熔断、指数退避和有界重试；写操作绝不因模型超时自动重试执行。
4. Chat provider 可切换，embedding provider/维度切换必须经过双写或重建索引。
5. Provider 故障时回退到关键词搜索、普通表单和手动聊天。
6. 回复失败不丢失用户已经提交的消息，也不保存半截助手回复为完整事实。

## 可观测性

每次 AgentRun 使用统一 `trace_id`，记录：

- 路由结果、provider、model、prompt 模板版本和工具 schema 版本。
- 检索数量、过滤数量、最终引用的资源 ID。
- 工具名、风险等级、耗时、结果类别和是否要求确认。
- token 用量、首 token 延迟、总延迟、取消和错误类别。
- 不记录密钥、完整 token、密码、完整收款码或无关私聊正文。

Metrics 关注成功路径与安全护栏：草稿采纳率、确认取消率、工具冲突率、provider 错误率、越权拦截数和每次有效闭环成本。

## 评估体系

### 离线数据集

至少覆盖：

- “出/收”意图识别和字段提取。
- 分类、预算、成色和校园硬约束。
- 找不到匹配时的诚实回答。
- 发布草稿不覆盖用户已填字段。
- 报价、成交、隐私公开的确认边界。
- prompt injection、越权、跨校园和被屏蔽关系。
- provider 超时、工具 409、数据库失败和流中断。
- 中文口语、错别字、中英混合和校园术语。

### 评价维度

| 维度 | 通过标准 |
| --- | --- |
| 意图正确性 | 选择正确流程，不把 wanted 当 offer |
| 事实一致性 | 不虚构库存、价格、身份和状态 |
| 权限安全 | 未确认时不执行 L2/L3，不跨用户或校园 |
| 可恢复性 | 失败后保留用户输入并提供手工路径 |
| 表达质量 | 简洁、礼貌、不给用户制造虚假承诺 |
| 成本与延迟 | 在预算和 SLO 内完成，避免无意义工具循环 |

任何 Agent 功能上线前必须同时通过确定性单元测试、service 集成测试、模型评估和 Codex Browser 用户流程验收。

## 上线门槛

- 需要事前确认的 L2/L3 已进入 crash-safe ActionPlan；可恢复 L2 有原子条件式撤销或被明确禁用。
- 工具权限和幂等测试通过，越权执行数为零。
- 有 provider 故障和无 LLM 的降级路径。
- Prompt、工具和模型版本可追踪。
- 安全评估集、质量基线和回滚开关存在。
- 用户界面能清楚区分建议、草稿、待确认和已执行结果。
