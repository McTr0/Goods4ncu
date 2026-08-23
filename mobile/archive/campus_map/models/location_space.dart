class CampusLocationSpace {
  const CampusLocationSpace({
    required this.id,
    required this.name,
    required this.locationKind,
    required this.isOfficial,
    required this.isMember,
    required this.memberCount,
    required this.canCreateChildren,
    this.locationMatchable = true,
    this.onlineCount,
    this.locationSlug,
    this.origin,
    this.description,
    this.parentSpaceId,
    this.myRole,
    this.children = const [],
  });

  final String id;
  final String name;
  final String? description;
  final String? parentSpaceId;
  final String locationKind;
  final bool isOfficial;
  final bool isMember;
  final String? myRole;
  final int memberCount;
  final bool canCreateChildren;
  final bool locationMatchable;
  final int? onlineCount;
  final String? locationSlug;
  final String? origin;
  final List<CampusLocationSpace> children;

  Iterable<CampusLocationSpace> walk() sync* {
    yield this;
    for (final child in children) {
      yield* child.walk();
    }
  }

  static List<CampusLocationSpace> primaryDirectories(
    Iterable<CampusLocationSpace> spaces,
  ) {
    const names = ['前湖北院', '前湖南院', '青山湖校区', '东湖校区'];
    final all = spaces.expand((space) => space.walk()).toList(growable: false);
    return names
        .map(
          (name) =>
              _firstOrNull(all.where((space) => space.name.trim() == name)),
        )
        .whereType<CampusLocationSpace>()
        .toList(growable: false);
  }

  factory CampusLocationSpace.fromJson(Map<String, dynamic> json) {
    return CampusLocationSpace(
      id: json['id']?.toString() ?? '',
      name: json['name']?.toString() ?? '',
      description: _optionalString(json['description']),
      parentSpaceId: _optionalString(json['parent_space_id']),
      locationKind: json['location_kind']?.toString() ?? 'custom',
      isOfficial: json['is_official'] == true,
      isMember: json['is_member'] == true,
      myRole: _optionalString(json['my_role']),
      memberCount: (json['member_count'] as num?)?.toInt() ?? 0,
      canCreateChildren: json['can_create_children'] == true,
      locationMatchable: json['location_matchable'] != false,
      onlineCount: (json['online_count'] as num?)?.toInt(),
      locationSlug: _optionalString(json['location_slug']),
      origin: _optionalString(json['origin']),
      children: (json['children'] as List<dynamic>? ?? const [])
          .whereType<Map>()
          .map(
            (child) =>
                CampusLocationSpace.fromJson(Map<String, dynamic>.from(child)),
          )
          .toList(growable: false),
    );
  }
}

class CampusLocationPresence {
  const CampusLocationPresence({
    required this.onlineCount,
    required this.expiresInSeconds,
  });

  final int onlineCount;
  final int expiresInSeconds;

  factory CampusLocationPresence.fromJson(Map<String, dynamic> json) {
    final expiresInSeconds =
        (json['ttl_seconds'] as num?)?.toInt() ??
        (json['expires_in_seconds'] as num?)?.toInt();
    return CampusLocationPresence(
      onlineCount: (json['online_count'] as num?)?.toInt() ?? 0,
      expiresInSeconds: expiresInSeconds?.clamp(10, 300) ?? 60,
    );
  }
}

class CampusLocationRecommendation {
  const CampusLocationRecommendation({required this.matched, this.space});

  final bool matched;
  final CampusLocationSpace? space;

  factory CampusLocationRecommendation.fromJson(Map<String, dynamic> json) {
    final rawSpace = json['space'];
    return CampusLocationRecommendation(
      matched: json['matched'] == true,
      space: rawSpace is Map
          ? CampusLocationSpace.fromJson(Map<String, dynamic>.from(rawSpace))
          : null,
    );
  }
}

enum CampusMapNodeKind { area, building, landmark, gate, transit }

class CampusMapNode {
  const CampusMapNode({
    required this.id,
    required this.name,
    required this.directoryName,
    required this.x,
    required this.y,
    required this.kind,
    this.latitude,
    this.longitude,
    this.coordinateVerified = false,
    this.minimumZoom = 0,
    this.spaceNames = const [],
    this.classroomExamples = const [],
  });

  final String id;
  final String name;
  final String directoryName;
  final double x;
  final double y;
  final CampusMapNodeKind kind;
  final double? latitude;
  final double? longitude;

