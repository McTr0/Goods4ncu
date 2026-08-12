import 'package:flutter/material.dart';

import 'social_persona_card.dart';
import '../l10n/app_localizations.dart';
import '../models/models.dart';
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
    this.otherPersona,
    this.selfPersona,
    this.latestEvent,
    this.isConnected = false,
    this.pinCount = 0,
    this.sharedObjectCount = 0,
    this.sharedObjects = const [],
    this.hasRecentConnection = false,
    this.compact = false,
  });

  final String otherName;
  final String? otherAvatarUrl;
  final SocialPersona? otherPersona;
  final SocialPersona? selfPersona;
  final String? latestEvent;
  final bool isConnected;
  final int pinCount;
  final int sharedObjectCount;
  final List<RelationshipSpaceSharedObject> sharedObjects;
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
                    persona: otherPersona,
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
                    persona: selfPersona,
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
            if (sharedObjects.isNotEmpty) ...[
              const SizedBox(height: AppTheme.sp8),
              _SharedObjectRail(objects: sharedObjects),
            ],
          ],
        ),
      ),
    );
  }
}

class _SharedObjectRail extends StatelessWidget {
  const _SharedObjectRail({required this.objects});

  final List<RelationshipSpaceSharedObject> objects;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final visible = objects.take(4).toList(growable: false);
    final hiddenCount = objects.length - visible.length;
    return Semantics(
      container: true,
      label: l.relationshipSpaceSharedObjectsTitle,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.link_rounded,
                size: 15,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 5),
              Text(
                l.relationshipSpaceSharedObjectsTitle,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(width: 5),
              Flexible(
                child: Text(
                  l.relationshipSpaceSharedObjectsReadOnly,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                    fontSize: 10,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 5),
          Wrap(
            spacing: 5,
            runSpacing: 5,
            children: [
              for (final object in visible) _SharedObjectChip(object: object),
              if (hiddenCount > 0)
                _RailChip(
                  icon: Icons.more_horiz_rounded,
                  label: '+$hiddenCount',
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _SharedObjectChip extends StatelessWidget {
  const _SharedObjectChip({required this.object});

  final RelationshipSpaceSharedObject object;

  String _label(AppLocalizations l) {
    switch (object.kind) {
      case 'listing':
        return l.quoteListing;
      case 'order':
        return l.quoteOrder;
      case 'file':
        return l.relationshipSpaceObjectFile;
      case 'link':
        return l.relationshipSpaceObjectLink;
      default:
        return l.relationshipSpaceObjectReference;
    }
  }

  IconData _icon() {
    switch (object.kind) {
      case 'listing':
        return Icons.inventory_2_outlined;
      case 'order':
        return Icons.receipt_long_outlined;
      case 'file':
        return Icons.insert_drive_file_outlined;
      case 'link':
        return Icons.link_outlined;
      default:
        return Icons.bookmark_border_rounded;
    }
  }

  String _title() {
    final snapshot = object.snapshot;
    for (final key in const ['title', 'listing_title', 'filename', 'label']) {
      final value = snapshot[key]?.toString().trim();
      if (value != null && value.isNotEmpty) return value;
    }
    return object.refId;
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final label = _label(l);
    final title = _title();
    return Semantics(
      label: '$label: $title',
      child: Container(
        constraints: const BoxConstraints(maxWidth: 260),
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 5),
        decoration: BoxDecoration(
          color: Theme.of(
            context,
          ).colorScheme.secondaryContainer.withValues(alpha: .55),
          borderRadius: BorderRadius.circular(AppTheme.radiusXl),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(_icon(), size: 14),
            const SizedBox(width: 4),
            Flexible(
              child: Text(
                '$label · $title',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
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
    this.persona,
    required this.alignment,
    this.compact = false,
  });

  final String name;
  final String? imageUrl;
  final SocialPersona? persona;
  final CrossAxisAlignment alignment;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final trimmedName = name.trim();
    final fallback = trimmedName.isEmpty ? '?' : trimmedName.characters.first;
    final hasImage = imageUrl != null && imageUrl!.trim().isNotEmpty;
    final roleAvatar = persona == null
        ? null
        : SocialPersonaAvatar(
            persona: persona!,
            size: compact ? 24 : 160,
            semanticLabel: trimmedName.isEmpty ? null : trimmedName,
          );
    return Column(
      crossAxisAlignment: alignment,
      children: [
        roleAvatar ??
            Container(
              width: compact ? 36 : 48,
              height: compact ? 36 : 48,
              decoration: BoxDecoration(
                color: AppTheme.mint,
                borderRadius: BorderRadius.circular(AppTheme.radiusLg),
                border: Border.all(
                  color: AppTheme.primary.withValues(alpha: .18),
                ),
              ),
              clipBehavior: Clip.antiAlias,
              child: hasImage
                  ? Image.network(
                      imageUrl!,
                      fit: BoxFit.cover,
                      errorBuilder: (context, error, stackTrace) =>
                          _FallbackFace(
                            label: fallback,
                            foreground: AppTheme.primary,
                          ),
                    )
                  : _FallbackFace(
                      label: fallback,
                      foreground: AppTheme.primary,
                    ),
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
