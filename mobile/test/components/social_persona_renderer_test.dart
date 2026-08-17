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
      expect(spec.assetId, isNull);
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

    testWidgets(
      'interactive size (>=32) renders with idle motion when enabled',
      (tester) async {
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
                  size: 48,
                  enableMotion: true,
                ),
              ),
            ),
          ),
        );

        expect(find.byType(SocialPersonaCharacterView), findsOneWidget);
        await tester.pump(const Duration(milliseconds: 500));
        expect(tester.takeException(), isNull);
      },
    );
  });
}
