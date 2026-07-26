import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../services/api_service.dart';
import '../../theme/app_theme.dart';

class AdminOrdersTab extends StatefulWidget {
  final ApiService apiService;
  final bool canManage;

  const AdminOrdersTab({
    super.key,
    required this.apiService,
    this.canManage = true,
  });

  @override
  State<AdminOrdersTab> createState() => _AdminOrdersTabState();
}

class _AdminOrdersTabState extends State<AdminOrdersTab> {
  Map<String, dynamic>? _orders;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final data = await widget.apiService.getAdminOrders(limit: 50);
      if (!mounted) return;
      setState(() {
        _orders = data;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Color _statusColor(String? status) {
    return switch (status) {
      'intent_pending' || 'pending' => AppTheme.warning,
      'confirmed' || 'completed' || 'paid' || 'shipped' => AppTheme.success,
      'cancelled' => AppTheme.error,
      _ => AppTheme.textSecondary,
    };
  }

  String _statusLabel(BuildContext context, String? status) {
    final l = AppLocalizations.of(context)!;
    return switch (status) {
      'intent_pending' || 'pending' => l.awaitingSellerConfirm,
      'confirmed' || 'completed' || 'paid' || 'shipped' => l.dealConfirmed,
      'cancelled' => l.dealCancelled,
      _ => l.unknown,
    };
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) return Center(child: Text('${l.error}: $_error'));

    final items = _orders?['orders'] as List? ?? [];

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.builder(
        itemCount: items.length,
        itemBuilder: (context, i) {
          final item = items[i] as Map<String, dynamic>;
          final id = (item['id'] ?? '').toString();
          final price = ((item['final_price'] as num?)?.toDouble() ?? 0);
          final status = item['status']?.toString();
          return ListTile(
            leading: CircleAvatar(
              backgroundColor: _statusColor(status),
              child: const Icon(Icons.handshake_outlined, color: Colors.white),
            ),
            title: Text(l.orderNumber(id.substring(0, id.length.clamp(0, 8)))),
            subtitle: Text(
              '${_statusLabel(context, status)} · ¥${price.toStringAsFixed(2)}',
            ),
            trailing: const Icon(
              Icons.chevron_right,
              color: AppTheme.textSecondary,
            ),
            onTap: () => _showOrderDetail(context, item),
          );
        },
      ),
    );
  }

  void _showOrderDetail(BuildContext context, Map<String, dynamic> item) {
    final l = AppLocalizations.of(context)!;
    var autoDelist = item['auto_delist'] != false;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) => DraggableScrollableSheet(
          initialChildSize: 0.62,
          minChildSize: 0.3,
          maxChildSize: 0.9,
          expand: false,
          builder: (_, scrollController) => ListView(
            controller: scrollController,
            padding: const EdgeInsets.all(AppTheme.sp16),
            children: [
              Text(
                l.orderNumber(item['id'] ?? ''),
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                l.platformNoEscrowShort,
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: AppTheme.textSecondary),
              ),
              const Divider(height: 28),
              _DetailRow(label: l.title, value: item['listing_title']),
              _DetailRow(label: l.buyer, value: item['buyer_username']),
              _DetailRow(label: l.owner, value: item['seller_username']),
              _DetailRow(
                label: l.price,
                value:
                    '¥${(((item['final_price'] as num?)?.toDouble() ?? 0)).toStringAsFixed(2)}',
              ),
              _DetailRow(
                label: l.status,
                value: _statusLabel(context, item['status']?.toString()),
              ),
              _DetailRow(
                label: l.listingStatus,
                value: item['listing_status'] ?? l.unknown,
              ),
              if (item['confirmed_at'] != null)
                _DetailRow(
                  label: l.sellerConfirmedDeal,
                  value: item['confirmed_at'],
                ),
              if (item['auto_delisted_at'] != null)
                _DetailRow(
                  label: l.itemAutoDelisted,
                  value: item['auto_delisted_at'],
                ),
              const Divider(height: 28),
              if (widget.canManage)
                SwitchListTile.adaptive(
                  contentPadding: EdgeInsets.zero,
                  value: autoDelist,
                  onChanged: (value) => setSheetState(() => autoDelist = value),
                  title: Text(l.autoDelistAfterConfirm),
                  subtitle: Text(l.autoDelistAfterConfirmSubtitle),
                ),
              if (widget.canManage) const SizedBox(height: 12),
              if (widget.canManage)
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () async {
                          try {
                            await widget.apiService.updateAdminOrderStatus(
                              item['id'],
                              'cancelled',
                              reason: 'admin_cancelled',
                            );
                            if (ctx.mounted) Navigator.pop(ctx);
                            _load();
                          } catch (e) {
                            if (ctx.mounted) {
                              ScaffoldMessenger.of(ctx).showSnackBar(
                                SnackBar(
                                  content: Text(
                                    l.operationFailed(e.toString()),
                                  ),
                                ),
                              );
                            }
                          }
                        },
                        child: Text(l.cancel),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: FilledButton(
                        onPressed: () async {
                          try {
                            await widget.apiService.updateAdminOrderStatus(
                              item['id'],
                              'confirmed',
                              autoDelist: autoDelist,
                            );
                            if (ctx.mounted) Navigator.pop(ctx);
                            _load();
                          } catch (e) {
                            if (ctx.mounted) {
                              ScaffoldMessenger.of(ctx).showSnackBar(
                                SnackBar(
                                  content: Text(
                                    l.operationFailed(e.toString()),
                                  ),
                                ),
                              );
                            }
                          }
                        },
                        child: Text(l.confirmOfflineDeal),
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

class _DetailRow extends StatelessWidget {
  final String label;
  final Object? value;

  const _DetailRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 96,
            child: Text(
              label,
              style: const TextStyle(color: AppTheme.textSecondary),
            ),
          ),
          Expanded(child: Text('${value ?? '-'}')),
        ],
      ),
    );
  }
}
