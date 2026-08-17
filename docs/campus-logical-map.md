# 校园逻辑地图、室内目录与地点聊天室

状态：数据库目录与约束由 `0088_campus_logical_map.sql` 提供；Flutter 已提供可折叠地点目录、逻辑示意图、一次性粗定位/手动起点、目的地搜索和地图进入聊天室。聊天室在线人数由独立 presence 能力提供，不能用成员总数代替。内置前端图可根据照片中的相对布局生成虚线“逻辑相邻路线”，但不显示距离或逐段导航；服务端经核验的路线服务和室内数据导入仍是后续能力。

## 数据可信边界

用户提供的前湖校区地图照片可以帮助理解整体布局，但它有透视、遮挡和文字分辨率限制，不能证明楼栋坐标、入口位置、道路连通性或教室编号。照片推导的数据必须保持 `verification_status=unverified` 或 `manual`，且 `is_routable=false`。

目前唯一经公开地图查询核对的数据是前湖校区整体锚点 `28.6572190, 115.7931408`。它来自 OpenStreetMap/Nominatim 的大学范围结果，只适合粗粒度校区匹配，不是建筑导航点。`0084` 中的北院、南院和地标坐标是早期粗范围，`0085` 中设施明确为 manual-only；它们都不能直接升级成路线节点。

任何建筑到建筑、楼层或教室导航上线前，至少需要以下一种来源：

1. 校方发布且版本明确的平面图、楼层图或 GeoJSON。
2. 运营人员现场核对的入口和步行路径。
3. 可追溯、许可兼容的公开地图要素，并由运营人员二次确认。

## 目录与命名

地图只返回四个 active 一级目录，顺序固定：

1. 前湖北院
2. 前湖南院
3. 青山湖校区
4. 东湖校区

原来的“前湖校区”合并根保留为 inactive resolver，`metadata.replacement_slugs` 指向 `qianhu-north` 和 `qianhu-south`。旧 ID、历史消息和链接因此不需要删除；新目录 API 不把它作为第五个可见根。

显示名统一使用简体“先骕园”。用户给出的“先驌园”保留为 legacy alias，只用于搜索和旧链接解析。`先骕园` 当前放在前湖北院目录下，但 `parent_assignment=provisional`，坐标为空；运营核对前不得声称它与任何入口或楼栋相邻。

当前迁移后的逻辑目录是：

```text
前湖北院
├── 先骕园（位置和归属待校核）
├── 前湖校区北门（位置待校核）
├── 润溪湖畔（位置待校核）
└── 前湖校区图书馆（位置待校核）
前湖南院
├── 前湖校区南门（位置待校核）
├── 修贤广场（位置待校核）
├── 天健操场（位置待校核）
├── 前湖校区体育馆（位置待校核）
└── 前湖校区校医院（位置待校核）
青山湖校区
└── 青山湖校区图书馆（位置待校核）
东湖校区
└── 东湖校区图书馆（位置待校核）
```

楼栋、楼层和教室不从照片中猜测，所以迁移不写入任何教室样例。

## 数据模型

### `campus_map_nodes`

同一张表承载可折叠目录和路线锚点。`node_kind` 支持 directory、area、landmark、building、entrance、floor、classroom、junction 和 transit_stop。

- `parent_node_id` 构成任意深度目录，复合外键阻止跨校园挂载，触发器阻止自引用和循环。
- `chat_space_id` 可把地图地点关联到一个官方地点聊天室；它不是聊天室成员关系。
- `route_anchor_node_id` 允许一个不可直接路由的地点落到已核验入口。例如教室可以先落到教学楼入口，室内图核验后再改到楼层节点。
- `logical_x/logical_y` 是 `map_key` 内的 0..1000 归一化坐标，只用于绘制一张逻辑图，不能换算成经纬度。
- `latitude/longitude` 只接受 WGS84 成对坐标。
- `verification_status` 记录可信等级；`is_routable=true` 只允许 operator_verified 或 official 的 active 节点。
- `metadata` 只能是 JSON object，可记录来源版本、临时关闭说明、替代目录等非核心扩展字段。

### `campus_map_edges`

边连接同一校园内的两个节点，支持 walkway、crosswalk、door、stairs、ramp、elevator 和 shuttle。`direction=both|forward` 明确方向，`accessibility` 不允许根据道路类型自行猜测。

只有同时满足以下条件的边才能进入自动寻路：

- `status=active`
- `verification_status` 为 operator_verified 或 official
- `is_routable=true`
- `distance_meters` 为正数
- 两端节点也满足可路由约束

本迁移故意不写正式路线边。照片不足以证明两点之间存在可步行路径；数据库路由图应返回“尚未核验路线”，不能用直线穿越湖面、围墙或建筑物。Flutter 内置图中的虚线边是独立的展示层数据，只表达地点顺序和大致相邻关系，不进入 `campus_map_edges`，也不产生距离承诺。

### `campus_map_aliases`

别名按 campus 做大小写和首尾空格归一化后唯一。它用于简繁体、旧名称和常见简称解析，不影响页面显示的规范名称。

### `campus_map_classrooms`

教室目录把 `room_code + floor_code` 绑定到一个 building 节点。可选 `destination_node_id` 必须指向 classroom 节点，`route_anchor_node_id` 可暂时指向入口或楼层锚点。数据库触发器拒绝把教室挂到非 building 节点。

