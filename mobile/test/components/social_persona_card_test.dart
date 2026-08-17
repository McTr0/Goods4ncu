import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goods4ncu_mobile/components/social_persona_card.dart';
import 'package:goods4ncu_mobile/components/social_persona_renderer.dart';
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
  testWidgets('full-screen editor selects Phoebe and previews actions', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    SocialPersonaDraft? saved;
    await tester.pumpWidget(
      _host(
        Builder(
          builder: (context) => FilledButton(
            onPressed: () async {
              saved = await showSocialPersonaEditor(context, null);
            },
            child: const Text('打开角色编辑器'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('打开角色编辑器'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('南大咕咕嘎嘎'), findsOneWidget);
    expect(find.text('南大 Doro'), findsOneWidget);
    expect(find.text('南大菲比啾比'), findsOneWidget);
    expect(find.text('默认角色'), findsNothing);
    expect(find.text('打招呼'), findsOneWidget);
    expect(find.text('庆祝'), findsOneWidget);
    expect(find.text('思考'), findsOneWidget);

    await tester.tap(
      find.ancestor(of: find.text('打招呼'), matching: find.byType(ActionChip)),
    );
    await tester.pump(const Duration(milliseconds: 100));
    final animatedAvatar = tester.widget<SocialPersonaAvatar>(
      find.byType(SocialPersonaAvatar).first,
    );
    expect(animatedAvatar.motionCue, AvatarMotionCue.wave);

    await tester.tap(
      find.byKey(const ValueKey('persona_character_ncu_phoebe_chupi')),
    );
    await tester.pump(const Duration(milliseconds: 220));
    await tester.scrollUntilVisible(
      find.text('保存草稿'),
      300,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.tap(find.text('保存草稿'));
    await tester.pumpAndSettle();

    expect(saved?.appearanceConfig['character'], 'ncu_phoebe_chupi');
  });

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
