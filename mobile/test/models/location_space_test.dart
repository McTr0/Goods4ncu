import 'package:flutter_test/flutter_test.dart';
import 'package:goods4ncu_mobile/models/location_space.dart';

void main() {
  test('location JSON keeps online count, slug, and ttl fields', () {
    final space = CampusLocationSpace.fromJson({
      'id': 'xian-su-yuan',
      'name': '先骕园',
      'location_kind': 'facility',
      'location_slug': 'xian-su-yuan',
      'online_count': 6,
      'member_count': 99,
      'children': const [],
    });
    final presence = CampusLocationPresence.fromJson({
      'online_count': 6,
      'ttl_seconds': 48,
    });

    expect(space.onlineCount, 6);
    expect(space.locationSlug, 'xian-su-yuan');
    expect(space.memberCount, 99);
    expect(presence.onlineCount, 6);
    expect(presence.expiresInSeconds, 48);
  });

  test('primary directories promote the four requested roots', () {
    final roots = [
      CampusLocationSpace.fromJson({
        'id': 'campus',
        'name': '前湖校区',
        'location_kind': 'campus',
        'children': [
          {
            'id': 'north',
            'name': '前湖北院',
            'location_kind': 'area',
            'children': const [],
          },
          {
            'id': 'south',
            'name': '前湖南院',
            'location_kind': 'area',
            'children': const [],
          },
        ],
      }),
      CampusLocationSpace.fromJson({
        'id': 'qing',
        'name': '青山湖校区',
        'location_kind': 'campus',
        'children': const [],
      }),
      CampusLocationSpace.fromJson({
        'id': 'dong',
        'name': '东湖校区',
        'location_kind': 'campus',
        'children': const [],
      }),
    ];

    expect(
      CampusLocationSpace.primaryDirectories(
        roots,
      ).map((space) => space.name).toList(),
      ['前湖北院', '前湖南院', '青山湖校区', '东湖校区'],
    );
  });

  test('only verified graph edges produce routes', () {
    const a = CampusMapNode(
      id: 'a',
      name: '起点',
      directoryName: '前湖北院',
      x: 0.2,
      y: 0.2,
      kind: CampusMapNodeKind.gate,
    );
    const b = CampusMapNode(
      id: 'b',
      name: '目标楼',
      directoryName: '前湖北院',
      x: 0.8,
      y: 0.8,
      kind: CampusMapNodeKind.building,
    );
    const unverified = CampusMapGraph(
      nodes: [a, b],
      links: [CampusMapLink(from: 'a', to: 'b', estimatedMeters: 100)],
    );
    final verified = CampusMapGraph(
      nodes: const [a, b],
      links: [
        CampusMapLink(from: 'a', to: 'b', estimatedMeters: 100, verified: true),
      ],
    );

    expect(unverified.shortestRoute('a', 'b'), isNull);
    expect(verified.shortestRoute('a', 'b')?.estimatedMeters, 100);
    expect(verified.shortestRoute('a', 'b')?.isVerified, isTrue);
  });

  test('schematic graph edges produce a route without verified status', () {
    const graph = CampusMapGraph(
      nodes: [
        CampusMapNode(
          id: 'a',
          name: '起点',
          directoryName: '前湖北院',
          x: 0.2,
          y: 0.2,
          kind: CampusMapNodeKind.gate,
        ),
        CampusMapNode(
          id: 'b',
          name: '目标楼',
          directoryName: '前湖北院',
          x: 0.8,
          y: 0.8,
          kind: CampusMapNodeKind.building,
        ),
      ],
      links: [
        CampusMapLink(
          from: 'a',
          to: 'b',
          estimatedMeters: 100,
          schematic: true,
        ),
      ],
    );

    final route = graph.shortestRoute('a', 'b');
    expect(route?.nodes.map((node) => node.id), ['a', 'b']);
    expect(route?.isVerified, isFalse);
  });

  test('bundled Qianhu graph supports schematic building orientation', () {
    final route = CampusMapGraph.ncu.shortestRoute(
      'qianhu-north-gate',
      'xian-su-yuan',
    );
    expect(route, isNotNull);
    expect(route?.nodes.last.name, '先骕园');
    expect(route?.isVerified, isFalse);
  });

  test('legacy traditional alias resolves to simplified Xiansu node', () {
    final node = CampusMapGraph.ncu.findDestination('先驌园');
    expect(node?.id, 'xian-su-yuan');
    expect(node?.name, '先骕园');
  });

  test('bundled Qianhu map exposes the six official gates progressively', () {
    final gates = CampusMapGraph.ncu.nodes
        .where(
          (node) =>
              node.kind == CampusMapNodeKind.gate &&
              (node.directoryName == '前湖北院' || node.directoryName == '前湖南院'),
        )
        .toList(growable: false);

    expect(gates, hasLength(6));
    expect(gates.every((node) => node.coordinateVerified), isTrue);
    expect(gates.every((node) => node.minimumZoom == 13.5), isTrue);
    expect(gates.map((node) => node.name), contains('五号门 · 嘉言路北门'));
    expect(gates.map((node) => node.name), contains('医学部二号门 · 嘉言路南门'));
  });
}
