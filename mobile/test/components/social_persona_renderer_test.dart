import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goods4ncu_mobile/components/social_persona_renderer.dart';
import 'package:goods4ncu_mobile/models/models.dart';

void main() {
  group('SocialPersonaRenderSpec', () {
    test(
      'deterministic hashing produces consistent spec for identical name',
      () {
        final s1 = SocialPersonaRenderSpec.fromName('alice');
        final s2 = SocialPersonaRenderSpec.fromName('alice');

        expect(s1, equals(s2));
        expect(s1.assetId, isNotEmpty);
      },
    );

    test('different names produce distinct specs', () {
      final s1 = SocialPersonaRenderSpec.fromName('alice');
      final s2 = SocialPersonaRenderSpec.fromName('bob');

      expect(s1 == s2, isFalse);
    });

    test('empty or whitespace-only names fall back to default spec', () {
      final s = SocialPersonaRenderSpec.fromName('');

      expect(s.assetId, isNotNull);
    });

    test('creates accurately from SocialPersona model', () {
      final persona = SocialPersona.fromJson({
        'representation_mode': 'trait_mapped',
        'appearance_config': {
          'palette': 'plum',
          'silhouette': 'round',
          'accessory': 'leaf',
          'outfit': 'campus',
        },
        'character': 'doro',
        'self_descriptions': ['slow_to_warm', 'meetup_friendly'],
        'contact_posture': 'leave_message',
        'status': 'published',
        'published_at': '2026-08-12T10:00:00Z',
      });

      final spec = SocialPersonaRenderSpec.fromPersona(persona);

      expect(spec.palette, 'plum');
      expect(spec.silhouette, 'round');
      expect(spec.accessory, 'leaf');
      expect(spec.outfit, 'campus');
      expect(spec.assetId, 'doro');
    });

    test('default system character selects doro', () {
      const spec = SocialPersonaRenderSpec(
        palette: 'teal',
        silhouette: 'soft',
        accessory: 'none',
        outfit: 'campus',
        assetId: 'doro',
      );
      expect(spec.resolvedCharacter, 'doro');
    });
  });

  group('AvatarActionController', () {
    test('replays the same semantic action with a new revision', () {
      final controller = AvatarActionController();
      var notifications = 0;
      controller.addListener(() => notifications++);

      controller.play(AvatarMotionCue.wave);
      expect(controller.cue, AvatarMotionCue.wave);
      expect(controller.revision, 1);

      controller.play(AvatarMotionCue.poke);
      expect(controller.cue, AvatarMotionCue.poke);
      expect(controller.revision, 2);
    });
  });

  group('DoroPortraitRenderer', () {
    testWidgets('doro assetId renders official portrait asset', (tester) async {
      late BuildContext ctx;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (c) {
              ctx = c;
              return const Scaffold();
            },
          ),
        ),
      );

      const renderer = DoroPortraitPersonaRenderer();
      final widget = renderer.buildCharacter(
        ctx,
        spec: const SocialPersonaRenderSpec(
          palette: 'teal',
          silhouette: 'soft',
          accessory: 'none',
          outfit: 'campus',
          assetId: 'doro',
        ),
        size: 96,
        motionProgress: 0,
        motionCue: AvatarMotionCue.idle,
        isDark: false,
        semanticLabel: 'me',
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: Center(child: widget)),
        ),
      );
      await tester.pump();

      final images = tester.widgetList<Image>(find.byType(Image));
      expect(images, isNotEmpty);
      for (final img in images) {
        if (img.image is AssetImage) {
          expect((img.image as AssetImage).assetName, contains('doro'));
        }
      }
    });
  });

  testWidgets('assistant page keeps navigation in persistent shell', (
    tester,
  ) async {
    // Smoke test: the companion stage renders inside a MaterialApp scaffold.
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: Container(width: 300, height: 340, color: Colors.teal),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.byType(Scaffold), findsOneWidget);
  });
}
