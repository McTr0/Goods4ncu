import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goods4ncu_mobile/components/content_report_dialog.dart';
import 'package:goods4ncu_mobile/l10n/app_localizations.dart';

Widget _launcher({
  required Locale locale,
  required ValueChanged<ContentReportResult?> onResult,
}) => MaterialApp(
  locale: locale,
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: Builder(
    builder: (context) => Scaffold(
      body: FilledButton(
        onPressed: () async {
          onResult(
            await showContentReportDialog(
              context: context,
              title: AppLocalizations.of(context)!.reportListingTitle,
            ),
          );
        },
        child: const Text('open'),
      ),
    ),
  ),
);

void main() {
  testWidgets('reason is required and optional details are normalized', (
    tester,
  ) async {
    ContentReportResult? result;
    await tester.pumpWidget(
      _launcher(
        locale: const Locale('zh'),
        onResult: (value) => result = value,
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    final reasonField = tester.widget<TextFormField>(
      find.byKey(const Key('content-report-reason')),
    );
    expect(reasonField.controller!.text, '不当内容');

    await tester.enterText(
      find.byKey(const Key('content-report-reason')),
      '   ',
    );
    await tester.tap(find.byKey(const Key('content-report-submit')));
    await tester.pump();
    expect(find.text('请填写举报原因'), findsOneWidget);
    expect(result, isNull);

    await tester.enterText(
      find.byKey(const Key('content-report-reason')),
      '  疑似诈骗  ',
    );
    await tester.enterText(
      find.byKey(const Key('content-report-details')),
      '   ',
    );
    await tester.tap(find.byKey(const Key('content-report-submit')));
    await tester.pumpAndSettle();

    expect(result?.reason, '疑似诈骗');
    expect(result?.details, isNull);
  });

  testWidgets('English report copy is generated from the shared localization', (
    tester,
  ) async {
    await tester.pumpWidget(
      _launcher(locale: const Locale('en'), onResult: (_) {}),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('Report this listing'), findsOneWidget);
    expect(find.text('Inappropriate content'), findsOneWidget);
    expect(find.text('Additional details (optional)'), findsOneWidget);
  });
}
