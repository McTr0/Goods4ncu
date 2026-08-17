import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goods4ncu_mobile/components/user_avatar.dart';
import 'package:goods4ncu_mobile/components/xiaochang_avatar.dart';
import 'package:goods4ncu_mobile/l10n/app_localizations.dart';
import 'package:goods4ncu_mobile/models/models.dart';
import 'package:goods4ncu_mobile/theme/app_theme.dart';

Widget _host(Widget child, {Locale locale = const Locale('zh')}) {
  return MaterialApp(
    theme: AppTheme.light,
    locale: locale,
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(body: Center(child: child)),
  );
}

void main() {
  testWidgets('XiaochangAvatar renders as the personal core Avatar', (
    tester,
  ) async {
    await tester.pumpWidget(_host(const XiaochangAvatar(size: 48)));

    expect(find.byType(XiaochangAvatar), findsOneWidget);
    expect(find.byType(Image), findsOneWidget);

    final semantics = tester.getSemantics(find.byType(XiaochangAvatar));
    expect(semantics.label, contains('小昌 · 核心 Avatar'));
  });

  testWidgets('XiaochangAvatar supports different token sizes 24, 48, 160', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        const Column(
          children: [
            XiaochangAvatar(size: 24),
            XiaochangAvatar(size: 48),
            XiaochangAvatar(size: 160),
          ],
        ),
      ),
    );

    final avatars = find.byType(XiaochangAvatar);
    expect(avatars, findsNWidgets(3));
    expect(tester.getSize(avatars.at(0)), const Size(24, 24));
    expect(tester.getSize(avatars.at(1)), const Size(48, 48));
    expect(tester.getSize(avatars.at(2)), const Size(160, 160));
  });

  testWidgets('XiaochangAvatar localizes English semantic label', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(const XiaochangAvatar(size: 48), locale: const Locale('en')),
    );

    final semantics = tester.getSemantics(find.byType(XiaochangAvatar));
    expect(semantics.label, contains('Xiaochang · Core Avatar'));
  });

  testWidgets(
    'Normal users still use UserAvatar without becoming XiaochangAvatar',
    (tester) async {
      const persona = SocialPersona(
        representationMode: 'role_character',
        styleVersion: 'v1',
        appearance: SocialPersonaAppearance(
          palette: 'teal',
          silhouette: 'soft',
          accessory: 'leaf',
          outfit: 'campus',
        ),
        selfDescriptions: [],
        contactPosture: 'leave_message',
        status: 'published',
      );

      await tester.pumpWidget(
        _host(
          const Row(
            children: [
              UserAvatar(name: 'Charlie', persona: persona, size: 48),
              XiaochangAvatar(size: 48),
            ],
          ),
        ),
      );

      expect(find.byType(UserAvatar), findsOneWidget);
      expect(find.byType(XiaochangAvatar), findsOneWidget);

      final userSemantics = tester.getSemantics(find.byType(UserAvatar));
      expect(userSemantics.label, 'Charlie');
    },
  );
}
