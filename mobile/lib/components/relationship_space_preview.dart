import 'dart:async';

import 'package:flutter/material.dart';

import 'social_persona_renderer.dart';
import 'user_avatar.dart';
import '../l10n/app_localizations.dart';
import '../models/models.dart';
import '../theme/app_theme.dart';

/// A deterministic local projection of a one-to-one relationship space.
///
/// This widget deliberately has no presence subscriptions or background network calls.
/// Expand and collapse are purely local UI states. All shown facts derive
/// deterministically from [RelationshipSpace.events], [RelationshipSpace.pins],
/// [RelationshipSpace.sharedObjects], and [RelationshipSpace.recentConnection].
class RelationshipSpacePreview extends StatefulWidget {
  const RelationshipSpacePreview({
    super.key,
    required this.otherName,
    this.otherPersona,
    this.selfPersona,
    this.events = const [],
    this.pins = const [],
    this.pinCount = 0,
    this.sharedObjects = const [],
    this.sharedObjectCount = 0,
    this.recentConnection,
    this.hasRecentConnection = false,
    this.isConnected = false,
    this.initiallyExpanded = false,
    this.compact = false,
    this.showRecentRecords = true,
    this.stageMode = false,
    this.stageContent,
  });

  final String otherName;
  final SocialPersona? otherPersona;
  final SocialPersona? selfPersona;
  final List<RelationshipSpaceEvent> events;
  final List<RelationshipSpacePin> pins;
  final int pinCount;
  final List<RelationshipSpaceSharedObject> sharedObjects;
  final int sharedObjectCount;
  final RelationshipSpaceConnection? recentConnection;
  final bool hasRecentConnection;
  final bool isConnected;
  final bool initiallyExpanded;
  final bool compact;
  final bool showRecentRecords;
  final bool stageMode;
  final Widget? stageContent;

  @override
  State<RelationshipSpacePreview> createState() =>
      _RelationshipSpacePreviewState();
}

class _RelationshipSpacePreviewState extends State<RelationshipSpacePreview> {
  late bool _expanded;
  bool _pokeActive = false;
  Timer? _pokeTimer;

  @override
  void initState() {
    super.initState();
    _expanded = widget.initiallyExpanded;
  }

  void _toggleExpanded() {
    setState(() {
      _expanded = !_expanded;
    });
  }

