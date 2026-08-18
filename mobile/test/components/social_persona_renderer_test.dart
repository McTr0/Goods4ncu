import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goods4ncu_mobile/components/social_persona_renderer.dart';
import 'package:goods4ncu_mobile/components/open_rig_renderer.dart';
import 'package:goods4ncu_mobile/models/models.dart';

void main() {
  group('SocialPersonaRenderSpec', () {
    test(
      'deterministic hashing produces consistent spec for identical name',
      () {
        final s1 = SocialPersonaRenderSpec.fromName('alice');
        final s2 = SocialPersonaRenderSpec.fromName('alice');
        expect(s1, equals(s2));
        expect(s1.hashCode, equals(s2.hashCode));
        expect(s1.name, 'alice');
      },
    );

    test('different names produce distinct specs', () {
      final s1 = SocialPersonaRenderSpec.fromName('alice');
      final s2 = SocialPersonaRenderSpec.fromName('bob');
      expect(s1, isNot(equals(s2)));
    });

    test('empty or whitespace-only names fall back to default spec', () {
      final s1 = SocialPersonaRenderSpec.fromName('');
      final s2 = SocialPersonaRenderSpec.fromName('   ');
      expect(s1.palette, 'teal');
      expect(s1.silhouette, 'soft');
      expect(s1.accessory, 'none');
      expect(s1.outfit, 'campus');
      expect(s2.palette, 'teal');
    });

    test('creates accurately from SocialPersona model', () {
      const persona = SocialPersona(
        userId: 'user-42',
        representationMode: 'role_character',
        styleVersion: 'v1',
        appearance: SocialPersonaAppearance(
          palette: 'plum',
          silhouette: 'sharp',
          accessory: 'headphones',
          outfit: 'workwear',
          character: 'ncu_doro',
        ),
        selfDescriptions: [],
        contactPosture: 'leave_message',
        status: 'published',
      );

      final spec = SocialPersonaRenderSpec.fromPersona(persona);
      expect(spec.palette, 'plum');
      expect(spec.silhouette, 'sharp');
      expect(spec.accessory, 'headphones');
      expect(spec.outfit, 'workwear');
      expect(spec.name, 'user-42');
      expect(spec.assetId, 'ncu_doro');
    });

    test('default system character selects the versioned sprout asset', () {
      final spec = SocialPersonaRenderSpec.fromName('alice');
      expect(spec.assetId, 'sprout');
    });
  });

  group('AvatarSpriteManifest', () {
    test('parses typed local-only motion sequences', () {
      final manifest = AvatarSpriteManifest.fromJson({
        'version': 1,
        'id': 'sprout',
        'image_asset': 'assets/atlas.png',
        'columns': 2,
        'rows': 2,
        'poster_frame': 0,
        'sequences': {
          'idle': {
            'frames': [0, 1, 0, 2],
            'duration_ms': 3600,
            'loop': true,
          },
          'pressed': {
            'frames': [0, 3],
            'duration_ms': 220,
            'loop': false,
          },
        },
      });

      expect(manifest.id, 'sprout');
      expect(manifest.sequenceFor(AvatarMotionCue.idle)?.loop, isTrue);
      expect(
        manifest
            .sequenceFor(AvatarMotionCue.pressed)
            ?.frameAt(0.75, posterFrame: manifest.posterFrame),
        3,
      );
      expect(AvatarMotionCue.confirmedByUser.manifestKey, 'confirmed_by_user');
      expect(AvatarMotionCue.wave.manifestKey, 'wave');
      expect(AvatarMotionCue.celebrate.manifestKey, 'celebrate');
      expect(AvatarMotionCue.thinking.manifestKey, 'thinking');
      expect(AvatarMotionCue.poke.manifestKey, 'poke');
      expect(AvatarMotionCue.highFive.manifestKey, 'high_five');
      expect(AvatarMotionCue.encourage.manifestKey, 'encourage');
    });

    test('rejects a sequence frame outside the declared grid', () {
      expect(
        () => AvatarSpriteManifest.fromJson({
          'version': 1,
          'id': 'sprout',
          'image_asset': 'assets/atlas.png',
          'columns': 2,
          'rows': 2,
          'poster_frame': 0,
          'sequences': {
            'idle': {
              'frames': [4],
              'duration_ms': 3600,
              'loop': true,
            },
          },
        }),
        throwsFormatException,
      );
    });
  });

  group('OpenRigDefinition', () {
    test('parses mesh bones and interpolates motion tracks', () {
      final rig = OpenRigDefinition.fromJson({
        'version': 1,
        'id': 'test',
        'texture': 'assets/test.png',
        'grid': [8, 8],
        'bones': [
          {
            'id': 'root',
            'pivot': [0.5, 0.5],
            'radius': 1.0,
            'strength': 1.0,
          },
        ],
        'motions': {
          'wave': {
            'tracks': {
              'root': [
                {'t': 0.0, 'tx': 0.0},
                {'t': 1.0, 'tx': 0.2},
              ],
            },
          },
        },
      });

      expect(rig.columns, 8);
      expect(rig.bones.single.influence(const Offset(0.5, 0.5)), 1);
      final pose = rig.motionFor('wave')!.transformFor('root', 0.5);
      expect(pose.translateX, closeTo(0.1, 0.0001));
    });
  });

  group('AvatarActionController', () {
    test('replays the same semantic action with a new revision', () {
      final controller = AvatarActionController();
      var notifications = 0;
      controller.addListener(() => notifications += 1);

      controller.play(AvatarMotionCue.wave);
      final firstRevision = controller.revision;
      controller.play(AvatarMotionCue.wave);

      expect(controller.cue, AvatarMotionCue.wave);
      expect(controller.revision, firstRevision + 1);
      expect(notifications, 2);
      controller.dispose();
    });
  });

  group('PersonaPaletteTokens', () {
    test('resolves light and dark tokens for all standard palettes', () {
      for (final palette in [
        'teal',
        'plum',
        'sun',
        'slate',
        'emerald',
        'sky',
        'rose',
        'indigo',
      ]) {
        final light = PersonaPaletteTokens.resolve(palette, isDark: false);
        final dark = PersonaPaletteTokens.resolve(palette, isDark: true);

        expect(light.primary, isNotNull);
        expect(light.background, isNotNull);
        expect(dark.primary, isNotNull);
        expect(dark.background, isNotNull);
        expect(light.primary, isNot(equals(dark.primary)));
      }
    });
  });

  group('CodeDrawnPersonaRenderer & SocialPersonaCharacterView', () {
    testWidgets(
      'renders borderless campus mascot assets from character token',
      (tester) async {
        const spec = SocialPersonaRenderSpec(
          palette: 'teal',
          silhouette: 'soft',
          accessory: 'none',
          outfit: 'campus',
          assetId: 'ncu_gugugaga',
        );

        await tester.pumpWidget(
          const MaterialApp(
            home: Scaffold(
              body: SocialPersonaCharacterView(
                spec: spec,
                size: 160,
                enableMotion: false,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(
          find.byKey(const ValueKey('persona_open_rig_ncu_gugugaga')),
          findsOneWidget,
        );
        expect(find.byType(CustomPaint), findsWidgets);
      },
    );

    testWidgets('renders Phoebe Chupi from the campus character catalog', (
      tester,
    ) async {
      const spec = SocialPersonaRenderSpec(
        palette: 'teal',
        silhouette: 'soft',
        accessory: 'none',
        outfit: 'campus',
        assetId: 'ncu_phoebe_chupi',
      );

      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: SocialPersonaCharacterView(
              spec: spec,
              size: 160,
              enableMotion: false,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('persona_open_rig_ncu_phoebe_chupi')),
        findsOneWidget,
      );
    });

    testWidgets('renders CustomPaint vector character for all silhouettes', (
      tester,
    ) async {
      for (final sil in ['soft', 'round', 'sharp']) {
        final spec = SocialPersonaRenderSpec(
          palette: 'teal',
          silhouette: sil,
          accessory: 'glasses',
          outfit: 'campus',
          name: 'test-$sil',
        );

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Center(
                child: SocialPersonaCharacterView(
                  spec: spec,
                  size: 48,
                  enableMotion: false,
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.byType(CustomPaint), findsWidgets);
        expect(find.byType(SocialPersonaCharacterView), findsOneWidget);
      }
    });

    testWidgets('micro size (<32) stays static without active ticking', (
      tester,
    ) async {
      const spec = SocialPersonaRenderSpec(
        palette: 'teal',
        silhouette: 'soft',
        accessory: 'leaf',
        outfit: 'casual',
        name: 'micro',
      );

      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Center(
              child: SocialPersonaCharacterView(spec: spec, size: 24),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        tester.getSize(find.byType(SocialPersonaCharacterView)),
        const Size(24, 24),
      );
    });

    testWidgets('large character renders with idle motion when enabled', (
      tester,
    ) async {
      const spec = SocialPersonaRenderSpec(
        palette: 'plum',
        silhouette: 'round',
        accessory: 'headphones',
        outfit: 'lab',
        name: 'interactive',
      );

      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Center(
              child: SocialPersonaCharacterView(
                spec: spec,
                size: 160,
                enableMotion: true,
              ),
            ),
          ),
        ),
      );

      expect(find.byType(SocialPersonaCharacterView), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 500));
      expect(tester.takeException(), isNull);
    });
  });
}
