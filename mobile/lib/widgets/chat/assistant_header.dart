import 'package:flutter/material.dart';

import 'package:go_router/go_router.dart';

import '../../companion/companion_config.dart';
import '../../components/xiaochang_avatar.dart';
import '../../l10n/app_localizations.dart';
import '../../models/models.dart';

class AssistantDigitalHumanHeader extends StatelessWidget {
  const AssistantDigitalHumanHeader({super.key, required this.onOpenHistory});

  final VoidCallback onOpenHistory;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        border: Border(
          bottom: BorderSide(color: Theme.of(context).dividerColor),
        ),
      ),
      child: Row(
        children: [
          const XiaochangAvatar(size: 36),
          const SizedBox(width: 10),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                l.assistantHeaderName,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                ),
              ),
              Text(
                l.assistantHeaderTagline,
                style: const TextStyle(fontSize: 11, color: Color(0xFF64748B)),
              ),
            ],
          ),
          const Spacer(),
          IconButton(
            tooltip: l.assistantHistoryTooltip,
            icon: const Icon(Icons.history_rounded, color: Color(0xFF0F766E)),
            onPressed: onOpenHistory,
          ),
          if (kCompanionEnabled)
            IconButton(
              key: const Key('assistant-open-companion-debug'),
              tooltip: 'Companion Debug',
              icon: const Icon(
                Icons.bug_report_outlined,
                color: Color(0xFF0F766E),
              ),
              onPressed: () => context.push('/companion/debug'),
            ),
          const SizedBox(width: 4),
          const AgentStatusPill(),
        ],
      ),
    );
  }
}

class HitlChip extends StatelessWidget {
  final HitlRequest request;
  final VoidCallback onTap;

  const HitlChip({super.key, required this.request, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    Color tagColor;
    String label;
    if (request.isPending) {
      tagColor = Colors.orange;
      label = l.pendingNegotiation;
    } else if (request.isCountered) {
      tagColor = Colors.blue;
      label = l.sellerCounterOffered;
    } else {
      tagColor = Colors.grey;
      label = l.negotiationStatusLine(request.status);
    }

    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(right: 8),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: tagColor.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: tagColor.withValues(alpha: 0.5)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: TextStyle(
                color: tagColor,
                fontWeight: FontWeight.bold,
                fontSize: 12,
              ),
            ),
            Text(
              '¥${request.proposedPrice.toStringAsFixed(0)}',
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
          ],
        ),
      ),
    );
  }
}

class AgentStatusPill extends StatelessWidget {
  const AgentStatusPill({super.key});

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: const Color(0xFFE1F4EF),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        l.assistantSystemBadge,
        style: const TextStyle(
          color: Color(0xFF0F766E),
          fontSize: 11,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}
