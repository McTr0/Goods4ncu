import 'package:flutter/material.dart';
import '../brand/app_brand.dart';
import '../components/xiaochang_avatar.dart';
import '../components/contact_conversation_sheet.dart';
import '../l10n/app_localizations.dart';
import 'package:go_router/go_router.dart';
import '../pages/home_page.dart';
import '../pages/listing_detail_page.dart';
import '../pages/my_listings_page.dart';
import '../pages/my_posts_page.dart';
import '../pages/profile_page.dart';
import '../pages/chat_page.dart';
import '../pages/companion_debug_console.dart';
import '../pages/companion_timeline_page.dart';
import '../companion/companion_config.dart';
import '../pages/conversation_list_page.dart';
import '../pages/user_chat_page.dart';
import '../pages/user_home_page.dart';
import '../pages/login_page.dart';
import '../pages/my_orders_page.dart';
import '../pages/order_detail_page.dart';
import '../pages/admin_page.dart';
import '../pages/settings_page.dart';
import '../pages/watchlist_page.dart';
import '../pages/notifications_page.dart';
import '../pages/moderation_cases_page.dart';
import '../models/models.dart';
import '../services/base_service.dart';
import '../services/chat_service.dart';
import '../services/user_service.dart';
import '../services/admin_role_cache.dart';
import '../pages/trust_page.dart';
import '../pages/post_detail_page.dart';
import '../pages/create_post_page.dart';
import '../pages/live2d_preview_page.dart';
import '../services/token_storage.dart';
import '../services/ws_service.dart';
import '../theme/app_theme.dart';
import '../theme/responsive.dart';
import 'package:provider/provider.dart';
import 'publish_navigation.dart';

final GlobalKey<NavigatorState> _rootNavigatorKey = BaseService.navigatorKey;

Map<String, dynamic>? assistantPageContext(Uri uri) {
  final listingId = uri.queryParameters['listingId'];
  final postId = uri.queryParameters['postId'];
  final focusedId = listingId ?? postId;
  if (focusedId == null) return null;
  final context = {
    'page': 'post_detail',
    'listingId': listingId,
    'postId': focusedId,
  };
  if (listingId == null) context.remove('listingId');
  return context;
}

Future<bool> getLoginStatus() async {
  final token = await TokenStorage.instance.getAccessToken();
  return token != null && token.isNotEmpty;
}

Future<bool> _hasAdminAccess(UserService userService) async {
  try {
    final cached = await AdminRoleCache.instance.getCachedForCurrentToken();
    if (cached != null) {
      return cached;
    }

    final capabilities = await userService.getAdminCapabilities();
    final canRead = capabilities['can_read'] == true;
    await AdminRoleCache.instance.saveForCurrentToken(canRead);
    return canRead;
  } catch (_) {
    AdminRoleCache.instance.invalidate();
    return false;
  }
}

