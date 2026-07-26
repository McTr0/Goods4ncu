# Goods4ncu（续樟）文档入口

| 项目 | 内容 |
| --- | --- |
| 适用读者 | 第一次了解续樟的读者，以及需要定位产品、工程或运维文档的协作者 |
| 当前状态 | 文档同时描述当前实现和生产目标，所有目标能力必须使用状态标记 |
| 事实来源 | `docs/` 专题文档、Axum 路由、数据库迁移、Flutter 页面和测试 |
| 最后核对范围 | 产品设计、领域模型、Agent、信任安全、当前架构、生产架构和工程手册 |

续樟是以校园可信身份为基础、由智能匹配和 Agent 辅助的信息流通平台。首个生产版本聚焦物品的“出 `offer` / 收 `wanted`”：用户表达自己愿意提供什么或正在寻找什么，系统帮助信息被合适的人发现，并在用户明确授权下推进沟通和线下成交。

平台不托管资金、不确认付款、不追踪物流。Agent 不是新的权限主体，高风险动作必须由用户确认。

## 能力状态标记

文档使用以下标记区分事实与方向：

| 标记 | 含义 |
| --- | --- |
| `[已实现]` | 当前代码、迁移和用户路径已经具备，仍可能存在生产硬化任务 |
| `[实验中]` | 有 API 或界面原型，但不属于稳定生产承诺 |
| `[目标态]` | 已做出设计决策，尚未完整实现 |
| `[待弃用]` | 当前仍需兼容，但不应继续扩大使用 |

没有标记的教程性说明只解释概念，不代表对应生产能力已经上线。

## 三条阅读路线

### 理解产品为什么这样设计

1. [产品设计](product-design.md)：理解“出/收”、用户控制权、产品边界与成功指标。
2. [信息模型](information-model.md)：理解意图、匹配、沟通、成交和审核事实。
3. [Agent 系统设计](agent-system.md)：理解 Agent 能做什么、何时必须确认。
4. [信任与安全](trust-safety.md)：理解身份、审核、隐私、收款码和治理边界。

### 开始开发或修改代码

1. [新人导览](onboarding.md)：通过一次完整用户旅程建立系统地图。
2. [当前架构与分层](architecture.md)：确认 Flutter、Axum、service、repository、worker 和 LLM 的边界。
3. [业务流程](domain-flows.md)：找到对应状态机和失败路径。
4. [API 参考](api-reference.md)：核对当前路由、字段和目标接口。
5. [开发指南](development.md)与[贡献指南](contributing.md)：实现、测试和提交。

### 部署、排错或规划生产化

1. [生产架构](production-architecture.md)：理解容量、租户、持久事件、SLO 和灾备目标。
2. [运行、配置与排错](operations.md)：处理本地与当前部署问题。
- [首次上线检查清单](first-launch-checklist.md) —— 第一次对真实学生开放前逐条走一遍。列的都是只在第一次出现的坑
3. [生产路线图](roadmap.md)：查看阶段、前置条件、验收门槛和退出标准。
4. [集成测试手册](integration-testing.md)：按真实用户操作验证系统。

## 文档地图

| 文档 | 唯一职责 |
| --- | --- |
| [产品设计](product-design.md) | 产品使命、出/收哲学、用户旅程、边界和成功指标 |
| [信息模型](information-model.md) | 领域对象、状态机、事实边界、事件和多租户不变量 |
| [Agent 系统设计](agent-system.md) | Agent 权限、ActionPlan、工具、RAG、安全和评估 |
| [信任与安全](trust-safety.md) | 身份、审核、通信治理、收款码、隐私、申诉和审计 |
| [生产架构](production-architecture.md) | 模块化单体、多校园、outbox、Redis、存储、SLO 和恢复 |
| [新人导览](onboarding.md) | 面向新人的教材式项目入口和术语解释 |
| [当前架构与分层](architecture.md) | 只描述当前代码结构、运行链路和已知风险 |
| [业务流程](domain-flows.md) | 当前与目标业务状态流及失败路径 |
| [API 参考](api-reference.md) | 当前公共接口和明确标记的目标契约 |
| [开发指南](development.md) | 本地开发、命令、测试选择和常见任务 |
| [运行、配置与排错](operations.md) | 配置、数据库、迁移、日志、指标、runbook 和事故处理 |
| [集成测试手册](integration-testing.md) | API 与 Codex Browser 的真实用户验收路径 |
| [生产路线图](roadmap.md) | 从当前代码到生产平台的阶段计划和验收门槛 |
| [贡献指南](contributing.md) | 分支、commit、PR、review、ADR 和文档同步规则 |

## 当前实现与目标形态

当前系统是 Rust Axum + Flutter + PostgreSQL/pgvector 的模块化单体，已经具备认证、offer/wanted、推荐、直聊、群组/频道原型、Agent 工具、线下成交记录、审核和管理能力。

生产目标不是立即拆成微服务，而是先补齐：校园 membership、多租户范围、Agent 确认协议、可解释推荐、统一审核案件、对象存储隔离、transactional outbox、多副本实时 fan-out、SLO 和灾难恢复。

完整差距和顺序见[生产路线图](roadmap.md)。

## 配置与仓库规则

[环境变量模板](.env.example)保存密钥和连接串示例，[TOML 配置模板](config.toml.example)保存非敏感运行参数。真实密钥不得提交。

根目录 [AGENTS.md](../AGENTS.md) 面向编码代理和仓库协作，不取代人类设计文档。编码代理重启后，进行 GUI 验收前必须重新确认前后端真实可访问。

## 文档维护规则

1. 同一主题只在一份专题文档详细维护，其他地方只给上下文和链接。
2. 当前事实优先从 migration、service、repository、handler 和客户端模型核对。
3. 目标接口必须标记 `[目标态]`，不得混入当前 curl 示例。
4. 新功能改变领域事实、权限、API、配置、SLO 或用户路径时，同一个 PR 更新对应文档。
5. 重大架构决策在相关设计文档记录背景、选择、后果和退出条件；稳定后再拆独立 ADR。
6. 文档以中文为主，保留必要英文术语并在首次出现时解释。

## 最短启动索引

完整步骤见[开发指南](development.md)和[运行排错](operations.md)：

```bash
cp docs/.env.example .env
cp docs/config.toml.example goods4ncu.toml
cargo check --locked
cargo run
```

Flutter Web/App 的依赖、API base URL 和测试命令见[开发指南](development.md)。
