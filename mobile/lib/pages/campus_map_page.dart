import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:go_router/go_router.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../models/location_space.dart';
import '../services/campus_location_service.dart';
import '../services/chat_service.dart';

class CampusMapPage extends StatefulWidget {
  const CampusMapPage({
    super.key,
    this.chatService,
    this.locationService,
    this.graph = CampusMapGraph.ncu,
  });

  final ChatService? chatService;
  final CampusLocationService? locationService;
  final CampusMapGraph graph;

  @override
  State<CampusMapPage> createState() => _CampusMapPageState();
}

class _CampusMapPageState extends State<CampusMapPage> {
  late final ChatService _chatService;
  late final CampusLocationService _locationService;
  final _buildingController = TextEditingController();
  final _classroomController = TextEditingController();

  List<CampusLocationSpace> _directoryRoots = const [];
  List<CampusLocationSpace> _allSpaces = const [];
  CampusMapNode? _origin;
  CampusMapNode? _destination;
  CampusLogicalRoute? _route;
  String _activeDirectory = '前湖北院';
  bool _loading = true;
  bool _locating = false;
  bool _entering = false;
  String? _error;
  String? _plannerError;

  @override
  void initState() {
    super.initState();
    _chatService = widget.chatService ?? context.read<ChatService>();
    _locationService = widget.locationService ?? CampusLocationService();
    _loadDirectory();
  }

  @override
  void dispose() {
    _buildingController.dispose();
    _classroomController.dispose();
    super.dispose();
  }

  Future<void> _loadDirectory() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final spaces = await _chatService.getLocationSpaces();
      final primary = CampusLocationSpace.primaryDirectories(spaces);
      if (!mounted) return;
      setState(() {
        _directoryRoots = primary.isEmpty ? spaces : primary;
        _allSpaces = spaces
            .expand((space) => space.walk())
            .toList(growable: false);
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      final fallback = _fallbackDirectory();
      setState(() {
        _loading = false;
        // The logical map is useful without the presence/chat endpoint. Keep
        // the route planner visible and make only chat entry unavailable.
        _directoryRoots = fallback;
        _allSpaces = fallback
            .expand((space) => space.walk())
            .toList(growable: false);
        _error = null;
      });
    }
  }

  List<CampusLocationSpace> _fallbackDirectory() {
    const directories = ['前湖北院', '前湖南院', '青山湖校区', '东湖校区'];
    return directories
        .map((directory) {
          final children = widget.graph.nodes
              .where(
                (node) =>
                    node.directoryName == directory &&
                    node.kind != CampusMapNodeKind.area,
              )
              .map(
                (node) => CampusLocationSpace(
                  id: 'logical-map-${node.id}',
                  name: node.name,
                  locationKind: node.kind.name,
                  isOfficial: false,
                  isMember: false,
                  memberCount: 0,
                  canCreateChildren: false,
                  locationMatchable: true,
                  locationSlug: node.id,
                  origin: 'logical_map',
                ),
              )
              .toList(growable: false);
          return CampusLocationSpace(
            id: 'logical-map-directory-$directory',
            name: directory,
            locationKind: 'campus',
            isOfficial: false,
            isMember: false,
            memberCount: 0,
            canCreateChildren: false,
            origin: 'logical_map',
            children: children,
          );
        })
        .toList(growable: false);
  }

  Future<void> _useCurrentLocation() async {
    if (_locating) return;
    final l = AppLocalizations.of(context)!;
    setState(() {
      _locating = true;
      _plannerError = null;
    });
    try {
      final position = await _locationService.determineCoarsePosition();
      final recommendation = await _chatService.recommendLocationSpace(
        latitude: position.latitude,
        longitude: position.longitude,
      );
      final space = recommendation.space;
      final node = space == null ? null : widget.graph.nodeForSpace(space);
      if (!recommendation.matched || node == null || !node.coordinateVerified) {
        if (!mounted) return;
        setState(() => _plannerError = l.campusMapManualOriginRequired);
        return;
      }
      if (!mounted) return;
      setState(() {
        _origin = node;
        _activeDirectory = node.directoryName;
        _route = null;
      });
    } on CampusLocationException {
      if (!mounted) return;
      setState(() => _plannerError = l.campusMapLocationFailed);
    } catch (_) {
      if (!mounted) return;
      setState(() => _plannerError = l.campusMapLocationFailed);
    } finally {
      if (mounted) setState(() => _locating = false);
    }
  }

  void _selectDestination(CampusMapNode node) {
    setState(() {
      _destination = node;
      _buildingController.text = node.name;
      _activeDirectory = node.directoryName;
      _route = null;
      _plannerError = null;
    });
  }

