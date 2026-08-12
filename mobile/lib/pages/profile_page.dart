import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../l10n/app_localizations.dart';
import 'package:go_router/go_router.dart';
import '../components/social_persona_card.dart';
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
        if (mounted) setState(() => _persona = persona);
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

  Future<void> _editPersona() async {
    final draft = await showSocialPersonaEditor(context, _persona);
    if (draft == null || !mounted) return;
    final l = AppLocalizations.of(context)!;
    try {
      final persona = await _apiService.upsertSocialPersona(
        representationMode: draft.representationMode,
        appearanceConfig: draft.appearanceConfig,
        selfDescriptions: draft.selfDescriptions,
        contactPosture: draft.contactPosture,
      );
      if (!mounted) return;
      setState(() => _persona = persona);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l.socialPersonaSaved)));
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('${l.error}: $error')));
    }
  }

  Future<void> _publishPersona() async {
    final l = AppLocalizations.of(context)!;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l.socialPersonaPublishConfirmTitle),
        content: Text(l.socialPersonaPublishConfirmBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(l.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(l.socialPersonaPublish),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      final persona = await _apiService.publishSocialPersona();
      if (!mounted) return;
      setState(() => _persona = persona);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l.socialPersonaPublishedToast)));
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('${l.error}: $error')));
    }
  }

  Future<void> _archivePersona() async {
    final l = AppLocalizations.of(context)!;
    try {
      final persona = await _apiService.archiveSocialPersona();
      if (!mounted) return;
      setState(() => _persona = persona);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l.socialPersonaArchivedToast)));
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('${l.error}: $error')));
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

  Future<void> _verifyCampusMembership(CampusMembership membership) async {
    final l = AppLocalizations.of(context)!;
    final shouldSend = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l.verifyCampusIdentity),
        content: Text(l.campusVerificationSendHint),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(l.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(l.sendVerificationCode),
          ),
        ],
      ),
    );
    if (shouldSend != true || !mounted) return;

    try {
      await _apiService.requestCampusVerification(membership.id);
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l.verificationCodeSent)));

      var enteredCode = '';
      final code = await showDialog<String>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text(l.verifyCampusIdentity),
          content: TextField(
            autofocus: true,
            keyboardType: TextInputType.number,
            maxLength: 6,
            onChanged: (value) => enteredCode = value,
            decoration: InputDecoration(labelText: l.verificationCode),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: Text(l.cancel),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, enteredCode.trim()),
              child: Text(l.confirmVerification),
            ),
          ],
        ),
      );
      if (code == null || code.isEmpty || !mounted) return;

      await _apiService.confirmCampusVerification(membership.id, code);
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l.campusVerificationSuccess)));
      await _loadProfile();
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('${l.error}: $error')));
    }
  }

  Future<void> _showCampusSwitcher() async {
    final l = AppLocalizations.of(context)!;
    final verified = _campusMemberships
        .where((membership) => membership.isVerified)
        .toList();
    if (verified.length < 2) return;

    final selected = await showModalBottomSheet<CampusMembership>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) {
        final locale = Localizations.localeOf(sheetContext);
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppTheme.sp20,
                  0,
                  AppTheme.sp20,
                  AppTheme.sp8,
                ),
                child: Text(
                  l.campusSwitchTitle,
                  style: Theme.of(sheetContext).textTheme.titleLarge,
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: AppTheme.sp20),
                child: Text(
                  l.campusSwitchDescription,
                  style: Theme.of(sheetContext).textTheme.bodyMedium,
                ),
              ),
              const SizedBox(height: AppTheme.sp8),
              for (final membership in verified)
                ListTile(
                  leading: const Icon(Icons.school_outlined),
                  title: Text(
                    locale.languageCode == 'zh'
                        ? membership.campusNameZh
                        : membership.campusNameEn,
                  ),
                  subtitle: membership.campusId == _activeCampusId
                      ? Text(l.campusActive)
                      : null,
                  trailing: membership.campusId == _activeCampusId
                      ? const Icon(Icons.check_circle, color: AppTheme.success)
                      : const Icon(Icons.chevron_right),
                  onTap: () => Navigator.pop(sheetContext, membership),
                ),
              const SizedBox(height: AppTheme.sp8),
            ],
          ),
        );
      },
    );
    if (selected == null || selected.campusId == _activeCampusId || !mounted) {
      return;
    }

    try {
      await _apiService.switchActiveCampus(selected.campusId);
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l.campusSwitchSuccess)));
      await _loadProfile();
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('${l.error}: $error')));
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
    final avatarUrl = _profile?['avatar_url'] as String?;
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
    final canSwitchCampus =
        _campusMemberships.where((membership) => membership.isVerified).length >
        1;
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
              avatarUrl: avatarUrl,
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
            if (campusMembership != null) ...[
              const SizedBox(height: AppTheme.sp12),
              _CampusMembershipBadge(
                membership: campusMembership,
                onVerify: campusMembership.status == 'pending'
                    ? () => _verifyCampusMembership(campusMembership!)
                    : null,
                onSwitch: campusMembership.isVerified && canSwitchCampus
                    ? _showCampusSwitcher
                    : null,
              ),
            ],
            if (campusMembership?.isVerified == true) ...[
              const SizedBox(height: AppTheme.sp20),
              _SocialPersonaSection(
                persona: _persona,
                onEdit: _editPersona,
                onPublish: _persona == null || _persona!.isPublished
                    ? null
                    : _publishPersona,
                onArchive: _persona?.isPublished == true
                    ? _archivePersona
                    : null,
              ),
            ],
            const SizedBox(height: AppTheme.sp32),

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

