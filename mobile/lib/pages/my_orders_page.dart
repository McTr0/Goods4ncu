import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import '../models/models.dart';
import '../services/order_service.dart';
import '../theme/app_theme.dart';

String _localizedOrderStatus(AppLocalizations l, String status) {
  return switch (status) {
    'pending' || 'intent_pending' => l.awaitingSellerConfirm,
    'paid' || 'shipped' || 'completed' || 'confirmed' => l.dealConfirmed,
    'cancelled' => l.dealCancelled,
    _ => l.unknown,
  };
}

/// Order list page with tabs: All / As Buyer / As Seller.
class MyOrdersPage extends StatefulWidget {
  final OrderService? orderService;

  const MyOrdersPage({super.key, this.orderService});

  @override
  State<MyOrdersPage> createState() => _MyOrdersPageState();
}

class _MyOrdersPageState extends State<MyOrdersPage>
    with SingleTickerProviderStateMixin {
  late final OrderService _orderService;
  late TabController _tabController;

  List<Order> _orders = [];
  bool _loading = true;
  String? _error;
  int _total = 0;

  // None = all, "buyer" = buyer role, "seller" = seller role
  String? _currentRole;
  final int _limit = 20;
  int _offset = 0;

  @override
  void initState() {
    super.initState();
    _orderService = widget.orderService ?? context.read<OrderService>();
    _tabController = TabController(length: 3, vsync: this);
    _tabController.addListener(_onTabChanged);
    _load();
  }

  @override
  void dispose() {
    _tabController.removeListener(_onTabChanged);
    _tabController.dispose();
    super.dispose();
  }

  void _onTabChanged() {
    if (!_tabController.indexIsChanging) {
      // 0 = all, 1 = buyer, 2 = seller
      final roles = [null, 'buyer', 'seller'];
      setState(() {
        _currentRole = roles[_tabController.index];
        _offset = 0;
        _orders = [];
        _loading = true;
      });
      _load();
    }
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final data = await _orderService.getOrders(
        role: _currentRole,
        limit: _limit,
        offset: _offset,
      );
      if (mounted) {
        setState(() {
          final response = OrdersResponse.fromJson(data);
          _orders = response.items;
          _total = response.total;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = e.toString();
        });
      }
    }
  }

  Future<void> _onRefresh() async {
    setState(() {
      _offset = 0;
    });
    await _load();
  }

  void _loadMore() {
    if (_orders.length >= _total) return;
    setState(() {
      _offset += _limit;
    });
    _loadMoreInternal();
  }

  Future<void> _loadMoreInternal() async {
    try {
      final data = await _orderService.getOrders(
        role: _currentRole,
        limit: _limit,
        offset: _offset,
      );
      if (mounted) {
        setState(() {
          final response = OrdersResponse.fromJson(data);
          _orders = [..._orders, ...response.items];
        });
      }
    } catch (_) {
      // Silently fail on load more
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(
        title: Text(l.myOrders),
        bottom: TabBar(
          controller: _tabController,
          tabs: [
            Tab(text: l.allOrders),
            Tab(text: l.buyerOrders),
            Tab(text: l.sellerOrders),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [_buildList(), _buildList(), _buildList()],
      ),
    );
  }

  Widget _buildList() {
    final l = AppLocalizations.of(context)!;
    if (_loading && _orders.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_error != null && _orders.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.error_outline, size: 48, color: AppTheme.error),
            const SizedBox(height: 16),
            Text(_error!, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            ElevatedButton(onPressed: _load, child: Text(l.retry)),
          ],
        ),
      );
    }

    if (_orders.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.shopping_bag_outlined,
              size: 64,
              color: AppTheme.textSecondary.withValues(alpha: 0.5),
            ),
            const SizedBox(height: 16),
            Text(
              l.noOrders,
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
        itemCount: _orders.length + (_orders.length < _total ? 1 : 0),
        separatorBuilder: (context, index) => const SizedBox(height: 12),
        itemBuilder: (context, i) {
          if (i >= _orders.length) {
            // Load more trigger
            _loadMore();
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(16),
                child: CircularProgressIndicator(),
              ),
            );
          }
          final order = _orders[i];
          return _OrderCard(
            order: order,
            onTap: () => context.push('/orders/${order.id}'),
          );
        },
      ),
    );
  }
}

class _OrderCard extends StatelessWidget {
  final Order order;
  final VoidCallback onTap;

  const _OrderCard({required this.order, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final roleLabel = order.role == 'buyer' ? l.orderAsBuyer : l.orderAsSeller;
    final peerLabel = order.role == 'buyer' ? l.owner : l.buyer;
    final peerUsername = order.role == 'buyer'
        ? order.sellerUsername
        : order.buyerUsername;

    return Card(
      margin: EdgeInsets.zero,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(AppTheme.sp16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      order.listingTitle,
                      style: const TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 15,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: order.statusColor.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      _localizedOrderStatus(l, order.status),
                      style: TextStyle(
                        color: order.statusColor,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: AppTheme.primary.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      roleLabel,
                      style: const TextStyle(
                        color: AppTheme.primary,
                        fontSize: 11,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '$peerLabel: $peerUsername',
                    style: const TextStyle(
                      color: AppTheme.textSecondary,
                      fontSize: 12,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    '¥${order.finalPriceCny.toStringAsFixed(2)}',
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                      color: AppTheme.primary,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                _formatDate(order.createdAt),
                style: const TextStyle(
                  color: AppTheme.textSecondary,
                  fontSize: 11,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _formatDate(String createdAt) {
    try {
      return createdAt.substring(0, 10);
    } catch (_) {
      return createdAt;
    }
  }
}