final GoRouter appRouter = GoRouter(
  navigatorKey: _rootNavigatorKey,
  initialLocation: '/',
  redirect: (context, state) async {
    try {
      final userService = context.read<UserService>();
      final loggedIn = await getLoginStatus();
      final onAuthRoute = state.matchedLocation == '/login';
      if (!loggedIn && !onAuthRoute) {
        return '/login';
      }
      if (loggedIn && onAuthRoute) {
        WsService.instance.connect();
        return '/';
      }
      if (loggedIn) {
        WsService.instance.connect();
      }
      if (state.matchedLocation == '/admin') {
        final hasAdminAccess = await _hasAdminAccess(userService);
        if (!hasAdminAccess) return '/';
      }
    } catch (e) {
      if (state.matchedLocation != '/login') {
        return '/login';
      }
    }
    return null;
  },
  routes: [
    GoRoute(path: '/login', builder: (context, state) => const LoginPage()),
    if (kCompanionEnabled) ...[
      GoRoute(
        path: '/companion/debug',
        builder: (context, state) => const CompanionDebugConsole(),
      ),
      GoRoute(
        path: '/companion/timeline',
        builder: (context, state) => const CompanionTimelinePage(),
      ),
    ],
    ShellRoute(
      builder: (context, state, child) => _ShellScaffold(child: child),
      routes: [
        GoRoute(path: '/trust', builder: (context, state) => const TrustPage()),
        GoRoute(
          path: '/settings',
          builder: (context, state) => const SettingsPage(),
        ),
        GoRoute(path: '/admin', builder: (context, state) => const AdminPage()),
        GoRoute(
          path: '/watchlist',
          builder: (context, state) => const WatchlistPage(),
        ),
        GoRoute(
          path: '/notifications',
          builder: (context, state) => const NotificationsPage(),
        ),
        GoRoute(
          path: '/moderation',
          builder: (context, state) => const ModerationCasesPage(),
        ),
        GoRoute(
          path: '/listing/:id/discussion',
          builder: (context, state) {
            final id = state.pathParameters['id']!;
            return PostDetailPage(listingId: id);
          },
        ),
        GoRoute(
          path: '/listing/:id',
          builder: (context, state) {
            final id = state.pathParameters['id']!;
            return ListingDetailPage(listingId: id);
          },
        ),
        GoRoute(
          path: '/posts/:id',
          builder: (context, state) {
            final id = state.pathParameters['id']!;
            return PostDetailPage(postId: id);
          },
        ),
        GoRoute(
          path: '/live2d-preview',
          builder: (context, state) => const Live2DPreviewPage(),
        ),
        GoRoute(
          path: '/orders/:id',
          builder: (context, state) {
            final id = state.pathParameters['id']!;
            return OrderDetailPage(orderId: id);
          },
        ),
        GoRoute(
          path: '/users/:id',
          pageBuilder: (context, state) {
            final id = state.pathParameters['id']!;
            return NoTransitionPage(
              key: state.pageKey,
              child: UserHomePage(userId: id),
            );
          },
        ),
        GoRoute(
          path: '/chat/:conversationId',
          redirect: (context, state) {
            final id = state.pathParameters['conversationId']!;
            return Uri(pathSegments: ['user-chat', id]).toString();
          },
        ),
        GoRoute(
          name: 'contact-user',
          path: '/contact/:recipientId',
          pageBuilder: (context, state) {
            final recipientId = state.pathParameters['recipientId']!;
            final extra = state.extra as Map<String, dynamic>?;
            return NoTransitionPage<Conversation>(
              key: state.pageKey,
              restorationId: state.pageKey.value,
              child: ContactConversationPage(
                chatService:
                    extra?['chatService'] as ChatService? ??
                    context.read<ChatService>(),
                recipientId: recipientId,
                initialMode: ConversationMode.parse(
                  state.uri.queryParameters['mode'],
                ),
                listingId: state.uri.queryParameters['listingId'],
                listingTitle: state.uri.queryParameters['listingTitle'],
                recipientName: state.uri.queryParameters['recipientName'],
              ),
            );
          },
        ),
        GoRoute(
          name: 'user-chat',
          path: '/user-chat/:conversationId',
          pageBuilder: (context, state) {
            final id = state.pathParameters['conversationId']!;
            final extra = state.extra as Map<String, dynamic>?;
            final otherUserId = extra?['otherUserId'] as String? ?? '';
            final otherUsername = extra?['otherUsername'] as String? ?? '';
            return NoTransitionPage<void>(
              key: state.pageKey,
              restorationId: state.pageKey.value,
              child: UserChatPage(
                conversationId: id,
                otherUserId: otherUserId,
                otherUsername: otherUsername,
              ),
            );
          },
        ),
        GoRoute(
          name: 'chat-thread',
          path: '/chat/threads/:peerUserId',
          pageBuilder: (context, state) {
            final id = state.pathParameters['peerUserId']!;
            final extra = state.extra as Map<String, dynamic>?;
            return NoTransitionPage<void>(
              key: state.pageKey,
              restorationId: state.pageKey.value,
              child: ChatThreadPage(
                peerUserId: id,
                initialThread: extra?['thread'] as ChatThread?,
              ),
            );
          },
        ),
        GoRoute(
          name: 'chat-space',
          path: '/spaces/:spaceId',
          pageBuilder: (context, state) {
            final id = state.pathParameters['spaceId']!;
            final extra = state.extra as Map<String, dynamic>?;
            return NoTransitionPage<void>(
              key: state.pageKey,
              restorationId: state.pageKey.value,
              child: SpaceChatPage(spaceId: id, initialSpace: extra),
            );
          },
        ),
        GoRoute(
          path: '/spaces/:spaceId/posts',
          pageBuilder: (context, state) {
            final spaceId = state.pathParameters['spaceId']!;
            final name = state.uri.queryParameters['name'] ?? '';
            return NoTransitionPage(
              key: state.pageKey,
              child: SpacePostsScreen(spaceId: spaceId, spaceName: name),
            );
          },
        ),
        GoRoute(
          path: '/',
          pageBuilder: (context, state) =>
              const NoTransitionPage(child: HomePage()),
        ),
        GoRoute(
          path: '/conversations',
          pageBuilder: (context, state) =>
              const NoTransitionPage(child: ConversationListPage()),
        ),
        GoRoute(
          path: PublishNavigation.hub,
          pageBuilder: (context, state) => NoTransitionPage(
            key: state.pageKey,
            child: CreatePostPage(
              initialCategory:
                  state.uri.queryParameters['category'] ?? 'discussion',
            ),
          ),
        ),
        GoRoute(
          path: PublishNavigation.discussion,
          redirect: (context, state) => PublishNavigation.hub,
        ),
        GoRoute(
          path: PublishNavigation.listingPath,
          redirect: (context, state) {
            final direction = state.uri.queryParameters['direction'] == 'wanted'
                ? 'wanted'
                : 'offer';
            return Uri(
              path: PublishNavigation.hub,
              queryParameters: {'category': direction},
            ).toString();
          },
        ),
        GoRoute(
          path: '/create',
          redirect: (context, state) =>
              PublishNavigation.redirectLegacy(state.uri),
        ),
        GoRoute(
          path: '/create/post',
          redirect: (context, state) =>
              PublishNavigation.redirectLegacy(state.uri),
        ),
        GoRoute(
          path: '/create/listing',
          redirect: (context, state) =>
              PublishNavigation.redirectLegacy(state.uri),
        ),
        GoRoute(
          path: '/profile',
          pageBuilder: (context, state) =>
              const NoTransitionPage(child: ProfilePage()),
        ),
        GoRoute(
          path: '/my-posts',
          builder: (context, state) => const MyPostsPage(),
        ),
        GoRoute(
          path: '/my-listings',
          pageBuilder: (context, state) =>
              const NoTransitionPage(child: MyListingsPage()),
        ),
        GoRoute(
          path: '/orders',
          pageBuilder: (context, state) =>
              const NoTransitionPage(child: MyOrdersPage()),
        ),
        GoRoute(
          path: '/chat',
          pageBuilder: (context, state) {
            final prompt = state.uri.queryParameters['prompt'];
            final pageContext = assistantPageContext(state.uri);
            return NoTransitionPage(
              key: state.pageKey,
              child: ChatPage(initialPrompt: prompt, pageContext: pageContext),
            );
          },
        ),
      ],
    ),
  ],
);

