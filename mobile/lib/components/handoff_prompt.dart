import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';

/// Someone's record, as a sentence.
///
/// This remains a profile-only fact. The former agreement handoff prompt was
/// removed from realtime conversations together with the legacy arrangement
/// card; keeping this small view in its existing file avoids an unrelated API
/// rename for profile consumers.
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
      hasTrackRecord
          ? l.reputationSummary(completed, onTime)
          : l.reputationNewcomer,
      style: const TextStyle(fontSize: 12, color: Color(0xFF6B7280)),
    );
  }
}
