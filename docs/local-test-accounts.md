# 本地测试账号与数据库清单

| 项目 | 内容 |
| --- | --- |
| 适用读者 | 在本机开发、调试、跑演示的人 |
| 当前状态 | 仅适用于本机；生产环境不得存在本文任何凭据 |
| 事实来源 | `migrations/0005_seed_data.sql`、`scripts/deploy_local.sh`，本文所列密码均经登录接口实测 |
| 最后核对 | 2026-07-26 |

> **这些是本地凭据，不是密钥。** 它们只在本机数据库 + 本机生成的 JWS 密钥下有效。真正的密钥（`jwt_secret`、数据库口令）在 `~/.goods4ncu-deploy/` 下以 `chmod 600` 保存，**不在本文、也不在仓库里**。
>
> **生产环境严禁出现这些账号。** 后端在生产模式下会检测种子账号并拒绝启动（`src/db.rs::assert_no_demo_seed_in_production`）。

## 一、三个数据库分别是什么

| 数据库 | 用途 | 谁创建 | 是否含种子账号 |
| --- | --- | --- | --- |
| `goods4ncu` | 日常开发库（`.env` 里的 `DATABASE_URL`） | 手工/`cargo run` | 是（开发便利，非生产模式无妨） |
| `goods4ncu_test` | 自动化测试库 | 测试基建 | 每个测试前 TRUNCATE，无稳定数据 |
| `goods4ncu_local` | 本机持久部署（生产模式，两校园演示） | `scripts/deploy_local.sh` | **否**，部署时已按生产要求移除 |

## 二、开发库 `goods4ncu` 的种子账号

来自 `migrations/0005_seed_data.sql`。**密码统一为 `Test1234`。**

| 用户名 | 密码 | 角色 | 状态 | 用途 |
| --- | --- | --- | --- | --- |
| `admin` | `Test1234` | admin | active | 管理后台调试 |
| `buyer1` | `Test1234` | user | active | 买家视角 |
| `buyer2` | `Test1234` | user | active | 第二买家（并发/会话测试） |
| `seller1` | `Test1234` | user | active | 卖家视角，持有多数种子商品 |
| `seller2` | `Test1234` | user | active | 第二卖家 |
| `banneduser` | `Test1234` | user | **banned** | 验证封禁拦截；**登录会被拒**，返回 `authentication_failed` |

种子商品由 `seller1`/`seller2` 持有（iPhone、高数教材、小米手环、拯救者、空调、AJ1，以及一条 `违规商品-请忽略` 用于测审核拦截）。

⚠️ **这份种子数据会随迁移自动进入任何新建数据库**（`0005` 虽写着"手动运行"却放在 `migrations/` 下）。因此：
- 生产库必须执行 `psql -d <db> -f scripts/remove_demo_seed.sql`
- 不执行的话，生产模式启动会被守卫拒绝并打印该命令

## 三、持久部署 `goods4ncu_local` 的账号

由 `scripts/deploy_local.sh` 通过**公开注册接口**创建（不是种入迁移行），因此不受生产种子守卫影响。密码故意不同于仓库公开的 `Test1234`。

| 用户名 | 密码 | 角色 | 校园 | 用途 |
| --- | --- | --- | --- | --- |
| `admin` | `Local-admin-1` | admin | `ncu` / pending | 平台管理员；敏感写操作需先 `POST /api/auth/reauth` 做密码 step-up |
| `seller1` | `Local-test-1` | user | `ncu` / verified | 卖家视角，持有演示商品 |
| `buyer1` | `Local-test-1` | user | `ncu` / verified | 买家视角 |
| `campus2_member` | `Local-test-1` | user | `demo-campus` / verified | 第二校园成员；与 `seller1` 对比即可看到跨校园隔离 |

可用环境变量覆盖：`ADMIN_USER` / `ADMIN_PASS` / `MEMBER_PASS`。部署脚本结束时会打印当前实际凭据，不必翻文档。

`admin` 的 membership 是 `pending` 而非 `verified`：`admin promote` 只改全局角色，不代替校园认证。这是符合设计的——后台读写走 `AdminScope`，与校园成员资格是两条独立的授权链。

⚠️ 这些账号只存在于**演示部署库** `goods4ncu_local`。开发库 `goods4ncu` 用的是第二节的种子账号（`Test1234`）。两者互不相通——用错库的账号就会看到"用户名或密码错误"。

### 校园

| slug | 名称 | 邮箱域名 | 说明 |
| --- | --- | --- | --- |
| `ncu` | 南昌大学 | `email.ncu.edu.cn` | 迁移种子里的默认校园，**唯一真实服务对象** |
| `demo-campus` | 演示大学（隔离测试租户） | `stu.demo-campus.test` | **虚构租户**，仅用于验证跨校园隔离。`.test` 是 RFC 2606 保留域名，不可能属于真实机构 |

> 只有一个校园时隔离无法验证——任何查询都只返回该校数据，分不清"过滤生效"还是"没有别的数据"。第二个租户的唯一目的就是让隔离可证。**这不代表任何合作关系。**

## 四、访问入口

| 服务 | 地址 |
| --- | --- |
| Web 前端 | http://127.0.0.1:3001 |
| API 副本 A | http://127.0.0.1:4601 |
| API 副本 B | http://127.0.0.1:4602 |
| 对象存储（MinIO） | http://127.0.0.1:9200（控制台 9201） |
| Redis | 127.0.0.1:6400 |

```bash
./scripts/deploy_local.sh            # 启动/复验（幂等）
./scripts/deploy_local.sh --stop     # 停进程，保留数据
./scripts/deploy_local.sh --destroy  # 连数据一起删
```

前端由部署脚本一并托管，因此 CORS 白名单与前端编译进去的 API 地址不会各自漂移——两者不一致时的表现是"API 健康但登录失败"，极易误判为服务没起来。

## 五、已知限制

- **小昌（AI 助手）无回复**：演示环境 `GEMINI_API_KEY` 是占位值。需要真实 key 重启后端才能对话；其余功能不受影响。
- **上传媒体**：bucket 为私有，审核通过后由服务端签发短期 presigned URL。演示环境未接图片审核服务，`MODERATION_IMAGE_ENABLED` 关闭时新媒体直接标记为 review-exempt。
- **邮箱验证码**：投递 webhook 是本地 stub（`scripts/deploy_local.sh` 内的 python 服务），部署脚本直接把成员 membership 置为 verified 而不走 OTP 往返。完整 OTP 流程见 `tests/admin_auth_regression.rs::second_campus_onboarding_journey_end_to_end`。

## 六、维护规则

- 新增测试账号必须同步更新本文，并注明密码与用途。
- 本文密码变更后要重新实测登录，不要凭记忆记录。
- 任何真实密钥（LLM key、生产数据库口令、OSS secret）**不得**写入本文；模板见 `.env.production.example`。
