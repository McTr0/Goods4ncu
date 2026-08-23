import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:goods4ncu_mobile/l10n/app_localizations.dart';
import 'package:goods4ncu_mobile/models/location_space.dart';
import 'package:goods4ncu_mobile/pages/campus_map_page.dart';
import 'package:goods4ncu_mobile/services/campus_location_service.dart';
import 'package:goods4ncu_mobile/services/chat_service.dart';
import 'package:goods4ncu_mobile/theme/app_theme.dart';

class _MapChatService extends ChatService {
  _MapChatService({
    this.locationFailure = false,
    this.directoryFailure = false,
  });

  final bool locationFailure;
  final bool directoryFailure;
  String? enteredSpaceId;

  final spaces = const [
    CampusLocationSpace(
      id: 'start',
      name: '前湖北院',
      locationSlug: 'start',
      locationKind: 'area',
      isOfficial: true,
      isMember: false,
      memberCount: 20,
      onlineCount: 8,
      canCreateChildren: false,
      children: [
        CampusLocationSpace(
          id: 'xian-su-yuan',
          name: '先骕园',
          locationSlug: 'target',
          locationKind: 'facility',
          isOfficial: true,
          isMember: false,
          memberCount: 0,
          onlineCount: 3,
          canCreateChildren: false,
        ),
      ],
    ),
    CampusLocationSpace(
      id: 'south',
      name: '前湖南院',
      locationKind: 'area',
      isOfficial: true,
      isMember: false,
      memberCount: 0,
      canCreateChildren: false,
      onlineCount: 1,
    ),
    CampusLocationSpace(
      id: 'qing',
      name: '青山湖校区',
      locationKind: 'campus',
      isOfficial: true,
      isMember: false,
      memberCount: 0,
      canCreateChildren: false,
      onlineCount: 0,
    ),
    CampusLocationSpace(
      id: 'dong',
      name: '东湖校区',
      locationKind: 'campus',
      isOfficial: true,
      isMember: false,
      memberCount: 0,
      canCreateChildren: false,
      onlineCount: 2,
    ),
  ];

  @override
  Future<List<CampusLocationSpace>> getLocationSpaces() async {
    if (directoryFailure) throw Exception('directory unavailable');
    return spaces;
  }

  @override
  Future<CampusLocationRecommendation> recommendLocationSpace({
    required double latitude,
    required double longitude,
  }) async {
    if (locationFailure) {
      throw const CampusLocationException(CampusLocationFailure.unavailable);
    }
    return CampusLocationRecommendation(matched: true, space: spaces.first);
  }

  @override
  Future<Map<String, dynamic>> enterLocationSpace(String spaceId) async {
    enteredSpaceId = spaceId;
    return {
      'id': spaceId,
      'kind': 'group',
      'name': '先骕园',
      'is_location_space': true,
      'online_count': 3,
      'created_at': '2026-08-16T10:00:00Z',
      'updated_at': '2026-08-16T10:00:00Z',
    };
  }
}

class _MapLocationService extends CampusLocationService {
  @override
  Future<CoarseCampusPosition> determineCoarsePosition() async =>
      const CoarseCampusPosition(latitude: 28.657, longitude: 115.793);
}

class _FailingMapLocationService extends CampusLocationService {
  @override
  Future<CoarseCampusPosition> determineCoarsePosition() async {
    throw const CampusLocationException(CampusLocationFailure.permissionDenied);
  }
}

const _mapGraph = CampusMapGraph(
  nodes: [
    CampusMapNode(
      id: 'start',
      name: '前湖北院',
      directoryName: '前湖北院',
      x: 0.2,
      y: 0.2,
      kind: CampusMapNodeKind.area,
      coordinateVerified: true,
    ),
    CampusMapNode(
      id: 'target',
      name: '先骕园',
      directoryName: '前湖北院',
      x: 0.8,
      y: 0.8,
      kind: CampusMapNodeKind.building,
      coordinateVerified: true,
    ),
  ],
  links: [
    CampusMapLink(
      from: 'start',
      to: 'target',
      estimatedMeters: 260,
      verified: true,
    ),
  ],
);

Widget _buildMapApp({
  required ChatService chatService,
  required CampusLocationService locationService,
  double textScale = 1,
  Size? mediaSize,
}) {
  return MaterialApp(
    theme: AppTheme.light,
    locale: const Locale('zh'),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(size: mediaSize, textScaler: TextScaler.linear(textScale)),
      child: child!,
    ),
    home: CampusMapPage(
      chatService: chatService,
      locationService: locationService,
      graph: _mapGraph,
    ),
  );
}

