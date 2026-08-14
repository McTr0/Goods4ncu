import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goods4ncu_mobile/components/social_persona_card.dart';
import 'package:goods4ncu_mobile/components/user_avatar.dart';
import 'package:goods4ncu_mobile/models/models.dart';

import 'package:goods4ncu_mobile/l10n/app_localizations.dart';

void main() {
  Widget buildFrame(Widget child) {
    return MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: Center(child: child)),
    );
  }

  testWidgets(
    'two different usernames produce distinct stable visual attributes',
    (tester) async {
      await tester.pumpWidget(
        buildFrame(
          const Row(
            children: [
              UserAvatar(name: 'alice', size: 48),
              UserAvatar(name: 'bob', size: 48),
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();

      final containers = tester
          .widgetList<Container>(find.byType(Container))
          .toList();
      expect(containers.length, greaterThanOrEqualTo(2));

      final decoAlice = containers[0].decoration as BoxDecoration?;
      final decoBob = containers[1].decoration as BoxDecoration?;

      expect(decoAlice?.color, isNotNull);
      expect(decoBob?.color, isNotNull);
      // alice and bob have different hashes, yielding different stable palette colors
      expect(decoAlice?.color, isNot(equals(decoBob?.color)));

      final icons = tester.widgetList<Icon>(find.byType(Icon)).toList();
      expect(icons.length, greaterThanOrEqualTo(2));
      expect(icons[0].color, isNot(equals(icons[1].color)));
    },
  );

  testWidgets(
    'same username produces identical stable visual attributes across rebuilds',
    (tester) async {
      await tester.pumpWidget(
        buildFrame(
          const Row(
            children: [
              UserAvatar(name: 'charlie', size: 48),
              UserAvatar(name: 'charlie', size: 48),
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();

      final containers = tester
          .widgetList<Container>(find.byType(Container))
          .toList();
      final deco1 = containers[0].decoration as BoxDecoration?;
      final deco2 = containers[1].decoration as BoxDecoration?;
      expect(deco1?.color, equals(deco2?.color));
    },
  );

  testWidgets('fallback uses one stable system outline across names', (
    tester,
  ) async {
    await tester.pumpWidget(
      buildFrame(
        const Row(
          children: [
            UserAvatar(name: 'alice'),
            UserAvatar(name: 'bob'),
          ],
        ),
      ),
    );
    final icons = tester.widgetList<Icon>(find.byType(Icon)).toList();
    expect(icons, hasLength(2));
    expect(icons[0].icon, Icons.person_outline_rounded);
    expect(icons[1].icon, Icons.person_outline_rounded);
  });

  testWidgets('supports tokens 24, 48, 160 with semantics label', (
    tester,
  ) async {
    for (final size in [24.0, 48.0, 160.0]) {
      await tester.pumpWidget(
        buildFrame(
          UserAvatar(
            name: 'tester',
            size: size,
            semanticLabel: 'Tester Avatar',
          ),
        ),
      );
      await tester.pumpAndSettle();

      final container = tester.widget<Container>(find.byType(Container).first);
      expect(
        container.constraints?.minWidth ?? container.constraints?.maxWidth,
        size,
      );
      expect(find.bySemanticsLabel('Tester Avatar'), findsOneWidget);
    }
  });

  testWidgets('persona has priority over avatarUrl and fallback', (
    tester,
  ) async {
    const persona = SocialPersona(
      userId: 'u1',
      representationMode: 'role_character',
      styleVersion: 'v1',
      appearance: SocialPersonaAppearance(
        palette: 'plum',
        silhouette: 'round',
        accessory: 'leaf',
        outfit: 'campus',
      ),
      selfDescriptions: ['slow_to_warm'],
      contactPosture: 'leave_message',
      status: 'published',
      publishedAt: '2026-08-12T10:00:00Z',
    );

    await tester.pumpWidget(
      buildFrame(
        UserAvatar(
          name: 'u1',
          persona: persona,
          avatarUrl: 'https://example.com/avatar.jpg',
          size: 48,
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Persona avatar truly renders SocialPersonaAvatar widget
    expect(find.byType(SocialPersonaAvatar), findsOneWidget);
    expect(
      tester.getSize(find.byType(SocialPersonaAvatar)),
      const Size(48, 48),
    );
  });
}
