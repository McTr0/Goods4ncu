import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../models/models.dart';
import '../services/agreement_service.dart';
import '../theme/app_theme.dart';

/// The arrangement, pinned above the conversation.
///
/// This is the feature: after thirty messages, "how much, when, where" is
/// scattered through them and both people scroll back to check. The card holds
/// the answer, identical for both, and the messages go back to being what they
/// are — annotation.
///
/// Two things the interface must never blur:
///
/// * **A suggestion is not the arrangement.** Anything the assistant read out of
///   the chat is shown as a question with an adopt button, visually distinct
///   from a term someone actually agreed to. A proposal that looks like a
///   decision is how somebody turns up on the wrong day.
/// * **Adopting sends the value you saw.** If the card changed while it was on
///   screen the server refuses, and the user is told to look again rather than
///   silently agreeing to something else.
class AgreementCard extends StatefulWidget {
  const AgreementCard({
    super.key,
    required this.agreement,
    required this.service,
    required this.currentUserId,
    this.onChanged,
  });

  final Agreement agreement;
  final AgreementService service;
  final String currentUserId;
  final ValueChanged<Agreement>? onChanged;

  @override
  State<AgreementCard> createState() => _AgreementCardState();
}

class _AgreementCardState extends State<AgreementCard> {
  late Agreement _agreement = widget.agreement;
  bool _busy = false;
  String? _notice;

  @override
  void didUpdateWidget(AgreementCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Any new object from the parent wins. Comparing ids instead meant a
    // refreshed card — the same arrangement with a newly adopted term — was
    // silently ignored, so the screen kept showing a state the server had
    // already moved past.
    if (!identical(oldWidget.agreement, widget.agreement)) {
      _agreement = widget.agreement;
    }
  }

  Future<void> _run(Future<Agreement> Function() action) async {
    setState(() {
      _busy = true;
      _notice = null;
    });
    try {
      final updated = await action();
      if (!mounted) return;
      setState(() {
        _agreement = updated;
        _busy = false;
      });
      widget.onChanged?.call(updated);
    } catch (e) {
      if (!mounted) return;
      final l = AppLocalizations.of(context)!;
      setState(() {
        // A conflict means the term moved on, which is a thing to look at
        // rather than an error the user caused.
        _notice = e.toString().contains('变了') ? l.agreementStale : e.toString();
        _busy = false;
      });
    }
  }

  Future<void> _edit(String slot, String label, String? current) async {
    final value = await showDialog<String>(
      context: context,
      builder: (_) => _TermDialog(label: label, initial: current),
    );
    if (value == null || value.isEmpty) return;
    await _run(() => widget.service.setTerm(_agreement.id, slot, value));
  }

  String _slotLabel(AppLocalizations l, String slot) => switch (slot) {
    'item' => l.agreementSlotItem,
    'price' => l.agreementSlotPrice,
    'time' => l.agreementSlotTime,
    'place' => l.agreementSlotPlace,
    'who' => l.agreementSlotWho,
    'bring' => l.agreementSlotBring,
    'conditions' => l.agreementSlotConditions,
    _ => slot,
  };

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final terms = {for (final t in _agreement.terms) t.slot: t};

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  l.agreementCardTitle,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const Spacer(),
                if (_agreement.isSettled)
                  Text(
                    l.agreementSettled,
                    style: const TextStyle(
                      fontSize: 12,
                      color: AppTheme.primary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
              ],
            ),
            if (_notice != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  _notice!,
                  style: const TextStyle(
                    fontSize: 12,
                    color: Color(0xFFB45309),
                  ),
                ),
              ),
            const SizedBox(height: 4),
            // Every slot this kind of arrangement can hold, so an empty one
            // reads as "not settled yet" rather than being invisible.
            ..._agreement.availableSlots.map(
              (slot) => _row(l, slot, terms[slot]),
            ),
            if (!_agreement.isSettled && _agreement.fullyAgreed)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: _busy
                        ? null
                        : () =>
                              _run(() => widget.service.settle(_agreement.id)),
                    child: Text(l.agreementSettle),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _row(AppLocalizations l, String slot, AgreementTerm? term) {
    final label = _slotLabel(l, slot);
    final settled = term?.settledBy(_agreement.participants) ?? false;
    final mineAlready = term?.agreedBy.contains(widget.currentUserId) ?? false;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 64,
            child: Text(
              label,
              style: const TextStyle(fontSize: 12, color: Color(0xFF6B7280)),
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  term?.value ?? l.agreementNotSet,
                  style: TextStyle(
                    fontSize: 14,
                    color: term == null
                        ? const Color(0xFF9CA3AF)
                        : const Color(0xFF111827),
                  ),
                ),
                // A suggestion says where it came from and asks. It is never
                // dressed as a decision.
                if (term != null && term.isSuggestion)
                  Text(
                    l.agreementSuggestion,
                    style: const TextStyle(
                      fontSize: 11,
                      color: Color(0xFFB45309),
                    ),
                  )
                else if (term != null && settled)
                  Text(
                    l.agreementAgreed,
                    style: const TextStyle(
                      fontSize: 11,
                      color: AppTheme.primary,
                    ),
                  )
                else if (term != null && mineAlready)
                  Text(
                    l.agreementWaitingOther,
                    style: const TextStyle(
                      fontSize: 11,
                      color: Color(0xFF9CA3AF),
                    ),
                  ),
              ],
            ),
          ),
          if (_agreement.isSettled)
            const SizedBox.shrink()
          else if (term == null)
            TextButton(
              onPressed: _busy ? null : () => _edit(slot, label, null),
              child: Text(l.agreementSet),
            )
          else if (!mineAlready)
            // Sends the value on screen, so a card that changed underneath
            // cannot capture this tap.
            TextButton(
              onPressed: _busy
                  ? null
                  : () => _run(
                      () =>
                          widget.service.adopt(_agreement.id, slot, term.value),
                    ),
              child: Text(l.agreementAdopt),
            )
          else
            TextButton(
              onPressed: _busy ? null : () => _edit(slot, label, term.value),
              child: Text(l.edit),
            ),
        ],
      ),
    );
  }
}

/// Editing one term.
///
/// Owns its controller, because disposing one straight after `showDialog`
/// returns throws while the dismissal animation is still rebuilding the field.
class _TermDialog extends StatefulWidget {
  const _TermDialog({required this.label, this.initial});

  final String label;
  final String? initial;

  @override
  State<_TermDialog> createState() => _TermDialogState();
}

class _TermDialogState extends State<_TermDialog> {
  late final _controller = TextEditingController(text: widget.initial ?? '');

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    return AlertDialog(
      title: Text(widget.label),
      content: TextField(
        controller: _controller,
        autofocus: true,
        decoration: const InputDecoration(border: OutlineInputBorder()),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l.cancel),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _controller.text.trim()),
          child: Text(l.confirm),
        ),
      ],
    );
  }
}