教室不保存猜测坐标。室内路线未核验时，服务最多导航到楼栋入口，并明确提示用户继续看现场楼层导视；不得生成不存在的楼层、房号或门禁路径。

## 路线流程

目标路线服务按以下顺序工作：

1. 通过 canonical slug、alias 或教室编号解析目的地。
2. 当前定位只在一次请求内使用。服务把它匹配到已核验入口或 junction 后立即丢弃；不写入上述地图表，也不关联用户账号。
3. 如果无法可靠匹配当前位置，让用户手动选择起点，不能把校区中心当作当前位置。
4. 对 active、verified、routable 子图运行 Dijkstra 或 A*。无障碍模式排除 stairs 和 `not_accessible` 边；`unknown` 默认不承诺无障碍。
5. 返回节点、边和来源状态。任何 manual/unverified 段都会使自动路线不可用，而不是悄悄降级成直线。
6. 教室没有已核验室内锚点时，终点降级为楼栋入口，并返回稳定 warning code。

建议的路线响应：

```json
{
  "status": "verified|unavailable",
  "start": {"node_id": "...", "matched": true},
  "destination": {
    "node_id": "...",
    "classroom_id": null,
    "resolved_to_route_anchor": false
  },
  "distance_meters": 620,
  "estimated_seconds": 480,
  "segments": [],
  "warning_code": null
}
```

未核验时应返回 `status=unavailable` 与 `warning_code=route_data_unverified`，而不是带虚假距离的空路线。

## 地图与聊天室

地图节点通过 `chat_space_id` 打开对应区域聊天室。这个动作语义是“进入当前地点的公共聊天”，不是申请加入一个群：

- 不显示“加入”或历史成员总数。
- 进入页面时创建/续租短 TTL presence，离开、断线或超时后自动消失。
- 同一用户多设备只计一人。
- 树和地图展示 `online_count`，而不是 `member_count`。
- 在线人数只展示聚合数量，不返回在线用户名、最后上线时间或用户坐标。
- 发言权限来自已验证的校园身份、封禁和审核规则，不依赖持久 `chat_space_members` 行。

地点树现有兼容接口还会返回 `location_slug`；地图接口应优先使用
`chat_space_id`/`location_slug` 绑定房间，不能用本地化的 `name` 做 ID。地点房间详情对访客应使用 `is_location_space=true` 和 `my_role="visitor"`，而不是把访客伪装成持久成员。

建议目录接口字段：

```json
{
  "items": [{
    "id": "...",
    "slug": "qianhu-north",
    "name": "前湖北院",
    "node_kind": "directory",
    "parent_node_id": null,
    "logical_position": null,
    "verification_status": "manual",
    "is_routable": false,
    "chat_space_id": "...",
    "online_count": 0,
    "children": []
  }]
}
```

客户端应默认折叠四个一级目录，保留每个目录独立展开状态。地图点击地点和目录点击聊天室最终使用同一个 stable `chat_space_id`，避免产生两套房间。

## 数据导入规则

运营导入一批地图数据时需要记录 `data_source`、`source_reference` 和来源版本。建议按以下顺序：

1. 建立 area/building/entrance 节点，保持 `unverified` 和 `is_routable=false`。
2. 核对名称、父目录、入口和无障碍事实。
3. 导入 junction 与 edge，实测或从许可兼容来源计算距离。
4. 由不同运营人员复核后，才把节点和边提升为 operator_verified 并开启 `is_routable`。
5. 施工、封路、门禁或电梯停运使用 `temporarily_closed`，不要删除历史节点。
6. 教室表最后导入；无法确认的楼层图不进入生产目录。

地图照片、官方图和公开地图可能使用不同方向与比例。每套逻辑坐标必须使用不同 `map_key`，禁止把两张图的 0..1000 坐标直接连边。

## 测试与验收

数据库与服务至少覆盖：

- 只有四个 active 一级目录，旧前湖根为 inactive 且含两个 replacement slug。
- 规范名称是“先骕园”，搜索“先驌园”解析到同一节点。
- 跨 campus 的父节点、route anchor、edge 和 classroom 引用被数据库拒绝。
- 自引用和父目录循环被拒绝。
- 单边逻辑坐标、单边经纬度、非法范围和非 object metadata 被拒绝。
- unverified/manual 节点或边无法设为 routable。
- 路径算法只读取 active、verified、routable 子图；无路径返回稳定 unavailable 状态。
- 无障碍路线不会经过 stairs 或 not_accessible 边。
- 教室不能挂到 area/landmark，destination 必须是 classroom 节点。
- 位置匹配请求前后数据库中没有新增用户坐标。
- 打开地点聊天室不会新增持久成员；presence 断线或 TTL 到期后 `online_count` 回落。
- 四个目录可独立展开/折叠，窄屏文字不溢出，地图和目录进入同一聊天室。

人工验收必须使用真实浏览器走一遍：手动选起点、搜索别名、选择楼栋/教室、无路线降级、从地图进入聊天室、两账号在线计数与断线回落。路线数据尚未核验时，验收重点是诚实的不可用状态，而不是画出看似完整的线。
