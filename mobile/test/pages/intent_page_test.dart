import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goods4ncu_mobile/l10n/app_localizations.dart';
import 'package:goods4ncu_mobile/models/models.dart';
import 'package:goods4ncu_mobile/pages/intent_page.dart';
import 'package:goods4ncu_mobile/services/feed_feedback_service.dart';
import 'package:goods4ncu_mobile/services/intent_service.dart';
import 'package:provider/provider.dart';

/// Records what the page actually sent, which is the only way to check that it
/// did not quietly invent a price nobody typed.
class _FakeIntentService extends IntentService {
  _FakeIntentService({
    this.mine = const [],
    this.feed = const [],
    this.projectedListingId,
  });

  List<UserIntent> mine;
  List<UserIntent> feed;
  final String? projectedListingId;
  final List<(String, String)> responses = [];

  IntentKind? sentKind;
  String? sentRawInput;
  IntentSlots? sentSlots;
  final List<String> fulfilled = [];
  final List<String> withdrawn = [];

  @override
  Future<List<UserIntent>> myIntents() async => mine;

  @override
  Future<List<UserIntent>> campusFeed({
    IntentKind? kind,
    int limit = 30,
  }) async => feed;

  /// null means "this deployment has no vision provider".
  List<String>? photoIds;
  int photoCalls = 0;

  @override
  Future<List<String>?> decomposePhoto({
    required String imageBase64,
    required String mime,
    String? rawInput,
  }) async {
    photoCalls++;
    return photoIds;
  }

  @override
  Future<String> respondToIntent(String intentId, String content) async {
    responses.add((intentId, content));
    return 'conversation-1';
  }

  Map<String, List<UserIntent>> matches = const {};

  @override
  Future<List<UserIntent>> matchesFor(String intentId) async =>
      matches[intentId] ?? const [];

  @override
  Future<IntentCreated> createIntent({
    required IntentKind kind,
    required String rawInput,
    IntentSlots slots = const IntentSlots(),
    DateTime? validUntil,
    bool private = false,
  }) async {
    sentKind = kind;
    sentRawInput = rawInput;
    sentSlots = slots;
    return IntentCreated(
      id: 'intent-1',
      projectedListingId: projectedListingId,
      specificity: 0.3,
    );
  }

  @override
  Future<void> fulfilIntent(String id) async => fulfilled.add(id);

  @override
  Future<void> withdrawIntent(String id) async => withdrawn.add(id);
}

class _FakeFeedFeedbackService extends FeedFeedbackService {
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

Widget _app(Widget child, {FeedFeedbackService? feedbackService}) =>
    Provider<FeedFeedbackService>.value(
      value: feedbackService ?? _FakeFeedFeedbackService(),
      child: MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: child,
      ),
    );

AppLocalizations _l(WidgetTester tester) =>
    AppLocalizations.of(tester.element(find.byType(Scaffold)))!;

