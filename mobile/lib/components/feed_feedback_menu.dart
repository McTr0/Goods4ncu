import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../services/feed_feedback_service.dart';
import '../theme/app_theme.dart';

typedef FeedFeedbackApplied = void Function(FeedFeedbackAction action);

/// The same explicit feed controls everywhere recommendations are shown.
///
/// The in-flight guard matters on slow networks: a repeated tap must not record
/// several signals or remove more than the item the user acted on.
class FeedFeedbackMenu extends StatefulWidget {
  const FeedFeedbackMenu({
    super.key,
    required this.service,
    required this.resourceType,
    required this.resourceId,
    required this.onApplied,
    this.compact = false,
  });

  final FeedFeedbackService service;
  final FeedResourceType resourceType;
  final String resourceId;
  final FeedFeedbackApplied onApplied;
  final bool compact;

  @override
  State<FeedFeedbackMenu> createState() => _FeedFeedbackMenuState();
}

class _FeedFeedbackMenuState extends State<FeedFeedbackMenu> {
  bool _submitting = false;

  Future<void> _submit(FeedFeedbackAction action) async {
    if (_submitting) return;
    setState(() => _submitting = true);
    final l = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await widget.service.submitFeedback(
        resourceType: widget.resourceType,
        resourceId: widget.resourceId,
        action: action,
      );
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(content: Text(l.feedFeedbackSaved)));
      widget.onApplied(action);
    } catch (_) {
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(content: Text(l.feedFeedbackFailed)));
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_submitting) {
      return SizedBox.square(
        key: ValueKey(
          'feed-feedback-loading-${widget.resourceType.wire}-${widget.resourceId}',
        ),
        dimension: widget.compact ? 32 : 40,
        child: const Padding(
          padding: EdgeInsets.all(9),
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }

    final l = AppLocalizations.of(context)!;
    return PopupMenuButton<FeedFeedbackAction>(
      key: ValueKey(
        'feed-feedback-${widget.resourceType.wire}-${widget.resourceId}',
      ),
      tooltip: l.feedFeedbackMenuTooltip,
      padding: EdgeInsets.zero,
      iconSize: widget.compact ? 19 : 22,
      icon: const Icon(Icons.more_horiz),
      onSelected: _submit,
      itemBuilder: (context) => [
        PopupMenuItem(
          value: FeedFeedbackAction.hide,
          child: _FeedbackMenuRow(
            icon: Icons.visibility_off_outlined,
            label: l.feedFeedbackHide,
          ),
        ),
        PopupMenuItem(
          value: FeedFeedbackAction.lessLikeThis,
          child: _FeedbackMenuRow(
            icon: Icons.tune_outlined,
            label: l.feedFeedbackLessLikeThis,
          ),
        ),
        PopupMenuItem(
          value: FeedFeedbackAction.notRelevant,
          child: _FeedbackMenuRow(
            icon: Icons.do_not_disturb_alt_outlined,
            label: l.feedFeedbackNotRelevant,
          ),
        ),
      ],
    );
  }
}

class _FeedbackMenuRow extends StatelessWidget {
  const _FeedbackMenuRow({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Icon(icon, size: 20, color: AppTheme.textSecondary),
      const SizedBox(width: 12),
      Text(label),
    ],
  );
}

/// Turns server reason codes into user-facing copy without ever printing an
/// unknown machine identifier such as `same_category_v2`.
String localizedFeedReason(AppLocalizations l, String? code, {String? source}) {
  final normalizedSource = source?.trim().toLowerCase();
  final normalized = code?.trim().toLowerCase() ?? '';
  String? knownReason(String value) => switch (value) {
    'recency' ||
    'recent' ||
    'latest' ||
    'latest_published' ||
    'recent_campus_intent' ||
    'campus_recency' => l.feedReasonRecent,
    'category_affinity' => l.feedReasonSameCategory,
    'same_category' || 'category_match' => l.feedReasonCategoryMatch,
    'vector_similarity' ||
    'similar' ||
    'semantic_similarity' => l.feedReasonSimilar,
    'within_budget' ||
    'budget_match' ||
    'price_within_constraint' => l.feedReasonWithinBudget,
    'condition_match' ||
    'condition_at_least_requested' => l.feedReasonConditionMatch,
    'same_kind' ||
    'intent_kind_match' ||
    'kind_compatible' ||
    'counterpart' => l.feedReasonIntentKind,
    'keyword' || 'keyword_match' => l.feedReasonKeywordMatch,
    'known_slots_compatible' ||
    'hard_constraints' => l.feedReasonRequirementsMatch,
    'time_overlap' => l.feedReasonTimeOverlap,
    _ => null,
  };

  // A specific rank or summary reason always wins. Source is only a fallback,
  // so `hard_constraints` cannot erase `price_within_constraint`.
  final mapped = knownReason(normalized);
  if (mapped != null) return mapped;
  final mappedSource = normalizedSource == null
      ? null
      : knownReason(normalizedSource);
  if (mappedSource != null) return mappedSource;

  final raw = code?.trim() ?? '';
  if (raw == '最新发布') return l.feedReasonRecent;
  if (raw == '与当前商品相似') return l.feedReasonSimilar;

  // Existing deployments may still send readable copy. Preserve that during
  // the migration, but never expose an unrecognised stable code.
  final looksLikeMachineCode = RegExp(
    r'^[a-z][a-z0-9_-]*$',
    caseSensitive: false,
  ).hasMatch(raw);
  if (raw.isNotEmpty && !looksLikeMachineCode) return raw;
  return l.feedReasonRecommended;
}

List<String> localizedFeedReasons(
  AppLocalizations l, {
  required List<String> codes,
  String? rankReason,
  String? source,
}) {
  // Eligibility facts are not useful explanations of “why this?”.
  const structuralCodes = {'same_campus', 'active_intent'};
  final meaningfulCodes = codes
      .where((code) => !structuralCodes.contains(code.trim().toLowerCase()))
      .toList();
  final rawCodes = meaningfulCodes.isNotEmpty
      ? meaningfulCodes
      : <String>[?rankReason];
  final localized = rawCodes
      .map((code) => localizedFeedReason(l, code, source: source))
      .toSet()
      .toList();
  if (localized.isEmpty && source != null && source.isNotEmpty) {
    localized.add(localizedFeedReason(l, null, source: source));
  }
  return localized;
}
