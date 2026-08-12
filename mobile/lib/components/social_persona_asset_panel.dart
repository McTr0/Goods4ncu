import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../models/models.dart';
import '../theme/app_theme.dart';

/// Owner-only controls for reviewed SocialPersona assets.
///
/// The panel intentionally renders lifecycle facts (uploading, review,
/// active, revoked) instead of inferring anything from image loading. An
/// asset becomes public only after the server has verified and approved it;
/// selecting it still requires an explicit owner action.
class SocialPersonaAssetPanel extends StatelessWidget {
  const SocialPersonaAssetPanel({
    super.key,
    required this.assets,
    required this.onAdd,
    required this.onSelect,
    required this.onComplete,
    required this.onRevoke,
    this.busy = false,
  });

  final List<SocialPersonaAsset> assets;
  final VoidCallback onAdd;
  final ValueChanged<SocialPersonaAsset> onSelect;
  final ValueChanged<SocialPersonaAsset> onComplete;
  final ValueChanged<SocialPersonaAsset> onRevoke;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(AppTheme.sp16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    l.socialPersonaAssetsTitle,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                OutlinedButton.icon(
                  onPressed: busy ? null : onAdd,
                  icon: const Icon(Icons.add_photo_alternate_outlined),
                  label: Text(l.socialPersonaAssetAdd),
                ),
              ],
            ),
            const SizedBox(height: AppTheme.sp4),
            Text(
              l.socialPersonaAssetsDescription,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: AppTheme.textSecondary),
            ),
            if (assets.isEmpty) ...[
              const SizedBox(height: AppTheme.sp12),
              Text(
                l.socialPersonaAssetsEmpty,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ] else ...[
              const SizedBox(height: AppTheme.sp12),
              ...assets.map(
                (asset) => Padding(
                  padding: const EdgeInsets.only(bottom: AppTheme.sp8),
                  child: _AssetRow(
                    asset: asset,
                    busy: busy,
                    onSelect: () => onSelect(asset),
                    onComplete: () => onComplete(asset),
                    onRevoke: () => onRevoke(asset),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _AssetRow extends StatelessWidget {
  const _AssetRow({
    required this.asset,
    required this.busy,
    required this.onSelect,
    required this.onComplete,
    required this.onRevoke,
  });

  final SocialPersonaAsset asset;
  final bool busy;
  final VoidCallback onSelect;
  final VoidCallback onComplete;
  final VoidCallback onRevoke;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final ready = asset.isReady;
    final status = _statusLabel(l, asset);
    final statusColor = ready
        ? AppTheme.success
        : asset.status == 'rejected'
        ? AppTheme.error
        : AppTheme.textSecondary;
    final label = asset.assetType == 'photo_stylized'
        ? l.socialPersonaAssetPhotoStylized
        : l.socialPersonaAssetIllustration;

    return DecoratedBox(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(AppTheme.radiusSm),
      ),
      child: Padding(
        padding: const EdgeInsets.all(AppTheme.sp8),
        child: Row(
          children: [
            Icon(
              ready ? Icons.image_outlined : Icons.hourglass_bottom_outlined,
              color: statusColor,
            ),
            const SizedBox(width: AppTheme.sp8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    status,
                    style: TextStyle(color: statusColor, fontSize: 12),
                  ),
                  if (asset.rejectReason case final reason?
                      when reason.trim().isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      reason,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: AppTheme.error, fontSize: 12),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: AppTheme.sp4),
            Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (ready)
                  TextButton(
                    onPressed: busy ? null : onSelect,
                    child: Text(l.socialPersonaAssetUse),
                  ),
                if (asset.status == 'pending_upload' ||
                    asset.status == 'pending_review')
                  TextButton(
                    onPressed: busy ? null : onComplete,
                    child: Text(l.socialPersonaAssetRetry),
                  ),
                if (asset.status != 'deleted' && asset.status != 'revoked')
                  IconButton(
                    onPressed: busy ? null : onRevoke,
                    tooltip: l.socialPersonaAssetRevoke,
                    icon: const Icon(Icons.delete_outline),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  String _statusLabel(AppLocalizations l, SocialPersonaAsset asset) {
    return switch (asset.status) {
      'pending_upload' => l.socialPersonaAssetPendingUpload,
      'pending_review' => l.socialPersonaAssetPendingReview,
      'active'
          when asset.moderationStatus == 'approved' ||
              asset.moderationStatus == 'not_required' =>
        l.socialPersonaAssetReady,
      'rejected' => l.socialPersonaAssetRejected,
      'revoked' => l.socialPersonaAssetRevoked,
      'deleted' => l.socialPersonaAssetDeleted,
      _ => l.socialPersonaAssetPendingReview,
    };
  }
}
