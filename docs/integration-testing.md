# Codex Browser 集成测试手册

这份手册把 Good4NCU 当成一个真实校园二手交易产品来验收。单元测试和接口测试回答“代码是否按预期返回”，Codex Browser 集成测试回答“一个普通同学日常使用时会不会困惑、卡住、白屏、误点或看到错误状态”。

集成测试分两层执行：

| 层次 | 工具 | 责任 |
| --- | --- | --- |
| 可视化用户层 | Codex Browser | 像真实用户一样打开 Flutter Web、登录、点击、截图、检查深色模式和响应式布局。 |
| 对方用户和数据准备层 | `scripts/codex_browser_api_driver.mjs` | 登录 seller/admin 等第二账号，创建会话、接通、发消息、制造通知和边界状态。 |

Codex Browser 通常共享一个浏览器登录态，不适合同时扮演两个用户。遇到聊天、订单、审核这类多角色流程时，让浏览器扮演主用户，让 API driver 扮演对方用户。

## 环境基线

本地服务默认地址：

| 服务 | 地址 |
| --- | --- |
| 后端 | `http://127.0.0.1:3000` |
| Flutter Web | `http://127.0.0.1:3001` |

启动后端：

```bash
cargo run
```

启动前端：

```bash
cd mobile
env NO_PROXY=127.0.0.1,localhost no_proxy=127.0.0.1,localhost \
  flutter run -d web-server --web-hostname 127.0.0.1 --web-port 3001
```

测试账号来自 `migrations/0005_seed_data.sql`，默认密码均为 `Test1234`：

| 用户 | 角色 | 用途 |
| --- | --- | --- |
| `buyer1` | 普通用户 | Codex Browser 的主用户。 |
| `buyer2` | 普通用户 | 第二买家、隔离通知和订单状态。 |
| `seller1` | 普通用户 | 商品卖家、聊天接收方、发货方。 |
| `seller2` | 普通用户 | 第二卖家、跨用户权限验证。 |
| `admin` | 管理员 | 封禁、下架、审计日志和后台权限。 |
| `banneduser` | 封禁用户 | 登录失败和访问限制验证。 |

## API Driver

脚本位置：

```bash
node scripts/codex_browser_api_driver.mjs --help
```

常用命令：

```bash
node scripts/codex_browser_api_driver.mjs health
node scripts/codex_browser_api_driver.mjs p0-chat
node scripts/codex_browser_api_driver.mjs spaces
node scripts/codex_browser_api_driver.mjs call-secret
node scripts/codex_browser_api_driver.mjs all
```

如果后端不是默认地址：

```bash
GOOD4NCU_API_BASE=http://127.0.0.1:3000 \
  node scripts/codex_browser_api_driver.mjs p0-chat
```

脚本会输出 JSON 摘要，包含创建的会话、消息、群组、频道、通话和 Secret Chat session id。把这些 id 填进浏览器地址或测试记录中，方便复现。

## Codex Browser 基本流程

每次浏览器验收都按同一个节奏走：

1. 打开 `http://127.0.0.1:3001/#/login`。
2. 登录 `buyer1 / Test1234`。
3. 打开 `http://127.0.0.1:3001/#/`，确认首页商品流加载。
4. 打开 `http://127.0.0.1:3001/#/conversations`，确认消息入口加载。
5. 用 API driver 准备对方用户状态。
6. 回到浏览器刷新当前页面，检查 UI 是否正确反映状态。
7. 在手机窄屏和桌面宽屏各截一张图。
8. 读取浏览器 console error；任何 Flutter assertion、白屏或 uncaught error 都算失败。

推荐视口：

| 视口 | 尺寸 | 重点 |
| --- | --- | --- |
| 手机 | `390x844` | 底部导航、详情页、聊天输入框、弹窗高度。 |
| 桌面 | `1440x900` | 左侧导航、消息双栏、列表和详情并排。 |

## P0 冒烟测试

这组测试每次大改后都应该跑。

