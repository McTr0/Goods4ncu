import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/api_service.dart';
import '../services/admin_impersonation_service.dart';
import '../l10n/app_localizations.dart';
import '../theme/app_theme.dart';
import 'admin/admin_listings_tab.dart';
import 'admin/admin_orders_tab.dart';
import 'admin/admin_stats_tab.dart';
import 'admin/admin_users_tab.dart';
import 'admin/admin_moderation_tab.dart';

export 'admin/admin_listings_tab.dart';
export 'admin/admin_orders_tab.dart';
export 'admin/admin_stats_tab.dart';
export 'admin/admin_users_tab.dart';
export 'admin/admin_moderation_tab.dart';

class AdminPage extends StatefulWidget {
  final ApiService? apiService;
  final AdminImpersonationService? impersonationService;

  const AdminPage({super.key, this.apiService, this.impersonationService});

  @override
  State<AdminPage> createState() => _AdminPageState();
}

class _AdminPageState extends State<AdminPage>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  late Future<Map<String, dynamic>> _capabilitiesFuture;
  Timer? _recentAuthTimer;
  bool _reauthenticating = false;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 5, vsync: this);
    _capabilitiesFuture = _fetchCapabilities();
  }

  @override
  void dispose() {
    _recentAuthTimer?.cancel();
    _tabController.dispose();
    super.dispose();
  }

  Future<Map<String, dynamic>> _fetchCapabilities() async {
    final apiService = widget.apiService ?? context.read<ApiService>();
    final capabilities = await apiService.getAdminCapabilities();
    _scheduleRecentAuthExpiry(capabilities);
    return capabilities;
  }

  void _scheduleRecentAuthExpiry(Map<String, dynamic> capabilities) {
    _recentAuthTimer?.cancel();
    if (capabilities['recent_authentication_valid'] != true) return;
    final expiresAt = DateTime.tryParse(
      capabilities['recent_authentication_expires_at']?.toString() ?? '',
    );
    if (expiresAt == null) return;
    final delay = expiresAt.toLocal().difference(DateTime.now());
    _recentAuthTimer = Timer(
      delay.isNegative ? Duration.zero : delay + const Duration(seconds: 1),
      () {
        if (!mounted) return;
        setState(() => _capabilitiesFuture = _fetchCapabilities());
      },
    );
  }

  Future<void> _reauthenticate() async {
    final l = AppLocalizations.of(context)!;
    var enteredPassword = '';
    var enteredTotp = '';
    final credentials = await showDialog<List<String>>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l.adminReauthenticateTitle),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              obscureText: true,
              autofocus: true,
              textInputAction: TextInputAction.next,
              onChanged: (value) => enteredPassword = value,
              decoration: InputDecoration(
                labelText: l.password,
                helperText: l.adminReauthenticateHint,
              ),
            ),
            TextField(
              keyboardType: TextInputType.number,
              textInputAction: TextInputAction.done,
              maxLength: 6,
              onChanged: (value) => enteredTotp = value,
              decoration: InputDecoration(
                labelText: l.adminTotpCodeLabel,
                helperText: l.adminTotpCodeHint,
                counterText: '',
              ),
              onSubmitted: (_) {
                if (enteredPassword.isNotEmpty) {
                  Navigator.pop(dialogContext, [enteredPassword, enteredTotp]);
                }
              },
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(l.cancel),
          ),
          FilledButton(
            onPressed: () {
              if (enteredPassword.isNotEmpty) {
                Navigator.pop(dialogContext, [enteredPassword, enteredTotp]);
              }
            },
            child: Text(l.adminUnlockActions),
          ),
        ],
      ),
    );
    if (credentials == null || credentials.isEmpty || !mounted) return;
    final password = credentials[0];
    final totpCode = credentials.length > 1 ? credentials[1] : '';
    if (password.isEmpty) return;

    setState(() => _reauthenticating = true);
    try {
      final apiService = widget.apiService ?? context.read<ApiService>();
      await apiService.reauthenticate(
        password,
        totpCode: totpCode.isEmpty ? null : totpCode,
      );
      if (!mounted) return;
      setState(() {
        _reauthenticating = false;
        _capabilitiesFuture = _fetchCapabilities();
      });
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l.adminReauthenticateSuccess)));
    } catch (error) {
      if (!mounted) return;
      setState(() => _reauthenticating = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('${l.error}: $error')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final apiService = widget.apiService ?? context.read<ApiService>();
    final impersonationService =
        widget.impersonationService ??
        context.read<AdminImpersonationService>();
    return FutureBuilder<Map<String, dynamic>>(
      future: _capabilitiesFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return Scaffold(
            appBar: AppBar(title: Text(l.adminConsole)),
            body: const Center(child: CircularProgressIndicator()),
          );
        }
        if (snapshot.hasError) {
          return Scaffold(
            appBar: AppBar(title: Text(l.adminConsole)),
            body: Center(child: Text('${l.error}: ${snapshot.error}')),
          );
        }
        final capabilities = snapshot.data ?? const <String, dynamic>{};
        final isPlatformAdmin = capabilities['is_platform_admin'] == true;
        final canReview = capabilities['can_review'] == true;
        final recentAuthenticationValid =
            capabilities['recent_authentication_valid'] == true;
        final canManage = canReview && recentAuthenticationValid;
        return Scaffold(
          appBar: AppBar(
            title: Text(l.adminConsole),
            bottom: TabBar(
              controller: _tabController,
              isScrollable: true,
              indicatorColor: AppTheme.primary.withValues(alpha: 0.8),
              tabs: [
                Tab(icon: const Icon(Icons.dashboard), text: l.adminStatsTab),
                Tab(
                  icon: const Icon(Icons.inventory),
                  text: l.adminListingsTab,
                ),
                Tab(
                  icon: const Icon(Icons.shopping_cart),
                  text: l.adminOrdersTab,
                ),
                Tab(icon: const Icon(Icons.people), text: l.adminUsersTab),
                Tab(
                  icon: const Icon(Icons.policy_outlined),
                  text: l.adminModerationTab,
                ),
              ],
            ),
          ),
          body: Column(
            children: [
              if (isPlatformAdmin && !recentAuthenticationValid)
                _SensitiveActionsBanner(
                  loading: _reauthenticating,
                  onUnlock: _reauthenticate,
                ),
              Expanded(
                child: TabBarView(
                  controller: _tabController,
                  children: [
                    AdminStatsTab(apiService: apiService),
                    AdminListingsTab(
                      apiService: apiService,
                      canManage: canManage,
                    ),
                    AdminOrdersTab(
                      apiService: apiService,
                      canManage: canManage,
                    ),
                    AdminUsersTab(
                      apiService: apiService,
                      impersonationService: impersonationService,
                      canManage: canManage,
                    ),
                    AdminModerationTab(
                      apiService: apiService,
                      canReview: canManage,
                      readOnlyMessage:
                          isPlatformAdmin && !recentAuthenticationValid
                          ? l.adminSensitiveActionsLockedSubtitle
                          : null,
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _SensitiveActionsBanner extends StatelessWidget {
  const _SensitiveActionsBanner({
    required this.loading,
    required this.onUnlock,
  });

  final bool loading;
  final VoidCallback onUnlock;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final colors = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(
        AppTheme.sp12,
        AppTheme.sp12,
        AppTheme.sp12,
        0,
      ),
      padding: const EdgeInsets.all(AppTheme.sp12),
      decoration: BoxDecoration(
        color: colors.tertiaryContainer.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(AppTheme.radiusMd),
        border: Border.all(color: colors.tertiary.withValues(alpha: 0.22)),
      ),
      child: Row(
        children: [
          Icon(Icons.lock_clock_outlined, color: colors.tertiary),
          const SizedBox(width: AppTheme.sp12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  l.adminSensitiveActionsLocked,
                  style: const TextStyle(fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: AppTheme.sp4),
                Text(
                  l.adminSensitiveActionsLockedSubtitle,
                  style: TextStyle(color: colors.onSurfaceVariant),
                ),
              ],
            ),
          ),
          const SizedBox(width: AppTheme.sp8),
          FilledButton.tonalIcon(
            onPressed: loading ? null : onUnlock,
            icon: loading
                ? const SizedBox.square(
                    dimension: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.lock_open_outlined),
            label: Text(l.adminUnlockActions),
          ),
        ],
      ),
    );
  }
}
