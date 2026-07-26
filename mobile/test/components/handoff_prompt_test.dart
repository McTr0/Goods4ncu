import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goods4ncu_mobile/components/handoff_prompt.dart';
import 'package:goods4ncu_mobile/l10n/app_localizations.dart';
import 'package:goods4ncu_mobile/services/reputation_service.dart';

class _FakeReputationService extends ReputationService {
  final List<(bool, bool?)> answers = [];

  @override
  Future<void> confirm(
    String agreementId, {
    required bool happened,
    bool? onTime,
  }) async {
    answers.add((happened, onTime));
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

void main() {
  testWidgets('there is no way to leave a comment', (tester) async {
    // A free-text field is where the social cost of an honest answer comes
    // straight back in — the thing star ratings get wrong on a campus. The
    // absence is the feature, so it is asserted.
    final service = _FakeReputationService();
    await tester.pumpWidget(
      _app(HandoffPrompt(agreementId: 'a1', service: service)),
    );
    await tester.pumpAndSettle();

    expect(find.byType(TextField), findsNothing);
    expect(find.byType(Slider), findsNothing, reason: 'and no rating either');
  });

  testWidgets('it says it is asked once before they answer', (tester) async {
    // Someone answering under the impression they can revise it later would
    // answer differently. Saying so afterwards would be too late.
    final service = _FakeReputationService();
    await tester.pumpWidget(
      _app(HandoffPrompt(agreementId: 'a1', service: service)),
    );
    await tester.pumpAndSettle();

    expect(find.text(_l(tester).handoffOnce), findsOneWidget);
    expect(service.answers, isEmpty);
  });

  testWidgets('punctuality is only asked once they say it happened', (
    tester,
  ) async {
    // "Were they late" for a meeting that never occurred is not a fact about
    // anyone.
    final service = _FakeReputationService();
    await tester.pumpWidget(
      _app(HandoffPrompt(agreementId: 'a1', service: service)),
    );
    await tester.pumpAndSettle();
    final l = _l(tester);

    expect(find.text(l.handoffOnTime), findsNothing);
    await tester.tap(find.text(l.handoffHappened));
    await tester.pumpAndSettle();
    expect(find.text(l.handoffOnTime), findsOneWidget);
    expect(find.text(l.handoffLate), findsOneWidget);

    await tester.tap(find.text(l.handoffOnTime));
    await tester.pumpAndSettle();
    expect(service.answers, [(true, true)]);
  });

  testWidgets('a no-show is recorded without a punctuality answer', (
    tester,
  ) async {
    final service = _FakeReputationService();
    await tester.pumpWidget(
      _app(HandoffPrompt(agreementId: 'a1', service: service)),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text(_l(tester).handoffMissed));
    await tester.pumpAndSettle();
    expect(service.answers, [(false, null)]);
  });

  testWidgets('the prompt stops asking once answered', (tester) async {
    final service = _FakeReputationService();
    await tester.pumpWidget(
      _app(HandoffPrompt(agreementId: 'a1', service: service)),
    );
    await tester.pumpAndSettle();
    final l = _l(tester);

    await tester.tap(find.text(l.handoffMissed));
    await tester.pumpAndSettle();

    expect(find.text(l.handoffThanks), findsOneWidget);
    expect(find.text(l.handoffMissed), findsNothing);
    expect(find.text(l.handoffHappened), findsNothing);
  });

  testWidgets('a newcomer reads as unmeasured, not as a bad record', (
    tester,
  ) async {
    // An empty tally — "completed 0, on time 0" — reads as a warning. Having no
    // history is the normal state of a first-year in September.
    await tester.pumpWidget(
      _app(
        const ReputationLine(completed: 0, onTime: 0, hasTrackRecord: false),
      ),
    );
    await tester.pumpAndSettle();
    final l = _l(tester);

    expect(find.text(l.reputationNewcomer), findsOneWidget);
    expect(find.textContaining('0'), findsNothing);
  });

  testWidgets('a record is stated as facts, not as a score', (tester) async {
    await tester.pumpWidget(
      _app(
        const ReputationLine(completed: 12, onTime: 11, hasTrackRecord: true),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text(_l(tester).reputationSummary(12, 11)), findsOneWidget);
    // No stars anywhere: a rating out of five can only be resented, and on a
    // campus it is either all fives or a fight.
    expect(find.byIcon(Icons.star), findsNothing);
    expect(find.byIcon(Icons.star_border), findsNothing);
  });
}
