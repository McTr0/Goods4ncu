> last-verified: 2026-11-21 — taxonomy v5 shipped: 8 post categories + 6 tags
> (migration `0109_simplify_taxonomy.sql`); errand experiment retired
> (`0101_post_taxonomy_v2.sql`); posts unified with listings
> (`0099_unified_posts.sql`).

# 校园帖子分类与关系设计

校园发现流应该像一个完整社区，而不是“论坛旁边放了一个商城”。因此模型把
**行为、主题和关系**分开，不为每一种页面都增加顶层帖子类型。

## 三层模型

### 1. 行为层：用户在这里能做什么

统一帖子模型（`0099_unified_posts.sql`）后，`posts.category` 携带行为，
CHECK 约束限定为 `'offer' | 'wanted' | 'discussion'`。旧的
`post_type`/`post_kind` 字段已删除；listing 通过可选的 `posts.listing_id`
引用挂接——没有同步触发器、没有 UNIQUE 约束、没有镜像行，listing 与它的
帖子是“同一对象、两个场景”的引用关系，不再是投影。

| 行为 | 存储方式 | 主操作 | 生命周期事实源 |
| --- | --- | --- | --- |
| 讨论 | `posts.category = discussion` | 回复 | `posts` |
| 闲置出售 | `posts.category = offer` + `listing_id` → `inventory.direction = offer` | 联系 / 发起成交 | `inventory` |
| 求购 | `posts.category = wanted` + `listing_id` → `inventory.direction = wanted` | 推荐我的商品 | `inventory` |

### 2. 主题层：8 个分类 + 6 个标签（taxonomy v5）

发布与展示层使用 8 个固定分类
（`mobile/lib/models/post_taxonomy.dart`，镜像 `0109_simplify_taxonomy.sql`）：

`announcement`、`offer`、`wanted`、`share`、`question`、`discussion`、
`recruit`、`team_up`

标签收敛为 6 个：ttl 组（`urgent`、`longterm`）+ location 组 ×4；
shipping/condition 标签已在 `0106_drop_shipping_condition_tags.sql` 移除。

历史演化：`0100_post_taxonomy.sql` 首版引入 3 分类 + errand（跑腿）标签；
`0101_post_taxonomy_v2.sql` **完全退役 errand 实验**；中间版本的
`lost`/`found`/`help`/`event` 分类已在 `0109` 删除（帖子重映射到
discussion/offer）。Q&A、攻略、互助、失物招领、活动搭子、社团、租房拼车、
招募等校园需求现在都落在上述 8 分类 + 标签组合里，不再各自成类。

注意：`src/categories.rs` 是**商品库存**分类（electronics/books/
digitalAccessories/dailyGoods/clothingShoes/other），与帖子分类是两个正交
轴，不要混用。

### 3. 关系层：两条内容为什么有关联

关系强度不同，不能都压缩成标签：

| 关系 | 事实源 | 含义 |
| --- | --- | --- |
| 商品 ↔ 商品帖子 | `posts.listing_id` | 可选引用，由发布/编辑流程维护 |
| 求购 → 闲置 | `wanted_responses` | 用户明确把一个有效商品推荐给一条有效求购 |
| 帖子 → 回复 | `post_replies.post_id` | 同一公开讨论内的回应 |
| 回复 → 回复 | `post_replies.reply_to_id` | 局部对话上下文，不是另一条帖子 |
| 同分类/标签 | 查询时派生 | 只是一种弱发现信号 |
| 相关/后续讨论 | 未来显式 `post_links` 边 | 作者或版主声明的跨帖关系 |

客户端可以从这些事实源组合一个“相关内容”区域，而不复制第二套事实：

1. 求购详情展示兼容闲置和用户明确提交的推荐。
2. 闲置详情展示它曾被推荐到哪些求购。
3. 商品详情可以推荐主题或地点高度相关的讨论，但必须标为“可能相关”，不能伪装成
   已确认关系。
4. 讨论详情先展示作者添加的引用、版主标记的重复帖或后续帖，再展示算法推荐。

若实现显式跨帖链接，可以使用校园隔离的边表，例如
`post_links(source_post_id, target_post_id, relation_type, origin, status)`。
可用关系包括 `references`、`follow_up`、`duplicate_of` 和 `resolved_by`。
商品引用与求购响应已有权威事实源，不应复制进这个表；API 只需把它们投影到统一的
相关内容响应中。

## 发现流与详情规则

- 卡片徽标表达分类：**offer / wanted / discussion / …** 共 8 类；标签表达
  ttl 与地点。
- 默认排序与个性化可以混排各分类，用户仍能按分类明确筛选。
- 商品详情同时是交易事实和公开讨论的唯一详情层级，不再建立第二个商品帖子详情页。
- 回复不能自动创建交易或匹配；这些动作必须形成显式业务记录。
- 商品生命周期变化应自动隐藏或归档挂接的帖子；普通讨论按自身审核状态独立保留。
- 暴露关系之前必须检查校园、可见性、审核和生命周期；禁止跨校园关系。

## 本地演示场景

`scripts/seed_demo_community.sql` 会创建一组互相关联的本地样例：

- 2 条闲置与 4 条求购；
- pending 和 accepted 两种显式求购响应；
- 覆盖搬寝、学习、互助、失物和活动搭子的讨论；
- 回复中包含一条 reply-to 关系。

自行车求购特意保持无匹配，用来验证系统能给出有用的空状态，而不是伪造关系。