  /// Whether this point is backed by a public map feature or operator review.
  /// Unverified points stay available to the chat directory but must not be
  /// presented as geographic destinations.
  final bool coordinateVerified;

  /// Minimum map zoom at which this point should be rendered. This keeps the
  /// mobile marker layer sparse while preserving every point for search.
  final double minimumZoom;
  final List<String> spaceNames;
  final List<String> classroomExamples;

  bool matches(String query) {
    final normalized = query.trim().toLowerCase();
    if (normalized.isEmpty) return false;
    return <String>[
      name,
      directoryName,
      ...spaceNames,
    ].any((candidate) => candidate.toLowerCase().contains(normalized));
  }
}

class CampusMapLink {
  const CampusMapLink({
    required this.from,
    required this.to,
    required this.estimatedMeters,
    this.verified = false,
    this.schematic = false,
  });

  final String from;
  final String to;
  final int estimatedMeters;

  /// Only operator-verified edges may power distance or turn-by-turn claims.
  final bool verified;

  /// A schematic edge only expresses logical adjacency from the supplied map.
  /// It may produce an orientation route, but never a distance claim.
  final bool schematic;

  bool get isRoutable => verified || schematic;
}

class CampusLogicalRoute {
  const CampusLogicalRoute({
    required this.nodes,
    required this.estimatedMeters,
    required this.isVerified,
  });

  final List<CampusMapNode> nodes;
  final int estimatedMeters;
  final bool isVerified;
}

class CampusMapGraph {
  const CampusMapGraph({required this.nodes, required this.links});

  final List<CampusMapNode> nodes;
  final List<CampusMapLink> links;

  CampusMapNode? nodeById(String id) =>
      _firstOrNull(nodes.where((node) => node.id == id));

  CampusMapNode? findDestination(String query) {
    final exact = nodes.where(
      (node) => node.name.toLowerCase() == query.trim().toLowerCase(),
    );
    if (exact.isNotEmpty) return exact.first;
    return _firstOrNull(nodes.where((node) => node.matches(query)));
  }

  CampusMapNode? nodeForSpace(CampusLocationSpace space) {
    final slug = space.locationSlug?.trim();
    if (slug != null && slug.isNotEmpty) {
      final bySlug = nodeById(slug);
      if (bySlug != null) return bySlug;
    }
    return _firstOrNull(
      nodes.where((node) {
        return node.name == space.name || node.spaceNames.contains(space.name);
      }),
    );
  }

  CampusLogicalRoute? shortestRoute(String startId, String destinationId) {
    final start = nodeById(startId);
    final destination = nodeById(destinationId);
    if (start == null || destination == null) return null;
    if (start.id == destination.id) {
      return CampusLogicalRoute(
        nodes: [start],
        estimatedMeters: 0,
        isVerified: true,
      );
    }

    final distances = <String, int>{for (final node in nodes) node.id: 1 << 30};
    final previous = <String, String>{};
    final previousLinks = <String, CampusMapLink>{};
    final remaining = nodes.map((node) => node.id).toSet();
    distances[start.id] = 0;

    while (remaining.isNotEmpty) {
      String? current;
      var currentDistance = 1 << 30;
      for (final id in remaining) {
        final distance = distances[id] ?? (1 << 30);
        if (distance < currentDistance) {
          current = id;
          currentDistance = distance;
        }
      }
      if (current == null || currentDistance == 1 << 30) break;
      remaining.remove(current);
      if (current == destination.id) break;

      for (final link in links.where(
        (link) =>
            link.isRoutable && (link.from == current || link.to == current),
      )) {
        final neighbour = link.from == current ? link.to : link.from;
        if (!remaining.contains(neighbour)) continue;
        final candidate = currentDistance + link.estimatedMeters;
        if (candidate < (distances[neighbour] ?? (1 << 30))) {
          distances[neighbour] = candidate;
          previous[neighbour] = current;
          previousLinks[neighbour] = link;
        }
      }
    }

    if (!previous.containsKey(destination.id)) return null;
    final ids = <String>[destination.id];
    var cursor = destination.id;
    var isVerified = true;
    while (cursor != start.id) {
      final parent = previous[cursor];
      if (parent == null) return null;
      isVerified = isVerified && (previousLinks[cursor]?.verified ?? false);
      ids.add(parent);
      cursor = parent;
    }
    final routeNodes = ids.reversed
        .map(nodeById)
        .whereType<CampusMapNode>()
        .toList(growable: false);
    return CampusLogicalRoute(
      nodes: routeNodes,
      estimatedMeters: distances[destination.id] ?? 0,
      isVerified: isVerified,
    );
  }