| 编号 | 用户动作 | API driver 辅助 | 期望 |
| --- | --- | --- | --- |
| P0-01 | 打开登录页并登录 `buyer1` | 无 | 登录成功，跳到首页，无 401 循环。 |
| P0-02 | 首页浏览商品 | 无 | 商品卡片、价格、图片或占位正常。 |
| P0-03 | 打开 `iPhone 14 Pro Max 256G` 商品详情 | 无 | 标题、价格、卖家、联系入口存在。 |
| P0-04 | 进入消息页 | `node scripts/codex_browser_api_driver.mjs p0-chat` | 消息列表展示 seller 会话，新消息可见。 |
| P0-05 | 打开聊天详情 | `p0-chat` 输出的 conversation id | 引用、反应、举报、删除后的状态合理。 |
| P0-06 | 进入个人页 | 无 | 普通用户看不到管理后台入口。 |
| P0-07 | 打开 `/admin` | 无 | 普通用户被重定向，不能看到后台数据。 |
| P0-08 | 访问后端健康检查 | `health` | `/api/health` 返回 `OK`。 |

失败判定：

| 现象 | 级别 |
| --- | --- |
| 白屏、Flutter assertion、登录死循环 | P0 |
| 关键按钮不可点或点后无反馈 | P0 |
| 图片全部破图但商品仍可操作 | P1 |
| 文案不一致但流程可完成 | P2 |

## 聊天专项测试

聊天是 Good4NCU 最容易出现心理预期错位的地方。这里不只测消息是否写入数据库，也要测用户是否理解“这次沟通”的状态。

| 场景 | 浏览器用户 | API driver 用户 | 检查点 |
| --- | --- | --- | --- |
| 实时三次握手 | `buyer1` 发起 | `seller1` 接通 | `syn_sent -> syn_ack -> active`，文案是“接通”，不是“好友申请”。 |
| 现在不方便 | `buyer1` 等待 | `seller1` decline | 浏览器显示“这次没有接通”，只能重新联系。 |
| 邮件留言 | `buyer1` 发送留言 | `seller1` 稍后回复 | 无在线、输入中、已读信号，显示“已送达”。 |
| 回复引用 | `buyer1` 长按回复 | `seller1` 发一条消息 | 引用气泡展示原发送者和摘要。 |
| 表情反应 | `buyer1` 添加反应 | 无 | 反应出现在气泡下方，自己的反应高亮。 |
| 仅对自己删除 | `buyer1` 删除消息 | `seller1` 读取同一会话 | buyer 看不到，seller 仍看得到。 |
| 举报消息 | `buyer1` 举报 | 无 | 举报成功后普通用户看不到处理状态。 |
| 屏蔽用户 | `buyer1` 屏蔽 seller | `seller1` 尝试发消息 | 双方不能继续发送，提示中性不可用。 |
| 重新联系 | 打开 closed/expired 会话 | 无 | 旧历史只读，新沟通必须创建新会话。 |
| Reply Assistant | 主动点“帮我回复” | 无 | 只填入草稿，不自动发送，不承诺价格或成交。 |

API driver 覆盖其中的可自动断言部分：

```bash
node scripts/codex_browser_api_driver.mjs p0-chat
```

浏览器负责确认长按菜单、确认弹窗、引用条、深色模式和响应式布局。

## 市场交易测试

| 场景 | 步骤 | 期望 |
| --- | --- | --- |
| 首页推荐 | 打开首页、滚动、切换深色/浅色 | 推荐解释不外露，商品流自然，布局不跳。 |
| 商品图片 | 打开多个商品详情 | URL 图片显示，失败时有占位，不出现大片空白。 |
| 收藏 | 收藏、取消收藏、刷新 | 状态持久化，不能收藏自己的商品。 |
| 发布商品 | 填表发布商品 | 必填校验明确，价格单位正确，提交成功后可在“我的发布”看到。 |
| 内容审核 | 用测试 blocked keyword 发布 | 被拒绝或进入审核队列，提示清楚。 |
| 发起成交意向 | 买家在商品详情发起成交意向 | 订单进入 `intent_pending`，商品仍可展示，卖家需要确认。 |
| 确认线下成交 | seller 确认成交，可切换自动下架 | 状态进入 `confirmed`；开启自动下架时商品进入 sold。 |
| 平台不处理付款/物流 | 访问旧支付或发货入口 | 返回明确提示，不推进资金或物流状态。 |
| 取消成交记录 | `intent_pending` 状态取消 | 权限和状态校验正确；不会自动重新上架已售商品。 |