void main() {
  testWidgets('a sentence with no price at all is enough to post', (
    tester,
  ) async {
    // The property the whole layer exists for. The listing form refuses to
    // accept anything without a price, category and condition score; this must
    // accept one sentence and must not fill in a figure nobody chose.
    final service = _FakeIntentService();
    await tester.pumpWidget(_app(IntentPage(intentService: service)));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '宿舍要清空了，小冰箱能卖多少卖多少');
    await tester.tap(find.text(_l(tester).intentSubmit));
    await tester.pumpAndSettle();

    expect(service.sentRawInput, '宿舍要清空了，小冰箱能卖多少卖多少');
    expect(
      service.sentSlots?.price,
      isNull,
      reason: 'nothing was chosen, so nothing should be sent',
    );
    expect(service.sentSlots?.toJson(), isEmpty);
  });

  testWidgets('"whatever you\'ll give me" is sent as an answer', (
    tester,
  ) async {
    final service = _FakeIntentService();
    await tester.pumpWidget(_app(IntentPage(intentService: service)));
    await tester.pumpAndSettle();
    final l = _l(tester);

    await tester.enterText(find.byType(TextField), '小冰箱');
    await tester.tap(find.text(l.intentPriceWhatever));
    await tester.pumpAndSettle();
    await tester.tap(find.text(l.intentSubmit));
    await tester.pumpAndSettle();

    expect(service.sentSlots?.price?.kind, 'whatever');
  });

  testWidgets('the production composer only exposes offer and wanted goods', (
    tester,
  ) async {
    final service = _FakeIntentService();
    await tester.pumpWidget(_app(IntentPage(intentService: service)));
    await tester.pumpAndSettle();
    final l = _l(tester);

    expect(find.text(l.intentKindGoodsOffer), findsOneWidget);
    expect(find.text(l.intentKindGoodsSeek), findsOneWidget);
    expect(find.text(l.intentKindCompanion), findsNothing);
    expect(find.text(l.intentKindHelp), findsNothing);
    expect(find.text(l.intentKindActivity), findsNothing);

    await tester.tap(find.text(l.intentKindGoodsSeek));
    await tester.enterText(find.byType(TextField), '想收一本高数教材');
    await tester.tap(find.text(l.intentSubmit));
    await tester.pumpAndSettle();
    expect(service.sentKind, IntentKind.goodsSeek);
  });

  testWidgets('an unpriced offer is told it will not appear in the grid', (
    tester,
  ) async {
    // The server declines to mirror an unpriced intent into the browse grid
    // rather than inventing a figure. Left unexplained, the user would think
    // posting had failed.
    final service = _FakeIntentService();
    await tester.pumpWidget(_app(IntentPage(intentService: service)));
    await tester.pumpAndSettle();
    final l = _l(tester);

    await tester.enterText(find.byType(TextField), '小冰箱，能卖就行');
    await tester.tap(find.text(l.intentSubmit));
    await tester.pump();

    expect(find.text(l.intentSavedNotListed), findsOneWidget);
  });

  testWidgets('a priced offer just says it is saved', (tester) async {
    final service = _FakeIntentService(projectedListingId: 'listing-1');
    await tester.pumpWidget(_app(IntentPage(intentService: service)));
    await tester.pumpAndSettle();
    final l = _l(tester);

    await tester.enterText(find.byType(TextField), '台灯 30 块');
    await tester.tap(find.text(l.intentSubmit));
    await tester.pump();

    expect(find.text(l.intentSaved), findsOneWidget);
  });

  testWidgets('sorted and never-mind are separate actions', (tester) async {
    // One "close" button would merge two opposite outcomes, and the community
    // health metrics depend on telling them apart.
    final service = _FakeIntentService(
      mine: [
        UserIntent(
          id: 'intent-9',
          kind: IntentKind.goodsSeek,
          rawInput: '想收一套自行车修理工具',
          slots: const IntentSlots(),
          status: 'active',
        ),
      ],
    );
    await tester.pumpWidget(_app(IntentPage(intentService: service)));
    await tester.pumpAndSettle();
    final l = _l(tester);

    expect(find.text('想收一套自行车修理工具'), findsOneWidget);
    // The feed sits above the caller's own intents, so the action may be below
    // the fold on a test-sized screen.
    await tester.ensureVisible(find.text(l.intentFulfilAction));
    await tester.pumpAndSettle();
    await tester.tap(find.text(l.intentFulfilAction));
    await tester.pumpAndSettle();
    expect(service.fulfilled, ['intent-9']);
    expect(service.withdrawn, isEmpty);
  });

  testWidgets('a draft asks for confirmation instead of offering to resolve', (
    tester,
  ) async {
    // An inferred reading is not matchable until its author agrees, so the only
    // action that makes sense on it is confirming it.
    final service = _FakeIntentService(
      mine: [
        UserIntent(
          id: 'intent-draft',
          kind: IntentKind.goodsOffer,
          rawInput: '（从照片识别）台灯',
          slots: const IntentSlots(subject: '台灯'),
          status: 'draft',
        ),
      ],
    );
    await tester.pumpWidget(_app(IntentPage(intentService: service)));
    await tester.pumpAndSettle();
    final l = _l(tester);

    await tester.ensureVisible(find.text(l.intentDraftBadge));
    await tester.pumpAndSettle();
    expect(find.text(l.intentDraftBadge), findsOneWidget);
    expect(find.text(l.intentConfirmDraft), findsOneWidget);
    expect(find.text(l.intentFulfilAction), findsNothing);
  });

  testWidgets('an intent is shown back in the words its author used', (
    tester,
  ) async {
    // Not a normalised title. Seeing your own phrasing is how you can tell you
    // were understood.
    final service = _FakeIntentService(
      mine: [
        UserIntent(
          id: 'intent-2',
          kind: IntentKind.goodsOffer,
          rawInput: '宿舍要清空了，小冰箱能卖多少卖多少',
          slots: const IntentSlots(
            subject: '小冰箱',
            price: PriceSlot(kind: 'whatever', hint: '能卖就行'),
          ),
          status: 'active',
        ),
      ],
    );
    await tester.pumpWidget(_app(IntentPage(intentService: service)));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('能卖就行'));
    await tester.pumpAndSettle();
    expect(find.text('宿舍要清空了，小冰箱能卖多少卖多少'), findsOneWidget);
    expect(find.text('能卖就行'), findsOneWidget);
  });

  testWidgets('someone who has posted nothing still finds things to answer', (
    tester,
  ) async {
    // The other half of the unanswered-post problem. Without the feed a new
    // student opens the app, has said nothing, and finds an empty room — while
    // the demand is sitting right there unanswered.
    final service = _FakeIntentService(
      feed: [
        UserIntent(
          id: 'intent-feed-1',
          kind: IntentKind.goodsSeek,
          rawInput: '想收个二手显示器，24 寸以内',
          slots: const IntentSlots(),
          status: 'active',
        ),
      ],
    );
    await tester.pumpWidget(_app(IntentPage(intentService: service)));
    await tester.pumpAndSettle();
    final l = _l(tester);

    expect(find.text(l.intentFeedHeader), findsOneWidget);
    expect(find.text('想收个二手显示器，24 寸以内'), findsOneWidget);
    // And there is something to do about it. A list with no action is the dead
    // end this replaces.
    expect(find.text(l.intentRespondAction), findsOneWidget);
    // Their own list is empty, which is exactly the case that used to show
    // nothing at all.
    await tester.drag(find.byType(ListView), const Offset(0, -700));
    await tester.pumpAndSettle();
    expect(find.text(l.intentMineEmpty), findsOneWidget);
  });

  testWidgets('answering someone sends what was typed', (tester) async {
    final service = _FakeIntentService(
      feed: [
        UserIntent(
          id: 'intent-feed-2',
          kind: IntentKind.goodsSeek,
          rawInput: '想收一套自行车修理工具',
          slots: const IntentSlots(),
          status: 'active',
        ),
      ],
    );
    await tester.pumpWidget(_app(IntentPage(intentService: service)));
    await tester.pumpAndSettle();
    final l = _l(tester);

    await tester.tap(find.text(l.intentRespondAction));
    await tester.pumpAndSettle();
    // The dialog shows their words, so the responder can see what they are
    // answering.
    expect(find.text('想收一套自行车修理工具'), findsWidgets);

    await tester.enterText(find.byType(TextField).last, '我会，明天下午有空');
    await tester.tap(find.text(l.intentRespondSend));
    await tester.pumpAndSettle();

    expect(service.responses, [('intent-feed-2', '我会，明天下午有空')]);
    expect(find.text(l.intentRespondSent), findsOneWidget);
  });

  testWidgets('an empty reply is not sent', (tester) async {
    // Opening a conversation with nothing in it wastes both people's time.
    final service = _FakeIntentService(
      feed: [
        UserIntent(
          id: 'intent-feed-3',
          kind: IntentKind.goodsSeek,
          rawInput: '想收一个羽毛球拍',
          slots: const IntentSlots(),
          status: 'active',
        ),
      ],
    );
    await tester.pumpWidget(_app(IntentPage(intentService: service)));
    await tester.pumpAndSettle();
    final l = _l(tester);

    await tester.tap(find.text(l.intentRespondAction));
    await tester.pumpAndSettle();
    await tester.tap(find.text(l.intentRespondSend));
    await tester.pumpAndSettle();

    expect(service.responses, isEmpty);
  });

  testWidgets('an empty feed says why rather than showing nothing', (
    tester,
  ) async {
    final service = _FakeIntentService();
    await tester.pumpWidget(_app(IntentPage(intentService: service)));
    await tester.pumpAndSettle();
    expect(find.text(_l(tester).intentFeedEmpty), findsOneWidget);
  });

  testWidgets('the photo affordance is offered only for goods being sold', (
    tester,
  ) async {
    final service = _FakeIntentService();
    await tester.pumpWidget(_app(IntentPage(intentService: service)));
    await tester.pumpAndSettle();
    final l = _l(tester);

    expect(find.text(l.intentPhotoAction), findsOneWidget);
    await tester.tap(find.text(l.intentKindGoodsSeek));
    await tester.pumpAndSettle();
    expect(find.text(l.intentPhotoAction), findsNothing);
  });

  testWidgets('the composer still works with no photo taken', (tester) async {
    // The photo path is an addition, never a precondition. Someone who just
    // types a sentence must not be made to do anything else.
    final service = _FakeIntentService();
    await tester.pumpWidget(_app(IntentPage(intentService: service)));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '宿舍小台灯');
    await tester.tap(find.text(_l(tester).intentSubmit));
    await tester.pumpAndSettle();

    expect(service.sentRawInput, '宿舍小台灯');
    expect(service.photoCalls, 0);
  });

  testWidgets('a match can be answered from where it is shown', (tester) async {
    // Matching computed the candidates and printed them as inert text. The
    // moment the system says somebody here wants what you have is the worst
    // possible moment to give them nothing to press.
    final service = _FakeIntentService(
      mine: [
        UserIntent(
          id: 'intent-mine-1',
          kind: IntentKind.goodsSeek,
          rawInput: '想收个二手显示器',
          slots: const IntentSlots(),
          status: 'active',
        ),
      ],
    );
    service.matches = {
      'intent-mine-1': [
        UserIntent(
          id: 'intent-theirs-1',
          kind: IntentKind.goodsOffer,
          rawInput: '出一台 24 寸显示器',
          slots: const IntentSlots(subject: '显示器'),
          status: 'active',
          matchSummary: const ['within_budget', 'condition_match'],
          source: 'intent_match',
        ),
      ],
    };
    await tester.pumpWidget(_app(IntentPage(intentService: service)));
    await tester.pumpAndSettle();
    final l = _l(tester);

    expect(find.text(l.intentMatchCount(1)), findsOneWidget);
    expect(find.textContaining(l.feedReasonWithinBudget), findsOneWidget);
    expect(find.textContaining('within_budget'), findsNothing);
    await tester.ensureVisible(find.text(l.intentRespondAction));
    await tester.pumpAndSettle();
    await tester.tap(find.text(l.intentRespondAction));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).last, '还在吗，我要');
    await tester.tap(find.text(l.intentRespondSend));
    await tester.pumpAndSettle();

    // Addressed to their intent, not to the caller's own.
    expect(service.responses, [('intent-theirs-1', '还在吗，我要')]);
  });

  testWidgets('having no match yet is stated, not left blank', (tester) async {
    final service = _FakeIntentService(
      mine: [
        UserIntent(
          id: 'intent-mine-2',
          kind: IntentKind.goodsSeek,
          rawInput: '想收个电饭煲',
          slots: const IntentSlots(),
          status: 'active',
        ),
      ],
    );
    await tester.pumpWidget(_app(IntentPage(intentService: service)));
    await tester.pumpAndSettle();
    final l = _l(tester);

    expect(find.text(l.intentNoMatchesYet), findsOneWidget);
    // And nothing to press, because there is nobody to press it at.
    expect(find.text(l.intentRespondAction), findsNothing);
  });

  testWidgets('campus feed feedback removes the item after success', (
    tester,
  ) async {
    final intents = _FakeIntentService(
      feed: [
        UserIntent(
          id: 'intent-feedback-1',
          kind: IntentKind.goodsSeek,
          rawInput: '想收一根登山杖',
          slots: const IntentSlots(),
          status: 'active',
          rankReason: 'same_kind',
          source: 'campus_feed',
        ),
      ],
    );
    final feedback = _FakeFeedFeedbackService();
    await tester.pumpWidget(
      _app(IntentPage(intentService: intents), feedbackService: feedback),
    );
    await tester.pumpAndSettle();
    final l = _l(tester);
    final menu = find.byKey(
      const ValueKey('feed-feedback-intent-intent-feedback-1'),
    );

    expect(find.text(l.feedReasonIntentKind), findsOneWidget);
    await tester.tap(menu);
    await tester.pumpAndSettle();
    await tester.tap(find.text(l.feedFeedbackLessLikeThis));
    await tester.pumpAndSettle();

    expect(find.text('想收一根登山杖'), findsNothing);
    expect(find.text(l.intentFeedEmpty), findsOneWidget);
    expect(feedback.calls, hasLength(1));
    expect(feedback.calls.single.action, FeedFeedbackAction.lessLikeThis);
  });

  testWidgets('feedback can dismiss an item from a match list', (tester) async {
    final intents = _FakeIntentService(
      mine: [
        UserIntent(
          id: 'intent-owner',
          kind: IntentKind.goodsSeek,
          rawInput: '想收个键盘',
          slots: const IntentSlots(),
          status: 'active',
        ),
      ],
    );
    intents.matches = {
      'intent-owner': [
        UserIntent(
          id: 'intent-match-feedback',
          kind: IntentKind.goodsOffer,
          rawInput: '出机械键盘',
          slots: const IntentSlots(subject: '机械键盘'),
          status: 'active',
          matchSummary: const ['keyword_match'],
        ),
      ],
    };
    final feedback = _FakeFeedFeedbackService();
    await tester.pumpWidget(
      _app(IntentPage(intentService: intents), feedbackService: feedback),
    );
    await tester.pumpAndSettle();
    final l = _l(tester);
    final menu = find.byKey(
      const ValueKey('feed-feedback-intent-intent-match-feedback'),
    );

    await tester.scrollUntilVisible(
      menu,
      250,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(menu);
    await tester.pumpAndSettle();
    await tester.tap(find.text(l.feedFeedbackNotRelevant));
    await tester.pumpAndSettle();

    expect(find.text('· 机械键盘'), findsNothing);
    expect(find.text(l.intentNoMatchesYet), findsOneWidget);
    expect(feedback.calls.single.resourceId, 'intent-match-feedback');
  });
}
