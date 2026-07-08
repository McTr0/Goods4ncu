import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';
import '../theme/app_theme.dart';

/// Offline deal badge — reminds users the platform does not escrow funds.
class EscrowBadge extends StatelessWidget {
  /// Show compact (icon + amount) or full (icon + title + amount + explanation).
  final bool compact;
  final double? amountCny;

  const EscrowBadge({super.key, this.compact = false, this.amountCny});

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    if (compact) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            Icons.handshake_outlined,
            size: 14,
            color: AppTheme.success,
          ),
          if (amountCny != null) ...[
            const SizedBox(width: 4),
            Text(
              '¥${amountCny!.toStringAsFixed(2)}',
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: AppTheme.success,
              ),
            ),
          ],
        ],
      );
    }

    return Container(
      padding: const EdgeInsets.all(AppTheme.sp12),
      decoration: BoxDecoration(
        color: AppTheme.success.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(AppTheme.radiusSm),
        border: Border.all(color: AppTheme.success.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.handshake_outlined,
                size: 18,
                color: AppTheme.success,
              ),
              const SizedBox(width: 8),
              Text(
                l.tradeProtection,
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 14,
                  color: AppTheme.success,
                ),
              ),
            ],
          ),
          if (amountCny != null) ...[
            const SizedBox(height: 8),
            Text(
              '¥${amountCny!.toStringAsFixed(2)}',
              style: const TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
                color: AppTheme.success,
              ),
            ),
          ],
          const SizedBox(height: 4),
          Text(
            l.tradeProtectionSubtitle,
            style: TextStyle(
              fontSize: 12,
              color: AppTheme.textSecondary.withValues(alpha: 0.9),
            ),
          ),
        ],
      ),
    );
  }
}
