import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goods4ncu_mobile/components/agreement_card.dart';
import 'package:goods4ncu_mobile/l10n/app_localizations.dart';
import 'package:goods4ncu_mobile/models/models.dart';
import 'package:goods4ncu_mobile/services/agreement_service.dart';

const _me = 'user-me';
const _them = 'user-them';

class _FakeAgreementService extends AgreementService {
  _FakeAgreementService({required this.next});

  Agreement next;
  final List<(String, String)> adopted = [];
  final List<(String, String)> setTerms = [];
  int settles = 0;
  Object? failWith;

  @override
  Future<Agreement> adopt(
    String agreementId,
    String slot,
    String expectedValue,
  ) async {
    if (failWith != null) throw failWith!;
    adopted.add((slot, expectedValue));
    return next;
  }

  @override
  Future<Agreement> setTerm(
    String agreementId,
    String slot,
    String value, {
    int? valueCents,
  }) async {
    setTerms.add((slot, value));
    return next;
  }

  @override
  Future<Agreement> settle(String agreementId) async {
    settles++;
    return next;
  }
}

Agreement _agreement({
  required List<AgreementTerm> terms,
  bool fullyAgreed = false,
  String status = 'forming',
  String kind = 'deal',
  List<String> slots = const ['item', 'price', 'time', 'place', 'conditions'],
}) => Agreement(
  id: 'agreement-1',
  kind: kind,
  status: status,
  terms: terms,
  participants: const [_me, _them],
  fullyAgreed: fullyAgreed,
  availableSlots: slots,
);

AgreementTerm _term({
  required String slot,
  required String value,
  String proposedBy = _them,
  List<String> agreedBy = const [_them],
  bool isSuggestion = false,
}) => AgreementTerm(
  slot: slot,
  value: value,
  proposedBy: proposedBy,
  agreedBy: agreedBy,
  isSuggestion: isSuggestion,
);

Widget _app(Widget child) => MaterialApp(
  locale: const Locale('zh'),
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: Scaffold(body: SingleChildScrollView(child: child)),
);

AppLocalizations _l(WidgetTester tester) =>
    AppLocalizations.of(tester.element(find.byType(Scaffold)))!;

