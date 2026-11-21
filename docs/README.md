# 文档索引

仓库根目录的 [AGENTS.md](../AGENTS.md) 是代理/协作者工作指南；本目录按主题组织设计与运维文档。示例配置见 [`docs/.env.example`](.env.example) 与 [`docs/config.toml.example`](config.toml.example)。

带 `last-verified:` 时间戳的文档反映各自的核验时间；时间戳过旧时，请对照当前代码重新核验后再信任其中的细节。

## 入门

| 文档 | 说明 |
| --- | --- |
| [onboarding.md](onboarding.md) | 新人导览：跟随一条需求穿过整个系统 |
| [development.md](development.md) | 开发指南 |
| [contributing.md](contributing.md) | 贡献指南 |
| [first-launch-checklist.md](first-launch-checklist.md) | 首次上线检查清单 |

## 产品与路线

| 文档 | 说明 |
| --- | --- |
| [product-design.md](product-design.md) | 产品设计：从校园集市到智能信息流通平台 |
| [roadmap.md](roadmap.md) | 生产路线图：从当前单实例到可信多校园平台 |
| [production-readiness.md](production-readiness.md) | 生产就绪评估报告；部署侧待办的权威清单 |
| [frontend-alignment.md](frontend-alignment.md) | 前端与产品设计对齐清单 |

## 架构与数据

| 文档 | 说明 |
| --- | --- |
| [architecture.md](architecture.md) | 当前架构与代码分层 |
| [information-model.md](information-model.md) | 信息模型：意图、匹配与流转事实 |
| [domain-flows.md](domain-flows.md) | 业务流程与状态机 |
| [api-reference.md](api-reference.md) | API 参考 |
| [posts-api.md](posts-api.md) | Posts API |
| [campus-logical-map.md](campus-logical-map.md) | 校园逻辑地图、室内目录与地点聊天室 |
| [campus-post-taxonomy.md](campus-post-taxonomy.md) | 校园帖子分类与关系设计 |
| [production-architecture.md](production-architecture.md) | 生产架构：模块化单体、多校园与可靠运行 |

## Agent 与 Companion（小昌）

| 文档 | 说明 |
| --- | --- |
| [agent-system.md](agent-system.md) | Agent 系统设计：从理解意图到受控行动 |
| [agent-safety.md](agent-safety.md) | Agent 安全边界：确认分级与注入防护 |
| [agent-tools.md](agent-tools.md) | Agent Tools Reference |
| [platform-tools.md](platform-tools.md) | Platform Tools |
| [companion-architecture.md](companion-architecture.md) | Companion 架构与子系统模块地图 |
| [companion-current-state.md](companion-current-state.md) | Companion Runtime 历史 Phase 0 基线（非现状权威） |
| [companion-demo-script.md](companion-demo-script.md) | Companion §111 演示脚本 |
| [character-system.md](character-system.md) | 小昌 Character System |
| [character-director.md](character-director.md) | Character Director |
| [animation-system.md](animation-system.md) | Animation System |
| [attention-system.md](attention-system.md) | Attention System |
| [emotion-system.md](emotion-system.md) | Emotion System |
| [memory-system.md](memory-system.md) | Memory System |
| [relationship-system.md](relationship-system.md) | Relationship System |
| [proactive-system.md](proactive-system.md) | Proactive System |
| [avatar-interaction-system.md](avatar-interaction-system.md) | Avatar Interaction System |
| [realtime-voice.md](realtime-voice.md) | Realtime Voice |

## 信任与安全

| 文档 | 说明 |
| --- | --- |
| [trust-safety.md](trust-safety.md) | 信任与安全：身份、审核、隐私与平台治理 |

## 运维与测试

| 文档 | 说明 |
| --- | --- |
| [operations.md](operations.md) | 运行、配置与排错 |
| [integration-testing.md](integration-testing.md) | Codex Browser 集成测试手册 |
| [local-test-accounts.md](local-test-accounts.md) | 本地测试账号与数据库清单 |

## 审计与治理

| 文档 | 说明 |
| --- | --- |
| [architecture-compliance-audit.md](architecture-compliance-audit.md) | 架构合规审计与整改报告 |
| [codex-session-noise-archive.md](codex-session-noise-archive.md) | 历史会话噪音归档（含被推翻的结论与事故记录） |
| [adr/](adr/) | 架构决策记录（当前：[agent-runtime-v2.md](adr/agent-runtime-v2.md)） |