  // Campus centers use published NCU/OSM coordinates. Interior Qianhu points
  // combine public map features with the supplied campus guide and remain
  // explicitly unverified in the UI until an operator confirms entrances.
  static const ncu = CampusMapGraph(
    nodes: [
      CampusMapNode(
        id: 'qianhu-north',
        name: '前湖北院',
        directoryName: '前湖北院',
        x: 0.30,
        y: 0.18,
        kind: CampusMapNodeKind.area,
        latitude: 28.6638,
        longitude: 115.8012,
      ),
      CampusMapNode(
        id: 'qianhu-north-gate',
        name: '三号门 · 前湖大道门',
        directoryName: '前湖北院',
        x: 0.12,
        y: 0.08,
        kind: CampusMapNodeKind.gate,
        latitude: 28.668010,
        longitude: 115.808180,
        coordinateVerified: true,
        minimumZoom: 13.5,
      ),
      CampusMapNode(
        id: 'qianhu-main-gate',
        name: '一号门 · 学府大道正门',
        directoryName: '前湖北院',
        x: 0.48,
        y: 0.66,
        kind: CampusMapNodeKind.gate,
        latitude: 28.6583218,
        longitude: 115.7976702,
        coordinateVerified: true,
        minimumZoom: 13.5,
      ),
      CampusMapNode(
        id: 'qianhu-east-gate',
        name: '二号门 · 学府大道东门',
        directoryName: '前湖北院',
        x: 0.78,
        y: 0.54,
        kind: CampusMapNodeKind.gate,
        latitude: 28.6614844,
        longitude: 115.8075227,
        coordinateVerified: true,
        minimumZoom: 13.5,
      ),
      CampusMapNode(
        id: 'qianhu-jiayan-north-gate',
        name: '五号门 · 嘉言路北门',
        directoryName: '前湖北院',
        x: 0.35,
        y: 0.70,
        kind: CampusMapNodeKind.gate,
        latitude: 28.6511878,
        longitude: 115.7902267,
        coordinateVerified: true,
        minimumZoom: 13.5,
      ),
      CampusMapNode(
        id: 'xian-su-yuan',
        name: '先骕园',
        directoryName: '前湖北院',
        x: 0.20,
        y: 0.34,
        kind: CampusMapNodeKind.building,
        latitude: 28.6641,
        longitude: 115.7950,
        spaceNames: ['先驌园'],
      ),
      CampusMapNode(
        id: 'qianhu-library',
        name: '前湖校区图书馆',
        directoryName: '前湖北院',
        x: 0.46,
        y: 0.36,
        kind: CampusMapNodeKind.building,
        latitude: 28.6577,
        longitude: 115.8001,
      ),
      CampusMapNode(
        id: 'xiuxian-square',
        name: '修贤广场',
        directoryName: '前湖北院',
        x: 0.57,
        y: 0.50,
        kind: CampusMapNodeKind.landmark,
        latitude: 28.6647,
        longitude: 115.8040,
      ),
      CampusMapNode(
        id: 'runxi-lake',
        name: '润溪湖畔',
        directoryName: '前湖北院',
        x: 0.73,
        y: 0.40,
        kind: CampusMapNodeKind.landmark,
        latitude: 28.666308,
        longitude: 115.802102,
        coordinateVerified: true,
        minimumZoom: 15.2,
      ),
      CampusMapNode(
        id: 'qianhu-south',
        name: '前湖南院',
        directoryName: '前湖南院',
        x: 0.49,
        y: 0.68,
        kind: CampusMapNodeKind.area,
        latitude: 28.656342,
        longitude: 115.801302,
      ),
      CampusMapNode(
        id: 'qianhu-south-gate',
        name: '医学部一号门 · 学府大道西门',
        directoryName: '前湖南院',
        x: 0.43,
        y: 0.92,
        kind: CampusMapNodeKind.gate,
        latitude: 28.6493156,
        longitude: 115.7934080,
        coordinateVerified: true,
        minimumZoom: 13.5,
      ),
      CampusMapNode(
        id: 'qianhu-medical-jiayan-gate',
        name: '医学部二号门 · 嘉言路南门',
        directoryName: '前湖南院',
        x: 0.38,
        y: 0.72,
        kind: CampusMapNodeKind.gate,
        latitude: 28.6506200,
        longitude: 115.7908700,
        coordinateVerified: true,
        minimumZoom: 13.5,
      ),
      CampusMapNode(
        id: 'qianhu-clinic',
        name: '前湖校区校医院',
        directoryName: '前湖南院',
        x: 0.27,
        y: 0.75,
        kind: CampusMapNodeKind.building,
        latitude: 28.6539,
        longitude: 115.7952,
      ),
      CampusMapNode(
        id: 'qianhu-gymnasium',
        name: '前湖校区体育馆',
        directoryName: '前湖北院',
        x: 0.72,
        y: 0.70,
        kind: CampusMapNodeKind.building,
        latitude: 28.659107,
        longitude: 115.811663,
      ),
      CampusMapNode(
        id: 'tianjian-field',
        name: '天健操场',
        directoryName: '前湖北院',
        x: 0.86,
        y: 0.84,
        kind: CampusMapNodeKind.landmark,
        latitude: 28.6571,
        longitude: 115.8098,
      ),
      CampusMapNode(
        id: 'qingshanhu-campus',
        name: '青山湖校区',
        directoryName: '青山湖校区',
        x: 0.88,
        y: 0.12,
        kind: CampusMapNodeKind.area,
        latitude: 28.685170,
        longitude: 115.939395,
      ),
      CampusMapNode(
        id: 'qingshanhu-library',
        name: '青山湖校区图书馆',
        directoryName: '青山湖校区',
        x: 0.91,
        y: 0.28,
        kind: CampusMapNodeKind.building,
        latitude: 28.68545,
        longitude: 115.9387,
      ),
      CampusMapNode(
        id: 'donghu-campus',
        name: '东湖校区',
        directoryName: '东湖校区',
        x: 0.09,
        y: 0.70,
        kind: CampusMapNodeKind.area,
        latitude: 28.687240,
        longitude: 115.901850,
      ),
      CampusMapNode(
        id: 'donghu-library',
        name: '东湖校区图书馆',
        directoryName: '东湖校区',
        x: 0.12,
        y: 0.86,
        kind: CampusMapNodeKind.building,
        latitude: 28.68755,
        longitude: 115.90135,
      ),
    ],
    // These edges express only the relative order visible on the supplied
    // campus guide. They intentionally do not claim verified walking distance.
    links: [
      CampusMapLink(
        from: 'qianhu-north-gate',
        to: 'qianhu-north',
        estimatedMeters: 120,
        schematic: true,
      ),
      CampusMapLink(
        from: 'qianhu-north',
        to: 'xian-su-yuan',
        estimatedMeters: 180,
        schematic: true,
      ),
      CampusMapLink(
        from: 'qianhu-north',
        to: 'qianhu-library',
        estimatedMeters: 240,
        schematic: true,
      ),
      CampusMapLink(
        from: 'xian-su-yuan',
        to: 'qianhu-library',
        estimatedMeters: 220,
        schematic: true,
      ),
      CampusMapLink(
        from: 'qianhu-library',
        to: 'xiuxian-square',
        estimatedMeters: 180,
        schematic: true,
      ),
      CampusMapLink(
        from: 'xiuxian-square',
        to: 'runxi-lake',
        estimatedMeters: 260,
        schematic: true,
      ),
      CampusMapLink(
        from: 'xiuxian-square',
        to: 'qianhu-south',
        estimatedMeters: 200,
        schematic: true,
      ),
      CampusMapLink(
        from: 'qianhu-south',
        to: 'qianhu-south-gate',
        estimatedMeters: 280,
        schematic: true,
      ),
      CampusMapLink(
        from: 'qianhu-south',
        to: 'qianhu-clinic',
        estimatedMeters: 200,
        schematic: true,
      ),
      CampusMapLink(
        from: 'qianhu-south',
        to: 'qianhu-gymnasium',
        estimatedMeters: 260,
        schematic: true,
      ),
      CampusMapLink(
        from: 'qianhu-gymnasium',
        to: 'tianjian-field',
        estimatedMeters: 160,
        schematic: true,
      ),
      CampusMapLink(
        from: 'qingshanhu-campus',
        to: 'qingshanhu-library',
        estimatedMeters: 240,
        schematic: true,
      ),
      CampusMapLink(
        from: 'donghu-campus',
        to: 'donghu-library',
        estimatedMeters: 220,
        schematic: true,
      ),
    ],
  );
}

String? _optionalString(dynamic value) {
  final text = value?.toString().trim();
  return text == null || text.isEmpty ? null : text;
}

T? _firstOrNull<T>(Iterable<T> values) {
  final iterator = values.iterator;
  return iterator.moveNext() ? iterator.current : null;
}
