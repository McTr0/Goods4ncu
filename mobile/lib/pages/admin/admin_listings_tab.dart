import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../services/api_service.dart';
import '../../theme/app_theme.dart';
import '../../utils/category_utils.dart';

class AdminListingsTab extends StatefulWidget {
  final ApiService apiService;

  const AdminListingsTab({super.key, required this.apiService});

  @override
  State<AdminListingsTab> createState() => _AdminListingsTabState();
}

class _AdminListingsTabState extends State<AdminListingsTab> {
  final ScrollController _scrollController = ScrollController();
  List<dynamic>? _listings;
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
      final data = await widget.apiService.getAdminListings(
        limit: 20,
        offset: 0,
      );
      final listings = (data['listings'] as List?) ?? [];
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
      final data = await widget.apiService.getAdminListings(
        limit: 20,
        offset: _offset,
      );
      final listings = (data['listings'] as List?) ?? [];
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
          final item = listings[i] as Map<String, dynamic>;
          final isTakedown = item['status'] == 'takedown';
          final isActive = item['status'] == 'active';
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
            title: Text(item['title'] ?? ''),
            subtitle: Text(
              '${localizedCategoryLabel(context, item['category']?.toString())} · ¥${item['suggested_price_cny'] ?? 0} · ${item['status']}',
            ),
            trailing: isTakedown
                ? Chip(
                    label: Text(
                      l.adminTakedown,
                      style: const TextStyle(color: Colors.white),
                    ),
                    backgroundColor: AppTheme.error,
                  )
                : const Icon(
                    Icons.chevron_right,
                    color: AppTheme.textSecondary,
                  ),
            onTap: isTakedown ? null : () => _showListingDetail(context, item),
          );
        },
      ),
    );
  }

  void _showListingDetail(BuildContext context, Map<String, dynamic> item) {
    final l = AppLocalizations.of(context)!;
    showModalBottomSheet(
      context: context,
      builder: (ctx) => Padding(
        padding: const EdgeInsets.all(AppTheme.sp16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              item['title'] ?? '',
              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Text('${l.idLabel} ${item['id']}'),
            Text(
              '${l.categoryLabel}: ${localizedCategoryLabel(context, item['category']?.toString())}',
            ),
            Text('${l.brandLabel}: ${item['brand'] ?? l.unknown}'),
            Text('${l.priceLabel}: ¥${item['suggested_price_cny'] ?? 0}'),
            Text('${l.conditionLabel}: ${item['condition_score'] ?? 0}'),
            Text('${l.status}: ${item['status']}'),
            Text('${l.ownerIdLabel} ${item['owner_id']}'),
            const SizedBox(height: AppTheme.sp16),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: () async {
                  final confirmed = await showDialog<bool>(
                    context: ctx,
                    builder: (dialogCtx) => AlertDialog(
                      title: Text(l.adminTakedownConfirm),
                      content: Text(
                        l.adminTakedownConfirmMessage(item['title'] ?? ''),
                      ),
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
                          child: Text(l.adminTakedown),
                        ),
                      ],
                    ),
                  );
                  if (confirmed != true) return;
                  if (ctx.mounted) {
                    Navigator.pop(ctx);
                    try {
                      await widget.apiService.takedownListing(
                        item['id'] as String,
                      );
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(l.adminTakedownSuccess),
                            backgroundColor: AppTheme.success,
                          ),
                        );
                      }
                      _load();
                    } catch (e) {
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(l.operationFailed(e.toString())),
                            backgroundColor: AppTheme.error,
                          ),
                        );
                      }
                    }
                  }
                },
                style: FilledButton.styleFrom(backgroundColor: AppTheme.error),
                icon: const Icon(Icons.archive),
                label: Text(l.adminTakedown),
              ),
            ),
            const SizedBox(height: AppTheme.sp8),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: () async {
                  try {
                    await widget.apiService.updateListing(
                      item['id'] as String,
                      {
                        'status': item['status'] == 'active'
                            ? 'sold'
                            : 'active',
                      },
                    );
                    if (ctx.mounted) Navigator.pop(ctx);
                    _load();
                  } catch (e) {
                    if (ctx.mounted) {
                      ScaffoldMessenger.of(ctx).showSnackBar(
                        SnackBar(
                          content: Text(l.operationFailed(e.toString())),
                        ),
                      );
                    }
                  }
                },
                icon: const Icon(Icons.toggle_on),
                label: Text(item['status'] == 'active' ? l.sold : l.adminUnban),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
