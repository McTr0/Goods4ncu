import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goods4ncu_mobile/components/social_persona_card.dart';
import 'package:goods4ncu_mobile/components/social_persona_renderer.dart';
import 'package:goods4ncu_mobile/components/user_avatar.dart';
import 'package:goods4ncu_mobile/l10n/app_localizations.dart';
import 'package:goods4ncu_mobile/models/models.dart';

class _SpyPersonaRenderer implements SocialPersonaRenderer {
  SocialPersonaRenderSpec? lastSpec;
  double? lastSize;
  double? lastMotionProgress;
  AvatarMotionCue? lastMotionCue;
  bool? lastIsDark;
  int callCount = 0;

  @override
  Widget buildCharacter(
    BuildContext context, {
    required SocialPersonaRenderSpec spec,
    required double size,
    required double motionProgress,
    required AvatarMotionCue motionCue,
    required bool isDark,
    String? semanticLabel,
  }) {
    lastSpec = spec;
    lastSize = size;
    lastMotionProgress = motionProgress;
    lastMotionCue = motionCue;
    lastIsDark = isDark;
    callCount++;
    return SizedBox(
      key: const ValueKey('spy_character'),
      width: size,
      height: size,
    );
  }
}

void main() {
  Widget buildFrame(Widget child, {bool disableAnimations = false}) {
    return MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: MediaQuery(
          data: MediaQueryData(disableAnimations: disableAnimations),
          child: Center(child: child),
        ),
      ),
    );
  }

  testWidgets(
    'two different usernames produce distinct stable deterministic character specs',
    (tester) async {
      final specAlice = SocialPersonaRenderSpec.fromName('alice');
      final specBob = SocialPersonaRenderSpec.fromName('bob');

      expect(specAlice, isNot(equals(specBob)));

      await tester.pumpWidget(
        buildFrame(
          const Row(
            children: [
              UserAvatar(name: 'alice', size: 48),
              UserAvatar(name: 'bob', size: 48),
            ],
          ),
          disableAnimations: true,
        ),
      );
      await tester.pumpAndSettle();

      final characterViews = find.byType(SocialPersonaCharacterView);
      expect(characterViews, findsNWidgets(2));
      final widgetAlice = tester.widget<SocialPersonaCharacterView>(
        characterViews.at(0),
      );
      final widgetBob = tester.widget<SocialPersonaCharacterView>(
        characterViews.at(1),
      );

      expect(widgetAlice.spec.name, 'alice');
      expect(widgetBob.spec.name, 'bob');
      expect(widgetAlice.spec, isNot(equals(widgetBob.spec)));
    },
  );

  testWidgets(
    'same username produces identical stable visual spec across rebuilds',
    (tester) async {
      final spec1 = SocialPersonaRenderSpec.fromName('charlie');
      final spec2 = SocialPersonaRenderSpec.fromName('charlie');
      expect(spec1, equals(spec2));
      expect(spec1.palette, equals(spec2.palette));
      expect(spec1.silhouette, equals(spec2.silhouette));
      expect(spec1.accessory, equals(spec2.accessory));
      expect(spec1.outfit, equals(spec2.outfit));

      await tester.pumpWidget(
        buildFrame(
          const Row(
            children: [
              UserAvatar(name: 'charlie', size: 48),
              UserAvatar(name: 'charlie', size: 48),
            ],
          ),
          disableAnimations: true,
        ),
      );
      await tester.pumpAndSettle();

      final characterViews = find.byType(SocialPersonaCharacterView);
      expect(characterViews, findsNWidgets(2));
      final widget1 = tester.widget<SocialPersonaCharacterView>(
        characterViews.at(0),
      );
      final widget2 = tester.widget<SocialPersonaCharacterView>(
        characterViews.at(1),
      );
      expect(widget1.spec, equals(widget2.spec));
    },
  );

  testWidgets(
    'fallback uses deterministic code-drawn character, never generic person icon or image',
    (tester) async {
      await tester.pumpWidget(
        buildFrame(
          const Row(
            children: [
              UserAvatar(name: 'alice'),
              UserAvatar(name: 'bob'),
            ],
          ),
          disableAnimations: true,
        ),
      );
      await tester.pumpAndSettle();

      // Renders code-drawn CustomPaint canvas
      expect(find.byType(CustomPaint), findsWidgets);

      // Must NEVER render generic person icons or network image avatars.
      expect(find.byIcon(Icons.person), findsNothing);
      expect(find.byIcon(Icons.person_outline_rounded), findsNothing);
      // Local doro portrait is the unified system fallback and is allowed.
      final images = tester.widgetList<Image>(find.byType(Image));
      for (final image in images) {
        final asset = image.image;
        if (asset is AssetImage) {
          expect(asset.assetName, contains('doro'));
        } else {
          fail('non-asset image rendered: ${image.image}');
        }
      }
    },
  );

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
          disableAnimations: true,
        ),
      );
      await tester.pumpAndSettle();

      final avatarFinder = find.byType(UserAvatar);
      expect(tester.getSize(avatarFinder), Size(size, size));
      expect(find.bySemanticsLabel('Tester Avatar'), findsOneWidget);
    }
  });

  testWidgets('persona has priority over default system fallback', (
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
        const UserAvatar(name: 'u1', persona: persona, size: 48),
        disableAnimations: true,
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

  testWidgets('renderer boundary allows a custom character engine', (
    tester,
  ) async {
    final spy = _SpyPersonaRenderer();
    await tester.pumpWidget(
      buildFrame(
        UserAvatar(name: 'alice', size: 48, renderer: spy),
        disableAnimations: true,
      ),
    );
    await tester.pumpAndSettle();

    expect(spy.callCount, greaterThanOrEqualTo(1));
    expect(spy.lastSpec?.name, 'alice');
    expect(spy.lastSize, 48.0);
    expect(spy.lastMotionProgress, 0.0);
    expect(spy.lastMotionCue, AvatarMotionCue.idle);
    expect(find.byKey(const ValueKey('spy_character')), findsOneWidget);
  });

  testWidgets('reduced motion mode forces static progress 0.0', (tester) async {
    final spy = _SpyPersonaRenderer();
    await tester.pumpWidget(
      buildFrame(
        UserAvatar(name: 'dave', size: 48, renderer: spy),
        disableAnimations: true,
      ),
    );
    await tester.pump();

    expect(spy.lastMotionProgress, 0.0);
  });

  testWidgets('motion never adds status text claims in semantics', (
    tester,
  ) async {
    await tester.pumpWidget(
      buildFrame(const UserAvatar(name: 'eve', size: 48)),
    );

    expect(find.textContaining('在线'), findsNothing);
    expect(find.textContaining('已读'), findsNothing);
    expect(find.textContaining('正在输入'), findsNothing);
    expect(find.textContaining('online'), findsNothing);
    expect(find.textContaining('typing'), findsNothing);
  });
}
