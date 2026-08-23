import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goods4ncu_mobile/components/feed_feedback_menu.dart';
import 'package:goods4ncu_mobile/l10n/app_localizations.dart';
import 'package:goods4ncu_mobile/services/feed_feedback_service.dart';

class _ControlledFeedbackService extends FeedFeedbackService {
  final Completer<void>? pending;
  final bool fail;
  int calls = 0;

  _ControlledFeedbackService({this.pending, this.fail = false});

  @override
  Future<void> submitFeedback({
    required FeedResourceType resourceType,
    required String resourceId,
    required FeedFeedbackAction action,
  }) async {
    calls++;
    if (pending != null) await pending!.future;
    if (fail) throw Exception('offline');
  }
}

Widget _app(
  FeedFeedbackService service, {
  required FeedFeedbackApplied onApplied,
}) => MaterialApp(
  locale: const Locale('zh'),
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: Scaffold(
    body: Center(
      child: FeedFeedbackMenu(
        service: service,
        resourceType: FeedResourceType.post,
        resourceId: 'post-1',
        onApplied: onApplied,
      ),
    ),
  ),
);

void main() {
  testWidgets('all intent contract reason codes become useful local copy', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(_ControlledFeedbackService(), onApplied: (_) {}),
    );
    final l = AppLocalizations.of(
      tester.element(find.byType(FeedFeedbackMenu)),
    )!;

    final summary = localizedFeedReasons(
      l,
      codes: const [
        'same_campus',
        'active_intent',
        'kind_compatible',
        'category_match',
        'price_within_constraint',
        'time_overlap',
        'condition_at_least_requested',
      ],
      rankReason: 'known_slots_compatible',
      source: 'hard_constraints',
    );

    expect(
      summary,
      containsAll([
        l.feedReasonIntentKind,
        l.feedReasonCategoryMatch,
        l.feedReasonWithinBudget,
        l.feedReasonTimeOverlap,
        l.feedReasonConditionMatch,
      ]),
    );
    expect(summary.join(' '), isNot(contains('same_campus')));
    expect(localizedFeedReason(l, 'recent_campus_intent'), l.feedReasonRecent);
    expect(
      localizedFeedReason(l, 'known_slots_compatible'),
      l.feedReasonRequirementsMatch,
    );
    expect(
      localizedFeedReason(l, null, source: 'campus_recency'),
      l.feedReasonRecent,
    );
    expect(
      localizedFeedReason(l, null, source: 'hard_constraints'),
      l.feedReasonRequirementsMatch,
    );
    expect(
      localizedFeedReason(l, 'future_rank'),
      l.feedReasonRecommended,
      reason: 'unknown machine identifiers must never be shown to users',
    );
  });

  testWidgets('in-flight submission replaces the menu and applies once', (
    tester,
  ) async {
    final pending = Completer<void>();
    final service = _ControlledFeedbackService(pending: pending);
    final applied = <FeedFeedbackAction>[];
    await tester.pumpWidget(_app(service, onApplied: applied.add));
    final l = AppLocalizations.of(
      tester.element(find.byType(FeedFeedbackMenu)),
    )!;

    await tester.tap(find.byKey(const ValueKey('feed-feedback-post-post-1')));
    await tester.pumpAndSettle();
    await tester.tap(find.text(l.feedFeedbackHide));
    await tester.pump();

    expect(service.calls, 1);
    expect(
      find.byKey(const ValueKey('feed-feedback-loading-post-post-1')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('feed-feedback-post-post-1')),
      findsNothing,
      reason: 'there is no second submit affordance while the first is pending',
    );

    pending.complete();
    await tester.pumpAndSettle();

    expect(service.calls, 1);
    expect(applied, [FeedFeedbackAction.hide]);
  });

  testWidgets('failure keeps the item by never calling onApplied', (
    tester,
  ) async {
    final service = _ControlledFeedbackService(fail: true);
    final applied = <FeedFeedbackAction>[];
    await tester.pumpWidget(_app(service, onApplied: applied.add));
    final l = AppLocalizations.of(
      tester.element(find.byType(FeedFeedbackMenu)),
    )!;

    await tester.tap(find.byKey(const ValueKey('feed-feedback-post-post-1')));
    await tester.pumpAndSettle();
    await tester.tap(find.text(l.feedFeedbackNotRelevant));
    await tester.pumpAndSettle();

    expect(service.calls, 1);
    expect(applied, isEmpty);
    expect(
      find.byKey(const ValueKey('feed-feedback-post-post-1')),
      findsOneWidget,
    );
    expect(find.text(l.feedFeedbackFailed), findsOneWidget);
  });
}
