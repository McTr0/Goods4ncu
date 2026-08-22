import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/app_localizations.dart';
import '../../models/models.dart';
import '../../services/api_service.dart';

/// Negotiation action card shown in the chat for HITL requests.
class NegotiationCard extends StatelessWidget {
  final HitlRequest request;
  final String currentUserId;
  final ApiService apiService;
  final VoidCallback onUpdated;

  const NegotiationCard({
    super.key,
    required this.request,
    required this.currentUserId,
    required this.apiService,
    required this.onUpdated,
  });

  bool get isSeller => request.sellerId == currentUserId;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final isPending = request.status == 'pending';
    final isCountered = request.status == 'countered';

    if (isPending && isSeller) {
      return _SellerPendingCard(
        request: request,
        apiService: apiService,
        onUpdated: onUpdated,
      );
    }
    if (isCountered && !isSeller) {
      return _BuyerCounteredCard(
        request: request,
        apiService: apiService,
        onUpdated: onUpdated,
      );
    }
    if (request.isExpired) {
      return _StatusBadge(
        icon: Icons.timer_off,
        label: l.negotiationExpired,
        color: Colors.grey,
      );
    }
    if (request.status == 'approved') {
      return _StatusBadge(
        icon: Icons.check_circle,
        label: l.sellerAcceptedDealComplete,
        color: Colors.green,
      );
    }
    if (request.status == 'rejected' || request.status == 'buyer_rejected') {
      return _StatusBadge(
        icon: Icons.cancel,
        label: l.negotiationRejected,
        color: Colors.red,
      );
    }
    return const SizedBox.shrink();
  }
}

class _SellerPendingCard extends StatefulWidget {
  final HitlRequest request;
  final ApiService apiService;
  final VoidCallback onUpdated;

  const _SellerPendingCard({
    required this.request,
    required this.apiService,
    required this.onUpdated,
  });

  @override
  State<_SellerPendingCard> createState() => _SellerPendingCardState();
}

class _SellerPendingCardState extends State<_SellerPendingCard> {
  bool _isLoading = false;
  final _counterController = TextEditingController();

  @override
  void dispose() {
    _counterController.dispose();
    super.dispose();
  }

  Future<void> _approve() async {
    final l = AppLocalizations.of(context)!;
    setState(() => _isLoading = true);
    try {
      await widget.apiService.respondNegotiation(
        widget.request.id,
        action: 'approve',
      );
      widget.onUpdated();
    } catch (e) {
      _showError(l.operationFailed(e.toString()));
    } finally {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _reject() async {
    final l = AppLocalizations.of(context)!;
    setState(() => _isLoading = true);
    try {
      await widget.apiService.respondNegotiation(
        widget.request.id,
        action: 'reject',
      );
      widget.onUpdated();
    } catch (e) {
      _showError(l.operationFailed(e.toString()));
    } finally {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _counter() async {
    final l = AppLocalizations.of(context)!;
    final price = double.tryParse(_counterController.text.trim());
    if (price == null || price <= 0) {
      _showError(l.enterValidCounterAmount);
      return;
    }
    setState(() => _isLoading = true);
    try {
      await widget.apiService.respondNegotiation(
        widget.request.id,
        action: 'counter',
        counterPrice: price,
      );
      widget.onUpdated();
    } catch (e) {
      _showError(l.operationFailed(e.toString()));
    } finally {
      setState(() => _isLoading = false);
    }
  }

  void _showError(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.handshake, color: Color(0xFF6366F1), size: 20),
                const SizedBox(width: 8),
                Text(
                  l.buyerInitiatedNegotiation,
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: Colors.grey[800],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              l.offerPriceLine(widget.request.proposedPrice.toStringAsFixed(2)),
            ),
            if (widget.request.reason.isNotEmpty)
              Text(l.reasonLine(widget.request.reason)),
            if (widget.request.expiresAt != null)
              Text(
                l.expiresAtLine(_formatExpiry(widget.request.expiresAt!)),
                style: const TextStyle(fontSize: 12, color: Colors.grey),
              ),
            const SizedBox(height: 12),
            if (_isLoading)
              const Center(child: CircularProgressIndicator(strokeWidth: 2))
            else ...[
              Row(
                children: [
                  Expanded(
                    child: ElevatedButton.icon(
                      onPressed: _approve,
                      icon: const Icon(Icons.check, size: 16),
                      label: Text(l.acceptAction),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.green,
                        foregroundColor: Colors.white,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _reject,
                      icon: const Icon(Icons.close, size: 16),
                      label: Text(l.rejectAction),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.red,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _counterController,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      inputFormatters: [
                        FilteringTextInputFormatter.allow(
                          RegExp(r'^\d*\.?\d{0,2}'),
                        ),
                      ],
                      decoration: InputDecoration(
                        hintText: l.counterOfferAmount,
                        isDense: true,
                        border: const OutlineInputBorder(),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 8,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton(
                    onPressed: _counter,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.orange,
                      foregroundColor: Colors.white,
                    ),
                    child: Text(l.counterOfferAction),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  String _formatExpiry(String iso) {
    try {
      final dt = DateTime.parse(iso);
      return '${dt.month}/${dt.day} ${dt.hour}:${dt.minute.toString().padLeft(2, '0')}';
    } catch (_) {
      return iso;
    }
  }
}

class _BuyerCounteredCard extends StatefulWidget {
  final HitlRequest request;
  final ApiService apiService;
  final VoidCallback onUpdated;

  const _BuyerCounteredCard({
    required this.request,
    required this.apiService,
    required this.onUpdated,
  });

  @override
  State<_BuyerCounteredCard> createState() => _BuyerCounteredCardState();
}

class _BuyerCounteredCardState extends State<_BuyerCounteredCard> {
  bool _isLoading = false;

  Future<void> _accept() async {
    final l = AppLocalizations.of(context)!;
    setState(() => _isLoading = true);
    try {
      await widget.apiService.acceptCounterNegotiation(widget.request.id);
      widget.onUpdated();
    } catch (e) {
      _showError(l.operationFailed(e.toString()));
    } finally {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _reject() async {
    final l = AppLocalizations.of(context)!;
    setState(() => _isLoading = true);
    try {
      await widget.apiService.rejectCounterNegotiation(widget.request.id);
      widget.onUpdated();
    } catch (e) {
      _showError(l.operationFailed(e.toString()));
    } finally {
      setState(() => _isLoading = false);
    }
  }

  void _showError(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      color: Colors.orange.shade50,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.countertops, color: Colors.orange, size: 20),
                const SizedBox(width: 8),
                Text(
                  l.sellerCounterPriceLine(
                    widget.request.counterPrice?.toStringAsFixed(2) ?? '?',
                  ),
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              l.yourOriginalOfferLine(
                widget.request.proposedPrice.toStringAsFixed(2),
              ),
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            ),
            const SizedBox(height: 12),
            if (_isLoading)
              const Center(child: CircularProgressIndicator(strokeWidth: 2))
            else
              Row(
                children: [
                  Expanded(
                    child: ElevatedButton.icon(
                      onPressed: _accept,
                      icon: const Icon(Icons.check, size: 16),
                      label: Text(l.acceptCounterAction),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.green,
                        foregroundColor: Colors.white,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _reject,
                      icon: const Icon(Icons.close, size: 16),
                      label: Text(l.rejectAction),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.red,
                      ),
                    ),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

class _StatusBadge extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;

  const _StatusBadge({
    required this.icon,
    required this.label,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: color, size: 16),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(color: color, fontWeight: FontWeight.w500),
          ),
        ],
      ),
    );
  }
}