void main() {
  testWidgets('an assistant suggestion is never dressed as a decision', (
    tester,
  ) async {
    // The failure this guards: a misread "周三下午" that looks settled, and
    // somebody turns up on the wrong day. A suggestion has to read as a
    // question.
    final service = _FakeAgreementService(next: _agreement(terms: const []));
    final agreement = _agreement(
      terms: [
        _term(
          slot: 'time',
          value: '周三下午三点',
          proposedBy: 'assistant',
          agreedBy: const [],
          isSuggestion: true,
        ),
      ],
    );
    await tester.pumpWidget(
      _app(
        AgreementCard(
          agreement: agreement,
          service: service,
          currentUserId: _me,
        ),
      ),
    );
    await tester.pumpAndSettle();
    final l = _l(tester);

    expect(find.text('周三下午三点'), findsOneWidget);
    expect(find.text(l.agreementSuggestion), findsOneWidget);
    // And crucially not the wording used for something both sides settled.
    expect(find.text(l.agreementAgreed), findsNothing);
  });

  testWidgets('adopting sends the value that was on screen', (tester) async {
    // If the card changed underneath, the server refuses rather than agreeing
    // to something the user never saw.
    final service = _FakeAgreementService(next: _agreement(terms: const []));
    final agreement = _agreement(
      terms: [_term(slot: 'price', value: '300 元')],
    );
    await tester.pumpWidget(
      _app(
        AgreementCard(
          agreement: agreement,
          service: service,
          currentUserId: _me,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text(_l(tester).agreementAdopt));
    await tester.pumpAndSettle();
    expect(service.adopted, [('price', '300 元')]);
  });

  testWidgets(
    'a term the viewer already agreed to offers editing, not adopting',
    (tester) async {
      final service = _FakeAgreementService(next: _agreement(terms: const []));
      final agreement = _agreement(
        terms: [
          _term(
            slot: 'price',
            value: '300 元',
            proposedBy: _me,
            agreedBy: const [_me],
          ),
        ],
      );
      await tester.pumpWidget(
        _app(
          AgreementCard(
            agreement: agreement,
            service: service,
            currentUserId: _me,
          ),
        ),
      );
      await tester.pumpAndSettle();
      final l = _l(tester);

      expect(find.text(l.agreementAdopt), findsNothing);
      expect(find.text(l.edit), findsOneWidget);
      // And it says it is waiting on the other person rather than claiming
      // agreement.
      expect(find.text(l.agreementWaitingOther), findsOneWidget);
    },
  );

  testWidgets('an unset slot is shown as outstanding rather than hidden', (
    tester,
  ) async {
    // The card's job is to say what is still undecided. A slot that vanishes
    // when empty puts the user back to guessing.
    final service = _FakeAgreementService(next: _agreement(terms: const []));
    await tester.pumpWidget(
      _app(
        AgreementCard(
          agreement: _agreement(terms: const []),
          service: service,
          currentUserId: _me,
        ),
      ),
    );
    await tester.pumpAndSettle();
    final l = _l(tester);

    expect(find.text(l.agreementSlotPrice), findsOneWidget);
    expect(find.text(l.agreementSlotTime), findsOneWidget);
    expect(find.text(l.agreementNotSet), findsWidgets);
  });

  testWidgets('a meetup card has no price row', (tester) async {
    // Pricing a game of badminton is a category error, and the slot list comes
    // from the server so the client cannot drift from what the card can hold.
    final service = _FakeAgreementService(next: _agreement(terms: const []));
    await tester.pumpWidget(
      _app(
        AgreementCard(
          agreement: _agreement(
            terms: const [],
            kind: 'meetup',
            slots: const ['item', 'time', 'place', 'who', 'bring'],
          ),
          service: service,
          currentUserId: _me,
        ),
      ),
    );
    await tester.pumpAndSettle();
    final l = _l(tester);

    expect(find.text(l.agreementSlotBring), findsOneWidget);
    expect(find.text(l.agreementSlotPrice), findsNothing);
  });

  testWidgets('settling is offered only once everything is agreed', (
    tester,
  ) async {
    final service = _FakeAgreementService(next: _agreement(terms: const []));

    await tester.pumpWidget(
      _app(
        AgreementCard(
          agreement: _agreement(
            terms: [_term(slot: 'price', value: '300 元')],
          ),
          service: service,
          currentUserId: _me,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text(_l(tester).agreementSettle), findsNothing);

    await tester.pumpWidget(
      _app(
        AgreementCard(
          agreement: _agreement(
            terms: [
              _term(
                slot: 'price',
                value: '300 元',
                agreedBy: const [_me, _them],
              ),
            ],
            fullyAgreed: true,
          ),
          service: service,
          currentUserId: _me,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text(_l(tester).agreementSettle));
    await tester.pumpAndSettle();
    expect(service.settles, 1);
  });

  testWidgets('a stale adopt is explained rather than shown as a failure', (
    tester,
  ) async {
    // The term moved on. That is something to look at, not an error the user
    // caused.
    final service = _FakeAgreementService(next: _agreement(terms: const []))
      ..failWith = Exception('这一项已经变了');
    await tester.pumpWidget(
      _app(
        AgreementCard(
          agreement: _agreement(
            terms: [_term(slot: 'price', value: '300 元')],
          ),
          service: service,
          currentUserId: _me,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text(_l(tester).agreementAdopt));
    await tester.pumpAndSettle();
    expect(find.text(_l(tester).agreementStale), findsOneWidget);
  });

  testWidgets('a settled card stops offering changes', (tester) async {
    final service = _FakeAgreementService(next: _agreement(terms: const []));
    await tester.pumpWidget(
      _app(
        AgreementCard(
          agreement: _agreement(
            terms: [
              _term(
                slot: 'price',
                value: '300 元',
                agreedBy: const [_me, _them],
              ),
            ],
            fullyAgreed: true,
            status: 'settled',
          ),
          service: service,
          currentUserId: _me,
        ),
      ),
    );
    await tester.pumpAndSettle();
    final l = _l(tester);

    expect(find.text(l.agreementSettled), findsOneWidget);
    expect(find.text(l.agreementAdopt), findsNothing);
    expect(find.text(l.agreementSet), findsNothing);
    expect(find.text(l.agreementSettle), findsNothing);
  });
}
