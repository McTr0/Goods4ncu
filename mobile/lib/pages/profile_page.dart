import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../l10n/app_localizations.dart';
import 'package:go_router/go_router.dart';
import '../components/user_avatar.dart';
import '../models/models.dart';
import '../services/api_service.dart';
import '../services/admin_role_cache.dart';
import '../services/ws_service.dart';
import '../services/token_storage.dart';
import '../services/user_service.dart';
import '../theme/app_theme.dart';
import '../theme/responsive.dart';

class ProfilePage extends StatefulWidget {
  final ApiService? apiService;

  const ProfilePage({super.key, this.apiService});

  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage> {
  late final ApiService _apiService;
  Map<String, dynamic>? _profile;
  SocialPersona? _persona;
  List<CampusMembership> _campusMemberships = const [];
  String? _activeCampusId;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _apiService = widget.apiService ?? context.read<ApiService>();
    _loadProfile();
  }

  Future<void> _loadProfile() async {
    setState(() {
      _loading = true;
      _error = null;
      _persona = null;
    });
    try {
      final results = await Future.wait<dynamic>([
        _apiService.getUserProfile(),
        _apiService.getCampusMembershipState(),
      ]);
      if (mounted) {
        setState(() {
          _profile = results[0] as Map<String, dynamic>;
          final campusState = results[1] as CampusMembershipState;
          _campusMemberships = campusState.items;
          _activeCampusId = campusState.activeCampusId;
          _loading = false;
        });
      }
      // The role layer is optional: a transient persona failure must not hide
      // the ordinary profile, campus membership, or contact controls.
      try {
        final persona = await _apiService.getSocialPersona();
        if (mounted) {
          setState(() {
            _persona = persona;
          });
        }
      } catch (_) {}
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error =
              AppLocalizations.of(context)?.profileLoadFailed ??
              'Failed to load profile';
        });
      }
    }
  }

  Future<void> _logout() async {
    final l = AppLocalizations.of(context)!;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l.logout),
        content: Text(l.logoutConfirm),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(l.cancel),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(backgroundColor: AppTheme.error),
            child: Text(l.logout),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      AdminRoleCache.instance.invalidate();
      await TokenStorage.instance.clearTokens();
      // Disconnect global WebSocket singleton on logout.
      await WsService.instance.disconnect();
      if (mounted) context.go('/login');
    }
  }

  String _formatDate(String? createdAt) {
    if (createdAt == null || createdAt.isEmpty) return '';
    try {
      return createdAt.substring(0, 10);
    } catch (_) {
      return '';
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(title: Text(l.profile)),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    final l = AppLocalizations.of(context)!;
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_error != null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.error_outline, size: 48, color: AppTheme.error),
            const SizedBox(height: 16),
            Text(_error!, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            ElevatedButton(onPressed: _loadProfile, child: Text(l.retry)),
          ],
        ),
      );
    }

    final username = _profile?['username'] ?? l.profile;
    final createdAt = _profile?['created_at'];
    final isAdmin = _profile?['role'] == 'admin';
    final userId = _profile?['user_id']?.toString();
    CampusMembership? campusMembership;
    if (_campusMemberships.isNotEmpty) {
      campusMembership = _campusMemberships.first;
      for (final membership in _campusMemberships) {
        if (membership.campusId == _activeCampusId) {
          campusMembership = membership;
          break;
        }
      }
    }
    final canAccessAdmin =
        isAdmin ||
        (campusMembership?.isVerified == true &&
            const {'operator', 'admin'}.contains(campusMembership?.role));

    return ResponsiveContent(
      maxWidth: 760,
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(AppTheme.sp16),
        child: Column(
          children: [
            const SizedBox(height: AppTheme.sp16),
            _ProfileAvatar(
              username: username,
              persona: _persona,
              tooltip: l.viewPublicProfile,
              onTap: userId == null || userId.isEmpty
                  ? null
                  : () => context.push('/users/$userId'),
            ),
            const SizedBox(height: AppTheme.sp16),
            Text(
              username,
              style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
            ),
            if (createdAt != null && createdAt.toString().isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                l.memberSince(_formatDate(createdAt.toString())),
                style: const TextStyle(
                  color: AppTheme.textSecondary,
                  fontSize: 13,
                ),
              ),
            ],
            const SizedBox(height: AppTheme.sp32),

            _MenuCard(
              icon: Icons.article_outlined,
              title: l.myPosts,
              subtitle: l.myPostsMenu,
              onTap: () => context.push('/my-posts'),
            ),
            _MenuCard(
              icon: Icons.inventory_2_outlined,
              title: l.myListings,
              subtitle: l.myListingsMenu,
              onTap: () => context.push('/my-listings'),
            ),
            _MenuCard(
              icon: Icons.favorite_border,
              title: l.myFavorites,
              subtitle: l.myFavoritesSubtitle,
              onTap: () => context.push('/watchlist'),
            ),
            _MenuCard(
              icon: Icons.notifications_none,
              title: l.notificationsCenter,
              subtitle: l.notificationsCenterSubtitle,
              onTap: () => context.push('/notifications'),
            ),
            _MenuCard(
              icon: Icons.policy_outlined,
              title: l.moderationCenter,
              subtitle: l.moderationCenterSubtitle,
              onTap: () => context.push('/moderation'),
            ),
            if (canAccessAdmin)
              _MenuCard(
                icon: Icons.admin_panel_settings_outlined,
                title: l.adminConsole,
                subtitle: l.adminConsoleSubtitle,
                onTap: () => context.push('/admin'),
              ),
            _MenuCard(
              icon: Icons.settings_outlined,
              title: l.settings,
              subtitle: l.settingsSubtitle,
              onTap: () => context.push('/settings'),
            ),
            const SizedBox(height: AppTheme.sp16),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: _logout,
                icon: const Icon(Icons.logout, color: AppTheme.error),
                label: Text(l.logout),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppTheme.error,
                  side: const BorderSide(color: AppTheme.error),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
              ),
            ),
            const SizedBox(height: AppTheme.sp32),
          ],
        ),
      ),
    );
  }
}

class _ProfileAvatar extends StatelessWidget {
  final String username;
  final SocialPersona? persona;
  final String tooltip;
  final VoidCallback? onTap;

  const _ProfileAvatar({
    required this.username,
    this.persona,
    required this.tooltip,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final avatar = UserAvatar(
      name: username,
      persona: persona,
      size: 104,
      semanticLabel: username,
    );

    if (onTap == null) {
      return avatar;
    }

    return Semantics(
      label: tooltip,
      button: true,
      child: Tooltip(
        message: tooltip,
        child: Material(
          color: Colors.transparent,
          shape: const CircleBorder(),
          child: InkResponse(
            onTap: onTap,
            customBorder: const CircleBorder(),
            radius: 64,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                avatar,
                Positioned(
                  right: 2,
                  bottom: 2,
                  child: Container(
                    width: 30,
                    height: 30,
                    decoration: BoxDecoration(
                      color: AppTheme.primary,
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: Theme.of(context).scaffoldBackgroundColor,
                        width: 3,
                      ),
                    ),
                    child: const Icon(
                      Icons.arrow_outward_rounded,
                      size: 16,
                      color: Colors.white,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _MenuCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _MenuCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(
          horizontal: AppTheme.sp16,
          vertical: AppTheme.sp8,
        ),
        leading: Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: AppTheme.primary.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(icon, color: AppTheme.primary),
        ),
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Text(
          subtitle,
          style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary),
        ),
        trailing: const Icon(
          Icons.chevron_right,
          color: AppTheme.textSecondary,
        ),
        onTap: onTap,
      ),
    );
  }
}
