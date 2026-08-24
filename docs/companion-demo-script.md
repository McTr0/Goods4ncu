# Companion §111 Demo Walkthrough Script

> 10-minute browser walkthrough of the master-goal demo scenario.
> Runtime is fully wired; this script makes the human acceptance pass a
> single straight run.

## 前置条件

1. 服务在跑：后端 `127.0.0.1:3000`（`/api/health` 返回 OK）、前端
   `127.0.0.1:3001`。
2. `.env` 里 `LLM_PROVIDER` / `LLM_MODEL` 可用（当前 nemotron free 档；
   journey 脚本 `scripts/agent_journey.sh` 先跑一遍确认全绿）。
3. 种子数据（已存在即可跳过）：
   - iPhone 14 Pro Max 256G（l0000000-…-0001，¥5999，9 成新）
   - 小米手环8 NFC（l0000000-…-0003）
   - 高等数学教材 / 联想拯救者 Y7000
4. 测试账号：`buyer1 / Test1234`。

## 打开方式

- 关系态重置（可选，演示"初次见面"）：
  ```bash
  psql "$DATABASE_URL" -c "DELETE FROM companion_relationships WHERE user_id='b0000000-0000-0000-0000-000000000001';"
  ```

## 场景走查

| # | 操作 | 预期现象 |
|---|---|---|
| 1 | 打开助手页 | 角色处于自然 idle；debug 面板 STATE=idle，情绪向量可见 |
| 2 | 输入「在吗？」发送 | STATE: listening→thinking→speaking→idle 全链路；timeline 出现 agentThinking/agentResponseStart |
| 3 | 「帮我看看最近有没有人出小米手环」 | tool_activity=search_inventory → SHOW_POSTS；结果条出现真实商品卡；角色 gaze 偏向结果区 |
| 4 | 点开结果中的手环帖 | page_context 变为 post_detail/listingId；timeline 出现 environmentChanged(postOpened) |
| 5 | 「这个怎么样？」 | 不反问是哪个帖子——直接基于当前帖子总结（get_listing_details 工具活动） |
| 6 | 「帮我问问周末能不能面交」 | 出现 发送/编辑/取消 确认卡；**点取消前** chat_messages 无新增记录 |
| 7 | 点【取消】 | timeline 出现 draftCancelled；关系事件 user_cancels_action 已记录 |
| 8 | （观察）等待 ~30s 不操作 | idle 微动作持续（blink/sway），不冻结、不说话 |

## Barge-in 专项（语音可用时）

Chrome + `COMPANION_ENABLED`：对角色说话（需麦克风权限）→ TTS 播报中再开口 →
预期 <300ms 内声音停止、闭嘴、gaze 回到用户、STATE=interrupted→listening。
Timeline 的 `interruptLatencyMs` 即实测值。

> 注：TTS 出声与麦克风按钮属于第二刀（voice UI wiring）落地后开放；
> 文字模式下可用 timeline 中手动注入的 interrupted 事件验证管线。

## 通过标准（§102）

- [ ] 她知道我在看哪个帖子（步骤 5 未反问）
- [ ] 她真的翻了平台数据（步骤 3 结果为真实库存）
- [ ] 她不敢替我说话（步骤 6 取消前零发送）
- [ ] 她有身体感（idle 不冻结、gaze 有目标）
- [ ] 她记得这次会话的话题（连续追问不重复背景）