class _SocialPersonaSection extends StatelessWidget {
  const _SocialPersonaSection({
    required this.persona,
    required this.onEdit,
    this.onPublish,
    this.onArchive,
  });

  final SocialPersona? persona;
  final VoidCallback onEdit;
  final VoidCallback? onPublish;
  final VoidCallback? onArchive;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final current = persona;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                l.socialPersonaTitle,
                style: Theme.of(
                  context,
                ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
              ),
            ),
            IconButton(
              onPressed: onEdit,
              tooltip: current == null
                  ? l.socialPersonaCreate
                  : l.socialPersonaEdit,
              icon: Icon(
                current == null
                    ? Icons.add_circle_outline
                    : Icons.edit_outlined,
              ),
            ),
          ],
        ),
        const SizedBox(height: AppTheme.sp4),
        Text(
          l.socialPersonaDescription,
          style: Theme.of(
            context,
          ).textTheme.bodySmall?.copyWith(color: AppTheme.textSecondary),
        ),
        const SizedBox(height: AppTheme.sp12),
        if (current == null)
          OutlinedButton.icon(
            onPressed: onEdit,
            icon: const Icon(Icons.auto_awesome_outlined),
            label: Text(l.socialPersonaCreate),
          )
        else ...[
          SocialPersonaPreviewCard(persona: current),
          const SizedBox(height: AppTheme.sp8),
          Text(switch (current.status) {
            'published' => l.socialPersonaPublished,
            'archived' => l.socialPersonaArchived,
            _ => l.socialPersonaDraft,
          }, style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: AppTheme.sp8),
          Wrap(
            spacing: AppTheme.sp8,
            runSpacing: AppTheme.sp8,
            children: [
              if (onPublish != null)
                FilledButton.icon(
                  onPressed: onPublish,
                  icon: const Icon(Icons.public_outlined),
                  label: Text(l.socialPersonaPublish),
                ),
              OutlinedButton.icon(
                onPressed: onEdit,
                icon: const Icon(Icons.edit_outlined),
                label: Text(l.socialPersonaEdit),
              ),
              if (onArchive != null)
                TextButton.icon(
                  onPressed: onArchive,
                  icon: const Icon(Icons.archive_outlined),
                  label: Text(l.socialPersonaArchive),
                ),
            ],
          ),
        ],
      ],
    );
  }
}

class _CampusMembershipBadge extends StatelessWidget {
  const _CampusMembershipBadge({
    required this.membership,
    this.onVerify,
    this.onSwitch,
  });

  final CampusMembership membership;
  final VoidCallback? onVerify;
  final VoidCallback? onSwitch;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final locale = Localizations.localeOf(context);
    final campusName = locale.languageCode == 'zh'
        ? membership.campusNameZh
        : membership.campusNameEn;
    final (label, color, icon) = switch (membership.status) {
      'verified' => (
        l.campusMembershipVerified,
        AppTheme.success,
        Icons.verified_rounded,
      ),
      'suspended' => (
        l.campusMembershipSuspended,
        AppTheme.error,
        Icons.block_rounded,
      ),
      'revoked' => (
        l.campusMembershipRevoked,
        AppTheme.textSecondary,
        Icons.cancel_rounded,
      ),
      _ => (
        l.campusMembershipPending,
        AppTheme.warning,
        Icons.schedule_rounded,
      ),
    };

    final badge = Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppTheme.sp12,
        vertical: AppTheme.sp8,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.28)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.school_rounded, size: 17, color: color),
          const SizedBox(width: AppTheme.sp8),
          Text(
            campusName,
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
          ),
          const SizedBox(width: AppTheme.sp8),
          Container(width: 1, height: 14, color: color.withValues(alpha: 0.3)),
          const SizedBox(width: AppTheme.sp8),
          Icon(icon, size: 15, color: color),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              color: color,
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
          if (onVerify != null || onSwitch != null) ...[
            const SizedBox(width: AppTheme.sp8),
            Icon(Icons.chevron_right_rounded, size: 17, color: color),
          ],
        ],
      ),
    );

    final onTap = onVerify ?? onSwitch;
    return Semantics(
      label: '$campusName, $label',
      button: onTap != null,
      child: onTap == null
          ? badge
          : Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: onTap,
                borderRadius: BorderRadius.circular(999),
                child: badge,
              ),
            ),
    );
  }
}

class _ProfileAvatar extends StatelessWidget {
  final String username;
  final String? avatarUrl;
  final String tooltip;
  final VoidCallback? onTap;

  const _ProfileAvatar({
    required this.username,
    required this.avatarUrl,
    required this.tooltip,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final hasAvatar = avatarUrl != null && avatarUrl!.isNotEmpty;
    final avatar = CircleAvatar(
      radius: 52,
      backgroundColor: AppTheme.primary.withValues(alpha: 0.15),
      backgroundImage: hasAvatar ? NetworkImage(avatarUrl!) : null,
      child: hasAvatar
          ? null
          : Text(
              username.isNotEmpty ? username[0].toUpperCase() : '?',
              style: const TextStyle(
                fontSize: 40,
                fontWeight: FontWeight.bold,
                color: AppTheme.primary,
              ),
            ),
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
                DecoratedBox(
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: AppTheme.primary.withValues(alpha: 0.28),
                      width: 2,
                    ),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(3),
                    child: avatar,
                  ),
                ),
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
