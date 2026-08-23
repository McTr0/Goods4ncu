import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goods4ncu_mobile/components/social_persona_card.dart';
import 'package:goods4ncu_mobile/l10n/app_localizations.dart';
import 'package:goods4ncu_mobile/models/models.dart';
import 'package:goods4ncu_mobile/theme/app_theme.dart';

Widget _host(Widget child, {ThemeData? theme}) {
  return MaterialApp(
    theme: theme ?? AppTheme.light,
    locale: const Locale('zh'),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(body: child),
  );
}

SocialPersona _persona() => const SocialPersona(
  representationMode: 'role_character',
  styleVersion: 'v1',
  appearance: SocialPersonaAppearance(
    palette: 'teal',
    silhouette: 'soft',
    accessory: 'leaf',
    outfit: 'campus',
  ),
  selfDescriptions: ['slow_to_warm', 'meetup_friendly'],
  contactPosture: 'leave_message',
  status: 'published',
);

void main() {
  testWidgets(
    'preview renders explicit identity choices without attention claims',
    (tester) async {
      await tester.pumpWidget(
        _host(SocialPersonaPreviewCard(persona: _persona(), title: '角色化呈现')),
      );

      expect(find.text('角色化呈现'), findsOneWidget);
      expect(find.text('可以留言，不保证即时回复'), findsOneWidget);
      expect(find.text('慢热'), findsOneWidget);
      expect(find.text('面交友好'), findsOneWidget);
      expect(find.textContaining('在线'), findsNothing);
      expect(find.textContaining('已读'), findsNothing);
      expect(find.textContaining('正在输入'), findsNothing);
    },
  );

  testWidgets('role token keeps the same deterministic visual at 24/48/160', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SocialPersonaAvatar(persona: _persona(), size: 24),
            SocialPersonaAvatar(persona: _persona(), size: 48),
            SocialPersonaAvatar(persona: _persona(), size: 160),
          ],
        ),
      ),
    );

    final avatars = find.byType(SocialPersonaAvatar);
    expect(avatars, findsNWidgets(3));
    expect(tester.getSize(avatars.at(0)), const Size(24, 24));
    expect(tester.getSize(avatars.at(1)), const Size(48, 48));
    expect(tester.getSize(avatars.at(2)), const Size(160, 160));
    expect(tester.takeException(), isNull);
  });

  testWidgets('preview card selects 48 compact and 160 full role tokens', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(SocialPersonaPreviewCard(persona: _persona(), compact: true)),
    );
    expect(
      tester.getSize(find.byType(SocialPersonaAvatar)),
      const Size(48, 48),
    );

    await tester.pumpWidget(
      _host(SocialPersonaPreviewCard(persona: _persona())),
    );
    expect(
      tester.getSize(find.byType(SocialPersonaAvatar)),
      const Size(160, 160),
    );
  });

  testWidgets(
    'role token stays static and legible in dark reduced-motion mode',
    (tester) async {
      await tester.pumpWidget(
        _host(
          MediaQuery(
            data: const MediaQueryData(disableAnimations: true),
            child: const SocialPersonaAvatar(
              persona: SocialPersona(
                representationMode: 'role_character',
                styleVersion: 'v1',
                appearance: SocialPersonaAppearance(
                  palette: 'slate',
                  silhouette: 'sharp',
                  accessory: 'glasses',
                  outfit: 'campus',
                ),
                selfDescriptions: [],
                contactPosture: 'later',
                status: 'published',
              ),
              size: 48,
            ),
          ),
          theme: AppTheme.dark,
        ),
      );

      expect(find.byType(SocialPersonaAvatar), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
