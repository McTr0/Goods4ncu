import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goods4ncu_mobile/components/price_discovery_sheet.dart';
import 'package:goods4ncu_mobile/l10n/app_localizations.dart';
import 'package:goods4ncu_mobile/models/models.dart';
import 'package:goods4ncu_mobile/services/price_discovery_service.dart';

const _rule = '双方各自私下说出自己的价格底线；成交价取中点；任何一方都看不到对方的数字。';

class _FakePriceService extends PriceDiscoveryService {
  _FakePriceService({required this.initial});

  PriceDiscoverySession initial;
  PriceDiscoverySession? afterLimit;
  final List<int> submitted = [];
  int accepts = 0;
  int declines = 0;

  PriceDiscoveryResult _result(PriceDiscoverySession session) =>
      PriceDiscoveryResult(
        session: session,
        rule: _rule,
        sessionId: session.id,
      );

  @override
  Future<PriceDiscoveryResult> propose(String listingId) async =>
      _result(initial);

  @override
  Future<PriceDiscoveryResult> session(String sessionId) async =>
      _result(initial);

  @override
  Future<PriceDiscoveryResult> accept(String sessionId) async {
    accepts++;
    return _result(
      PriceDiscoverySession(
        id: sessionId,
        status: 'open',
        youHaveStated: false,
      ),
    );
  }

  @override
  Future<PriceDiscoveryResult> decline(String sessionId) async {
    declines++;
    return _result(
      PriceDiscoverySession(
        id: sessionId,
        status: 'declined',
        youHaveStated: false,
      ),
    );
  }

  @override
  Future<PriceDiscoveryResult> stateLimit(String sessionId, int cents) async {
    submitted.add(cents);
    return _result(
      afterLimit ??
          PriceDiscoverySession(
            id: sessionId,
            status: 'open',
            youHaveStated: true,
          ),
    );
  }
}

Widget _app(Widget child) => MaterialApp(
  locale: const Locale('zh'),
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: Scaffold(body: child),
);

AppLocalizations _l(WidgetTester tester) =>
    AppLocalizations.of(tester.element(find.byType(Scaffold)))!;

PriceDiscoverySheet _sheet(_FakePriceService service, {bool seller = false}) =>
    PriceDiscoverySheet(
      listingId: 'listing-1',
      viewerIsSeller: seller,
      service: service,
    );

