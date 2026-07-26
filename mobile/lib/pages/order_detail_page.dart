import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';
import '../l10n/app_localizations.dart';
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

/// Order detail page with action buttons based on status and role.
class OrderDetailPage extends StatefulWidget {
  final String orderId;
  final OrderService? orderService;

  const OrderDetailPage({super.key, required this.orderId, this.orderService});

  @override
  State<OrderDetailPage> createState() => _OrderDetailPageState();
}

class _OrderDetailPageState extends State<OrderDetailPage> {
  late final OrderService _orderService;
  OrderDetail? _order;
  bool _loading = true;
  String? _error;
  bool _acting = false;
  bool _autoDelist = true;
  late String _confirmIdempotencyKey;

  @override
  void initState() {
    super.initState();
    _orderService = widget.orderService ?? context.read<OrderService>();
    _confirmIdempotencyKey = const Uuid().v4();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final data = await _orderService.getOrder(widget.orderId);
      if (mounted) {
        setState(() {
          _order = OrderDetail.fromJson(data);
          _autoDelist = _order?.autoDelist ?? true;
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

  Future<void> _doAction(Future<void> Function() action) async {
    if (_acting) return;
    setState(() => _acting = true);
    try {
      await action();
      if (mounted) _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '${AppLocalizations.of(context)?.operationFailed ?? "Failed"}: $e',
            ),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _acting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(title: Text(l.orderDetail)),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    final l = AppLocalizations.of(context)!;
    if (_loading) return const Center(child: CircularProgressIndicator());

    if (_error != null) {
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

    final order = _order!;
    return Column(
      children: [
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(AppTheme.sp16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Status card
                _StatusCard(order: order),
                const SizedBox(height: 16),

                // Listing info
                _SectionCard(
                  title: l.listingDetail,
                  children: [
                    _InfoRow(label: l.title, value: order.listingTitle),
                    _InfoRow(
                      label: l.price,
                      value: '¥${order.finalPriceCny.toStringAsFixed(2)}',
                      valueColor: AppTheme.primary,
                      isBold: true,
                    ),
                  ],
                ),
                const SizedBox(height: 16),

                // Parties info
                _SectionCard(
                  title: l.dealParties,
                  children: [
                    _InfoRow(
                      label: l.buyer,
                      value:
                          '${order.buyerUsername} (${order.buyerId.substring(0, 8)}...)',
                    ),
                    _InfoRow(
                      label: l.owner,
                      value:
                          '${order.sellerUsername} (${order.sellerId.substring(0, 8)}...)',
                    ),
                    _InfoRow(label: '${l.orderId}:', value: order.id),
                  ],
                ),
                const SizedBox(height: 16),

                // Timeline
                _SectionCard(
                  title: l.dealTimeline,
                  children: [
                    _TimelineRow(
                      label: l.dealIntentCreated,
                      time: order.createdAt,
                      done: true,
                    ),
                    if (order.confirmedAt != null)
                      _TimelineRow(
                        label: l.sellerConfirmedDeal,
                        time: order.confirmedAt!,
                        done: true,
                      ),
                    if (order.autoDelistedAt != null)
                      _TimelineRow(
                        label: l.itemAutoDelisted,
                        time: order.autoDelistedAt!,
                        done: true,
                      ),
                    if (order.cancelledAt != null)
                      _TimelineRow(
                        label: l.cancel,
                        time: order.cancelledAt!,
                        done: true,
                      ),
                    if (order.cancellationReason != null &&
                        order.cancellationReason!.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(
                          '${l.cancel}: ${order.cancellationReason}',
                          style: const TextStyle(
                            color: AppTheme.error,
                            fontSize: 13,
                          ),
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),

        // Action buttons
        _buildActions(order),
      ],
    );
  }

  Widget _buildActions(OrderDetail order) {
    if (_acting) {
      return const SizedBox(
        height: 64,
        child: Center(child: CircularProgressIndicator()),
      );
    }

    final l = AppLocalizations.of(context)!;
    final actions = <Widget>[];

    if (order.canConfirm) {
      actions.add(
        Expanded(
          child: ElevatedButton(
            onPressed: () => _doAction(
              () => _orderService.confirmOrder(
                order.id,
                autoDelist: _autoDelist,
                idempotencyKey: _confirmIdempotencyKey,
              ),
            ),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.primary,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 14),
            ),
            child: Text(l.confirmOfflineDeal),
          ),
        ),
      );
    }

    if (order.canCancel) {
      if (actions.isNotEmpty) actions.add(const SizedBox(width: 12));
      actions.add(
        Expanded(
          child: OutlinedButton(
            onPressed: () => _showCancelDialog(order),
            style: OutlinedButton.styleFrom(
              foregroundColor: AppTheme.error,
              side: const BorderSide(color: AppTheme.error),
              padding: const EdgeInsets.symmetric(vertical: 14),
            ),
            child: Text(l.cancel),
          ),
        ),
      );
    }

    if (actions.isEmpty) return const SizedBox.shrink();

    return Container(
      padding: const EdgeInsets.all(AppTheme.sp16),
      decoration: BoxDecoration(
        color: Theme.of(context).cardTheme.color,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 10,
            offset: const Offset(0, -4),
          ),
        ],
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (order.canChooseAutoDelist)
              SwitchListTile.adaptive(
                contentPadding: EdgeInsets.zero,
                value: _autoDelist,
                onChanged: _acting
                    ? null
                    : (value) => setState(() {
                        _autoDelist = value;
                        _confirmIdempotencyKey = const Uuid().v4();
                      }),
                title: Text(l.autoDelistAfterConfirm),
                subtitle: Text(l.autoDelistAfterConfirmSubtitle),
              ),
            Row(children: actions),
          ],
        ),
      ),
    );
  }

  Future<void> _showCancelDialog(OrderDetail order) async {
    final l = AppLocalizations.of(context)!;
    final reasonController = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l.cancel),
        content: TextField(
          controller: reasonController,
          decoration: InputDecoration(labelText: l.reason, hintText: l.cancel),
          maxLines: 2,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(l.cancel),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(backgroundColor: AppTheme.error),
            child: Text(l.confirm),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await _doAction(
        () => _orderService.cancelOrder(
          order.id,
          reason: reasonController.text.isEmpty ? null : reasonController.text,
        ),
      );
    }
  }
}

class _StatusCard extends StatelessWidget {
  final OrderDetail order;
  const _StatusCard({required this.order});

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    return Card(
      color: order.statusColor.withValues(alpha: 0.1),
      child: Padding(
        padding: const EdgeInsets.all(AppTheme.sp16),
        child: Row(
          children: [
            Icon(_statusIcon(order.status), color: order.statusColor, size: 32),
            const SizedBox(width: 12),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _localizedOrderStatus(l, order.status),
                  style: TextStyle(
                    color: order.statusColor,
                    fontWeight: FontWeight.bold,
                    fontSize: 18,
                  ),
                ),
                Text(
                  _statusHint(context, order.status),
                  style: TextStyle(
                    color: order.statusColor.withValues(alpha: 0.8),
                    fontSize: 13,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  IconData _statusIcon(String status) {
    switch (status) {
      case 'pending':
      case 'intent_pending':
        return Icons.hourglass_empty;
      case 'paid':
      case 'shipped':
      case 'completed':
      case 'confirmed':
        return Icons.check_circle_outline;
      case 'cancelled':
        return Icons.cancel_outlined;
      default:
        return Icons.help_outline;
    }
  }

  String _statusHint(BuildContext context, String status) {
    switch (status) {
      case 'pending':
      case 'intent_pending':
        return AppLocalizations.of(context)!.awaitingSellerConfirm;
      case 'paid':
      case 'shipped':
      case 'completed':
      case 'confirmed':
        return AppLocalizations.of(context)!.dealConfirmed;
      case 'cancelled':
        return AppLocalizations.of(context)!.dealCancelled;
      default:
        return '';
    }
  }
}

class _SectionCard extends StatelessWidget {
  final String title;
  final List<Widget> children;

  const _SectionCard({required this.title, required this.children});

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(AppTheme.sp16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: const TextStyle(
                fontWeight: FontWeight.w600,
                fontSize: 14,
                color: AppTheme.textSecondary,
              ),
            ),
            const SizedBox(height: 12),
            ...children,
          ],
        ),
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  final String label;
  final String value;
  final Color? valueColor;
  final bool isBold;

  const _InfoRow({
    required this.label,
    required this.value,
    this.valueColor,
    this.isBold = false,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 80,
            child: Text(
              label,
              style: const TextStyle(
                color: AppTheme.textSecondary,
                fontSize: 13,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                color: valueColor ?? (isBold ? AppTheme.primary : null),
                fontSize: 13,
                fontWeight: isBold ? FontWeight.bold : FontWeight.normal,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _TimelineRow extends StatelessWidget {
  final String label;
  final String time;
  final bool done;

  const _TimelineRow({
    required this.label,
    required this.time,
    required this.done,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Icon(
            done ? Icons.check_circle : Icons.circle_outlined,
            size: 16,
            color: done ? AppTheme.primary : AppTheme.textSecondary,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                fontSize: 13,
                color: done ? null : AppTheme.textSecondary,
              ),
            ),
          ),
          Text(
            _formatDate(time),
            style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary),
          ),
        ],
      ),
    );
  }

  String _formatDate(String t) {
    try {
      return t.substring(0, 16).replaceAll('T', ' ');
    } catch (_) {
      return t;
    }
  }
}
