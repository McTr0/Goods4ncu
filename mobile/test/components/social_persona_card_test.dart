import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goods4ncu_mobile/components/social_persona_card.dart';
import 'package:goods4ncu_mobile/l10n/app_localizations.dart';
import 'package:goods4ncu_mobile/models/models.dart';
import 'package:goods4ncu_mobile/theme/app_theme.dart';

Widget _host(Widget child) {
  return MaterialApp(
    theme: AppTheme.light,
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
}
