import 'package:flutter/material.dart';
import '../../l10n/app_localizations.dart';
import '../../models/models.dart';

class AssistantDigitalHumanHeader extends StatelessWidget {
  const AssistantDigitalHumanHeader({
    super.key,
    required this.onOpenHistory,
    this.onOpenMemoryPanel,
    this.onClearHistory,
  });

  final VoidCallback onOpenHistory;
  final VoidCallback? onOpenMemoryPanel;
  final VoidCallback? onClearHistory;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    return AppBar(
      key: const Key('assistant-header'),
      primary: false,
      automaticallyImplyLeading: false,
      leading: const SizedBox.shrink(),
      title: Text(l.assistantName),
      actions: [
        IconButton(
          tooltip: l.assistantHistoryTooltip,
          icon: const Icon(Icons.history_rounded),
          onPressed: onOpenHistory,
        ),
        if (onOpenMemoryPanel != null)
          IconButton(
            key: const Key('assistant-memory-entry'),
            tooltip: l.assistantMemoryEntry,
            icon: const Icon(Icons.psychology_outlined),
            onPressed: onOpenMemoryPanel,
          ),
        if (onClearHistory != null)
          IconButton(
            key: const Key('assistant-clear-history'),
            tooltip: l.assistantClearHistoryTooltip,
            icon: const Icon(Icons.delete_sweep_outlined),
            onPressed: onClearHistory,
          ),
      ],
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