  void _buildRoute() {
    final l = AppLocalizations.of(context)!;
    final origin = _origin;
    final destination =
        _destination ?? widget.graph.findDestination(_buildingController.text);
    if (origin == null) {
      setState(() => _plannerError = l.campusMapSelectOrigin);
      return;
    }
    if (destination == null || !destination.coordinateVerified) {
      setState(() => _plannerError = l.campusMapSelectBuilding);
      return;
    }
    final route = widget.graph.shortestRoute(origin.id, destination.id);
    setState(() {
      _destination = destination;
      _route = route;
      _plannerError = route == null ? l.campusMapRouteUnavailable : null;
    });
  }

  CampusLocationSpace? _spaceForNode(CampusMapNode node) {
    for (final space in _allSpaces) {
      if (space.locationSlug == node.id ||
          space.name == node.name ||
          node.spaceNames.contains(space.name)) {
        return space;
      }
    }
    return null;
  }

  Future<void> _enterSpace(CampusLocationSpace space) async {
    if (_entering) return;
    final l = AppLocalizations.of(context)!;
    if (space.origin == 'logical_map') {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l.campusMapChatUnavailable)));
      return;
    }
    setState(() => _entering = true);
    try {
      final data = await _chatService.enterLocationSpace(space.id);
      if (!mounted) return;
      context.pushNamed(
        'chat-space',
        pathParameters: {'spaceId': space.id},
        extra: {
          ...data,
          'is_location_space': true,
          'origin': space.origin ?? 'campus_location',
          'location_kind': space.locationKind,
          'location_slug': space.locationSlug,
        },
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l.locationEnterFailed(error.toString()))),
      );
    } finally {
      if (mounted) setState(() => _entering = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(
        title: Text(l.campusMapTitle),
        actions: [
          IconButton(
            icon: const Icon(Icons.face_retouching_natural_rounded),
            tooltip: '小昌数字人',
            onPressed: () => context.push('/live2d-preview'),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? _LoadError(message: _error!, onRetry: _loadDirectory)
          : LayoutBuilder(
              builder: (context, constraints) {
                if (constraints.maxWidth >= 980) {
                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(flex: 3, child: _buildMapPane()),
                      SizedBox(
                        width: 390,
                        child: ListView(
                          padding: const EdgeInsets.fromLTRB(18, 18, 18, 28),
                          children: [
                            _buildPlanner(),
                            const SizedBox(height: 22),
                            _buildDirectory(),
                          ],
                        ),
                      ),
                    ],
                  );
                }
                return SingleChildScrollView(
                  padding: const EdgeInsets.only(bottom: 28),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _buildMapPane(),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 20, 16, 0),
                        child: _buildPlanner(),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 22, 16, 0),
                        child: _buildDirectory(),
                      ),
                    ],
                  ),
                );
              },
            ),
    );
  }

  Widget _buildMapPane() {
    final l = AppLocalizations.of(context)!;
    final scheme = Theme.of(context).colorScheme;
    final mapAspectRatio = MediaQuery.sizeOf(context).width < 600 ? 1.12 : 1.5;
    return ColoredBox(
      color: scheme.surfaceContainerLow,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 18, 16, 18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    l.campusMapLogicalTitle,
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: scheme.tertiaryContainer,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    l.campusMapEstimateBadge,
                    style: TextStyle(
                      color: scheme.onTertiaryContainer,
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 5),
            Text(
              l.campusMapLogicalHint,
              style: TextStyle(color: scheme.onSurfaceVariant, height: 1.35),
            ),
            const SizedBox(height: 12),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (final name in const [
                    '前湖北院',
                    '前湖南院',
                    '青山湖校区',
                    '东湖校区',
                  ]) ...[
                    SizedBox(
                      width: 112,
                      child: FilterChip(
                        key: ValueKey('campus-map-filter-$name'),
                        labelPadding: const EdgeInsets.symmetric(horizontal: 6),
                        label: Center(
                          child: Text(name, maxLines: 1, softWrap: false),
                        ),
                        selected: _activeDirectory == name,
                        onSelected: (_) {
                          setState(() => _activeDirectory = name);
                        },
                      ),
                    ),
                    const SizedBox(width: 7),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 12),
            AspectRatio(
              aspectRatio: mapAspectRatio,
              child: _CampusGeographicMap(
                graph: widget.graph,
                activeDirectory: _activeDirectory,
                origin: _origin,
                destination: _destination,
                route: _route,
                onSelect: _selectDestination,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDirectory() {
    final l = AppLocalizations.of(context)!;
    return _Section(
      title: l.campusMapDirectoryTitle,
      icon: Icons.account_tree_outlined,
      child: Column(
        children: [
          for (final space in _directoryRoots)
            _CampusDirectoryTile(
              space: space,
              level: 0,
              graph: widget.graph,
              onSelectNode: _selectDestination,
              onEnterSpace: _enterSpace,
            ),
        ],
      ),
    );
  }

  Widget _buildPlanner() {
    final l = AppLocalizations.of(context)!;
    final scheme = Theme.of(context).colorScheme;
    final suggestions = widget.graph.nodes
        .where(
          (node) =>
              node.coordinateVerified &&
              node.kind != CampusMapNodeKind.area &&
              (node.directoryName == _activeDirectory ||
                  node.matches(_buildingController.text)),
        )
        .take(6)
        .toList(growable: false);
    final destinationSpace = _destination == null
        ? null
        : _spaceForNode(_destination!);

    return _Section(
      title: l.campusMapPlannerTitle,
      icon: Icons.route_outlined,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: FilledButton.tonalIcon(
                  key: const ValueKey('campus-map-use-location'),
                  onPressed: _locating ? null : _useCurrentLocation,
                  icon: _locating
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.my_location_rounded, size: 18),
                  label: Text(l.campusMapUseCurrentLocation),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          InputDecorator(
            decoration: InputDecoration(
              labelText: l.campusMapManualOrigin,
              border: const OutlineInputBorder(),
            ),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<String>(
                key: const ValueKey('campus-map-origin'),
                isExpanded: true,
                value: _origin?.id,
                hint: Text(l.campusMapSelectOrigin),
                items: widget.graph.nodes
                    .where((node) => node.coordinateVerified)
                    .map(
                      (node) => DropdownMenuItem(
                        value: node.id,
                        child: Text(
                          '${node.directoryName} · ${node.name}',
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    )
                    .toList(growable: false),
                onChanged: (id) {
                  final node = id == null ? null : widget.graph.nodeById(id);
                  setState(() {
                    _origin = node;
                    if (node != null) _activeDirectory = node.directoryName;
                    _route = null;
                    _plannerError = null;
                  });
                },
              ),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const ValueKey('campus-map-building'),
            controller: _buildingController,
            decoration: InputDecoration(
              labelText: l.campusMapBuildingLabel,
              hintText: l.campusMapBuildingHint,
              prefixIcon: const Icon(Icons.apartment_outlined),
              border: const OutlineInputBorder(),
            ),
            onChanged: (value) {
              setState(() {
                _destination = widget.graph.findDestination(value);
                _route = null;
                _plannerError = null;
              });
            },
          ),
          if (suggestions.isNotEmpty) ...[
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final node in suggestions)
                  ActionChip(
                    key: ValueKey('campus-map-suggestion-${node.id}'),
                    label: Text(node.name),
                    onPressed: () => _selectDestination(node),
                  ),
              ],
            ),
          ],
          const SizedBox(height: 12),
          TextField(
            key: const ValueKey('campus-map-classroom'),
            controller: _classroomController,
            decoration: InputDecoration(
              labelText: l.campusMapClassroomLabel,
              hintText: l.campusMapClassroomHint,
              prefixIcon: const Icon(Icons.meeting_room_outlined),
              border: const OutlineInputBorder(),
            ),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            key: const ValueKey('campus-map-build-route'),
            onPressed: _buildRoute,
            icon: const Icon(Icons.directions_walk_rounded),
            label: Text(l.campusMapBuildRoute),
          ),
          if (_plannerError != null) ...[
            const SizedBox(height: 10),
            Text(
              _plannerError!,
              key: const ValueKey('campus-map-planner-error'),
              style: TextStyle(color: scheme.error, height: 1.35),
            ),
          ],
          if (_route != null) ...[
            const SizedBox(height: 16),
            _RouteSummary(
              route: _route!,
              classroom: _classroomController.text.trim(),
            ),
          ],
          if (_destination != null) ...[
            const SizedBox(height: 12),
            OutlinedButton.icon(
              key: const ValueKey('campus-map-enter-chat'),
              onPressed: destinationSpace == null || _entering
                  ? null
                  : () => _enterSpace(destinationSpace),
              icon: _entering
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.forum_outlined),
              label: Text(
                destinationSpace == null
                    ? l.campusMapChatUnavailable
                    : l.campusMapEnterChat(destinationSpace.name),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _CampusDirectoryTile extends StatelessWidget {
  const _CampusDirectoryTile({
    required this.space,
    required this.level,
    required this.graph,
    required this.onSelectNode,
    required this.onEnterSpace,
  });

  final CampusLocationSpace space;
  final int level;
  final CampusMapGraph graph;
  final ValueChanged<CampusMapNode> onSelectNode;
  final ValueChanged<CampusLocationSpace> onEnterSpace;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final scheme = Theme.of(context).colorScheme;
    final node = graph.nodeForSpace(space);
    final subtitle = space.onlineCount == null
        ? l.locationOnlineUnavailable
        : l.locationOnlineCount(space.onlineCount!);
    final title = Row(
      children: [
        Expanded(
          child: Text(
            space.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
        ),
        IconButton(
          key: ValueKey('campus-map-chat-${space.id}'),
          tooltip: l.locationEnterAction,
          onPressed: () => onEnterSpace(space),
          icon: const Icon(Icons.forum_outlined, size: 19),
        ),
      ],
    );
    if (space.children.isEmpty) {
      return ListTile(
        key: ValueKey('campus-map-directory-${space.id}'),
        dense: true,
        contentPadding: EdgeInsets.only(left: 8 + level * 14.0, right: 0),
        leading: Icon(_iconForLocationKind(space.locationKind)),
        title: title,
        subtitle: Text(subtitle),
        onTap: node == null ? null : () => onSelectNode(node),
      );
    }
    return Padding(
      padding: EdgeInsets.only(left: level * 10.0),
      child: ExpansionTile(
        key: ValueKey('campus-map-directory-${space.id}'),
        tilePadding: const EdgeInsets.only(left: 8),
        childrenPadding: EdgeInsets.zero,
        leading: Icon(_iconForLocationKind(space.locationKind)),
        title: title,
        subtitle: Text(
          subtitle,
          style: TextStyle(color: scheme.onSurfaceVariant),
        ),
        children: [
          for (final child in space.children)
            _CampusDirectoryTile(
              space: child,
              level: level + 1,
              graph: graph,
              onSelectNode: onSelectNode,
              onEnterSpace: onEnterSpace,
            ),
        ],
      ),
    );
  }
}

class _CampusGeographicMap extends StatefulWidget {
  const _CampusGeographicMap({
    required this.graph,
    required this.activeDirectory,
    required this.origin,
    required this.destination,
    required this.route,
    required this.onSelect,
  });

  final CampusMapGraph graph;
  final String activeDirectory;
  final CampusMapNode? origin;
  final CampusMapNode? destination;
  final CampusLogicalRoute? route;
  final ValueChanged<CampusMapNode> onSelect;

  @override
  State<_CampusGeographicMap> createState() => _CampusGeographicMapState();
}

class _CampusGeographicMapState extends State<_CampusGeographicMap> {
  static const _tileUrl = String.fromEnvironment(
    'MAP_TILE_URL',
    defaultValue: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
  );
  static const _mobileTileCacheBytes = 128 * 1024 * 1024;

  // OpenStreetMap university polygons, retrieved 2026-08-17. The point sets
  // preserve the campus perimeter while dropping only collinear vertices.
  // Sources: ways 223390772, 225359378, 225360249 and 491783995.
  static const _qianhuBoundary = <LatLng>[
    LatLng(28.6551007, 115.7877453),
    LatLng(28.6521974, 115.7862318),
    LatLng(28.6456531, 115.7834231),
    LatLng(28.6452088, 115.7832693),
    LatLng(28.6450379, 115.7832691),
    LatLng(28.6448307, 115.7833495),
    LatLng(28.6440918, 115.7855794),
    LatLng(28.6445420, 115.7857475),
    LatLng(28.6453577, 115.7847902),
    LatLng(28.6457120, 115.7837154),
    LatLng(28.6461377, 115.7839071),
    LatLng(28.6455790, 115.7856885),
    LatLng(28.6461464, 115.7859491),
    LatLng(28.6454433, 115.7869665),
    LatLng(28.6454194, 115.7889570),
    LatLng(28.6449425, 115.7915811),
    LatLng(28.6451416, 115.7920177),
    LatLng(28.6506883, 115.7933595),
    LatLng(28.6534241, 115.7940545),
    LatLng(28.6593373, 115.7996973),
    LatLng(28.6603578, 115.8012454),
    LatLng(28.6623489, 115.8093307),
    LatLng(28.6661105, 115.8079277),
    LatLng(28.6666901, 115.8077115),
    LatLng(28.6706330, 115.8062408),
    LatLng(28.6709154, 115.8053610),
    LatLng(28.6708589, 115.8046100),
    LatLng(28.6690327, 115.7983454),
    LatLng(28.6674371, 115.7954304),
    LatLng(28.6652673, 115.7927021),
    LatLng(28.6621795, 115.7906207),
  ];
  static const _qianhuNorthBoundary = <LatLng>[
    LatLng(28.6521974, 115.7862318),
    LatLng(28.6534241, 115.7940545),
    LatLng(28.6593373, 115.7996973),
    LatLng(28.6603578, 115.8012454),
    LatLng(28.6623489, 115.8093307),
    LatLng(28.6661105, 115.8079277),
    LatLng(28.6666901, 115.8077115),
    LatLng(28.6706330, 115.8062408),
    LatLng(28.6709154, 115.8053610),
    LatLng(28.6708589, 115.8046100),
    LatLng(28.6690327, 115.7983454),
    LatLng(28.6674371, 115.7954304),
    LatLng(28.6652673, 115.7927021),
    LatLng(28.6621795, 115.7906207),
    LatLng(28.6551007, 115.7877453),
    LatLng(28.6525638, 115.7866330),
  ];
  static const _qianhuMedicalBoundary = <LatLng>[
    LatLng(28.6451017, 115.7918437),
    LatLng(28.6456102, 115.7889899),
    LatLng(28.6466749, 115.7883711),
    LatLng(28.6467244, 115.7861438),
    LatLng(28.6473276, 115.7842724),
    LatLng(28.6519729, 115.7863292),
    LatLng(28.6511878, 115.7883923),
    LatLng(28.6508198, 115.7902267),
    LatLng(28.6500731, 115.7930883),
  ];
  static const _qingshanhuNorthBoundary = <LatLng>[
    LatLng(28.6886144, 115.9384501),
    LatLng(28.6852834, 115.9384507),
    LatLng(28.6852815, 115.9367339),
    LatLng(28.6859215, 115.9364403),
    LatLng(28.6861690, 115.9363144),
    LatLng(28.6861763, 115.9355124),
    LatLng(28.6853876, 115.9355074),
    LatLng(28.6852842, 115.9305773),
    LatLng(28.6879666, 115.9306416),
    LatLng(28.6880043, 115.9314570),
    LatLng(28.6883007, 115.9322080),
    LatLng(28.6886147, 115.9322888),
    LatLng(28.6886936, 115.9340483),
    LatLng(28.6890551, 115.9340818),
    LatLng(28.6891512, 115.9337090),
    LatLng(28.6894336, 115.9336272),
    LatLng(28.6894277, 115.9339008),
    LatLng(28.6895912, 115.9339303),
    LatLng(28.6895949, 115.9343592),
    LatLng(28.6900347, 115.9343863),
    LatLng(28.6903359, 115.9355812),
    LatLng(28.6886372, 115.9355444),
    LatLng(28.6886276, 115.9366832),
  ];
  static const _qingshanhuSouthBoundary = <LatLng>[
    LatLng(28.6826126, 115.9437076),
    LatLng(28.6808499, 115.9437359),
    LatLng(28.6808416, 115.9434812),
    LatLng(28.6788544, 115.9434277),
    LatLng(28.6788113, 115.9418044),
    LatLng(28.6779378, 115.9417782),
    LatLng(28.6779378, 115.9393642),
    LatLng(28.6789168, 115.9393427),
    LatLng(28.6789025, 115.9374332),
    LatLng(28.6806156, 115.9374118),
    LatLng(28.6808557, 115.9359846),
    LatLng(28.6836027, 115.9359190),
    LatLng(28.6835799, 115.9366743),
    LatLng(28.6838038, 115.9366691),
    LatLng(28.6838038, 115.9372942),
    LatLng(28.6835799, 115.9373098),
    LatLng(28.6836134, 115.9387636),
    LatLng(28.6832039, 115.9387784),
    LatLng(28.6831522, 115.9389073),
    LatLng(28.6823864, 115.9389810),
    LatLng(28.6824090, 115.9394083),
    LatLng(28.6827832, 115.9398286),
    LatLng(28.6831053, 115.9398255),
    LatLng(28.6830339, 115.9413618),
    LatLng(28.6827698, 115.9427218),
  ];
  static const _donghuBoundary = <LatLng>[
    LatLng(28.6867899, 115.8987926),
    LatLng(28.6868020, 115.8993410),
    LatLng(28.6864650, 115.8993506),
    LatLng(28.6865312, 115.9018189),
    LatLng(28.6865475, 115.9030908),
    LatLng(28.6866488, 115.9043723),
    LatLng(28.6871712, 115.9043777),
    LatLng(28.6871712, 115.9048980),
    LatLng(28.6875947, 115.9049141),
    LatLng(28.6877830, 115.9047049),
    LatLng(28.6880041, 115.9046406),
    LatLng(28.6879947, 115.9031331),
    LatLng(28.6878865, 115.9030741),
    LatLng(28.6877975, 115.8990205),
    LatLng(28.6871952, 115.8990378),
    LatLng(28.6871895, 115.8987812),
  ];
  static const _campusBoundaries = <String, List<List<LatLng>>>{
    '前湖北院': [_qianhuNorthBoundary, _qianhuMedicalBoundary],
    '前湖南院': [_qianhuNorthBoundary, _qianhuMedicalBoundary],
    '青山湖校区': [_qingshanhuNorthBoundary, _qingshanhuSouthBoundary],
    '东湖校区': [_donghuBoundary],
  };
  static const _views = <String, ({LatLng center, double zoom})>{
    '前湖北院': (center: LatLng(28.6631, 115.8019), zoom: 15.35),
    '前湖南院': (center: LatLng(28.6564, 115.8031), zoom: 15.45),
    '青山湖校区': (center: LatLng(28.685170, 115.939395), zoom: 16.8),
    '东湖校区': (center: LatLng(28.687240, 115.901850), zoom: 16.8),
  };

  final MapController _mapController = MapController();
  late final NetworkTileProvider _tileProvider;
  late double _currentZoom;
  bool _showPoints = true;

  @override
  void initState() {
    super.initState();
    _currentZoom = _activeView.zoom;
    _tileProvider = NetworkTileProvider(
      abortObsoleteRequests: true,
      cachingProvider: BuiltInMapCachingProvider.getOrCreateInstance(
        maxCacheSize: _mobileTileCacheBytes,
      ),
    );
  }

  ({LatLng center, double zoom}) get _activeView =>
      _views[widget.activeDirectory] ?? _views['前湖北院']!;

  List<List<LatLng>> get _activeBoundaries =>
      _campusBoundaries[widget.activeDirectory] ?? const [_qianhuBoundary];

  bool get _isQianhu =>
      widget.activeDirectory == '前湖北院' || widget.activeDirectory == '前湖南院';

  List<List<LatLng>> get _maskSourceBoundaries =>
      _isQianhu ? const [_qianhuBoundary] : _activeBoundaries;

  double get _maskScale => switch (widget.activeDirectory) {
    '前湖北院' || '前湖南院' => 1.10,
    '青山湖校区' => 1.14,
    '东湖校区' => 1.22,
    _ => 1.10,
  };

  List<List<LatLng>> get _activeMaskBoundaries => _maskSourceBoundaries
      .map((boundary) => _expandBoundary(boundary, _maskScale))
      .toList(growable: false);

  LatLngBounds get _activeBounds => LatLngBounds.fromPoints(
    _activeMaskBoundaries.expand((points) => points).toList(growable: false),
  );

  CameraFit get _activeCameraFit => CameraFit.bounds(
    bounds: _activeBounds,
    padding: const EdgeInsets.all(18),
    maxZoom: 17.4,
  );

  @override
  void didUpdateWidget(covariant _CampusGeographicMap oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.activeDirectory != widget.activeDirectory) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _mapController.fitCamera(_activeCameraFit);
      });
    }
  }

  @override
  void dispose() {
    _mapController.dispose();
    super.dispose();
  }

  LatLng _point(CampusMapNode node) {
    final latitude = node.latitude;
    final longitude = node.longitude;
    if (latitude != null && longitude != null) {
      return LatLng(latitude, longitude);
    }
    final view = _views[node.directoryName] ?? _activeView;
    return LatLng(
      view.center.latitude + (0.5 - node.y) * 0.008,
      view.center.longitude + (node.x - 0.5) * 0.010,
    );
  }

  void _changeZoom(double delta) {
    final camera = _mapController.camera;
    _mapController.move(camera.center, (camera.zoom + delta).clamp(5, 19));
  }

  void _resetView() {
    _mapController.fitCamera(_activeCameraFit);
  }

  void _handlePositionChanged(MapCamera camera, bool _) {
    final previousBucket = (_currentZoom * 2).floor();
    final nextBucket = (camera.zoom * 2).floor();
    if (previousBucket == nextBucket) return;
    setState(() => _currentZoom = camera.zoom);
  }

  List<LatLng> _expandBoundary(List<LatLng> boundary, double scale) {
    final centerLatitude =
        boundary.fold<double>(0, (sum, point) => sum + point.latitude) /
        boundary.length;
    final centerLongitude =
        boundary.fold<double>(0, (sum, point) => sum + point.longitude) /
        boundary.length;
    return boundary
        .map(
          (point) => LatLng(
            centerLatitude + (point.latitude - centerLatitude) * scale,
            centerLongitude + (point.longitude - centerLongitude) * scale,
          ),
        )
        .toList(growable: false);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final l = AppLocalizations.of(context)!;
    final compactViewport = MediaQuery.sizeOf(context).width < 600;
    final routeIds =
        widget.route?.nodes.map((node) => node.id).toSet() ?? const <String>{};
    final visible = widget.graph.nodes
        .where(
          (node) =>
              node.coordinateVerified &&
              node.minimumZoom <= _currentZoom &&
              (_showPoints || routeIds.contains(node.id)) &&
              (node.directoryName == widget.activeDirectory ||
                  routeIds.contains(node.id)),
        )
        .toList(growable: false);
    final visibleIds = visible.map((node) => node.id).toSet();
    final polylines = <Polyline>[];
    for (final link in widget.graph.links) {
      if (!link.isRoutable ||
          !visibleIds.contains(link.from) ||
          !visibleIds.contains(link.to)) {
        continue;
      }
      final from = widget.graph.nodeById(link.from);
      final to = widget.graph.nodeById(link.to);
      if (from == null || to == null) continue;
      final highlighted =
          routeIds.contains(from.id) && routeIds.contains(to.id);
      polylines.add(
        Polyline(
          points: [_point(from), _point(to)],
          strokeWidth: highlighted ? 5 : 2.5,
          color: highlighted
              ? scheme.tertiary
              : scheme.outline.withValues(alpha: 0.65),
          borderStrokeWidth: highlighted ? 2 : 0,
          borderColor: scheme.surface,
          pattern: highlighted
              ? const StrokePattern.solid()
              : StrokePattern.dashed(segments: const [8, 6]),
        ),
      );
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border.all(color: scheme.outlineVariant),
          borderRadius: BorderRadius.circular(12),
        ),
        child: FlutterMap(
          mapController: _mapController,
          options: MapOptions(
            initialCenter: _activeView.center,
            initialZoom: _activeView.zoom,
            initialCameraFit: _activeCameraFit,
            minZoom: 13.5,
            maxZoom: 19,
            backgroundColor: scheme.surfaceContainerLow,
            onPositionChanged: _handlePositionChanged,
          ),
          children: [
            TileLayer(
              urlTemplate: _tileUrl,
              userAgentPackageName: 'cn.edu.ncu.goods4ncu',
              tileProvider: _tileProvider,
              maxNativeZoom: 19,
              tileBounds: _activeBounds,
              keepBuffer: 1,
              panBuffer: 1,
              retinaMode: false,
              tileDisplay: const TileDisplay.instantaneous(),
              evictErrorTileStrategy:
                  EvictErrorTileStrategy.notVisibleRespectMargin,
            ),
            PolygonLayer(
              key: ValueKey('campus-map-mask-${widget.activeDirectory}'),
              invertedFill: scheme.surface,
              polygons: [
                for (final boundary in _activeMaskBoundaries)
                  Polygon(points: boundary),
              ],
            ),
            PolygonLayer(
              key: ValueKey('campus-map-boundary-${widget.activeDirectory}'),
              polygons: [
                for (final boundary in _activeBoundaries)
                  Polygon(
                    points: boundary,
                    borderColor: const Color(0xFF2F80ED),
                    borderStrokeWidth: 2.2,
                    pattern: StrokePattern.dashed(segments: const [9, 6]),
                  ),
              ],
            ),
            if (polylines.isNotEmpty) PolylineLayer(polylines: polylines),
            MarkerLayer(
              rotate: true,
              markers: [
                for (final node in visible)
                  Marker(
                    key: ValueKey('campus-map-node-${node.id}'),
                    point: _point(node),
                    width:
                        !compactViewport ||
                            widget.origin?.id == node.id ||
                            widget.destination?.id == node.id ||
                            routeIds.contains(node.id)
                        ? 168
                        : 44,
                    height: 44,
                    alignment: const Alignment(-0.8, 0),
                    child: _CampusMapMarker(
                      node: node,
                      showLabel:
                          !compactViewport ||
                          widget.origin?.id == node.id ||
                          widget.destination?.id == node.id ||
                          routeIds.contains(node.id),
                      isOrigin: widget.origin?.id == node.id,
                      isDestination: widget.destination?.id == node.id,
                      isOnRoute: routeIds.contains(node.id),
                      onTap: () => widget.onSelect(node),
                    ),
                  ),
              ],
            ),
            const _MapAttribution(),
            Align(
              alignment: Alignment.topRight,
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _MapControlButton(
                      tooltip: l.campusMapZoomIn,
                      icon: Icons.add_rounded,
                      onPressed: () => _changeZoom(1),
                    ),
                    const SizedBox(height: 6),
                    _MapControlButton(
                      tooltip: l.campusMapZoomOut,
                      icon: Icons.remove_rounded,
                      onPressed: () => _changeZoom(-1),
                    ),
                    const SizedBox(height: 6),
                    _MapControlButton(
                      tooltip: l.campusMapTogglePoints,
                      icon: _showPoints
                          ? Icons.layers_rounded
                          : Icons.layers_clear_rounded,
                      onPressed: () {
                        setState(() => _showPoints = !_showPoints);
                      },
                    ),
                    const SizedBox(height: 6),
                    _MapControlButton(
                      tooltip: l.campusMapResetView,
                      icon: Icons.center_focus_strong_rounded,
                      onPressed: _resetView,
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MapAttribution extends StatelessWidget {
  const _MapAttribution();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SafeArea(
      child: Align(
        alignment: Alignment.bottomRight,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 250),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: scheme.surface.withValues(alpha: 0.88),
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(6),
              ),
            ),
            child: const Padding(
              padding: EdgeInsets.symmetric(horizontal: 6, vertical: 3),
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerRight,
                child: Text('© OpenStreetMap contributors · ODbL'),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _CampusMapMarker extends StatelessWidget {
  const _CampusMapMarker({
    required this.node,
    required this.showLabel,
    required this.isOrigin,
    required this.isDestination,
    required this.isOnRoute,
    required this.onTap,
  });

  final CampusMapNode node;
  final bool showLabel;
  final bool isOrigin;
  final bool isDestination;
  final bool isOnRoute;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = isDestination
        ? scheme.error
        : isOnRoute
        ? scheme.tertiary
        : scheme.primary;
    return Semantics(
      button: true,
      label: node.name,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                color: color,
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white, width: 2.5),
                boxShadow: const [
                  BoxShadow(
                    color: Color(0x33000000),
                    blurRadius: 5,
                    offset: Offset(0, 2),
                  ),
                ],
              ),
              child: Icon(
                isOrigin ? Icons.my_location_rounded : _iconForNode(node.kind),
                color: Colors.white,
                size: 19,
              ),
            ),
            if (showLabel) ...[
              const SizedBox(width: 4),
              Flexible(
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 7,
                    vertical: 5,
                  ),
                  decoration: BoxDecoration(
                    color: scheme.surface.withValues(alpha: 0.94),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: color.withValues(alpha: 0.5)),
                    boxShadow: const [
                      BoxShadow(
                        color: Color(0x26000000),
                        blurRadius: 4,
                        offset: Offset(0, 1),
                      ),
                    ],
                  ),
                  child: Text(
                    node.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: scheme.onSurface,
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _MapControlButton extends StatelessWidget {
  const _MapControlButton({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surface.withValues(alpha: 0.94),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: scheme.outlineVariant),
      ),
      child: IconButton(
        constraints: const BoxConstraints.tightFor(width: 40, height: 40),
        padding: EdgeInsets.zero,
        tooltip: tooltip,
        icon: Icon(icon, size: 20),
        onPressed: onPressed,
      ),
    );
  }
}

class _RouteSummary extends StatelessWidget {
  const _RouteSummary({required this.route, required this.classroom});

  final CampusLogicalRoute route;
  final String classroom;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final scheme = Theme.of(context).colorScheme;
    return Container(
      key: const ValueKey('campus-map-route-summary'),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.secondaryContainer.withValues(alpha: 0.34),
        border: Border.all(color: scheme.outlineVariant),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l.campusMapRouteTitle,
            style: const TextStyle(fontWeight: FontWeight.w900),
          ),
          const SizedBox(height: 7),
          Text(
            route.nodes.map((node) => node.name).join('  →  '),
            style: const TextStyle(height: 1.45),
          ),
          const SizedBox(height: 7),
          if (route.isVerified)
            Text(
              l.campusMapEstimatedDistance(route.estimatedMeters),
              style: TextStyle(color: scheme.onSurfaceVariant),
            )
          else
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  Icons.info_outline_rounded,
                  size: 17,
                  color: scheme.onSurfaceVariant,
                ),
                const SizedBox(width: 7),
                Expanded(
                  child: Text(
                    l.campusMapSchematicRouteWarning,
                    style: TextStyle(
                      color: scheme.onSurfaceVariant,
                      height: 1.35,
                    ),
                  ),
                ),
              ],
            ),
          if (classroom.isNotEmpty) ...[
            const SizedBox(height: 5),
            Text(
              l.campusMapClassroomArrival(classroom),
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
          ],
        ],
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({
    required this.title,
    required this.icon,
    required this.child,
  });

  final String title;
  final IconData icon;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Icon(icon, size: 20, color: scheme.primary),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                title,
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w900),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        DecoratedBox(
          decoration: BoxDecoration(
            border: Border(
              top: BorderSide(color: scheme.outlineVariant),
              bottom: BorderSide(color: scheme.outlineVariant),
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: child,
          ),
        ),
      ],
    );
  }
}

class _LoadError extends StatelessWidget {
  const _LoadError({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off_outlined, size: 42),
            const SizedBox(height: 10),
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 10),
            TextButton(onPressed: onRetry, child: Text(l.retry)),
          ],
        ),
      ),
    );
  }
}

IconData _iconForLocationKind(String kind) => switch (kind) {
  'campus' => Icons.school_outlined,
  'area' => Icons.domain_outlined,
  'facility' => Icons.apartment_outlined,
  'landmark' => Icons.place_outlined,
  _ => Icons.forum_outlined,
};

IconData _iconForNode(CampusMapNodeKind kind) => switch (kind) {
  CampusMapNodeKind.area => Icons.domain_outlined,
  CampusMapNodeKind.building => Icons.apartment_outlined,
  CampusMapNodeKind.landmark => Icons.place_outlined,
  CampusMapNodeKind.gate => Icons.door_front_door_outlined,
  CampusMapNodeKind.transit => Icons.directions_bus_outlined,
};