void main() {
  testWidgets('mobile map bounds tile work and uses progressive overlays', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      _buildMapApp(
        chatService: _MapChatService(),
        locationService: _MapLocationService(),
        mediaSize: const Size(390, 844),
      ),
    );
    await tester.pumpAndSettle();

    final tiles = tester.widget<TileLayer>(find.byType(TileLayer));
    final provider = tiles.tileProvider as NetworkTileProvider;
    final boundary = tester.widget<PolygonLayer>(
      find.byKey(const ValueKey('campus-map-boundary-前湖北院')),
    );
    final markers = tester.widget<MarkerLayer>(find.byType(MarkerLayer));
    final compactMarker = markers.markers.first;

    expect(tiles.tileBounds, isNotNull);
    expect(tiles.keepBuffer, 1);
    expect(tiles.panBuffer, 1);
    expect(provider.abortObsoleteRequests, isTrue);
    expect(boundary.polygons, hasLength(2));
    expect(markers.markers.length, lessThanOrEqualTo(5));
    expect(compactMarker.width, 44);
    expect(tester.takeException(), isNull);
  });

  testWidgets('campus switch replaces the clipping boundary', (tester) async {
    await tester.binding.setSurfaceSize(const Size(817, 1044));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      _buildMapApp(
        chatService: _MapChatService(),
        locationService: _MapLocationService(),
      ),
    );
    await tester.pumpAndSettle();

    final qingshanhu = find.byKey(const ValueKey('campus-map-filter-青山湖校区'));
    await tester.tap(qingshanhu);
    await tester.pumpAndSettle();

    final maskLayer = tester.widget<PolygonLayer>(
      find.byKey(const ValueKey('campus-map-mask-青山湖校区')),
    );
    final boundaryLayer = tester.widget<PolygonLayer>(
      find.byKey(const ValueKey('campus-map-boundary-青山湖校区')),
    );
    expect(maskLayer.invertedFill, isNotNull);
    expect(maskLayer.polygons, hasLength(2));
    expect(boundaryLayer.invertedFill, isNull);
    expect(boundaryLayer.polygons, hasLength(2));
    expect(tester.takeException(), isNull);
  });

  testWidgets('map plans a verified route and accepts a classroom hint', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final service = _MapChatService();
    await tester.pumpWidget(
      _buildMapApp(
        chatService: service,
        locationService: _MapLocationService(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('校园地图'), findsOneWidget);
    expect(find.text('前湖北院'), findsWidgets);
    final maskLayer = tester.widget<PolygonLayer>(
      find.byKey(const ValueKey('campus-map-mask-前湖北院')),
    );
    expect(maskLayer.invertedFill, isNotNull);
    expect(maskLayer.polygons, isNotEmpty);
    expect(
      find.byKey(const ValueKey('campus-map-directory-xian-su-yuan')),
      findsNothing,
    );

    final useLocation = find.byKey(const ValueKey('campus-map-use-location'));
    await tester.ensureVisible(useLocation);
    await tester.tap(useLocation);
    await tester.pumpAndSettle();
    final startDirectory = find.byKey(
      const ValueKey('campus-map-directory-start'),
    );
    await tester.ensureVisible(startDirectory);
    await tester.tap(startDirectory);
    await tester.pumpAndSettle();
    final targetSuggestion = find.byKey(
      const ValueKey('campus-map-suggestion-target'),
    );
    await tester.ensureVisible(targetSuggestion);
    await tester.tap(targetSuggestion);
    final classroom = find.byKey(const ValueKey('campus-map-classroom'));
    await tester.ensureVisible(classroom);
    await tester.enterText(classroom, 'A101');
    final buildRoute = find.byKey(const ValueKey('campus-map-build-route'));
    await tester.ensureVisible(buildRoute);
    await tester.tap(buildRoute);
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('campus-map-route-summary')),
      findsOneWidget,
    );
    expect(find.textContaining('260'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('campus-map-route-summary')),
        matching: find.textContaining('A101'),
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('location failure leaves a manual start path at 200% text', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      _buildMapApp(
        chatService: _MapChatService(locationFailure: true),
        locationService: _FailingMapLocationService(),
        textScale: 2,
      ),
    );
    await tester.pumpAndSettle();

    final useLocation = find.byKey(const ValueKey('campus-map-use-location'));
    await tester.ensureVisible(useLocation);
    await tester.tap(useLocation);
    await tester.pumpAndSettle();
    expect(find.text('定位暂不可用，请手动选择起点。'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'directory failure keeps the logical map and route planner visible',
    (tester) async {
      await tester.pumpWidget(
        _buildMapApp(
          chatService: _MapChatService(directoryFailure: true),
          locationService: _MapLocationService(),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('校园地图'), findsOneWidget);
      expect(find.byKey(const ValueKey('campus-map-building')), findsOneWidget);
      expect(find.text('前湖北院'), findsWidgets);
      expect(find.byType(CircularProgressIndicator), findsNothing);
    },
  );

  testWidgets('map destination can open its location chat', (tester) async {
    final service = _MapChatService();
    final router = GoRouter(
      initialLocation: '/campus-map',
      routes: [
        GoRoute(
          path: '/campus-map',
          builder: (context, state) => CampusMapPage(
            chatService: service,
            locationService: _MapLocationService(),
            graph: _mapGraph,
          ),
        ),
        GoRoute(
          name: 'chat-space',
          path: '/spaces/:spaceId',
          builder: (context, state) =>
              Scaffold(body: Text('opened-${state.pathParameters['spaceId']}')),
        ),
      ],
    );
    await tester.pumpWidget(
      MaterialApp.router(
        theme: AppTheme.light,
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        routerConfig: router,
      ),
    );
    await tester.pumpAndSettle();
    final startDirectory = find.byKey(
      const ValueKey('campus-map-directory-start'),
    );
    await tester.ensureVisible(startDirectory);
    await tester.tap(startDirectory);
    await tester.pumpAndSettle();
    final targetSuggestion = find.byKey(
      const ValueKey('campus-map-suggestion-target'),
    );
    await tester.ensureVisible(targetSuggestion);
    await tester.tap(targetSuggestion);
    await tester.pumpAndSettle();
    final enterChat = find.byKey(const ValueKey('campus-map-enter-chat'));
    await tester.ensureVisible(enterChat);
    await tester.tap(enterChat);
    await tester.pumpAndSettle();

    expect(service.enteredSpaceId, 'xian-su-yuan');
    expect(find.text('opened-xian-su-yuan'), findsOneWidget);
  });
}
