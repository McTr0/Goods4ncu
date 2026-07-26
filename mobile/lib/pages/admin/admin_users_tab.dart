import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../l10n/app_localizations.dart';
import '../../services/admin_impersonation_service.dart';
import '../../services/admin_user_permissions.dart';
import '../../services/api_service.dart';
import '../../theme/app_theme.dart';

class AdminUsersTab extends StatefulWidget {
  final ApiService? apiService;
  final AdminImpersonationService? impersonationService;
  final bool canManage;

  const AdminUsersTab({
    super.key,
    this.apiService,
    this.impersonationService,
    this.canManage = true,
  });

  @override
  State<AdminUsersTab> createState() => _AdminUsersTabState();
}

class _AdminUsersTabState extends State<AdminUsersTab> {
  late final ApiService _apiService;
  late final AdminImpersonationService _adminImpersonationService;
  final TextEditingController _searchController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  List<dynamic>? _users;
  bool _loading = false;
  bool _loadingMore = false;
  String? _error;
  int _offset = 0;
  bool _hasMore = true;

  @override
  void initState() {
    super.initState();
    _apiService = widget.apiService ?? context.read<ApiService>();
    _adminImpersonationService =
        widget.impersonationService ??
        context.read<AdminImpersonationService>();
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_scrollController.position.pixels >=
        _scrollController.position.maxScrollExtent - 200) {
      if (_hasMore && !_loadingMore && !_loading) {
        _loadMore(_searchController.text);
      }
    }
  }

  Future<void> _search(String query, {bool reset = false}) async {
    if (reset) {
      _offset = 0;
      _hasMore = true;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final data = await _apiService.getAdminUsers(
        q: query.isEmpty ? null : query,
        limit: 20,
        offset: _offset,
      );
      if (!mounted) return;
      final results = (data['users'] as List?) ?? [];
      setState(() {
        if (reset || _offset == 0) {
          _users = results;
        } else {
          _users = [...?_users, ...results];
        }
        _loading = false;
        if (results.length < 20) {
          _hasMore = false;
        } else {
          _offset += 20;
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Future<void> _loadMore(String query) async {
    if (!_hasMore || _loadingMore) return;
    setState(() {
      _loadingMore = true;
    });
    try {
      final data = await _apiService.getAdminUsers(
        q: query.isEmpty ? null : query,
        limit: 20,
        offset: _offset,
      );
      if (!mounted) return;
      final results = (data['users'] as List?) ?? [];
      setState(() {
        _users = [...?_users, ...results];
        _loadingMore = false;
        if (results.length < 20) {
          _hasMore = false;
        } else {
          _offset += 20;
        }
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loadingMore = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(AppTheme.sp12),
          child: TextField(
            controller: _searchController,
            decoration: InputDecoration(
              hintText: l.adminSearchUsersPlaceholder,
              prefixIcon: const Icon(Icons.search),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(AppTheme.radiusSm),
              ),
              suffixIcon: IconButton(
                icon: const Icon(Icons.clear),
                onPressed: () {
                  _searchController.clear();
                  _search('');
                },
              ),
            ),
            onSubmitted: _search,
          ),
        ),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : _error != null
              ? Center(child: Text('${l.error}: $_error'))
              : _users == null
              ? Center(child: Text(l.adminSearchUsersPlaceholder))
              : _users!.isEmpty
              ? Center(child: Text(l.adminNoUsersFound))
              : ListView.builder(
                  controller: _scrollController,
                  itemCount: _users!.length + (_loadingMore ? 1 : 0),
                  itemBuilder: (context, i) {
                    if (i >= _users!.length) {
                      return const Center(
                        child: Padding(
                          padding: EdgeInsets.all(16),
                          child: CircularProgressIndicator(),
                        ),
                      );
                    }
                    final u = _users![i];
                    final isBanned = u['status'] == 'banned';
                    return ListTile(
                      leading: CircleAvatar(
                        backgroundColor: isBanned
                            ? AppTheme.error
                            : AppTheme.primary,
                        child: Text(
                          (u['username'] ?? '?')[0].toUpperCase(),
                          style: const TextStyle(color: Colors.white),
                        ),
                      ),
                      title: Text(u['username'] ?? l.unknown),
                      subtitle: Text(
                        '${u['role']} · ${l.joinedLabel} ${u['created_at'] ?? l.unknown}',
                      ),
                      trailing: Text(
                        '${l.myListings}: ${u['listing_count'] ?? 0}',
                      ),
                      onTap: () => _showUserDetail(u),
                    );
                  },
                ),
        ),
      ],
    );
  }

  void _showUserDetail(Map<String, dynamic> u) {
    final l = AppLocalizations.of(context)!;
    final isBanned = u['status'] == 'banned';
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(
            AppTheme.sp16,
            AppTheme.sp16,
            AppTheme.sp16,
            AppTheme.sp16 + MediaQuery.of(ctx).viewInsets.bottom,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  CircleAvatar(
                    radius: 28,
                    backgroundColor: isBanned
                        ? AppTheme.error
                        : AppTheme.primary,
                    child: Text(
                      (u['username'] ?? '?')[0].toUpperCase(),
                      style: const TextStyle(color: Colors.white, fontSize: 24),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        u['username'] ?? l.unknown,
                        style: const TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      Text(
                        '${l.idLabel} ${u['id'] ?? u['user_id'] ?? l.unknown}',
                      ),
                    ],
                  ),
                ],
              ),
              const Divider(),
              Text('${l.status}: ${u['status'] ?? 'active'}'),
              Text('${l.myListings}: ${u['listing_count'] ?? 0}'),
              Text('${l.joinedLabel} ${u['created_at'] ?? l.unknown}'),
              Text('Role: ${u['role'] ?? 'user'}'),
              const SizedBox(height: AppTheme.sp16),
              if (widget.canManage && !isBanned)
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: () async {
                      final messenger = ScaffoldMessenger.of(context);
                      final userId =
                          (u['id'] ?? u['user_id'])?.toString() ?? '';
                      if (userId.isEmpty) {
                        messenger.showSnackBar(
                          SnackBar(content: Text(l.operationFailed(l.unknown))),
                        );
                        return;
                      }

                      final confirmed = await showDialog<bool>(
                        context: ctx,
                        builder: (dialogCtx) => AlertDialog(
                          title: Text(l.adminBanConfirm),
                          content: Text(l.adminBanConfirmMessage),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(dialogCtx, false),
                              child: Text(l.cancel),
                            ),
                            FilledButton(
                              onPressed: () => Navigator.pop(dialogCtx, true),
                              style: FilledButton.styleFrom(
                                backgroundColor: AppTheme.error,
                              ),
                              child: Text(l.adminBan),
                            ),
                          ],
                        ),
                      );
                      if (confirmed != true) return;
                      if (ctx.mounted) {
                        Navigator.pop(ctx);
                      }
                      try {
                        await _apiService.banUser(userId);
                        if (!mounted) return;
                        messenger.showSnackBar(
                          SnackBar(
                            content: Text(l.adminBanSuccess),
                            backgroundColor: AppTheme.success,
                          ),
                        );
                        _search('', reset: true);
                      } catch (e) {
                        if (!mounted) return;
                        messenger.showSnackBar(
                          SnackBar(
                            content: Text(l.operationFailed(e.toString())),
                            backgroundColor: AppTheme.error,
                          ),
                        );
                      }
                    },
                    style: FilledButton.styleFrom(
                      backgroundColor: AppTheme.error,
                    ),
                    icon: const Icon(Icons.block),
                    label: Text(l.adminBan),
                  ),
                )
              else if (widget.canManage)
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: () async {
                      final messenger = ScaffoldMessenger.of(context);
                      final userId =
                          (u['id'] ?? u['user_id'])?.toString() ?? '';
                      if (userId.isEmpty) {
                        messenger.showSnackBar(
                          SnackBar(content: Text(l.operationFailed(l.unknown))),
                        );
                        return;
                      }

                      final confirmed = await showDialog<bool>(
                        context: ctx,
                        builder: (dialogCtx) => AlertDialog(
                          title: Text(l.adminUnban),
                          content: Text(
                            l.unbanConfirmMessage(u['username'] ?? l.unknown),
                          ),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(dialogCtx, false),
                              child: Text(l.cancel),
                            ),
                            FilledButton(
                              onPressed: () => Navigator.pop(dialogCtx, true),
                              child: Text(l.adminUnban),
                            ),
                          ],
                        ),
                      );
                      if (confirmed != true) return;
                      if (ctx.mounted) {
                        Navigator.pop(ctx);
                      }
                      try {
                        await _apiService.unbanUser(userId);
                        if (!mounted) return;
                        messenger.showSnackBar(
                          SnackBar(
                            content: Text(l.adminUnbanSuccess),
                            backgroundColor: AppTheme.success,
                          ),
                        );
                        _search('', reset: true);
                      } catch (e) {
                        if (!mounted) return;
                        messenger.showSnackBar(
                          SnackBar(
                            content: Text(l.operationFailed(e.toString())),
                            backgroundColor: AppTheme.error,
                          ),
                        );
                      }
                    },
                    style: FilledButton.styleFrom(
                      backgroundColor: AppTheme.success,
                    ),
                    icon: const Icon(Icons.check_circle),
                    label: Text(l.adminUnban),
                  ),
                ),
              const SizedBox(height: AppTheme.sp8),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: () async {
                    Navigator.pop(ctx);
                    _searchController.text = u['username'] ?? '';
                    _search(u['username'] ?? '');
                  },
                  icon: const Icon(Icons.visibility),
                  label: Text(l.adminViewListings),
                ),
              ),
              if (widget.canManage && canAdminImpersonateUser(u))
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: () async {
                      final userId =
                          (u['id'] ?? u['user_id'])?.toString() ?? '';
                      if (userId.isEmpty) {
                        if (!mounted) return;
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text(l.adminLoginAsFailed)),
                        );
                        return;
                      }

                      final confirmed = await showDialog<bool>(
                        context: context,
                        builder: (dialogCtx) => AlertDialog(
                          title: Text(l.adminLoginAsConfirm),
                          content: Text(l.adminLoginAsAuditLogWarning),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(dialogCtx, false),
                              child: Text(l.cancel),
                            ),
                            FilledButton(
                              onPressed: () => Navigator.pop(dialogCtx, true),
                              child: Text(l.adminLoginAsConfirm),
                            ),
                          ],
                        ),
                      );
                      if (confirmed != true) return;

                      if (ctx.mounted) {
                        Navigator.pop(ctx);
                      }

                      try {
                        await _adminImpersonationService.impersonate(userId);
                        if (!mounted) return;
                        GoRouter.of(context).go('/');
                      } catch (e) {
                        if (!mounted) return;
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(l.impersonationFailed(e.toString())),
                          ),
                        );
                      }
                    },
                    icon: const Icon(Icons.login, color: Colors.purple),
                    label: Text(l.adminLoginAs),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.purple,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
