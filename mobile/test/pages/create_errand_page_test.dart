import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goods4ncu_mobile/l10n/app_localizations.dart';
import 'package:goods4ncu_mobile/models/models.dart';
import 'package:goods4ncu_mobile/pages/create_errand_page.dart';
import 'package:goods4ncu_mobile/services/intent_service.dart';
import 'package:goods4ncu_mobile/theme/app_theme.dart';

class _FakeIntentService extends IntentService {
  IntentKind? kind;
  IntentSlots? slots;

  @override
  Future<IntentCreated> createIntent({
    required IntentKind kind,
    required String rawInput,
    IntentSlots slots = const IntentSlots(),
    DateTime? validUntil,
    bool private = false,
  }) async {
    this.kind = kind;
    this.slots = slots;
    return const IntentCreated(id: 'errand-1', specificity: 0.8);
  }
}

void main() {
  Widget app({required Widget home}) {
    return MaterialApp(
      theme: AppTheme.light,
      locale: const Locale('zh'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: home,
    );
  }

  testWidgets('publishes a structured campus errand', (tester) async {
    final service = _FakeIntentService();
    await tester.pumpWidget(
      app(home: CreateErrandPage(intentService: service)),
    );
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const ValueKey('errand-subject-field')),
      '帮我取打印材料',
    );
    await tester.enterText(
      find.byKey(const ValueKey('errand-pickup-field')),
      '前湖校区图书馆',
    );
    await tester.enterText(
      find.byKey(const ValueKey('errand-dropoff-field')),
      '修贤广场',
    );
    final printMode = find.byKey(const ValueKey('errand-mode-print'));
    await tester.ensureVisible(printMode);
    await tester.tap(printMode);
    await tester.ensureVisible(
      find.byKey(const ValueKey('errand-publish-action')),
    );
    await tester.tap(find.byKey(const ValueKey('errand-publish-action')));
    await tester.pumpAndSettle();

    expect(service.kind, IntentKind.help);
    expect(service.slots?.serviceMode, 'print');
    expect(service.slots?.pickupPlace, '前湖校区图书馆');
    expect(service.slots?.dropoffPlace, '修贤广场');
    expect(service.slots?.category, 'campus_errand');
    expect(service.slots?.serviceDirection, 'wanted');
  });

  testWidgets('can publish an offered campus service', (tester) async {
    final service = _FakeIntentService();
    await tester.pumpWidget(
      app(home: CreateErrandPage(intentService: service)),
    );
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const ValueKey('errand-subject-field')),
      '今晚可以帮忙取快递',
    );
    await tester.tap(find.text('出服务'));
    await tester.ensureVisible(
      find.byKey(const ValueKey('errand-publish-action')),
    );
    await tester.tap(find.byKey(const ValueKey('errand-publish-action')));
    await tester.pumpAndSettle();

    expect(service.kind, IntentKind.help);
    expect(service.slots?.serviceDirection, 'offer');
  });

  testWidgets('requires the errand subject', (tester) async {
    await tester.pumpWidget(
      app(home: CreateErrandPage(intentService: _FakeIntentService())),
    );
    await tester.pumpAndSettle();

    await tester.ensureVisible(
      find.byKey(const ValueKey('errand-publish-action')),
    );
    await tester.tap(find.byKey(const ValueKey('errand-publish-action')));
    await tester.pump();
    expect(find.text('请写下要帮忙完成的事情'), findsOneWidget);
  });
}