void main() {
  testWidgets('the rule is on screen before anyone states a number', (
    tester,
  ) async {
    // A pricing black box is worse than haggling — at least haggling is legible.
    // The rule comes from the server so it cannot drift from what the code does,
    // and it has to be visible before the user commits to anything.
    final service = _FakePriceService(
      initial: const PriceDiscoverySession(
        id: 's1',
        status: 'open',
        youHaveStated: false,
      ),
    );
    await tester.pumpWidget(_app(_sheet(service)));
    await tester.pumpAndSettle();

    expect(find.text(_rule), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);
  });

  testWidgets('a buyer is asked for their most, a seller for their least', (
    tester,
  ) async {
    // The only asymmetry in the whole mechanism, and it is just the prompt.
    final buyerService = _FakePriceService(
      initial: const PriceDiscoverySession(
        id: 's1',
        status: 'open',
        youHaveStated: false,
      ),
    );
    await tester.pumpWidget(_app(_sheet(buyerService)));
    await tester.pumpAndSettle();
    expect(find.text(_l(tester).priceDiscoveryBuyerHint), findsOneWidget);

    final sellerService = _FakePriceService(
      initial: const PriceDiscoverySession(
        id: 's1',
        status: 'open',
        youHaveStated: false,
      ),
    );
    await tester.pumpWidget(_app(_sheet(sellerService, seller: true)));
    await tester.pumpAndSettle();
    expect(find.text(_l(tester).priceDiscoverySellerHint), findsOneWidget);
  });

  testWidgets('a stated limit is sent in cents and then hidden', (
    tester,
  ) async {
    final service = _FakePriceService(
      initial: const PriceDiscoverySession(
        id: 's1',
        status: 'open',
        youHaveStated: false,
      ),
    );
    await tester.pumpWidget(_app(_sheet(service)));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '280');
    await tester.tap(find.text(_l(tester).priceDiscoverySubmit));
    await tester.pumpAndSettle();

    expect(service.submitted, [
      28000,
    ], reason: 'yuan on screen, cents on the wire');
    // Once stated, the field is gone: a limit cannot be revised, because
    // re-submitting until it matches would locate the other side's number.
    expect(find.byType(TextField), findsNothing);
    expect(find.text(_l(tester).priceDiscoveryWaiting), findsOneWidget);
  });

  testWidgets(
    'waiting says nothing about whether the other side has answered',
    (tester) async {
      // Knowing someone is still deciding is itself a small advantage.
      final service = _FakePriceService(
        initial: const PriceDiscoverySession(
          id: 's1',
          status: 'open',
          youHaveStated: true,
        ),
      );
      await tester.pumpWidget(_app(_sheet(service)));
      await tester.pumpAndSettle();

      final text = _l(tester).priceDiscoveryWaiting;
      expect(find.text(text), findsOneWidget);
      expect(
        text.contains('对方已'),
        isFalse,
        reason: 'no claim about their state',
      );
    },
  );

  testWidgets('a match shows the agreed price and nothing else', (
    tester,
  ) async {
    final service = _FakePriceService(
      initial: const PriceDiscoverySession(
        id: 's1',
        status: 'matched',
        matchedCents: 26500,
        youHaveStated: true,
      ),
    );
    await tester.pumpWidget(_app(_sheet(service)));
    await tester.pumpAndSettle();

    expect(
      find.text(_l(tester).priceDiscoveryMatched('265.00')),
      findsOneWidget,
    );
    // The inputs that produced it are not on screen, and the widget has no field
    // that could carry them.
    for (final secret in ['280', '250', '28000', '25000']) {
      expect(
        find.textContaining(secret),
        findsNothing,
        reason: 'neither limit may be displayed',
      );
    }
  });

  testWidgets('no deal says so without hinting at the gap', (tester) async {
    // The property most likely to be softened later by someone trying to be
    // helpful. "You were 20 short" hands one side the other's floor.
    final service = _FakePriceService(
      initial: const PriceDiscoverySession(
        id: 's1',
        status: 'no_deal',
        youHaveStated: true,
      ),
    );
    await tester.pumpWidget(_app(_sheet(service)));
    await tester.pumpAndSettle();

    final message = _l(tester).priceDiscoveryNoDeal;
    expect(find.text(message), findsOneWidget);
    expect(
      RegExp(r'\d').hasMatch(message),
      isFalse,
      reason: 'the no-deal message must contain no figure at all',
    );
  });

  testWidgets('an invitation can be declined in favour of talking', (
    tester,
  ) async {
    // Both sides opt in, and declining is a peer of agreeing rather than a way
    // out — a mechanism nobody chose is not a kindness.
    final service = _FakePriceService(
      initial: const PriceDiscoverySession(
        id: 's1',
        status: 'proposed',
        youHaveStated: false,
      ),
    );
    await tester.pumpWidget(_app(_sheet(service)));
    await tester.pumpAndSettle();
    final l = _l(tester);

    expect(find.text(l.priceDiscoveryAgree), findsOneWidget);
    expect(find.text(l.priceDiscoveryPreferHaggle), findsOneWidget);

    await tester.tap(find.text(l.priceDiscoveryPreferHaggle));
    await tester.pumpAndSettle();
    expect(service.declines, 1);
    expect(service.submitted, isEmpty, reason: 'declining states no limit');
    expect(find.text(l.priceDiscoveryDeclined), findsOneWidget);
  });

  testWidgets('a nonsense limit is refused rather than coerced', (
    tester,
  ) async {
    // A typo here is a real trade at a wrong price.
    final service = _FakePriceService(
      initial: const PriceDiscoverySession(
        id: 's1',
        status: 'open',
        youHaveStated: false,
      ),
    );
    await tester.pumpWidget(_app(_sheet(service)));
    await tester.pumpAndSettle();
    final l = _l(tester);

    await tester.tap(find.text(l.priceDiscoverySubmit));
    await tester.pumpAndSettle();
    expect(service.submitted, isEmpty);
    expect(find.text(l.priceDiscoveryInvalid), findsOneWidget);
  });
}
