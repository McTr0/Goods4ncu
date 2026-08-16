import 'package:flutter/material.dart';
import '../brand/app_brand.dart';
import '../l10n/app_localizations.dart';
import 'package:go_router/go_router.dart';
import '../pages/home_page.dart';
import '../pages/listing_detail_page.dart';
import '../pages/create_listing_page.dart';
import '../pages/intent_page.dart';
import '../pages/my_listings_page.dart';
import '../pages/profile_page.dart';
import '../pages/chat_page.dart';
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
import '../services/user_service.dart';
import '../services/admin_role_cache.dart';
import '../pages/trust_page.dart';
import '../pages/post_detail_page.dart';
import '../pages/create_post_page.dart';
import '../services/token_storage.dart';
import '../services/ws_service.dart';
import '../theme/app_theme.dart';
import '../theme/responsive.dart';
import 'package:provider/provider.dart';

final GlobalKey<NavigatorState> _rootNavigatorKey = BaseService.navigatorKey;

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

    // Detail routes (Hide bottom bar)
    GoRoute(
      path: '/listing/:id',
      builder: (context, state) {
        final id = state.pathParameters['id']!;
        return ListingDetailPage(listingId: id);
      },
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
      builder: (context, state) {
        final id = state.pathParameters['id']!;
        return UserHomePage(userId: id);
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
      name: 'user-chat',
      path: '/user-chat/:conversationId',
      pageBuilder: (context, state) {
        final id = state.pathParameters['conversationId']!;
        final extra = state.extra as Map<String, dynamic>?;
        final otherUserId = extra?['otherUserId'] as String? ?? '';
        final otherUsername = extra?['otherUsername'] as String? ?? '';
        return MaterialPage<void>(
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
        return MaterialPage<void>(
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
        return MaterialPage<void>(
          key: state.pageKey,
          restorationId: state.pageKey.value,
          child: SpaceChatPage(spaceId: id, initialSpace: extra),
        );
      },
    ),

    // Tab routes (Show bottom bar)
    ShellRoute(
      builder: (context, state, child) => _ShellScaffold(child: child),
      routes: [
        GoRoute(
          path: '/listing/:id/discussion',
          builder: (context, state) {
            final id = state.pathParameters['id']!;
            return PostDetailPage(listingId: id);
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
          // The bottom-nav "publish" tab opens the intent composer, not the
          // listing form. The form is the threshold most demand on a campus
          // never gets over; it stays reachable at /create/listing for anyone
          // who wants to fill one in.
          path: '/create',
          pageBuilder: (context, state) {
            final requestedKind = state.uri.queryParameters['kind'];
            final initialKind = requestedKind == 'wanted'
                ? IntentKind.goodsSeek
                : IntentKind.goodsOffer;
            return NoTransitionPage(
              key: state.pageKey,
              child: IntentPage(initialKind: initialKind),
            );
          },
        ),
        GoRoute(
          path: '/create/listing',
          pageBuilder: (context, state) =>
              const NoTransitionPage(child: CreateListingPage()),
        ),
        GoRoute(
          path: '/create/post',
          pageBuilder: (context, state) =>
              const NoTransitionPage(child: CreatePostPage()),
        ),
        GoRoute(
          path: '/profile',
          pageBuilder: (context, state) =>
              const NoTransitionPage(child: ProfilePage()),
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
            return NoTransitionPage(
              key: state.pageKey,
              child: ChatPage(initialPrompt: prompt),
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

  static const _routes = ['/', '/conversations', '/create', '/profile'];

  int _tabIndexForLocation(String location) {
    switch (location) {
      case '/':
        return 0;
      case '/conversations':
        return 1;
      case '/create':
      case '/create/listing':
      case '/create/post':
        return 2;
      // Xiaobang is a tool entered from home, not a human conversation in the
      // inbox. Keep the home destination selected while the assistant is open.
      case '/chat':
        return 0;
      case '/profile':
      case '/my-listings':
      case '/orders':
        return 3;
      default:
        return _currentIndex;
    }
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
              icon: const Icon(Icons.add_circle_outline),
              selectedIcon: const Icon(Icons.add_circle_rounded),
              label: Text(labels[2]),
            ),
            NavigationRailDestination(
              icon: const Icon(Icons.person_outline),
              selectedIcon: const Icon(Icons.person_rounded),
              label: Text(labels[3]),
            ),
          ],
        ),
      ),
    );
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