## 用户、隐私和主页测试

| 场景 | 步骤 | 期望 |
| --- | --- | --- |
| 用户名查找 | 消息页找同学，输入 `seller1` | 可找到，显示用户名和脱敏信息。 |
| 邮箱查找关闭 | 输入完整邮箱 | 对方未开启时查不到。 |
| 学号查找 | 设置学校邮箱后开启学号查找 | 只能完整匹配，不支持部分匹配。 |
| 用户主页 | 打开 `/users/{id}` | 展示用户信息、在售商品、联系入口。 |
| 收款码 | 用户上传微信/支付宝二维码 | 主页显示对应码；未上传时不出现破图模块。 |
| 管理入口 | 普通用户打开个人页 | 不显示管理后台入口。 |
| 管理员入口 | admin 登录 | 显示管理后台入口。 |

## 群组、频道、通话和 Secret Chat

自动准备：

```bash
node scripts/codex_browser_api_driver.mjs spaces
node scripts/codex_browser_api_driver.mjs call-secret
```

浏览器验收：

| 场景 | 期望 |
| --- | --- |
| 群组入口 | 消息页展示“校园通信”，可创建群组。 |
| 群组创建后可发现 | 用 Codex Browser 点击“创建群组”，提交后必须看到详情面板；关闭详情后，新群组必须出现在“校园群组与频道”列表。 |
| 群组发言 | 成员可以发言，消息出现在群组消息流。 |
| 频道入口 | 可创建频道，普通成员只读。 |
| 频道权限 | 非 owner/admin 发言被拒绝，UI 不应误导用户。 |
| 一对一通话 | active realtime 会话显示通话按钮，mail 不显示。 |
| 权限失败 | 无麦克风/摄像头权限时有可恢复提示。 |
| Secret Chat | 有独立安全标识，不进入小帮、不参与搜索、通知不含正文。 |

## 故障注入测试

| 故障 | 注入方式 | 期望 |
| --- | --- | --- |
| 后端断开 | 停止 `cargo run` | 页面显示离线/重试，不白屏。 |
| 前端刷新 | 在任意详情页刷新浏览器 | 登录态恢复，路由不丢。 |
| access token 过期 | 使用旧 token 调 API | 自动 refresh；失败后回登录页。 |
| refresh token 失效 | API driver 调 logout 后刷新 | 回登录页，错误文案清楚。 |
| 图片 404 | 准备坏图片 URL 商品 | 卡片和详情页有占位。 |
| WebSocket 断开 | 停后端再重启 | 不误显示“对方在线/离线”，恢复后可继续收消息。 |
| API 409 | 对 closed 会话发消息 | 提示会话状态已变化。 |
| API 429 | 连续创建会话或请求回复助手 | 显示限流提示，不重复提交。 |
| 管理员下架 | admin 下架商品 | 买家详情页显示已下架，不能下单。 |
| 封禁用户 | `banneduser` 登录 | 登录失败，提示账号不可用。 |

## 验收报告模板

每轮执行后记录：

```text
日期：
分支/commit：
后端地址：
前端地址：
数据库：
浏览器视口：
主账号：
API driver 命令：
通过场景：
失败场景：
截图：
控制台错误：
后端错误日志：
P0 必修：
P1 建议修：
P2 可排期：
```

## 合并前建议

文档或测试工具改动至少跑：

```bash
node --check scripts/codex_browser_api_driver.mjs
git diff --check
```

聊天、用户、交易或移动端 UI 改动建议跑：

```bash
cargo fmt -- --check
cargo clippy --all-targets -- -D warnings
cargo test -- --nocapture --test-threads=1
cd mobile && flutter analyze
cd mobile && flutter test --concurrency=1
```

如果时间有限，先跑 `health` 和 `p0-chat`，再用 Codex Browser 验证 `/conversations` 的手机和桌面视图。
