import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../models/models.dart';
import '../../services/admin_service.dart';
import '../../theme/app_theme.dart';
import '../../utils/category_utils.dart';

class AdminListingsTab extends StatefulWidget {
  final AdminService adminService;
  final bool canManage;

  const AdminListingsTab({
    super.key,
    required this.adminService,
    this.canManage = true,
  });

  @override
  State<AdminListingsTab> createState() => _AdminListingsTabState();
}

class _AdminListingsTabState extends State<AdminListingsTab> {
  final ScrollController _scrollController = ScrollController();
  List<Listing>? _listings;
  bool _loading = true;
  bool _loadingMore = false;
  String? _error;
  int _offset = 0;
  bool _hasMore = true;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    _load();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_scrollController.position.pixels >=
        _scrollController.position.maxScrollExtent - 200) {
      if (_hasMore && !_loadingMore && !_loading) {
        _loadMore();
      }
    }
  }

  Future<void> _load() async {
    _offset = 0;
    _hasMore = true;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final data = await widget.adminService.getAdminListings(
        limit: 20,
        offset: 0,
      );
      final listings = (data['listings'] as List<dynamic>? ?? const [])
          .whereType<Map>()
          .map(
            (item) => Listing.fromJson(
              item.map((key, value) => MapEntry(key.toString(), value)),
            ),
          )
          .toList(growable: false);
      setState(() {
        _listings = listings;
        _loading = false;
        if (listings.length < 20) {
          _hasMore = false;
        } else {
          _offset = 20;
        }
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Future<void> _loadMore() async {
    if (!_hasMore || _loadingMore) return;
    setState(() {
      _loadingMore = true;
    });
    try {
      final data = await widget.adminService.getAdminListings(
        limit: 20,
        offset: _offset,
      );
      final listings = (data['listings'] as List<dynamic>? ?? const [])
          .whereType<Map>()
          .map(
            (item) => Listing.fromJson(
              item.map((key, value) => MapEntry(key.toString(), value)),
            ),
          )
          .toList(growable: false);
      setState(() {
        _listings = [...?_listings, ...listings];
        _loadingMore = false;
        if (listings.length < 20) {
          _hasMore = false;
        } else {
          _offset += 20;
        }
      });
    } catch (_) {
      setState(() {
        _loadingMore = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) return Center(child: Text('${l.error}: $_error'));

    final listings = _listings ?? [];

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.builder(
        controller: _scrollController,
        itemCount: listings.length + (_loadingMore ? 1 : 0),
        itemBuilder: (context, i) {
          if (i >= listings.length) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(16),
                child: CircularProgressIndicator(),
              ),
            );
          }
          final item = listings[i];
          final isActive = item.status == 'active' && !item.isRestricted;
          return ListTile(
            leading: CircleAvatar(
              backgroundColor: isActive
                  ? AppTheme.success
                  : AppTheme.textSecondary,
              child: Icon(
                isActive ? Icons.check : Icons.archive,
                color: Colors.white,
                size: 18,
              ),
            ),
            title: Text(item.title),
            subtitle: Text(
              '${localizedCategoryLabel(context, item.category)} · '
              '¥${item.suggestedPriceCny.toStringAsFixed(2)} · '
              '${_lifecycleLabel(l, item.status)}'
              '${item.isRestricted ? ' · ${l.listingRestrictedBadge}' : ''}',
            ),
            trailing: const Icon(
              Icons.chevron_right,
              color: AppTheme.textSecondary,
            ),
            onTap: () => _showListingDetail(context, item),
          );
        },
      ),
    );
  }

  Future<void> _showListingDetail(BuildContext context, Listing item) async {
    final l = AppLocalizations.of(context)!;
    var operating = false;
    String? actionError;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (sheetContext, setSheetState) {
          Future<void> runAction(String action) async {
            if (operating) return;
            final takedown = action == Listing.adminActionTakedown;
            String? restoreReason;
            if (takedown) {
              final confirmed = await showDialog<bool>(
                context: sheetContext,
                builder: (dialogContext) => AlertDialog(
                  title: Text(l.adminTakedownConfirm),
                  content: Text(l.adminTakedownConfirmMessage(item.title)),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(dialogContext, false),
                      child: Text(l.cancel),
                    ),
                    FilledButton(
                      onPressed: () => Navigator.pop(dialogContext, true),
                      style: FilledButton.styleFrom(
                        backgroundColor: AppTheme.error,
                      ),
                      child: Text(l.adminTakedown),
                    ),
                  ],
                ),
              );
              if (confirmed != true) return;
            } else {
              var input = '';
              restoreReason = await showDialog<String>(
                context: sheetContext,
                builder: (dialogContext) => StatefulBuilder(
                  builder: (dialogContext, setDialogState) => AlertDialog(
                    title: Text(l.adminRestoreListingConfirm),
                    content: TextField(
                      key: const Key('admin-listing-restore-reason'),
                      autofocus: true,
                      minLines: 2,
                      maxLines: 5,
                      maxLength: 2000,
                      onChanged: (value) => setDialogState(() => input = value),
                      decoration: InputDecoration(
                        hintText: l.adminRestoreReasonHint,
                      ),
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(dialogContext),
                        child: Text(l.cancel),
                      ),
                      FilledButton(
                        onPressed: input.trim().isEmpty
                            ? null
                            : () => Navigator.pop(dialogContext, input.trim()),
                        child: Text(l.adminRestoreListing),
                      ),
                    ],
                  ),
                ),
              );
              if (restoreReason == null) return;
            }
            if (!sheetContext.mounted) return;
            setSheetState(() {
              operating = true;
              actionError = null;
            });
            try {
              if (takedown) {
                await widget.adminService.takedownListing(item.id);
              } else {
                await widget.adminService.restoreListing(
                  item.id,
                  reason: restoreReason!,
                );
              }
              if (!sheetContext.mounted) return;
              Navigator.pop(sheetContext);
              if (!context.mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(
                    takedown
                        ? l.adminTakedownSuccess
                        : l.adminRestoreListingSuccess,
                  ),
                  backgroundColor: AppTheme.success,
                ),
              );
              await _load();
            } catch (error) {
              if (!sheetContext.mounted) return;
              setSheetState(() {
                operating = false;
                actionError = l.operationFailed(error.toString());
              });
            }
          }

          final canTakedown = item.allowsAdminAction(
            Listing.adminActionTakedown,
          );
          final canRestore = item.allowsAdminAction(Listing.adminActionRestore);
          return SafeArea(
            child: SingleChildScrollView(
              padding: EdgeInsets.fromLTRB(
                AppTheme.sp16,
                0,
                AppTheme.sp16,
                AppTheme.sp24 + MediaQuery.viewInsetsOf(sheetContext).bottom,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.title,
                    style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: AppTheme.sp8),
                  Text('${l.idLabel} ${item.id}'),
                  Text(
                    '${l.categoryLabel}: '
                    '${localizedCategoryLabel(context, item.category)}',
                  ),
                  Text('${l.brandLabel}: ${item.brand}'),
                  Text(
                    '${l.priceLabel}: '
                    '¥${item.suggestedPriceCny.toStringAsFixed(2)}',
                  ),
                  Text('${l.conditionLabel}: ${item.conditionScore}'),
                  Text('${l.status}: ${_lifecycleLabel(l, item.status)}'),
                  if (item.isRestricted)
                    Text(
                      l.listingRestrictedBadge,
                      style: const TextStyle(
                        color: AppTheme.error,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  Text('${l.ownerIdLabel} ${item.ownerId ?? l.unknown}'),
                  const SizedBox(height: AppTheme.sp16),
                  if (actionError != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: AppTheme.sp12),
                      child: Text(
                        actionError!,
                        key: const Key('admin-listing-action-error'),
                        style: const TextStyle(color: AppTheme.error),
                      ),
                    ),
                  if (operating)
                    const Center(child: CircularProgressIndicator())
                  else if (!widget.canManage)
                    Text(l.adminSensitiveActionsLockedSubtitle)
                  else if (canTakedown)
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        key: const Key('admin-listing-takedown-action'),
                        onPressed: () => runAction(Listing.adminActionTakedown),
                        style: FilledButton.styleFrom(
                          backgroundColor: AppTheme.error,
                        ),
                        icon: const Icon(Icons.archive_outlined),
                        label: Text(l.adminTakedown),
                      ),
                    )
                  else if (canRestore)
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        key: const Key('admin-listing-restore-action'),
                        onPressed: () => runAction(Listing.adminActionRestore),
                        icon: const Icon(Icons.restore),
                        label: Text(l.adminRestoreListing),
                      ),
                    )
                  else
                    Text(l.adminListingNoActions),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

String _lifecycleLabel(AppLocalizations l, String status) => switch (status) {
  'active' => l.listingLifecycleActive,
  'fulfilled' => l.listingLifecycleFulfilled,
  'sold' => l.listingLifecycleSold,
  'deleted' => l.listingLifecycleOwnerDeleted,
  _ => l.listingLifecycleUnknown,
};
