import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goods4ncu_mobile/l10n/app_localizations.dart';
import 'package:goods4ncu_mobile/pages/settings_page.dart';
import 'package:goods4ncu_mobile/services/feed_feedback_service.dart';
import 'package:goods4ncu_mobile/services/locale_service.dart';
import 'package:goods4ncu_mobile/services/user_service.dart';

class _FakeUserService extends UserService {
  @override
  Future<Map<String, dynamic>> getUserProfile() async => {
    'user_id': 'user-1',
    'username': 'student',
    'email': 'student@email.ncu.edu.cn',
    'discoverability': <String, dynamic>{
      'username': true,
      'email': false,
      'student_id': false,
    },
    'payment_qr': <String, dynamic>{},
  };
}

class _FakeFeedFeedbackService extends FeedFeedbackService {
  bool enabled = true;
  final List<bool> updates = [];
  int clearCalls = 0;

  @override
  Future<FeedPreferences> getPreferences() async =>
      FeedPreferences(personalizationEnabled: enabled);

  @override
  Future<FeedPreferences> updatePersonalization(bool next) async {
    updates.add(next);
    enabled = next;
    return FeedPreferences(personalizationEnabled: next);
  }

  @override
  Future<void> clearPersonalization() async {
    clearCalls++;
  }
}

Widget _app(FeedFeedbackService feedbackService) {
  final notifier = LocaleNotifier();
  return LocaleProvider(
    notifier: notifier,
    child: MaterialApp(
      locale: const Locale('zh'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: SettingsPage(
        userService: _FakeUserService(),
        feedbackService: feedbackService,
      ),
    ),
  );
}

AppLocalizations _l(WidgetTester tester) =>
    AppLocalizations.of(tester.element(find.byType(SettingsPage)))!;

void main() {
  testWidgets('personalization can be disabled from settings', (tester) async {
    final feedback = _FakeFeedFeedbackService();
    await tester.pumpWidget(_app(feedback));
    await tester.pumpAndSettle();
    final l = _l(tester);
    final title = find.text(l.feedPersonalizationTitle);

    await tester.ensureVisible(title);
    await tester.pumpAndSettle();
    final tile = find.ancestor(
      of: title,
      matching: find.byType(SwitchListTile),
    );
    expect(tester.widget<SwitchListTile>(tile).value, isTrue);

    await tester.tap(tile);
    await tester.pumpAndSettle();

    expect(feedback.updates, [false]);
    expect(tester.widget<SwitchListTile>(tile).value, isFalse);
    expect(find.text(l.feedPersonalizationUpdated), findsOneWidget);
  });

  testWidgets('reset explains its scope and keeps hidden items hidden', (
    tester,
  ) async {
    final feedback = _FakeFeedFeedbackService();
    await tester.pumpWidget(_app(feedback));
    await tester.pumpAndSettle();
    final l = _l(tester);
    final reset = find.text(l.feedPersonalizationClearTitle);

    await tester.ensureVisible(reset);
    await tester.pumpAndSettle();
    await tester.tap(reset);
    await tester.pumpAndSettle();

    expect(find.text(l.feedPersonalizationClearConfirmBody), findsOneWidget);
    await tester.tap(find.text(l.feedPersonalizationClearAction));
    await tester.pumpAndSettle();

    expect(feedback.clearCalls, 1);
    expect(find.text(l.feedPersonalizationCleared), findsOneWidget);
  });
}
