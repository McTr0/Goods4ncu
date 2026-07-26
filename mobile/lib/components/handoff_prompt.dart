import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../services/reputation_service.dart';
import '../theme/app_theme.dart';

/// Asking what happened, once.
///
/// Two questions with checkable answers and no comment box. A free-text field is
/// where the social cost of an honest answer comes straight back in, which is
/// what star ratings get wrong on a campus: the rating that is safe to give
/// carries no information, and the one that carries information is unsafe.
///
/// It says up front that it is asked once and cannot be changed. Someone
/// answering under the impression they can revise it later would answer
/// differently, and revising after a falling-out is exactly what the record must
/// not allow.
class HandoffPrompt extends StatefulWidget {
  const HandoffPrompt({
    super.key,
    required this.agreementId,
    required this.service,
    this.onAnswered,
  });

  final String agreementId;
  final ReputationService service;
  final VoidCallback? onAnswered;

  @override
  State<HandoffPrompt> createState() => _HandoffPromptState();
}

class _HandoffPromptState extends State<HandoffPrompt> {
  /// null until they say whether it happened; the punctuality question only
  /// makes sense afterwards.
  bool? _happened;
  bool _busy = false;
  bool _answered = false;
  String? _error;

  Future<void> _submit({required bool happened, bool? onTime}) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.service.confirm(
        widget.agreementId,
        happened: happened,
        onTime: onTime,
      );
      if (!mounted) return;
      setState(() {
        _answered = true;
        _busy = false;
      });
      widget.onAnswered?.call();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _busy = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    if (_answered) {
      return Padding(
        padding: const EdgeInsets.all(12),
        child: Text(
          l.handoffThanks,
          style: const TextStyle(fontSize: 13, color: AppTheme.primary),
        ),
      );
    }

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l.handoffPromptTitle,
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 2),
            // Said before they answer, not after.
            Text(
              l.handoffOnce,
              style: const TextStyle(fontSize: 11, color: Color(0xFF9CA3AF)),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  _error!,
                  style: const TextStyle(
                    fontSize: 12,
                    color: Color(0xFFB91C1C),
                  ),
                ),
              ),
            const SizedBox(height: 8),
            if (_happened == null)
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: _busy ? null : () => _submit(happened: false),
                      child: Text(l.handoffMissed),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton(
                      onPressed: _busy
                          ? null
                          : () => setState(() => _happened = true),
                      child: Text(l.handoffHappened),
                    ),
                  ),
                ],
              )
            else
              // Only asked once they said it happened: punctuality for a meeting
              // that never occurred is not a fact about anyone.
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: _busy
                          ? null
                          : () => _submit(happened: true, onTime: false),
                      child: Text(l.handoffLate),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton(
                      onPressed: _busy
                          ? null
                          : () => _submit(happened: true, onTime: true),
                      child: Text(l.handoffOnTime),
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

/// Someone's record, as a sentence.
///
/// Never a score, and never a negative shown to third parties. A missed
/// arrangement lowers matching weight; it does not put a mark on a profile for
/// the rest of somebody's degree.
class ReputationLine extends StatelessWidget {
  const ReputationLine({
    super.key,
    required this.completed,
    required this.onTime,
    required this.hasTrackRecord,
  });

  final int completed;
  final int onTime;
  final bool hasTrackRecord;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    return Text(
      // A newcomer is unmeasured, not untrusted, and the wording has to say so
      // rather than showing an empty tally that reads as a bad one.
      hasTrackRecord
          ? l.reputationSummary(completed, onTime)
          : l.reputationNewcomer,
      style: const TextStyle(fontSize: 12, color: Color(0xFF6B7280)),
    );
  }
}
