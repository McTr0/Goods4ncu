import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../models/models.dart';
import '../theme/app_theme.dart';

/// A reusable view of explicit, human-submitted recommendations for a wanted
/// listing.
///
/// The parent owns loading and mutation state. Keeping row busy state outside
/// this widget lets a detail page or inbox update its canonical response list
/// only after the server wins the pending-state transition.
class WantedResponseSection extends StatelessWidget {
  const WantedResponseSection({
    super.key,
    required this.role,
    required this.responses,
    this.isLoading = false,
    this.errorMessage,
    this.onRetry,
    this.busyResponseIds = const <String>{},
    this.onOpenOffer,
    this.onAccept,
    this.onDismiss,
    this.onWithdraw,
    this.title,
  });

  final WantedResponseRole role;
  final List<WantedResponse> responses;
  final bool isLoading;
  final String? errorMessage;
  final VoidCallback? onRetry;
  final Set<String> busyResponseIds;
  final ValueChanged<WantedResponse>? onOpenOffer;
  final ValueChanged<WantedResponse>? onAccept;
  final ValueChanged<WantedResponse>? onDismiss;
  final ValueChanged<WantedResponse>? onWithdraw;
  final String? title;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final resolvedTitle =
        title ??
        (role == WantedResponseRole.requester
            ? l.wantedResponsesReceivedTitle
            : l.wantedResponsesSentTitle);

    return Column(
      key: const ValueKey('wanted-response-section'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(
              role == WantedResponseRole.requester
                  ? Icons.move_to_inbox_outlined
                  : Icons.outbox_outlined,
              color: Theme.of(context).colorScheme.primary,
            ),
            const SizedBox(width: AppTheme.sp8),
            Expanded(
              child: Text(
                resolvedTitle,
                style: Theme.of(
                  context,
                ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w900),
              ),
            ),
            if (isLoading && responses.isNotEmpty)
              const SizedBox.square(
                dimension: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
          ],
        ),
        const SizedBox(height: AppTheme.sp12),
        if (isLoading && responses.isEmpty)
          const _SectionLoading()
        else if (errorMessage != null && responses.isEmpty)
          _SectionError(
            message: errorMessage!.trim().isEmpty
                ? l.wantedResponseLoadFailed
                : errorMessage!,
            onRetry: onRetry,
          )
        else ...[
          if (errorMessage != null)
            Padding(
              padding: const EdgeInsets.only(bottom: AppTheme.sp12),
              child: _SectionError(
                message: errorMessage!.trim().isEmpty
                    ? l.wantedResponseLoadFailed
                    : errorMessage!,
                onRetry: onRetry,
                compact: true,
              ),
            ),
          if (responses.isEmpty)
            _SectionEmpty(
              message: role == WantedResponseRole.requester
                  ? l.wantedResponsesReceivedEmpty
                  : l.wantedResponsesSentEmpty,
            )
          else
            ...responses.map(
              (response) => Padding(
                padding: const EdgeInsets.only(bottom: AppTheme.sp12),
                child: _WantedResponseCard(
                  response: response,
                  role: role,
                  busy: busyResponseIds.contains(response.id),
                  onOpenOffer: onOpenOffer,
                  onAccept: onAccept,
                  onDismiss: onDismiss,
                  onWithdraw: onWithdraw,
                ),
              ),
            ),
        ],
      ],
    );
  }
}

class _WantedResponseCard extends StatelessWidget {
  const _WantedResponseCard({
    required this.response,
    required this.role,
    required this.busy,
    required this.onOpenOffer,
    required this.onAccept,
    required this.onDismiss,
    required this.onWithdraw,
  });

  final WantedResponse response;
  final WantedResponseRole role;
  final bool busy;
  final ValueChanged<WantedResponse>? onOpenOffer;
  final ValueChanged<WantedResponse>? onAccept;
  final ValueChanged<WantedResponse>? onDismiss;
  final ValueChanged<WantedResponse>? onWithdraw;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final statusLabel = _responseStatusLabel(l, response.status);
    final offerTitle = response.offerTitle.isNotEmpty
        ? response.offerTitle
        : response.offerListingId;
    final wantedTitle = response.wantedTitle.isNotEmpty
        ? response.wantedTitle
        : response.wantedListingId;
    final canOpenOffer =
        onOpenOffer != null &&
        response.offerListingId.isNotEmpty &&
        response.offerStatus != 'deleted';