class _ShellScaffold extends StatefulWidget {
  final Widget child;
  const _ShellScaffold({required this.child});

  @override
  State<_ShellScaffold> createState() => _ShellScaffoldState();
}

class _ShellScaffoldState extends State<_ShellScaffold> {
  int _currentIndex = 0;

  static const _routes = [
    '/',
    '/conversations',
    '/chat',
    PublishNavigation.hub,
    '/profile',
  ];

  int _tabIndexForLocation(String location) {
    if (location == '/') return 0;
    if (location == '/conversations' ||
        location.startsWith('/user-chat/') ||
        location.startsWith('/chat/threads/') ||
        location.startsWith('/spaces/')) {
      return 1;
    }
    if (location == '/chat') return 2;
    if (location == PublishNavigation.hub ||
        location.startsWith('${PublishNavigation.hub}/')) {
      return 3;
    }
    if (location == '/profile' ||
        location == '/my-listings' ||
        location == '/orders' ||
        location.startsWith('/orders/') ||
        location == '/settings' ||
        location == '/watchlist' ||
        location == '/notifications' ||
        location == '/moderation' ||
        location == '/admin' ||
        location == '/trust') {
      return 4;
    }
    if (location.startsWith('/listing/') ||
        location.startsWith('/posts/') ||
        location.startsWith('/users/')) {
      return 0;
    }
    return _currentIndex;
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    if (l == null) {
      return const SizedBox.shrink();
    }
    final location = GoRouterState.of(context).matchedLocation;
    final nextIndex = _tabIndexForLocation(location);
    if (_currentIndex != nextIndex) {
      _currentIndex = nextIndex;
    }

    void selectDestination(int index) {
      setState(() => _currentIndex = index);
      context.go(_routes[index]);
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final isDesktop = constraints.maxWidth >= AppBreakpoints.desktop;
        if (isDesktop) {
          final extended = constraints.maxWidth >= AppBreakpoints.wideDesktop;
          return Scaffold(
            backgroundColor: AppTheme.surface,
            body: Row(
              children: [
                _DesktopNavigation(
                  selectedIndex: _currentIndex,
                  extended: extended,
                  labels: [
                    l.homeTab,
                    l.messagesTab,
                    l.assistantName,
                    l.publishTab,
                    l.profileTab,
                  ],
                  onDestinationSelected: selectDestination,
                ),
                Expanded(
                  child: ColoredBox(
                    color: AppTheme.surface,
                    child: ResponsiveContent(
                      child: SizedBox.expand(child: widget.child),
                    ),
                  ),
                ),
              ],
            ),
          );
        }

        return Scaffold(
          body: widget.child,
          bottomNavigationBar: DecoratedBox(
            decoration: BoxDecoration(
              color: Theme.of(context).navigationBarTheme.backgroundColor,
              border: Border(
                top: BorderSide(
                  color: Theme.of(context).dividerColor.withValues(alpha: 0.7),
                ),
              ),
              boxShadow: AppTheme.cardShadow,
            ),
            child: NavigationBar(
              selectedIndex: _currentIndex,
              onDestinationSelected: selectDestination,
              destinations: [
                NavigationDestination(
                  icon: const Icon(Icons.home_outlined),
                  selectedIcon: const Icon(Icons.home_rounded),
                  label: l.homeTab,
                ),
                NavigationDestination(
                  icon: const Icon(Icons.chat_bubble_outline),
                  selectedIcon: const Icon(Icons.chat_bubble_rounded),
                  label: l.messagesTab,
                ),
                NavigationDestination(
                  icon: const _XiaochangNavigationIcon(),
                  selectedIcon: const _XiaochangNavigationIcon(selected: true),
                  label: l.assistantName,
                ),
                NavigationDestination(
                  icon: const Icon(Icons.add_circle_outline),
                  selectedIcon: const Icon(Icons.add_circle_rounded),
                  label: l.publishTab,
                ),
                NavigationDestination(
                  icon: const Icon(Icons.person_outline),
                  selectedIcon: const Icon(Icons.person_rounded),
                  label: l.profileTab,
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _DesktopNavigation extends StatelessWidget {
  final int selectedIndex;
  final bool extended;
  final List<String> labels;
  final ValueChanged<int> onDestinationSelected;

  const _DesktopNavigation({
    required this.selectedIndex,
    required this.extended,
    required this.labels,
    required this.onDestinationSelected,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: extended ? 216 : 88,
      decoration: BoxDecoration(
        color: theme.cardTheme.color,
        border: Border(
          right: BorderSide(color: theme.dividerColor.withValues(alpha: 0.75)),
        ),
        boxShadow: const [
          BoxShadow(
            color: Color(0x0A0F766E),
            blurRadius: 24,
            offset: Offset(8, 0),
          ),
        ],
      ),
      child: SafeArea(
        child: NavigationRail(
          extended: extended,
          minWidth: 88,
          minExtendedWidth: 216,
          backgroundColor: Colors.transparent,
          selectedIndex: selectedIndex,
          groupAlignment: extended ? -0.5 : -0.42,
          useIndicator: true,
          indicatorColor: AppTheme.accentSoft,
          selectedIconTheme: const IconThemeData(color: AppTheme.primaryDark),
          unselectedIconTheme: const IconThemeData(
            color: AppTheme.textSecondary,
          ),
          selectedLabelTextStyle: const TextStyle(
            color: AppTheme.primaryDark,
            fontWeight: FontWeight.w900,
          ),
          unselectedLabelTextStyle: const TextStyle(
            color: AppTheme.textSecondary,
            fontWeight: FontWeight.w700,
          ),
          onDestinationSelected: onDestinationSelected,
          leading: Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
            child: _DesktopBrand(extended: extended),
          ),
          destinations: [
            NavigationRailDestination(
              icon: const Icon(Icons.home_outlined),
              selectedIcon: const Icon(Icons.home_rounded),
              label: Text(labels[0]),
            ),
            NavigationRailDestination(
              icon: const Icon(Icons.chat_bubble_outline),
              selectedIcon: const Icon(Icons.chat_bubble_rounded),
              label: Text(labels[1]),
            ),
            NavigationRailDestination(
              icon: const _XiaochangNavigationIcon(desktop: true),
              selectedIcon: const _XiaochangNavigationIcon(
                selected: true,
                desktop: true,
              ),
              label: Text(labels[2]),
            ),
            NavigationRailDestination(
              icon: const Icon(Icons.add_circle_outline),
              selectedIcon: const Icon(Icons.add_circle_rounded),
              label: Text(labels[3]),
            ),
            NavigationRailDestination(
              icon: const Icon(Icons.person_outline),
              selectedIcon: const Icon(Icons.person_rounded),
              label: Text(labels[4]),
            ),
          ],
        ),
      ),
    );
  }
}

class _XiaochangNavigationIcon extends StatelessWidget {
  const _XiaochangNavigationIcon({this.selected = false, this.desktop = false});

  final bool selected;
  final bool desktop;

  @override
  Widget build(BuildContext context) {
    final size = desktop ? 36.0 : 42.0;
    final avatar = Container(
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(15),
        border: Border.all(
          color: selected
              ? Theme.of(context).colorScheme.primary
              : Theme.of(context).colorScheme.outlineVariant,
          width: selected ? 2 : 1,
        ),
        boxShadow: selected ? AppTheme.cardShadow : null,
      ),
      child: XiaochangAvatar(
        size: size,
        borderRadius: BorderRadius.circular(12),
      ),
    );
    return desktop
        ? avatar
        : Transform.translate(offset: const Offset(0, -7), child: avatar);
  }
}

class _DesktopBrand extends StatelessWidget {
  final bool extended;

  const _DesktopBrand({required this.extended});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final mark = Container(
      width: extended ? 52 : 56,
      height: extended ? 52 : 56,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(AppTheme.radiusXl),
        border: Border.all(
          color: theme.colorScheme.primary.withValues(alpha: 0.22),
        ),
        boxShadow: [
          BoxShadow(
            color: theme.colorScheme.primary.withValues(alpha: 0.12),
            blurRadius: 16,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(2),
        child: Image.asset(AppBrand.logoAsset, fit: BoxFit.contain),
      ),
    );

    if (!extended) return mark;
    return Row(
      children: [
        mark,
        const SizedBox(width: AppTheme.sp12),
        const Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                AppBrand.englishName,
                style: TextStyle(
                  color: AppTheme.textPrimary,
                  fontSize: 17,
                  fontWeight: FontWeight.w900,
                ),
              ),
              Text(
                AppBrand.subtitle,
                style: TextStyle(
                  color: AppTheme.textSecondary,
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