  void _poke() {
    _pokeTimer?.cancel();
    setState(() => _pokeActive = true);
    _pokeTimer = Timer(const Duration(milliseconds: 700), () {
      if (mounted) setState(() => _pokeActive = false);
    });
    final l = AppLocalizations.of(context)!;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          duration: const Duration(milliseconds: 1400),
          content: Text(l.relationshipSpacePokeFeedback(widget.otherName)),
        ),
      );
  }

  @override
  void dispose() {
    _pokeTimer?.cancel();
    super.dispose();
  }

  static String _formatTimestamp(DateTime dt, {required bool chinese}) {
    final local = dt.toLocal();
    final m = local.month.toString().padLeft(2, '0');
    final d = local.day.toString().padLeft(2, '0');
    final h = local.hour.toString().padLeft(2, '0');
    final min = local.minute.toString().padLeft(2, '0');
    return chinese ? '$m月$d日 $h:$min' : '$m-$d $h:$min';
  }

  static String formatEventText(
    RelationshipSpaceEvent event,
    AppLocalizations l,
  ) {
    final eventType = event.eventType.toLowerCase().trim();
    if (eventType == 'message.sent' || eventType == 'message_sent') {
      return l.relationshipSpaceEventSentMessage;
    }
    if (eventType == 'message.opening' || eventType == 'message_opening') {
      return l.relationshipSpaceEventOpeningMessage;
    }
    if (eventType == 'connection.started' ||
        eventType == 'conversation_acknowledged' ||
        eventType == 'conversation_acknowledged_by_message' ||
        eventType == 'mutual_open') {
      return l.relationshipSpaceEventConnectionStarted;
    }
    if (eventType == 'connection.ended' ||
        eventType == 'conversation_closed' ||
        eventType == 'conversation_expired') {
      return l.relationshipSpaceEventConnectionEnded;
    }
    if (eventType == 'connection.accepted' ||
        eventType == 'conversation_accepted') {
      return l.relationshipSpaceEventConnectionAccepted;
    }
    if (eventType == 'connection.declined' ||
        eventType == 'conversation_declined') {
      return l.relationshipSpaceEventConnectionDeclined;
    }
    if (eventType == 'conversation.created' ||
        eventType == 'conversation_created') {
      return l.relationshipSpaceEventConversationCreated;
    }
    if (eventType.contains('pin') ||
        eventType.startsWith('memory.pinned') ||
        eventType.startsWith('relationship.pinned')) {
      return l.relationshipSpaceEventPinChanged;
    }
    if (eventType.startsWith('acknowledgement')) {
      return l.relationshipSpaceEventAcknowledgementChanged;
    }
    if (eventType.startsWith('shared_object') ||
        eventType.startsWith('sharedobject') ||
        eventType == 'shared_object_changed') {
      return l.relationshipSpaceEventSharedObjectChanged;
    }
    return l.relationshipSpaceEventDefault;
  }

  static IconData _eventIcon(RelationshipSpaceEvent event) {
    final eventType = event.eventType.toLowerCase().trim();
    if (eventType.startsWith('connection')) {
      if (eventType.contains('ended') || eventType.contains('declined')) {
        return Icons.call_end_outlined;
      }
      return Icons.compare_arrows_rounded;
    }
    if (eventType.contains('pin') ||
        eventType.startsWith('memory.pinned') ||
        eventType.startsWith('relationship.pinned')) {
      return Icons.push_pin_outlined;
    }
    if (eventType.startsWith('shared_object') ||
        eventType.startsWith('sharedobject') ||
        eventType == 'shared_object_changed') {
      return Icons.link_rounded;
    }
    if (eventType.startsWith('acknowledgement')) {
      return Icons.done_all_rounded;
    }
    return Icons.mail_outline_rounded;
  }

  /// Collapse technical projections that describe one user action into one
  /// recent record. The underlying deterministic events remain untouched.
  List<RelationshipSpaceEvent> _visibleEvents() {
    final conversationsWithMessages = widget.events
        .where((event) {
          final type = event.eventType.toLowerCase().trim();
          return type == 'message.sent' || type == 'message_sent';
        })
        .map((event) => event.conversationId)
        .toSet();
    return widget.events
        .where((event) {
          final type = event.eventType.toLowerCase().trim();
          final conversationHasMessage = conversationsWithMessages.contains(
            event.conversationId,
          );
          if (conversationHasMessage &&
              (type == 'message.opening' || type == 'message_opening')) {
            return false;
          }
          if (type == 'conversation.created' ||
              type == 'conversation_created') {
            return !conversationHasMessage;
          }
          return true;
        })
        .toList(growable: false);
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final scheme = Theme.of(context).colorScheme;
    final stateLabel = widget.isConnected
        ? l.relationshipSpaceConnected
        : l.relationshipSpaceAsync;

    final effectivePinCount = widget.pins.isNotEmpty
        ? widget.pins.length
        : widget.pinCount;
    final effectiveSharedObjectCount = widget.sharedObjects.isNotEmpty
        ? widget.sharedObjects.length
        : widget.sharedObjectCount;
    final effectiveHasRecentConnection =
        widget.recentConnection != null || widget.hasRecentConnection;
    final availableWidth = MediaQuery.sizeOf(context).width;
    final avatarSize = widget.compact
        ? 40.0
        : availableWidth < 600
        ? 88.0
        : 120.0;

    if (widget.stageMode) {
      return _buildStage(context, l, scheme, stateLabel);
    }

    return Semantics(
      container: true,
      label: l.relationshipSpaceTitle,
      child: Container(
        key: const Key('relationship-space-preview'),
        width: double.infinity,
        padding: EdgeInsets.all(widget.compact ? AppTheme.sp8 : AppTheme.sp16),
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
                  size: widget.compact ? 18 : 20,
                  color: AppTheme.primary,
                ),
                const SizedBox(width: AppTheme.sp8),
                Expanded(
                  child: Text(
                    l.relationshipSpaceTitle,
                    style: TextStyle(
                      fontSize: widget.compact ? 14 : 16,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
                _StatePill(label: stateLabel, isConnected: widget.isConnected),
                const SizedBox(width: AppTheme.sp4),
                IconButton(
                  key: const Key('relationship-space-expand-toggle'),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(
                    minWidth: 48,
                    minHeight: 48,
                  ),
                  iconSize: 20,
                  icon: Icon(
                    _expanded
                        ? Icons.keyboard_arrow_up_rounded
                        : Icons.keyboard_arrow_down_rounded,
                    color: scheme.onSurfaceVariant,
                  ),
                  tooltip: _expanded
                      ? l.relationshipSpaceCollapseAction
                      : l.relationshipSpaceExpandAction,
                  onPressed: _toggleExpanded,
                ),
              ],
            ),
            SizedBox(height: widget.compact ? AppTheme.sp8 : AppTheme.sp16),
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(
                  child: _PersonaAnchor(
                    name: widget.otherName,
                    persona: widget.otherPersona,
                    showPersona: true,
                    alignment: CrossAxisAlignment.start,
                    compact: widget.compact,
                    size: avatarSize,
                    motionCue: _pokeActive
                        ? AvatarMotionCue.pressed
                        : AvatarMotionCue.idle,
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: AppTheme.sp4),
                  child: TextButton.icon(
                    key: const Key('relationship-space-poke'),
                    onPressed: _poke,
                    icon: Icon(
                      Icons.touch_app_rounded,
                      size: widget.compact ? 16 : 20,
                    ),
                    label: Text(l.relationshipSpacePokeAction),
                    style: TextButton.styleFrom(
                      padding: EdgeInsets.symmetric(
                        horizontal: widget.compact ? 6 : 10,
                        vertical: 6,
                      ),
                      visualDensity: VisualDensity.compact,
                    ),
                  ),
                ),
                Expanded(
                  child: _PersonaAnchor(
                    name: l.relationshipSpaceMe,
                    persona: widget.selfPersona,
                    showPersona: true,
                    alignment: CrossAxisAlignment.end,
                    compact: widget.compact,
                    size: avatarSize,
                    motionCue: _pokeActive
                        ? AvatarMotionCue.selected
                        : AvatarMotionCue.idle,
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppTheme.sp12),
            _buildPriorityRail(
              context,
              l,
              scheme,
              effectivePinCount,
              effectiveSharedObjectCount,
              effectiveHasRecentConnection,
            ),
            if (widget.showRecentRecords) ...[
              const SizedBox(height: AppTheme.sp12),
              _buildRecentRecords(context, l, scheme),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildStage(
    BuildContext context,
    AppLocalizations l,
    ColorScheme scheme,
    String stateLabel,
  ) {
    return Semantics(
      container: true,
      label: l.relationshipSpaceTitle,
      child: Container(
        key: const Key('relationship-space-stage'),
        width: double.infinity,
        height: double.infinity,
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: scheme.surfaceContainerLowest,
          border: Border.all(color: scheme.outlineVariant),
          borderRadius: BorderRadius.circular(AppTheme.radiusLg),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              scheme.primaryContainer.withValues(alpha: 0.22),
              scheme.surfaceContainerLowest,
              scheme.tertiaryContainer.withValues(alpha: 0.18),
            ],
          ),
        ),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final isNarrow = constraints.maxWidth < 600;
            final avatarSize = isNarrow ? 104.0 : 148.0;
            final edge = isNarrow ? 16.0 : 24.0;
            final contentHorizontal = isNarrow ? 14.0 : avatarSize + edge + 28;
            final contentTop = isNarrow ? 204.0 : 126.0;
            final contentBottom = isNarrow ? 142.0 : 76.0;

            return Stack(
              children: [
                Positioned(
                  left: edge,
                  right: edge,
                  top: 14,
                  child: Row(
                    children: [
                      Icon(
                        Icons.hub_outlined,
                        size: 20,
                        color: AppTheme.primary,
                      ),
                      const SizedBox(width: AppTheme.sp8),
                      Expanded(
                        child: Text(
                          l.relationshipSpaceTitle,
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                      ),
                      _StatePill(
                        label: stateLabel,
                        isConnected: widget.isConnected,
                      ),
                    ],
                  ),
                ),
                Positioned(
                  left: edge,
                  top: 62,
                  child: _PersonaAnchor(
                    name: widget.otherName,
                    persona: widget.otherPersona,
                    showPersona: true,
                    alignment: CrossAxisAlignment.start,
                    size: avatarSize,
                    motionCue: _pokeActive
                        ? AvatarMotionCue.pressed
                        : AvatarMotionCue.idle,
                  ),
                ),
                Positioned(
                  right: edge,
                  bottom: edge,
                  child: _PersonaAnchor(
                    name: l.relationshipSpaceMe,
                    persona: widget.selfPersona,
                    showPersona: true,
                    alignment: CrossAxisAlignment.end,
                    size: avatarSize,
                    motionCue: _pokeActive
                        ? AvatarMotionCue.selected
                        : AvatarMotionCue.idle,
                  ),
                ),
                Positioned(
                  top: isNarrow ? 112 : 72,
                  left: 0,
                  right: 0,
                  child: Center(
                    child: TextButton.icon(
                      key: const Key('relationship-space-poke'),
                      onPressed: _poke,
                      icon: const Icon(Icons.touch_app_rounded, size: 20),
                      label: Text(l.relationshipSpacePokeAction),
                    ),
                  ),
                ),
                Positioned(
                  left: contentHorizontal,
                  right: contentHorizontal,
                  top: contentTop,
                  bottom: contentBottom,
                  child: widget.stageContent ?? const SizedBox.shrink(),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildPriorityRail(
    BuildContext context,
    AppLocalizations l,
    ColorScheme scheme,
    int pinCount,
    int sharedObjectCount,
    bool hasRecentConnection,
  ) {
    if (pinCount == 0 && sharedObjectCount == 0 && !hasRecentConnection) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(AppTheme.sp8),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest.withValues(alpha: .35),
          borderRadius: BorderRadius.circular(AppTheme.radiusMd),
        ),
        child: Text(
          l.relationshipSpaceNoEvent,
          style: TextStyle(color: scheme.onSurfaceVariant, height: 1.3),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (pinCount > 0) ...[
          Text(
            l.relationshipSpacePinsTitle,
            style: TextStyle(
              color: scheme.onSurfaceVariant,
              fontSize: 11,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: AppTheme.sp4),
          _RailChip(
            icon: Icons.push_pin_outlined,
            label: l.relationshipSpacePinsCount(pinCount),
          ),
        ],
        if (sharedObjectCount > 0) ...[
          if (pinCount > 0) const SizedBox(height: AppTheme.sp6),
          if (widget.sharedObjects.isNotEmpty)
            _SharedObjectRail(objects: widget.sharedObjects)
          else
            _RailChip(
              icon: Icons.link_rounded,
              label: l.relationshipSpaceObjectsCount(sharedObjectCount),
            ),
        ],
        if (hasRecentConnection) ...[
          const SizedBox(height: AppTheme.sp6),
          _RailChip(
            icon: Icons.history_rounded,
            label: widget.recentConnection == null || !_expanded
                ? l.relationshipSpaceLastConnection
                : '${l.relationshipSpaceRecentRecovery} · ${_formatTimestamp(widget.recentConnection!.endedAt ?? widget.recentConnection!.startedAt, chinese: Localizations.localeOf(context).languageCode == 'zh')}',
          ),
        ],
      ],
    );
  }

  Widget _buildRecentRecords(
    BuildContext context,
    AppLocalizations l,
    ColorScheme scheme,
  ) {
    final events = _visibleEvents();
    final hasMemory =
        widget.pins.isNotEmpty ||
        widget.pinCount > 0 ||
        widget.sharedObjects.isNotEmpty ||
        widget.sharedObjectCount > 0 ||
        widget.recentConnection != null ||
        widget.hasRecentConnection;
    // Avoid a blank section when the relationship has no history at all. The
    // priority rail already provides the actionable empty state in that case.
    if (events.isEmpty && !hasMemory) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          l.relationshipSpaceRecentRecords,
          style: TextStyle(
            color: scheme.onSurfaceVariant,
            fontSize: 12,
            fontWeight: FontWeight.w800,
          ),
        ),
        const SizedBox(height: AppTheme.sp6),
        if (events.isNotEmpty)
          _expanded
              ? _buildExpandedEvents(context, l, scheme, events)
              : _buildCompactEventRow(context, l, scheme, events)
        else
          Text(
            l.relationshipSpaceNoRecentRecords,
            style: TextStyle(color: scheme.onSurfaceVariant, height: 1.3),
          ),
      ],
    );
  }

  Widget _buildCompactEventRow(
    BuildContext context,
    AppLocalizations l,
    ColorScheme scheme,
    List<RelationshipSpaceEvent> events,
  ) {
    if (events.isNotEmpty) {
      final latest = events.first;
      final text = formatEventText(latest, l);
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(_eventIcon(latest), size: 16, color: scheme.onSurfaceVariant),
          const SizedBox(width: AppTheme.sp8),
          Expanded(
            child: Text(
              text,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: scheme.onSurfaceVariant,
                fontSize: 13,
                height: 1.3,
              ),
            ),
          ),
          const SizedBox(width: AppTheme.sp4),
          Text(
            _formatTimestamp(
              latest.occurredAt,
              chinese: Localizations.localeOf(context).languageCode == 'zh',
            ),
            style: TextStyle(
              color: scheme.onSurfaceVariant.withValues(alpha: 0.7),
              fontSize: 11,
            ),
          ),
        ],
      );
    }

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          Icons.lightbulb_outline_rounded,
          size: 16,
          color: scheme.onSurfaceVariant,
        ),
        const SizedBox(width: AppTheme.sp8),
        Expanded(
          child: Text(
            l.relationshipSpaceNoEvent,
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
    );
  }

  Widget _buildExpandedEvents(
    BuildContext context,
    AppLocalizations l,
    ColorScheme scheme,
    List<RelationshipSpaceEvent> events,
  ) {
    if (events.isNotEmpty) {
      final topEvents = events.take(3).toList(growable: false);
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < topEvents.length; i++) ...[
            if (i > 0) const SizedBox(height: AppTheme.sp6),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  _eventIcon(topEvents[i]),
                  size: 15,
                  color: scheme.onSurfaceVariant,
                ),
                const SizedBox(width: AppTheme.sp8),
                Expanded(
                  child: Text(
                    formatEventText(topEvents[i], l),
                    style: TextStyle(
                      color: scheme.onSurface,
                      fontSize: 13,
                      fontWeight: i == 0 ? FontWeight.w700 : FontWeight.w500,
                    ),
                  ),
                ),
                const SizedBox(width: AppTheme.sp4),
                Text(
                  _formatTimestamp(
                    topEvents[i].occurredAt,
                    chinese:
                        Localizations.localeOf(context).languageCode == 'zh',
                  ),
                  style: TextStyle(
                    color: scheme.onSurfaceVariant.withValues(alpha: 0.7),
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ],
        ],
      );
    }

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          Icons.lightbulb_outline_rounded,
          size: 16,
          color: scheme.onSurfaceVariant,
        ),
        const SizedBox(width: AppTheme.sp8),
        Expanded(
          child: Text(
            l.relationshipSpaceNoEvent,
            style: TextStyle(
              color: scheme.onSurfaceVariant,
              fontSize: 13,
              height: 1.3,
            ),
          ),
        ),
      ],
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
    this.persona,
    this.showPersona = true,
    required this.alignment,
    this.compact = false,
    required this.size,
    this.motionCue = AvatarMotionCue.idle,
  });

  final String name;
  final SocialPersona? persona;
  final bool showPersona;
  final CrossAxisAlignment alignment;
  final bool compact;
  final double size;
  final AvatarMotionCue motionCue;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final trimmedName = name.trim();
    return Column(
      crossAxisAlignment: alignment,
      children: [
        UserAvatar(
          name: trimmedName,
          persona: persona,
          size: size,
          showPersona: showPersona,
          motionCue: motionCue,
          semanticLabel: trimmedName.isEmpty ? null : trimmedName,
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
