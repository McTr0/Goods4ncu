import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:goods4ncu_mobile/components/feed_feedback_menu.dart';
import 'package:goods4ncu_mobile/components/recommendation_carousel.dart';
import 'package:goods4ncu_mobile/l10n/app_localizations.dart';
import 'package:goods4ncu_mobile/models/models.dart';
import 'package:goods4ncu_mobile/services/feed_feedback_service.dart';
import 'package:goods4ncu_mobile/theme/app_theme.dart';

class _RecordingFeedbackService extends FeedFeedbackService {
  final List<
    ({
      FeedResourceType resourceType,
      String resourceId,
      FeedFeedbackAction action,
    })
  >
  calls = [];

  @override
  Future<void> submitFeedback({
    required FeedResourceType resourceType,
    required String resourceId,
    required FeedFeedbackAction action,
  }) async {
    calls.add((
      resourceType: resourceType,
      resourceId: resourceId,
      action: action,
    ));
  }
}

Widget _app({
  required Listing listing,
  required FeedFeedbackService feedbackService,
  required ValueChanged<Listing> onApplied,
  double textScale = 1,
}) {
  final router = GoRouter(
    routes: [
      GoRoute(
        path: '/',
        builder: (context, state) => Scaffold(
          body: RecommendationCarousel(
            listings: [listing],
            title: '相似推荐',
            feedbackMenuBuilder: (candidate) => FeedFeedbackMenu(
              service: feedbackService,
              resourceType: FeedResourceType.listing,
              resourceId: candidate.id,
              compact: true,
              onApplied: (_) => onApplied(candidate),
            ),
          ),
        ),
      ),
      GoRoute(
        path: '/listing/:id',
        builder: (context, state) =>
            Text('destination ${state.pathParameters['id']}'),
      ),
    ],
  );

  return MaterialApp.router(
    theme: AppTheme.light,
    locale: const Locale('en'),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    routerConfig: router,
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(textScaler: TextScaler.linear(textScale)),
      child: child!,
    ),
  );
}

void main() {
  testWidgets(
    'narrow 200% layout keeps explanation and feedback controls separate',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(320, 700));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final feedback = _RecordingFeedbackService();
      final applied = <Listing>[];
      final listing = Listing(
        id: 'candidate-1',
        title: '一本标题很长的程序设计教材',
        category: 'books',
        brand: 'NCU',
        conditionScore: 8,
        suggestedPriceCny: 25,
        status: 'active',
        rankReason: 'future_listing_signal',
        matchSummary: const ['semantic_similarity', 'future_listing_signal'],
        source: 'vector_similarity',
      );

      await tester.pumpWidget(
        _app(
          listing: listing,
          feedbackService: feedback,
          onApplied: applied.add,
          textScale: 2,
        ),
      );
      await tester.pumpAndSettle();
      final l = AppLocalizations.of(
        tester.element(find.byType(RecommendationCarousel)),
      )!;
      final menu = find.byKey(
        const ValueKey('feed-feedback-listing-candidate-1'),
      );
      final title = find.byKey(
        const ValueKey('recommendation-title-candidate-1'),
      );
      final reason = find.byKey(
        const ValueKey('recommendation-reason-candidate-1'),
      );
      final details = find.byKey(
        const ValueKey('recommendation-details-candidate-1'),
      );

      expect(tester.takeException(), isNull);
      expect(menu, findsOneWidget);
      expect(find.byTooltip(l.feedFeedbackMenuTooltip), findsOneWidget);
      expect(find.textContaining(l.feedReasonSimilar), findsOneWidget);
      expect(find.textContaining('future_listing_signal'), findsNothing);
      final cardSemantics = tester.widget<Semantics>(
        find.byWidgetPredicate(
          (widget) =>
              widget is Semantics &&
              (widget.properties.label ?? '').startsWith(listing.title),
        ),
      );
      expect(cardSemantics.properties.label, contains(l.feedReasonSimilar));
      expect(cardSemantics.properties.label, contains('¥25.00'));
      expect(cardSemantics.properties.label, contains('8/10'));
      expect(tester.getRect(menu).overlaps(tester.getRect(title)), isFalse);
      expect(tester.getRect(menu).overlaps(tester.getRect(reason)), isFalse);
      expect(tester.getRect(reason).overlaps(tester.getRect(details)), isFalse);
      expect(tester.getSize(menu).shortestSide, greaterThanOrEqualTo(48));

      await tester.tap(menu);
      await tester.pumpAndSettle();

      expect(find.textContaining('destination'), findsNothing);
      await tester.tap(find.text(l.feedFeedbackNotRelevant));
      await tester.pumpAndSettle();
      expect(applied, [listing]);
      expect(feedback.calls.single.resourceType, FeedResourceType.listing);
      expect(feedback.calls.single.resourceId, listing.id);
    },
  );
}
