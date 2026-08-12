import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../theme/app_theme.dart';

/// A small, deterministic projection of a one-to-one relationship.
///
/// This widget deliberately has no animation or presence subscription. The
/// only live fact it accepts is whether the current conversation is explicitly
/// connected; everything else is a user-facing projection of existing thread
/// history. It is therefore safe to use while the Relationship Space backend
/// is still being introduced behind the existing Thread/Conversation model.
class RelationshipSpacePreview extends StatelessWidget {
  const RelationshipSpacePreview({
    super.key,
    required this.otherName,
    this.otherAvatarUrl,
    this.latestEvent,
    this.isConnected = false,
    this.pinCount = 0,
    this.sharedObjectCount = 0,
    this.hasRecentConnection = false,
    this.compact = false,
  });

  final String otherName;
  final String? otherAvatarUrl;
  final String? latestEvent;
  final bool isConnected;
  final int pinCount;
  final int sharedObjectCount;
  final bool hasRecentConnection;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final scheme = Theme.of(context).colorScheme;
    final event = latestEvent?.trim();
    final stateLabel = isConnected
        ? l.relationshipSpaceConnected
        : l.relationshipSpaceAsync;

    return Semantics(
      container: true,
      label: l.relationshipSpaceTitle,
      child: Container(
        key: const Key('relationship-space-preview'),
        width: double.infinity,
        padding: EdgeInsets.all(compact ? AppTheme.sp8 : AppTheme.sp16),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerLowest,
          borderRadius: BorderRadius.circular(AppTheme.radiusLg),
          border: Border.all(color: scheme.outlineVariant),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.hub_outlined,
                  size: compact ? 18 : 20,
                  color: AppTheme.primary,
                ),
                const SizedBox(width: AppTheme.sp8),
                Expanded(
                  child: Text(
                    l.relationshipSpaceTitle,
                    style: TextStyle(
                      fontSize: compact ? 14 : 16,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
                _StatePill(label: stateLabel, isConnected: isConnected),
              ],
            ),
            SizedBox(height: compact ? AppTheme.sp8 : AppTheme.sp16),
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(
                  child: _PersonaAnchor(
                    name: otherName,
                    imageUrl: otherAvatarUrl,
                    alignment: CrossAxisAlignment.start,
                    compact: compact,
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: AppTheme.sp8),
                  child: Icon(
                    isConnected
                        ? Icons.compare_arrows_rounded
                        : Icons.more_horiz_rounded,
                    semanticLabel: isConnected
                        ? l.relationshipSpaceConnected
                        : l.relationshipSpaceTimeline,
                    color: isConnected
                        ? AppTheme.success
                        : scheme.onSurfaceVariant,
                  ),
                ),
                Expanded(
                  child: _PersonaAnchor(
                    name: l.relationshipSpaceMe,
                    alignment: CrossAxisAlignment.end,
                    compact: compact,
                  ),
                ),
              ],
            ),
            if (!compact) ...[
              const SizedBox(height: AppTheme.sp12),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.timeline_outlined,
                    size: 17,
                    color: scheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: AppTheme.sp8),
                  Expanded(
                    child: Text(
                      event == null || event.isEmpty
                          ? l.relationshipSpaceNoEvent
                          : event,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: scheme.onSurfaceVariant,
                        fontSize: 13,
                        height: 1.3,
                      ),
                    ),
                  ),
                ],
              ),
              if (pinCount > 0 ||
                  sharedObjectCount > 0 ||
                  hasRecentConnection) ...[
                const SizedBox(height: AppTheme.sp8),
                Wrap(
                  spacing: AppTheme.sp6,
                  runSpacing: AppTheme.sp6,
                  children: [
                    if (pinCount > 0)
                      _RailChip(
                        icon: Icons.push_pin_outlined,
                        label: l.relationshipSpacePinsCount(pinCount),
                      ),
                    if (sharedObjectCount > 0)
                      _RailChip(
                        icon: Icons.link_rounded,
                        label: l.relationshipSpaceObjectsCount(
                          sharedObjectCount,
                        ),
                      ),
                    if (hasRecentConnection)
                      _RailChip(
                        icon: Icons.history_rounded,
                        label: l.relationshipSpaceTimeline,
                      ),
                  ],
                ),
              ],
            ],
            if (compact &&
                (pinCount > 0 ||
                    sharedObjectCount > 0 ||
                    hasRecentConnection)) ...[
              const SizedBox(height: AppTheme.sp6),
              Wrap(
                spacing: AppTheme.sp4,
                runSpacing: AppTheme.sp4,
                children: [
                  if (pinCount > 0)
                    _RailChip(
                      icon: Icons.push_pin_outlined,
                      label: l.relationshipSpacePinsCount(pinCount),
                    ),
                  if (sharedObjectCount > 0)
                    _RailChip(
                      icon: Icons.link_rounded,
                      label: l.relationshipSpaceObjectsCount(sharedObjectCount),
                    ),
                  if (hasRecentConnection)
                    _RailChip(
                      icon: Icons.history_rounded,
                      label: l.relationshipSpaceTimeline,
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _RailChip extends StatelessWidget {
  const _RailChip({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(
        color: scheme.secondaryContainer.withValues(alpha: .55),
        borderRadius: BorderRadius.circular(AppTheme.radiusXl),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: scheme.onSecondaryContainer),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              color: scheme.onSecondaryContainer,
              fontSize: 11,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

class _PersonaAnchor extends StatelessWidget {
  const _PersonaAnchor({
    required this.name,
    this.imageUrl,
    required this.alignment,
    this.compact = false,
  });

  final String name;
  final String? imageUrl;
  final CrossAxisAlignment alignment;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final trimmedName = name.trim();
    final fallback = trimmedName.isEmpty ? '?' : trimmedName.characters.first;
    final hasImage = imageUrl != null && imageUrl!.trim().isNotEmpty;
    return Column(
      crossAxisAlignment: alignment,
      children: [
        Container(
          width: compact ? 36 : 48,
          height: compact ? 36 : 48,
          decoration: BoxDecoration(
            color: AppTheme.mint,
            borderRadius: BorderRadius.circular(AppTheme.radiusLg),
            border: Border.all(color: AppTheme.primary.withValues(alpha: .18)),
          ),
          clipBehavior: Clip.antiAlias,
          child: hasImage
              ? Image.network(
                  imageUrl!,
                  fit: BoxFit.cover,
                  errorBuilder: (context, error, stackTrace) => _FallbackFace(
                    label: fallback,
                    foreground: AppTheme.primary,
                  ),
                )
              : _FallbackFace(label: fallback, foreground: AppTheme.primary),
        ),
        SizedBox(height: compact ? AppTheme.sp2 : AppTheme.sp4),
        Text(
          trimmedName.isEmpty ? '?' : trimmedName,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: alignment == CrossAxisAlignment.end
              ? TextAlign.right
              : TextAlign.left,
          style: TextStyle(
            color: scheme.onSurface,
            fontSize: compact ? 11 : 12,
            fontWeight: FontWeight.w800,
          ),
        ),
      ],
    );
  }
}

class _FallbackFace extends StatelessWidget {
  const _FallbackFace({required this.label, required this.foreground});

  final String label;
  final Color foreground;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Text(
        label,
        semanticsLabel: label,
        style: TextStyle(
          color: foreground,
          fontSize: 22,
          fontWeight: FontWeight.w900,
        ),
      ),
    );
  }
}

class _StatePill extends StatelessWidget {
  const _StatePill({required this.label, required this.isConnected});

  final String label;
  final bool isConnected;

  @override
  Widget build(BuildContext context) {
    final color = isConnected ? AppTheme.success : AppTheme.primary;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppTheme.sp8,
        vertical: AppTheme.sp4,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: .1),
        borderRadius: BorderRadius.circular(AppTheme.radiusXl),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            isConnected ? Icons.circle : Icons.mail_outline_rounded,
            size: 10,
            color: color,
          ),
          const SizedBox(width: AppTheme.sp4),
          Text(
            label,
            style: TextStyle(
              color: color,
              fontSize: 11,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }
}
