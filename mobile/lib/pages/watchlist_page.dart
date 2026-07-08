import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../components/price_tag.dart';
import '../l10n/app_localizations.dart';
import '../models/models.dart';
import '../services/watchlist_service.dart';
import '../theme/app_theme.dart';
import '../utils/category_utils.dart';

class WatchlistPage extends StatefulWidget {
  final WatchlistService? watchlistService;

  const WatchlistPage({super.key, this.watchlistService});

  @override
  State<WatchlistPage> createState() => _WatchlistPageState();
}

class _WatchlistPageState extends State<WatchlistPage> {
  static const int _limit = 20;

  late final WatchlistService _watchlistService;

  List<WatchlistItem> _items = [];
  bool _loading = true;
  bool _loadingMore = false;
  String? _error;
  String? _paginationError;
  int _total = 0;
  int _offset = 0;
  int _activeRequestId = 0;
  final Set<String> _pendingRemoveIds = <String>{};

  @override
  void initState() {
    super.initState();
    _watchlistService =
        widget.watchlistService ?? context.read<WatchlistService>();
    _load(reset: true);
  }

  bool get _hasMore => _items.length < _total;

  Future<void> _load({bool reset = false, int? requestOffset}) async {
    final effectiveOffset = reset ? 0 : (requestOffset ?? _offset);
    final requestId = ++_activeRequestId;

    if (reset) {
      setState(() {
        _loading = true;
        _error = null;
        _paginationError = null;
      });
    }

    try {
      final response = await _watchlistService.getWatchlist(
        limit: _limit,
        offset: effectiveOffset,
      );
      if (!mounted || requestId != _activeRequestId) return;

      setState(() {
        if (reset) {
          _items = response.items;
        } else {
          _items = [..._items, ...response.items];
        }
        _total = response.total;
        _offset = effectiveOffset;
        _loading = false;
        _loadingMore = false;
        _paginationError = null;
      });
    } catch (e) {
      if (!mounted || requestId != _activeRequestId) return;
      setState(() {
        if (reset) {
          _error = e.toString();
        } else {
          _paginationError = e.toString();
        }
        _loading = false;
        _loadingMore = false;
      });
    }
  }

  Future<void> _onRefresh() async {
    await _load(reset: true);
  }

  void _loadMore() {
    if (_loading || _loadingMore || !_hasMore) return;
    final nextOffset = _items.length;
    setState(() {
      _loadingMore = true;
      _paginationError = null;
    });
    _load(requestOffset: nextOffset);
  }

  Future<void> _removeFromWatchlist(WatchlistItem item) async {
    if (!mounted) return;
    if (_pendingRemoveIds.contains(item.listingId)) return;

    final l = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);
    final removedIndex = _items.indexWhere(
      (it) => it.listingId == item.listingId,
    );

    setState(() {
      _pendingRemoveIds.add(item.listingId);
    });

    try {
      await _watchlistService.removeFromWatchlist(item.listingId);
      if (!mounted) return;
      setState(() {
        final exists = _items.any((it) => it.listingId == item.listingId);
        if (exists) {
          _items = _items
              .where((it) => it.listingId != item.listingId)
              .toList();
          if (_total > 0) {
            _total -= 1;
          }
        }
        _pendingRemoveIds.remove(item.listingId);
      });

      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(
        SnackBar(
          content: Text(l.favoriteRemoved),
          action: SnackBarAction(
            label: l.undo,
            onPressed: () {
              if (!mounted) return;
              _restoreRemovedItem(item, removedIndex);
            },
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _pendingRemoveIds.remove(item.listingId);
      });
      messenger.showSnackBar(
        SnackBar(content: Text(l.operationFailed(e.toString()))),
      );
    }
  }

  Future<void> _restoreRemovedItem(WatchlistItem item, int removedIndex) async {
    if (!mounted) return;

    final l = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);

