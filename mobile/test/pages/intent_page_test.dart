import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goods4ncu_mobile/l10n/app_localizations.dart';
import 'package:goods4ncu_mobile/models/models.dart';
import 'package:goods4ncu_mobile/pages/intent_page.dart';
import 'package:goods4ncu_mobile/services/intent_service.dart';

/// Records what the page actually sent, which is the only way to check that it
/// did not quietly invent a price nobody typed.
class _FakeIntentService extends IntentService {
  _FakeIntentService({this.mine = const [], this.projectedListingId});

  List<UserIntent> mine;
  final String? projectedListingId;

  IntentKind? sentKind;
  String? sentRawInput;
  IntentSlots? sentSlots;
  final List<String> fulfilled = [];
  final List<String> withdrawn = [];

  @override
  Future<List<UserIntent>> myIntents() async => mine;

  @override
  Future<List<UserIntent>> matchesFor(String intentId) async => const [];

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

Widget _app(Widget child) => MaterialApp(
  locale: const Locale('zh'),
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: child,
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

    await tester.enterText(
      find.byType(TextField),
      '宿舍要清空了，小冰箱能卖多少卖多少',
    );
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

  testWidgets('"whatever you\'ll give me" is sent as an answer', (tester) async {
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

  testWidgets('a badminton partner is never asked for a price', (tester) async {
    // Pricing a person is a category error, and offering the field invites it.
    final service = _FakeIntentService();
    await tester.pumpWidget(_app(IntentPage(intentService: service)));
    await tester.pumpAndSettle();
    final l = _l(tester);

    expect(find.text(l.intentPriceWhatever), findsOneWidget);
    await tester.tap(find.text(l.intentKindCompanion));
    await tester.pumpAndSettle();
    expect(
      find.text(l.intentPriceWhatever),
      findsNothing,
      reason: 'companion intents have no price to state',
    );

    await tester.enterText(find.byType(TextField), '想找人一起打羽毛球');
    await tester.tap(find.text(l.intentSubmit));
    await tester.pumpAndSettle();
    expect(service.sentKind, IntentKind.companion);
    expect(service.sentSlots?.price, isNull);
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
          kind: IntentKind.help,
          rawInput: '有人会修自行车吗',
          slots: const IntentSlots(),
          status: 'active',
        ),
      ],
    );
    await tester.pumpWidget(_app(IntentPage(intentService: service)));
    await tester.pumpAndSettle();
    final l = _l(tester);

    expect(find.text('有人会修自行车吗'), findsOneWidget);
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

    expect(find.text('宿舍要清空了，小冰箱能卖多少卖多少'), findsOneWidget);
    expect(find.text('能卖就行'), findsOneWidget);
  });
}