    return Card(
      key: ValueKey('wanted-response-${response.id}'),
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
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
                    l.wantedResponseOfferContext(
                      offerTitle,
                      _listingStatusLabel(l, response.offerStatus),
                    ),
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
                const SizedBox(width: AppTheme.sp8),
                _ResponseStatusChip(
                  status: response.status,
                  label: statusLabel,
                ),
              ],
            ),
            const SizedBox(height: AppTheme.sp8),
            Text(
              l.wantedResponseWantedContext(
                wantedTitle,
                _listingStatusLabel(l, response.wantedStatus),
              ),
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                fontWeight: FontWeight.w600,
              ),
            ),
            if (response.message != null) ...[
              const SizedBox(height: AppTheme.sp12),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(AppTheme.sp12),
                decoration: BoxDecoration(
                  color: Theme.of(
                    context,
                  ).colorScheme.surfaceContainerHighest.withValues(alpha: 0.55),
                  borderRadius: BorderRadius.circular(AppTheme.radiusMd),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      l.wantedResponseMessageLabel,
                      style: Theme.of(context).textTheme.labelMedium?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: AppTheme.sp4),
                    Text(response.message!),
                  ],
                ),
              ),
            ],
            if (_hasActions(canOpenOffer)) ...[
              const SizedBox(height: AppTheme.sp12),
              Wrap(
                spacing: AppTheme.sp8,
                runSpacing: AppTheme.sp8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  if (canOpenOffer)
                    TextButton.icon(
                      key: ValueKey(
                        'wanted-response-open-offer-${response.id}',
                      ),
                      onPressed: busy
                          ? null
                          : () => onOpenOffer!.call(response),
                      icon: const Icon(Icons.open_in_new, size: 18),
                      label: Text(l.wantedResponseOpenOfferAction),
                    ),
                  if (response.isPending &&
                      role == WantedResponseRole.requester &&
                      onAccept != null)
                    FilledButton.tonalIcon(
                      key: ValueKey('wanted-response-accept-${response.id}'),
                      onPressed: busy ? null : () => onAccept!.call(response),
                      icon: const Icon(Icons.check_rounded, size: 18),
                      label: Text(l.wantedResponseAcceptAction),
                    ),
                  if (response.isPending &&
                      role == WantedResponseRole.requester &&
                      onDismiss != null)
                    OutlinedButton.icon(
                      key: ValueKey('wanted-response-dismiss-${response.id}'),
                      onPressed: busy ? null : () => onDismiss!.call(response),
                      icon: const Icon(Icons.close_rounded, size: 18),
                      label: Text(l.wantedResponseDismissAction),
                    ),
                  if (response.isPending &&
                      role == WantedResponseRole.responder &&
                      onWithdraw != null)
                    OutlinedButton.icon(
                      key: ValueKey('wanted-response-withdraw-${response.id}'),
                      onPressed: busy ? null : () => onWithdraw!.call(response),
                      icon: const Icon(Icons.undo_rounded, size: 18),
                      label: Text(l.wantedResponseWithdrawAction),
                    ),
                  if (busy)
                    SizedBox.square(
                      key: ValueKey('wanted-response-row-busy-${response.id}'),
                      dimension: 20,
                      child: const CircularProgressIndicator(strokeWidth: 2),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  bool _hasActions(bool canOpenOffer) {
    if (canOpenOffer) return true;
    if (!response.isPending) return false;
    return switch (role) {
      WantedResponseRole.requester => onAccept != null || onDismiss != null,
      WantedResponseRole.responder => onWithdraw != null,
    };
  }
}

class _ResponseStatusChip extends StatelessWidget {
  const _ResponseStatusChip({required this.status, required this.label});

  final String status;
  final String label;

  @override
  Widget build(BuildContext context) {
    final color = switch (status) {
      'accepted' => AppTheme.success,
      'dismissed' => Theme.of(context).colorScheme.error,
      'withdrawn' => Theme.of(context).colorScheme.outline,
      _ => AppTheme.warning,
    };
    return Semantics(
      label: label,
      excludeSemantics: true,
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: AppTheme.sp12,
          vertical: AppTheme.sp6,
        ),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: color.withValues(alpha: 0.24)),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: color,
            fontSize: 12,
            fontWeight: FontWeight.w800,
          ),
        ),
      ),
    );
  }
}

class _SectionLoading extends StatelessWidget {
  const _SectionLoading();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(AppTheme.sp24),
        child: CircularProgressIndicator(strokeWidth: 2),
      ),
    );
  }
}

class _SectionEmpty extends StatelessWidget {
  const _SectionEmpty({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppTheme.sp16),
      decoration: BoxDecoration(
        color: Theme.of(
          context,
        ).colorScheme.surfaceContainerHighest.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(AppTheme.radiusMd),
      ),
      child: Text(
        message,
        style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
      ),
    );
  }
}

class _SectionError extends StatelessWidget {
  const _SectionError({
    required this.message,
    required this.onRetry,
    this.compact = false,
  });

  final String message;
  final VoidCallback? onRetry;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(compact ? AppTheme.sp12 : AppTheme.sp16),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(AppTheme.radiusMd),
      ),
      child: Wrap(
        spacing: AppTheme.sp8,
        runSpacing: AppTheme.sp8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text(
            message,
            style: TextStyle(
              color: Theme.of(context).colorScheme.onErrorContainer,
            ),
          ),
          if (onRetry != null)
            TextButton(
              key: const ValueKey('wanted-response-retry'),
              onPressed: onRetry,
              child: Text(AppLocalizations.of(context)!.retry),
            ),
        ],
      ),
    );
  }
}

String _responseStatusLabel(AppLocalizations l, String status) {
  return switch (status) {
    'pending' => l.wantedResponseStatusPending,
    'accepted' => l.wantedResponseStatusAccepted,
    'dismissed' => l.wantedResponseStatusDismissed,
    'withdrawn' => l.wantedResponseStatusWithdrawn,
    _ => l.wantedResponseStatusUnknown,
  };
}

String _listingStatusLabel(AppLocalizations l, String status) {
  return switch (status) {
    'active' => l.wantedResponseListingStatusActive,
    'fulfilled' => l.wantedResponseListingStatusFulfilled,
    'sold' => l.wantedResponseListingStatusSold,
    'deleted' => l.wantedResponseListingStatusDeleted,
    _ => l.wantedResponseListingStatusUnknown,
  };
}