    try {
      await _watchlistService.addToWatchlist(item.listingId);
      if (!mounted) return;

      setState(() {
        final exists = _items.any((it) => it.listingId == item.listingId);
        if (!exists) {
          final targetIndex = removedIndex < 0
              ? _items.length
              : removedIndex.clamp(0, _items.length);
          _items.insert(targetIndex, item);
          _total += 1;
        }
        _pendingRemoveIds.remove(item.listingId);
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _pendingRemoveIds.remove(item.listingId);
      });
      messenger.showSnackBar(
        SnackBar(content: Text(l.operationFailed(e.toString()))),
      );
    }
  }

  Future<void> _confirmAndRemoveFromWatchlist(WatchlistItem item) async {
    final l = AppLocalizations.of(context)!;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l.delete),
        content: Text(l.removeFavoriteConfirm),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(l.cancel),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(l.delete),
          ),
        ],
      ),
    );

    if (!mounted) return;

    if (confirmed == true) {
      await _removeFromWatchlist(item);
    }
  }

  String _formatDate(String raw) {
    if (raw.isEmpty) return '';
    if (raw.length >= 10) return raw.substring(0, 10);
    return raw;
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;

    return Scaffold(
      appBar: AppBar(title: Text(l.myFavorites)),
      body: _buildBody(l),
    );
  }

  Widget _buildBody(AppLocalizations l) {
    if (_loading && _items.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_error != null && _items.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(AppTheme.sp16),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.error_outline, size: 48, color: AppTheme.error),
              const SizedBox(height: AppTheme.sp16),
              Text(_error!, textAlign: TextAlign.center),
              const SizedBox(height: AppTheme.sp16),
              ElevatedButton(
                onPressed: () => _load(reset: true),
                child: Text(l.retry),
              ),
            ],
          ),
        ),
      );
    }

    if (_items.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.favorite_border,
              size: 64,
              color: AppTheme.textSecondary.withValues(alpha: 0.55),
            ),
            const SizedBox(height: AppTheme.sp16),
            Text(
              l.watchlistEmpty,
              style: const TextStyle(
                fontSize: 16,
                color: AppTheme.textSecondary,
              ),
            ),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _onRefresh,
      child: ListView.separated(
        padding: const EdgeInsets.all(AppTheme.sp16),
        itemCount:
            _items.length + ((_hasMore || _paginationError != null) ? 1 : 0),
        separatorBuilder: (context, index) =>
            const SizedBox(height: AppTheme.sp12),
        itemBuilder: (context, index) {
          if (index >= _items.length) {
            if (_paginationError != null) {
              return Center(
                child: TextButton.icon(
                  onPressed: _loadMore,
                  icon: const Icon(Icons.refresh),
                  label: Text(l.retry),
                ),
              );
            }
            if (_loadingMore) {
              return const Center(
                child: Padding(
                  padding: EdgeInsets.all(AppTheme.sp16),
                  child: CircularProgressIndicator(),
                ),
              );
            }
            return Center(
              child: TextButton.icon(
                onPressed: _loadMore,
                icon: const Icon(Icons.expand_more),
                label: Text(l.loadMore),
              ),
            );
          }

          final item = _items[index];
          return _WatchlistCard(
            item: item,
            formattedDate: _formatDate(item.createdAt),
            onTap: () => context.push('/listing/${item.listingId}'),
            onRemove: () => _confirmAndRemoveFromWatchlist(item),
            removing: _pendingRemoveIds.contains(item.listingId),
          );
        },
      ),
    );
  }
}

class _WatchlistCard extends StatelessWidget {
  final WatchlistItem item;
  final String formattedDate;
  final VoidCallback onTap;
  final VoidCallback onRemove;
  final bool removing;

  const _WatchlistCard({
    required this.item,
    required this.formattedDate,
    required this.onTap,
    required this.onRemove,
    required this.removing,
  });

  @override
  Widget build(BuildContext context) {
    final category = localizedCategoryLabel(context, item.category);
    final categoryBrand = item.brand.isEmpty
        ? category
        : '$category · ${item.brand}';

    return Card(
      margin: EdgeInsets.zero,
      child: InkWell(
        borderRadius: BorderRadius.circular(AppTheme.radiusMd),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(AppTheme.sp16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Text(
                      item.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        height: 1.35,
                      ),
                    ),
                  ),
                  const SizedBox(width: AppTheme.sp8),
                  IconButton(
                    tooltip: AppLocalizations.of(context)!.myFavorites,
                    onPressed: removing ? null : onRemove,
                    icon: removing
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.favorite, color: AppTheme.error),
                  ),
                ],
              ),
              const SizedBox(height: AppTheme.sp8),
              Text(
                categoryBrand,
                style: const TextStyle(
                  color: AppTheme.textSecondary,
                  fontSize: 13,
                ),
              ),
              const SizedBox(height: AppTheme.sp12),
              Row(
                children: [
                  PriceTag(priceCny: item.suggestedPriceCny, fontSize: 18),
                  const SizedBox(width: AppTheme.sp8),
                  conditionBadgeFromScore(item.conditionScore),
                  const Spacer(),
                  Text(
                    formattedDate,
                    style: const TextStyle(
                      color: AppTheme.textSecondary,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
