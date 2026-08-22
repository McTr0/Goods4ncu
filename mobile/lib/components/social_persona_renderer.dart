import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/models.dart';
import 'open_rig_renderer.dart';

/// Resolved specification for rendering a SocialPersona or default system character.
class SocialPersonaRenderSpec {
  const SocialPersonaRenderSpec({
    required this.palette,
    required this.silhouette,
    required this.accessory,
    required this.outfit,
    this.name = '',
    this.assetId,
  });

  final String palette;
  final String silhouette;
  final String accessory;
  final String outfit;
  final String name;
  final String? assetId;

  /// Creates a spec from a published [SocialPersona].
  factory SocialPersonaRenderSpec.fromPersona(
    SocialPersona persona, {
    String? name,
  }) {
    final rawChar = persona.appearance.character;
    final character = switch (rawChar) {
      'classic' || '' => 'doro',
      _ => rawChar,
    };
    return SocialPersonaRenderSpec(
      palette: persona.appearance.palette,
      silhouette: persona.appearance.silhouette,
      accessory: persona.appearance.accessory,
      outfit: persona.appearance.outfit,
      name: name ?? persona.userId ?? '',
      assetId: character,
    );
  }

  /// Creates a deterministic spec from a user name for stable default system characters.
  factory SocialPersonaRenderSpec.fromName(String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) {
      return const SocialPersonaRenderSpec(
        palette: 'teal',
        silhouette: 'soft',
        accessory: 'none',
        outfit: 'campus',
        name: '',
        assetId: 'doro',
      );
    }
    final hash = _stableHash(trimmed);
    const palettes = [
      'teal',
      'plum',
      'sun',
      'slate',
      'emerald',
      'sky',
      'rose',
      'indigo',
    ];
    const silhouettes = ['soft', 'round', 'sharp'];
    const accessories = ['none', 'glasses', 'headphones', 'leaf'];
    const outfits = ['campus', 'workwear', 'casual', 'lab'];

    final palIdx = hash.abs() % palettes.length;
    final silIdx = (hash.abs() ~/ palettes.length) % silhouettes.length;
    final accIdx =
        (hash.abs() ~/ (palettes.length * silhouettes.length)) %
        accessories.length;
    final outIdx =
        (hash.abs() ~/
            (palettes.length * silhouettes.length * accessories.length)) %
        outfits.length;

    return SocialPersonaRenderSpec(
      palette: palettes[palIdx],
      silhouette: silhouettes[silIdx],
      accessory: accessories[accIdx],
      outfit: outfits[outIdx],
      name: trimmed,
      assetId: 'doro',
    );
  }

  static int _stableHash(String text) {
    var hash = 0x811c9dc5;
    for (var i = 0; i < text.length; i++) {
      hash ^= text.codeUnitAt(i);
      hash = (hash * 0x01000193) & 0x7fffffff;
    }
    return hash;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SocialPersonaRenderSpec &&
          runtimeType == other.runtimeType &&
          palette == other.palette &&
          silhouette == other.silhouette &&
          accessory == other.accessory &&
          outfit == other.outfit &&
          name == other.name &&
          assetId == other.assetId;

  @override
  int get hashCode =>
      Object.hash(palette, silhouette, accessory, outfit, name, assetId);
}

/// Local-only motion cues accepted by Avatar renderers.
///
/// These cues describe the character's presentation or an explicit action by
/// the current user. They must never be derived from online, read, typing, or
/// inferred emotional state.
enum AvatarMotionCue {
  idle,
  pressed,
  selected,
  published,
  confirmedByUser,
  wave,
  celebrate,
  thinking,
  poke,
  highFive,
  encourage,
  acknowledge,
}

extension AvatarMotionCueContract on AvatarMotionCue {
  String get manifestKey => switch (this) {
    AvatarMotionCue.idle => 'idle',
    AvatarMotionCue.pressed => 'pressed',
    AvatarMotionCue.selected => 'selected',
    AvatarMotionCue.published => 'published',
    AvatarMotionCue.confirmedByUser => 'confirmed_by_user',
    AvatarMotionCue.wave => 'wave',
    AvatarMotionCue.celebrate => 'celebrate',
    AvatarMotionCue.thinking => 'thinking',
    AvatarMotionCue.poke => 'poke',
    AvatarMotionCue.highFive => 'high_five',
    AvatarMotionCue.encourage => 'encourage',
    AvatarMotionCue.acknowledge => 'acknowledge',
  };

  Duration get fallbackDuration => switch (this) {
    AvatarMotionCue.idle => const Duration(milliseconds: 3600),
    AvatarMotionCue.pressed => const Duration(milliseconds: 220),
    AvatarMotionCue.selected => const Duration(milliseconds: 420),
    AvatarMotionCue.published => const Duration(milliseconds: 640),
    AvatarMotionCue.confirmedByUser => const Duration(milliseconds: 480),
    AvatarMotionCue.wave => const Duration(milliseconds: 720),
    AvatarMotionCue.celebrate => const Duration(milliseconds: 820),
    AvatarMotionCue.thinking => const Duration(milliseconds: 1100),
    AvatarMotionCue.poke => const Duration(milliseconds: 760),
    AvatarMotionCue.highFive => const Duration(milliseconds: 900),
    AvatarMotionCue.encourage => const Duration(milliseconds: 1050),
    AvatarMotionCue.acknowledge => const Duration(milliseconds: 680),
  };

  bool get loops => this == AvatarMotionCue.idle;
}

/// Semantic command source for avatar interactions.
///
/// [revision] changes on every [play] call so callers can replay the same
/// action without briefly switching through an unrelated state. Network
/// presence and message attention must never drive this controller.
class AvatarActionController extends ChangeNotifier {
  AvatarActionController({AvatarMotionCue initialCue = AvatarMotionCue.idle})
    : _cue = initialCue;

  AvatarMotionCue _cue;
  int _revision = 0;

  AvatarMotionCue get cue => _cue;
  int get revision => _revision;

  void play(AvatarMotionCue cue) {
    _cue = cue;
    _revision += 1;
    notifyListeners();
  }
}

/// Color tokens tailored for character presentation in light and dark themes.
class PersonaPaletteTokens {
  const PersonaPaletteTokens({
    required this.primary,
    required this.background,
    required this.surface,
    required this.accent,
    required this.outline,
    required this.clothing,
    required this.skin,
    required this.eyes,
  });

  final Color primary;
  final Color background;
  final Color surface;
  final Color accent;
  final Color outline;
  final Color clothing;
  final Color skin;
  final Color eyes;

  static PersonaPaletteTokens resolve(String palette, {required bool isDark}) {
    return switch (palette) {
      'plum' =>
        isDark
            ? const PersonaPaletteTokens(
                primary: Color(0xFFA78BFA),
                background: Color(0xFF2E1065),
                surface: Color(0xFF3B0764),
                accent: Color(0xFFC084FC),
                outline: Color(0xFF8B5CF6),
                clothing: Color(0xFF581C87),
                skin: Color(0xFFEDE9FE),
                eyes: Color(0xFF1E1B4B),
              )
            : const PersonaPaletteTokens(
                primary: Color(0xFF7C3AED),
                background: Color(0xFFEDE9FE),
                surface: Color(0xFFDDD6FE),
                accent: Color(0xFFA78BFA),
                outline: Color(0xFF8B5CF6),
                clothing: Color(0xFF6D28D9),
                skin: Color(0xFFFFF7ED),
                eyes: Color(0xFF2E1065),
              ),
      'sun' =>
        isDark
            ? const PersonaPaletteTokens(
                primary: Color(0xFFFBBF24),
                background: Color(0xFF451A03),
                surface: Color(0xFF78350F),
                accent: Color(0xFFFCD34D),
                outline: Color(0xFFF59E0B),
                clothing: Color(0xFF92400E),
                skin: Color(0xFFFEF3C7),
                eyes: Color(0xFF261005),
              )
            : const PersonaPaletteTokens(
                primary: Color(0xFFD97706),
                background: Color(0xFFFEF3C7),
                surface: Color(0xFFFDE68A),
                accent: Color(0xFFFBBF24),
                outline: Color(0xFFF59E0B),
                clothing: Color(0xFFB45309),
                skin: Color(0xFFFFF7ED),
                eyes: Color(0xFF451A03),
              ),
      'slate' =>
        isDark
            ? const PersonaPaletteTokens(
                primary: Color(0xFF94A3B8),
                background: Color(0xFF0F172A),
                surface: Color(0xFF1E293B),
                accent: Color(0xFFCBD5E1),
                outline: Color(0xFF64748B),
                clothing: Color(0xFF334155),
                skin: Color(0xFFF1F5F9),
                eyes: Color(0xFF020617),
              )
            : const PersonaPaletteTokens(
                primary: Color(0xFF475569),
                background: Color(0xFFF1F5F9),
                surface: Color(0xFFE2E8F0),
                accent: Color(0xFF94A3B8),
                outline: Color(0xFF64748B),
                clothing: Color(0xFF334155),
                skin: Color(0xFFFFF7ED),
                eyes: Color(0xFF0F172A),
              ),
      'emerald' =>
        isDark
            ? const PersonaPaletteTokens(
                primary: Color(0xFF34D399),
                background: Color(0xFF064E3B),
                surface: Color(0xFF065F46),
                accent: Color(0xFF6EE7B7),
                outline: Color(0xFF10B981),
                clothing: Color(0xFF047857),
                skin: Color(0xFFD1FAE5),
                eyes: Color(0xFF022C22),
              )
            : const PersonaPaletteTokens(
                primary: Color(0xFF059669),
                background: Color(0xFFD1FAE5),
                surface: Color(0xFFA7F3D0),
                accent: Color(0xFF34D399),
                outline: Color(0xFF10B981),
                clothing: Color(0xFF047857),
                skin: Color(0xFFFFF7ED),
                eyes: Color(0xFF064E3B),
              ),
      'sky' =>
        isDark
            ? const PersonaPaletteTokens(
                primary: Color(0xFF38BDF8),
                background: Color(0xFF082F49),
                surface: Color(0xFF075985),
                accent: Color(0xFF7DD3FC),
                outline: Color(0xFF0EA5E9),
                clothing: Color(0xFF0369A1),
                skin: Color(0xFFE0F2FE),
                eyes: Color(0xFF031A29),
              )
            : const PersonaPaletteTokens(
                primary: Color(0xFF0284C7),
                background: Color(0xFFE0F2FE),
                surface: Color(0xFFBAE6FD),
                accent: Color(0xFF38BDF8),
                outline: Color(0xFF0EA5E9),
                clothing: Color(0xFF0369A1),
                skin: Color(0xFFFFF7ED),
                eyes: Color(0xFF082F49),
              ),
      'rose' =>
        isDark
            ? const PersonaPaletteTokens(
                primary: Color(0xFFFB7185),
                background: Color(0xFF4C0519),
                surface: Color(0xFF881337),
                accent: Color(0xFFFDA4AF),
                outline: Color(0xFFF43F5E),
                clothing: Color(0xFF9F1239),
                skin: Color(0xFFFFE4E6),
                eyes: Color(0xFF2A020E),
              )
            : const PersonaPaletteTokens(
                primary: Color(0xFFE11D48),
                background: Color(0xFFFFE4E6),
                surface: Color(0xFFFECDD3),
                accent: Color(0xFFFB7185),
                outline: Color(0xFFF43F5E),
                clothing: Color(0xFFBE123C),
                skin: Color(0xFFFFF7ED),
                eyes: Color(0xFF4C0519),
              ),
      'indigo' =>
        isDark
            ? const PersonaPaletteTokens(
                primary: Color(0xFF818CF8),
                background: Color(0xFF1E1B4B),
                surface: Color(0xFF312E81),
                accent: Color(0xFFA5B4FC),
                outline: Color(0xFF6366F1),
                clothing: Color(0xFF3730A3),
                skin: Color(0xFFEEF2FF),
                eyes: Color(0xFF0F0E2A),
              )
            : const PersonaPaletteTokens(
                primary: Color(0xFF4F46E5),
                background: Color(0xFFEEF2FF),
                surface: Color(0xFFE0E7FF),
                accent: Color(0xFF818CF8),
                outline: Color(0xFF6366F1),
                clothing: Color(0xFF4338CA),
                skin: Color(0xFFFFF7ED),
                eyes: Color(0xFF1E1B4B),
              ),
      _ =>
        isDark // 'teal' and fallback default
            ? const PersonaPaletteTokens(
                primary: Color(0xFF2DD4BF),
                background: Color(0xFF134E4A),
                surface: Color(0xFF115E59),
                accent: Color(0xFF5EEAD4),
                outline: Color(0xFF14B8A6),
                clothing: Color(0xFF0F766E),
                skin: Color(0xFFCCFBF1),
                eyes: Color(0xFF042F2E),
              )
            : const PersonaPaletteTokens(
                primary: Color(0xFF0F766E),
                background: Color(0xFFCCFBF1),
                surface: Color(0xFF99F6E4),
                accent: Color(0xFF14B8A6),
                outline: Color(0xFF14B8A6),
                clothing: Color(0xFF115E59),
                skin: Color(0xFFFFF7ED),
                eyes: Color(0xFF042F2E),
              ),
    };
  }
}

/// Abstract renderer boundary for SocialPersona character presentation.
///
/// This boundary isolates character visual rendering from identity avatar components.
///
/// The default implementation uses a versioned sprite atlas for the system
/// character and falls back to [CodeDrawnPersonaRenderer] for configured
/// personas or asset failures.
abstract class SocialPersonaRenderer {
  Widget buildCharacter(
    BuildContext context, {
    required SocialPersonaRenderSpec spec,
    required double size,
    required double motionProgress,
    required AvatarMotionCue motionCue,
    required bool isDark,
    String? semanticLabel,
  });
}

/// Deterministic code-drawn vector character renderer.
class CodeDrawnPersonaRenderer implements SocialPersonaRenderer {
  const CodeDrawnPersonaRenderer();

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
    final tokens = PersonaPaletteTokens.resolve(spec.palette, isDark: isDark);
    final radius = switch (spec.silhouette) {
      'round' => size * 0.38,
      'sharp' => size * 0.13,
      _ => size * 0.24,
    };

    final content = CustomPaint(
      size: Size(size, size),
      painter: _PersonaCharacterPainter(
        spec: spec,
        tokens: tokens,
        motionProgress: motionProgress,
        radius: radius,
      ),
    );

    if (semanticLabel == null || semanticLabel.isEmpty) {
      return content;
    }

    return Semantics(label: semanticLabel, image: true, child: content);
  }
}

class AvatarSpriteSequence {
  const AvatarSpriteSequence({
    required this.frames,
    required this.duration,
    required this.loop,
  });

  final List<int> frames;
  final Duration duration;
  final bool loop;

  factory AvatarSpriteSequence.fromJson(Map<String, Object?> json) {
    final frames = (json['frames'] as List<Object?>? ?? const <Object?>[])
        .whereType<num>()
        .map((frame) => frame.toInt())
        .toList(growable: false);
    return AvatarSpriteSequence(
      frames: frames,
      duration: Duration(
        milliseconds: (json['duration_ms'] as num?)?.toInt() ?? 0,
      ),
      loop: json['loop'] == true,
    );
  }

  int frameAt(double progress, {required int posterFrame}) {
    if (frames.isEmpty) return posterFrame;
    final normalized = progress.clamp(0.0, 0.999999);
    return frames[(normalized * frames.length).floor()];
  }
}

class AvatarSpriteManifest {
  const AvatarSpriteManifest({
    required this.version,
    required this.id,
    required this.imageAsset,
    required this.columns,
    required this.rows,
    required this.posterFrame,
    required this.sequences,
  });

  final int version;
  final String id;
  final String imageAsset;
  final int columns;
  final int rows;
  final int posterFrame;
  final Map<String, AvatarSpriteSequence> sequences;

  factory AvatarSpriteManifest.fromJson(Map<String, Object?> json) {
    final rawSequences =
        json['sequences'] as Map<String, Object?>? ?? const <String, Object?>{};
    final manifest = AvatarSpriteManifest(
      version: (json['version'] as num?)?.toInt() ?? 0,
      id: json['id'] as String? ?? '',
      imageAsset: json['image_asset'] as String? ?? '',
      columns: (json['columns'] as num?)?.toInt() ?? 0,
      rows: (json['rows'] as num?)?.toInt() ?? 0,
      posterFrame: (json['poster_frame'] as num?)?.toInt() ?? 0,
      sequences: rawSequences.map(
        (key, value) => MapEntry(
          key,
          AvatarSpriteSequence.fromJson(value as Map<String, Object?>),
        ),
      ),
    );
    manifest.validate();
    return manifest;
  }

  void validate() {
    if (version != 1 || id.isEmpty || imageAsset.isEmpty) {
      throw const FormatException('Unsupported Avatar sprite manifest');
    }
    if (columns <= 0 || rows <= 0) {
      throw const FormatException('Avatar atlas grid must be positive');
    }
    final frameCount = columns * rows;
    if (posterFrame < 0 || posterFrame >= frameCount) {
      throw const FormatException('Avatar poster frame is outside the atlas');
    }
    for (final sequence in sequences.values) {
      if (sequence.frames.any((frame) => frame < 0 || frame >= frameCount)) {
        throw const FormatException(
          'Avatar sequence frame is outside the atlas',
        );
      }
    }
  }

  AvatarSpriteSequence? sequenceFor(AvatarMotionCue cue) =>
      sequences[cue.manifestKey];
}

class _LoadedAvatarSpriteAtlas {
  const _LoadedAvatarSpriteAtlas({required this.manifest, required this.image});

  final AvatarSpriteManifest manifest;
  final ui.Image image;
}

/// Asset-backed renderer for the stable default system Avatar.
///
/// Configured personas remain code-drawn until they have approved atlas packs,
/// preserving their selected palette, silhouette, accessory, and outfit.
class SpriteAtlasPersonaRenderer implements SocialPersonaRenderer {
  const SpriteAtlasPersonaRenderer({
    required this.manifestAsset,
    this.assetId = 'sprout',
    this.fallback = const CodeDrawnPersonaRenderer(),
  });

  final String manifestAsset;
  final String assetId;
  final SocialPersonaRenderer fallback;

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
    if (spec.assetId != assetId) {
      return fallback.buildCharacter(
        context,
        spec: spec,
        size: size,
        motionProgress: motionProgress,
        motionCue: motionCue,
        isDark: isDark,
        semanticLabel: semanticLabel,
      );
    }

    return _SpriteAtlasCharacter(
      manifestAsset: manifestAsset,
      fallback: fallback,
      spec: spec,
      size: size,
      motionProgress: motionProgress,
      motionCue: motionCue,
      isDark: isDark,
      semanticLabel: semanticLabel,
    );
  }
}

class _SpriteAtlasCharacter extends StatefulWidget {
  const _SpriteAtlasCharacter({
    required this.manifestAsset,
    required this.fallback,
    required this.spec,
    required this.size,
    required this.motionProgress,
    required this.motionCue,
    required this.isDark,
    this.semanticLabel,
  });

  final String manifestAsset;
  final SocialPersonaRenderer fallback;
  final SocialPersonaRenderSpec spec;
  final double size;
  final double motionProgress;
  final AvatarMotionCue motionCue;
  final bool isDark;
  final String? semanticLabel;

  @override
  State<_SpriteAtlasCharacter> createState() => _SpriteAtlasCharacterState();
}

class _SpriteAtlasCharacterState extends State<_SpriteAtlasCharacter> {
  static final Map<String, Future<_LoadedAvatarSpriteAtlas>> _cache = {};
  late Future<_LoadedAvatarSpriteAtlas> _atlas;

  @override
  void initState() {
    super.initState();
    _atlas = _load(widget.manifestAsset);
  }

  @override
  void didUpdateWidget(_SpriteAtlasCharacter oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.manifestAsset != widget.manifestAsset) {
      _atlas = _load(widget.manifestAsset);
    }
  }

  Future<_LoadedAvatarSpriteAtlas> _load(String manifestAsset) {
    return _cache.putIfAbsent(manifestAsset, () async {
      final manifestJson = jsonDecode(
        await rootBundle.loadString(manifestAsset),
      );
      final manifest = AvatarSpriteManifest.fromJson(
        manifestJson as Map<String, Object?>,
      );
      final imageData = await rootBundle.load(manifest.imageAsset);
      final codec = await ui.instantiateImageCodec(
        imageData.buffer.asUint8List(
          imageData.offsetInBytes,
          imageData.lengthInBytes,
        ),
      );
      final frame = await codec.getNextFrame();
      codec.dispose();
      return _LoadedAvatarSpriteAtlas(manifest: manifest, image: frame.image);
    });
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<_LoadedAvatarSpriteAtlas>(
      future: _atlas,
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return widget.fallback.buildCharacter(
            context,
            spec: widget.spec,
            size: widget.size,
            motionProgress: widget.motionProgress,
            motionCue: widget.motionCue,
            isDark: widget.isDark,
            semanticLabel: widget.semanticLabel,
          );
        }

        final atlas = snapshot.requireData;
        final sequence = atlas.manifest.sequenceFor(widget.motionCue);
        final frame =
            sequence?.frameAt(
              widget.motionProgress,
              posterFrame: atlas.manifest.posterFrame,
            ) ??
            atlas.manifest.posterFrame;
        Widget character = CustomPaint(
          size: Size.square(widget.size),
          painter: _SpriteAtlasPainter(
            image: atlas.image,
            manifest: atlas.manifest,
            frame: frame,
            background: PersonaPaletteTokens.resolve(
              widget.spec.palette,
              isDark: widget.isDark,
            ).background,
          ),
        );
        if (widget.semanticLabel case final label? when label.isNotEmpty) {
          character = Semantics(label: label, image: true, child: character);
        }
        return character;
      },
    );
  }
}

class _SpriteAtlasPainter extends CustomPainter {
  const _SpriteAtlasPainter({
    required this.image,
    required this.manifest,
    required this.frame,
    required this.background,
  });

  final ui.Image image;
  final AvatarSpriteManifest manifest;
  final int frame;
  final Color background;

  @override
  void paint(Canvas canvas, Size size) {
    final destination = Offset.zero & size;
    final radius = Radius.circular(size.shortestSide * 0.24);
    final clip = RRect.fromRectAndRadius(destination, radius);
    canvas.save();
    canvas.clipRRect(clip);
    canvas.drawColor(background, BlendMode.src);

    final cellWidth = image.width / manifest.columns;
    final cellHeight = image.height / manifest.rows;
    final column = frame % manifest.columns;
    final row = frame ~/ manifest.columns;
    final source = Rect.fromLTWH(
      column * cellWidth,
      row * cellHeight,
      cellWidth,
      cellHeight,
    );
    canvas.drawImageRect(
      image,
      source,
      destination,
      Paint()..filterQuality = FilterQuality.medium,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_SpriteAtlasPainter oldDelegate) =>
      oldDelegate.image != image ||
      oldDelegate.frame != frame ||
      oldDelegate.background != background;
}

/// Borderless campus mascot renderer backed by the repository-owned open rig.
///
/// A low-density mesh deforms a transparent PNG texture using JSON-authored
/// bone influences and motion tracks. This keeps the runtime and asset format
/// free of editor subscriptions while supporting Android, iOS and Web through
/// Flutter's Canvas/Impeller stack.
class CampusMascotPersonaRenderer implements SocialPersonaRenderer {
  const CampusMascotPersonaRenderer({required this.fallback});

  final SocialPersonaRenderer fallback;

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
    final assetId = spec.assetId;
    if (assetId == null || !OpenRigAssetCache.manifests.containsKey(assetId)) {
      return fallback.buildCharacter(
        context,
        spec: spec,
        size: size,
        motionProgress: motionProgress,
        motionCue: motionCue,
        isDark: isDark,
        semanticLabel: semanticLabel,
      );
    }
    final fallbackCharacter = fallback.buildCharacter(
      context,
      spec: spec,
      size: size,
      motionProgress: motionProgress,
      motionCue: motionCue,
      isDark: isDark,
      semanticLabel: null,
    );
    Widget character = SizedBox.square(
      dimension: size,
      child: OpenRigCharacter(
        characterId: assetId,
        size: size,
        motionKey: motionCue.manifestKey,
        progress: motionProgress,
        fallback: fallbackCharacter,
      ),
    );
    if (semanticLabel case final label? when label.isNotEmpty) {
      character = Semantics(label: label, image: true, child: character);
    }
    return character;
  }
}

const defaultPersonaRenderer = CampusMascotPersonaRenderer(
  fallback: SpriteAtlasPersonaRenderer(
    manifestAsset: 'assets/avatars/v1/sprout/manifest.json',
  ),
);

/// Widget that hosts a character spec with subtle local-only idle motion.
///
/// Default list-scale avatars stay static; 96px+ previews animate. A focused
/// caller can explicitly opt a smaller avatar in, and reduced motion always
/// wins.
///
/// Motion is local-only and NEVER reflects online, read, typing, or background activity.
class SocialPersonaCharacterView extends StatefulWidget {
  const SocialPersonaCharacterView({
    super.key,
    required this.spec,
    required this.size,
    this.enableMotion,
    this.motionCue = AvatarMotionCue.idle,
    this.motionRevision = 0,
    this.renderer,
    this.semanticLabel,
  }) : assert(size > 0);

  final SocialPersonaRenderSpec spec;
  final double size;
  final bool? enableMotion;
  final AvatarMotionCue motionCue;
  final int motionRevision;
  final SocialPersonaRenderer? renderer;
  final String? semanticLabel;

  @override
  State<SocialPersonaCharacterView> createState() =>
      _SocialPersonaCharacterViewState();
}

class _SocialPersonaCharacterViewState extends State<SocialPersonaCharacterView>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: widget.motionCue.fallbackDuration,
    );
  }

  bool _shouldAnimate(BuildContext context) {
    if (widget.enableMotion == false) return false;
    // Tiny token sizes (like 24px list icons) remain static for crispness and performance
    if (widget.size < 32) return false;
    final media = MediaQuery.maybeOf(context);
    if (media?.disableAnimations == true) return false;
    if (widget.enableMotion == true) return true;
    // Default list and message avatars stay static. Large profile/preview
    // characters animate, while callers can opt a smaller focused avatar in.
    return widget.size >= 96;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncMotion();
  }

  @override
  void didUpdateWidget(SocialPersonaCharacterView oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncMotion(
      restart:
          oldWidget.motionCue != widget.motionCue ||
          oldWidget.motionRevision != widget.motionRevision ||
          oldWidget.enableMotion != widget.enableMotion ||
          oldWidget.size != widget.size,
    );
  }

  void _syncMotion({bool restart = false}) {
    _controller.duration = widget.motionCue.fallbackDuration;
    if (!_shouldAnimate(context)) {
      _controller.stop();
      _controller.value = 0.0;
      return;
    }
    if (widget.motionCue.loops) {
      if (!_controller.isAnimating || restart) {
        _controller.repeat();
      }
      return;
    }
    if (restart || _controller.status == AnimationStatus.dismissed) {
      _controller.forward(from: 0.0);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final renderer = widget.renderer ?? defaultPersonaRenderer;
    final shouldAnimate = _shouldAnimate(context);

    if (!shouldAnimate) {
      return renderer.buildCharacter(
        context,
        spec: widget.spec,
        size: widget.size,
        motionProgress: 0.0,
        motionCue: widget.motionCue,
        isDark: isDark,
        semanticLabel: widget.semanticLabel,
      );
    }

    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        return renderer.buildCharacter(
          context,
          spec: widget.spec,
          size: widget.size,
          motionProgress: _controller.value,
          motionCue: widget.motionCue,
          isDark: isDark,
          semanticLabel: widget.semanticLabel,
        );
      },
    );
  }
}

class _PersonaCharacterPainter extends CustomPainter {
  const _PersonaCharacterPainter({
    required this.spec,
    required this.tokens,
    required this.motionProgress,
    required this.radius,
  });

  final SocialPersonaRenderSpec spec;
  final PersonaPaletteTokens tokens;
  final double motionProgress;
  final double radius;

  @override
  void paint(Canvas canvas, Size size) {
    final width = size.width;
    final height = size.height;
    final cx = width * 0.5;
    final cy = height * 0.5;

    // 1. Clip and outer container
    final outerRect = RRect.fromRectAndRadius(
      Rect.fromLTWH(0, 0, width, height),
      Radius.circular(radius),
    );
    canvas.save();
    canvas.clipRRect(outerRect);

    // Background fill
    final bgPaint = Paint()..color = tokens.background;
    canvas.drawPaint(bgPaint);

    // Background soft radial depth
    final depthPaint = Paint()
      ..shader = RadialGradient(
        center: const Alignment(0, -0.2),
        radius: 0.8,
        colors: [
          tokens.surface.withValues(alpha: 0.4),
          tokens.background.withValues(alpha: 0.0),
        ],
      ).createShader(Rect.fromLTWH(0, 0, width, height));
    canvas.drawRect(Rect.fromLTWH(0, 0, width, height), depthPaint);

    // Motion parameters (subtle local-only idle breathing / bob)
    // Motion NEVER represents online/read/typing status
    final hasMotion = width >= 32 && motionProgress > 0;
    final idleOffsetY = hasMotion
        ? math.sin(motionProgress * 2 * math.pi) *
              (width * 0.02).clamp(0.5, 2.0)
        : 0.0;
    final isBlinking =
        hasMotion && motionProgress >= 0.48 && motionProgress <= 0.52;

    // 2. Torso / Outfit (lower portion)
    _drawOutfit(canvas, width, height, cx, cy, idleOffsetY);

    // 3. Head & Hair
    _drawHeadAndHair(canvas, width, height, cx, cy, idleOffsetY);

    // 4. Face (Eyes, Cheeks, Mouth)
    _drawFace(canvas, width, cx, cy, idleOffsetY, isBlinking);

    // 5. Accessory
    _drawAccessory(canvas, width, cx, cy, idleOffsetY);

    canvas.restore();

    // 6. Border
    final borderPaint = Paint()
      ..color = tokens.outline.withValues(alpha: 0.5)
      ..style = PaintingStyle.stroke
      ..strokeWidth = (width * 0.03).clamp(1.0, 2.5);
    canvas.drawRRect(outerRect, borderPaint);
  }

  void _drawOutfit(
    Canvas canvas,
    double width,
    double height,
    double cx,
    double cy,
    double idleOffsetY,
  ) {
    final clothingPaint = Paint()..color = tokens.clothing;
    final torsoTop = cy + width * 0.16 + idleOffsetY * 0.4;
    final shoulderW = width * 0.42;

    final torsoPath = Path()
      ..moveTo(cx - shoulderW, height)
      ..lineTo(cx - shoulderW * 0.78, torsoTop)
      ..quadraticBezierTo(
        cx,
        torsoTop - width * 0.04,
        cx + shoulderW * 0.78,
        torsoTop,
      )
      ..lineTo(cx + shoulderW, height)
      ..close();
    canvas.drawPath(torsoPath, clothingPaint);

    // Outfit details
    switch (spec.outfit) {
      case 'workwear':
        // Collared vest with lapels and button accents
        final lapelPaint = Paint()
          ..color = tokens.accent.withValues(alpha: 0.8)
          ..style = PaintingStyle.stroke
          ..strokeWidth = (width * 0.02).clamp(1.0, 2.2);
        final lapelPath = Path()
          ..moveTo(cx - width * 0.12, torsoTop)
          ..lineTo(cx - width * 0.04, torsoTop + width * 0.18)
          ..moveTo(cx + width * 0.12, torsoTop)
          ..lineTo(cx + width * 0.04, torsoTop + width * 0.18);
        canvas.drawPath(lapelPath, lapelPaint);

        final buttonPaint = Paint()..color = tokens.accent;
        canvas.drawCircle(
          Offset(cx, torsoTop + width * 0.12),
          (width * 0.018).clamp(1.0, 2.5),
          buttonPaint,
        );
        canvas.drawCircle(
          Offset(cx, torsoTop + width * 0.22),
          (width * 0.018).clamp(1.0, 2.5),
          buttonPaint,
        );
        break;

      case 'lab':
        // Crisp white/light lab coat overlay with center seam
        final labPaint = Paint()
          ..color = tokens.skin.withValues(alpha: 0.85)
          ..style = PaintingStyle.stroke
          ..strokeWidth = (width * 0.022).clamp(1.0, 2.5);
        final labPath = Path()
          ..moveTo(cx, torsoTop)
          ..lineTo(cx, height)
          ..moveTo(cx - width * 0.14, torsoTop)
          ..lineTo(cx, torsoTop + width * 0.14)
          ..lineTo(cx + width * 0.14, torsoTop);
        canvas.drawPath(labPath, labPaint);
        break;

      case 'casual':
        // Simple crewneck ribbed curve
        final ribPaint = Paint()
          ..color = tokens.primary.withValues(alpha: 0.9)
          ..style = PaintingStyle.stroke
          ..strokeWidth = (width * 0.025).clamp(1.2, 2.8);
        final ribPath = Path()
          ..moveTo(cx - width * 0.12, torsoTop)
          ..quadraticBezierTo(
            cx,
            torsoTop + width * 0.08,
            cx + width * 0.12,
            torsoTop,
          );
        canvas.drawPath(ribPath, ribPaint);
        break;

      case 'campus':
      default:
        // Campus hoodie / sweater V-neck curve & cords
        final hoodPaint = Paint()
          ..color = tokens.primary.withValues(alpha: 0.9)
          ..style = PaintingStyle.stroke
          ..strokeWidth = (width * 0.022).clamp(1.0, 2.4);
        final hoodPath = Path()
          ..moveTo(cx - width * 0.11, torsoTop)
          ..quadraticBezierTo(
            cx,
            torsoTop + width * 0.10,
            cx + width * 0.11,
            torsoTop,
          );
        canvas.drawPath(hoodPath, hoodPaint);

        final cordPaint = Paint()
          ..color = tokens.accent
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round
          ..strokeWidth = (width * 0.018).clamp(1.0, 2.0);
        canvas.drawLine(
          Offset(cx - width * 0.04, torsoTop + width * 0.08),
          Offset(cx - width * 0.04, torsoTop + width * 0.16),
          cordPaint,
        );
        canvas.drawLine(
          Offset(cx + width * 0.04, torsoTop + width * 0.08),
          Offset(cx + width * 0.04, torsoTop + width * 0.16),
          cordPaint,
        );
        break;
    }
  }

  void _drawHeadAndHair(
    Canvas canvas,
    double width,
    double height,
    double cx,
    double cy,
    double idleOffsetY,
  ) {
    final headCenterY = cy - width * 0.04 + idleOffsetY;
    final headW = width * 0.44;
    final headH = width * 0.42;

    // Skin Head
    final skinPaint = Paint()..color = tokens.skin;
    final headRect = RRect.fromRectAndRadius(
      Rect.fromCenter(
        center: Offset(cx, headCenterY),
        width: headW,
        height: headH,
      ),
      Radius.circular(spec.silhouette == 'round' ? headW * 0.42 : headW * 0.32),
    );
    canvas.drawRRect(headRect, skinPaint);

    // Hair / Bangs top styling
    final hairPaint = Paint()..color = tokens.primary;
    final hairTop = headCenterY - headH * 0.52;

    switch (spec.silhouette) {
      case 'sharp':
        // Angular/geometric fringe
        final hairPath = Path()
          ..moveTo(cx - headW * 0.54, headCenterY - headH * 0.10)
          ..lineTo(cx - headW * 0.50, hairTop)
          ..lineTo(cx + headW * 0.50, hairTop)
          ..lineTo(cx + headW * 0.54, headCenterY - headH * 0.10)
          ..lineTo(cx + headW * 0.20, headCenterY - headH * 0.14)
          ..lineTo(cx, headCenterY - headH * 0.04)
          ..lineTo(cx - headW * 0.20, headCenterY - headH * 0.14)
          ..close();
        canvas.drawPath(hairPath, hairPaint);
        break;

      case 'round':
        // Dome swept round fringe
        final hairPath = Path()
          ..moveTo(cx - headW * 0.52, headCenterY)
          ..quadraticBezierTo(cx - headW * 0.52, hairTop, cx, hairTop)
          ..quadraticBezierTo(
            cx + headW * 0.52,
            hairTop,
            cx + headW * 0.52,
            headCenterY,
          )
          ..quadraticBezierTo(
            cx + headW * 0.26,
            headCenterY - headH * 0.12,
            cx,
            headCenterY - headH * 0.08,
          )
          ..quadraticBezierTo(
            cx - headW * 0.26,
            headCenterY - headH * 0.12,
            cx - headW * 0.52,
            headCenterY,
          )
          ..close();
        canvas.drawPath(hairPath, hairPaint);
        break;

      case 'soft':
      default:
        // Soft rounded bangs
        final hairPath = Path()
          ..moveTo(cx - headW * 0.52, headCenterY - headH * 0.05)
          ..quadraticBezierTo(cx - headW * 0.50, hairTop, cx, hairTop)
          ..quadraticBezierTo(
            cx + headW * 0.50,
            hairTop,
            cx + headW * 0.52,
            headCenterY - headH * 0.05,
          )
          ..quadraticBezierTo(
            cx + headW * 0.18,
            headCenterY - headH * 0.10,
            cx + headW * 0.06,
            headCenterY - headH * 0.02,
          )
          ..quadraticBezierTo(
            cx - headW * 0.18,
            headCenterY - headH * 0.10,
            cx - headW * 0.52,
            headCenterY - headH * 0.05,
          )
          ..close();
        canvas.drawPath(hairPath, hairPaint);
        break;
    }
  }

  void _drawFace(
    Canvas canvas,
    double width,
    double cx,
    double cy,
    double idleOffsetY,
    bool isBlinking,
  ) {
    final eyeY = cy - width * 0.02 + idleOffsetY;
    final eyeDist = width * 0.10;

    // Eyes
    if (isBlinking) {
      // Resting blink smile curves
      final blinkPaint = Paint()
        ..color = tokens.eyes
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeWidth = (width * 0.022).clamp(1.2, 2.4);
      final leftBlink = Path()
        ..moveTo(cx - eyeDist - width * 0.03, eyeY)
        ..quadraticBezierTo(
          cx - eyeDist,
          eyeY + width * 0.02,
          cx - eyeDist + width * 0.03,
          eyeY,
        );
      final rightBlink = Path()
        ..moveTo(cx + eyeDist - width * 0.03, eyeY)
        ..quadraticBezierTo(
          cx + eyeDist,
          eyeY + width * 0.02,
          cx + eyeDist + width * 0.03,
          eyeY,
        );
      canvas.drawPath(leftBlink, blinkPaint);
      canvas.drawPath(rightBlink, blinkPaint);
    } else {
      // Expressive eye beads
      final eyePaint = Paint()..color = tokens.eyes;
      final eyeW = (width * 0.052).clamp(2.5, 8.0);
      final eyeH = (width * 0.072).clamp(3.5, 11.0);

      canvas.drawOval(
        Rect.fromCenter(
          center: Offset(cx - eyeDist, eyeY),
          width: eyeW,
          height: eyeH,
        ),
        eyePaint,
      );
      canvas.drawOval(
        Rect.fromCenter(
          center: Offset(cx + eyeDist, eyeY),
          width: eyeW,
          height: eyeH,
        ),
        eyePaint,
      );

      // Catchlight highlights
      if (width >= 28) {
        final catchPaint = Paint()..color = Colors.white;
        final catchRadius = (width * 0.016).clamp(1.0, 2.5);
        canvas.drawCircle(
          Offset(cx - eyeDist + eyeW * 0.22, eyeY - eyeH * 0.22),
          catchRadius,
          catchPaint,
        );
        canvas.drawCircle(
          Offset(cx + eyeDist + eyeW * 0.22, eyeY - eyeH * 0.22),
          catchRadius,
          catchPaint,
        );
      }
    }

    // Blush cheeks (for interactive/standard sizes >= 28)
    if (width >= 28) {
      final blushPaint = Paint()
        ..color = const Color(0xFFFB7185).withValues(alpha: 0.35);
      final blushRadius = (width * 0.032).clamp(1.5, 5.0);
      final blushY = eyeY + width * 0.055;
      canvas.drawCircle(
        Offset(cx - eyeDist - width * 0.03, blushY),
        blushRadius,
        blushPaint,
      );
      canvas.drawCircle(
        Offset(cx + eyeDist + width * 0.03, blushY),
        blushRadius,
        blushPaint,
      );
    }

    // Smile
    final smilePaint = Paint()
      ..color = tokens.eyes
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = (width * 0.02).clamp(1.0, 2.2);
    final smileY = eyeY + width * 0.075;
    final smileW = (width * 0.055).clamp(2.0, 9.0);
    final smilePath = Path()
      ..moveTo(cx - smileW, smileY)
      ..quadraticBezierTo(cx, smileY + width * 0.025, cx + smileW, smileY);
    canvas.drawPath(smilePath, smilePaint);
  }

  void _drawAccessory(
    Canvas canvas,
    double width,
    double cx,
    double cy,
    double idleOffsetY,
  ) {
    final eyeY = cy - width * 0.02 + idleOffsetY;
    final eyeDist = width * 0.10;
    final headCenterY = cy - width * 0.04 + idleOffsetY;
    final headW = width * 0.44;
    final headH = width * 0.42;

    switch (spec.accessory) {
      case 'glasses':
        final glassPaint = Paint()
          ..color = tokens.accent
          ..style = PaintingStyle.stroke
          ..strokeWidth = (width * 0.022).clamp(1.0, 2.2);
        final lensW = width * 0.13;
        final lensH = width * 0.11;
        final lensR = Radius.circular(width * 0.03);

        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromCenter(
              center: Offset(cx - eyeDist, eyeY),
              width: lensW,
              height: lensH,
            ),
            lensR,
          ),
          glassPaint,
        );
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromCenter(
              center: Offset(cx + eyeDist, eyeY),
              width: lensW,
              height: lensH,
            ),
            lensR,
          ),
          glassPaint,
        );
        // Nose bridge
        canvas.drawLine(
          Offset(cx - eyeDist + lensW * 0.5, eyeY),
          Offset(cx + eyeDist - lensW * 0.5, eyeY),
          glassPaint,
        );
        break;

      case 'headphones':
        final hpPaint = Paint()
          ..color = tokens.accent
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round
          ..strokeWidth = (width * 0.035).clamp(1.5, 4.0);
        // Headband arc
        final hpPath = Path()
          ..moveTo(cx - headW * 0.50, headCenterY + headH * 0.05)
          ..quadraticBezierTo(
            cx,
            headCenterY - headH * 0.68,
            cx + headW * 0.50,
            headCenterY + headH * 0.05,
          );
        canvas.drawPath(hpPath, hpPaint);

        // Ear cups
        final cupPaint = Paint()..color = tokens.accent;
        final cupW = (width * 0.055).clamp(2.5, 8.0);
        final cupH = (width * 0.14).clamp(5.0, 20.0);
        final cupR = Radius.circular(width * 0.02);

        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromCenter(
              center: Offset(cx - headW * 0.50, headCenterY + headH * 0.02),
              width: cupW,
              height: cupH,
            ),
            cupR,
          ),
          cupPaint,
        );
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromCenter(
              center: Offset(cx + headW * 0.50, headCenterY + headH * 0.02),
              width: cupW,
              height: cupH,
            ),
            cupR,
          ),
          cupPaint,
        );
        break;

      case 'leaf':
        // Sprout on top of head
        final stemPaint = Paint()
          ..color = const Color(0xFF15803D)
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round
          ..strokeWidth = (width * 0.02).clamp(1.0, 2.2);
        final stemBaseX = cx + headW * 0.12;
        final stemBaseY = headCenterY - headH * 0.50;
        final stemTipX = stemBaseX + width * 0.03;
        final stemTipY = stemBaseY - width * 0.08;

        canvas.drawLine(
          Offset(stemBaseX, stemBaseY),
          Offset(stemTipX, stemTipY),
          stemPaint,
        );

        final leafPaint = Paint()..color = const Color(0xFF22C55E);
        canvas.drawOval(
          Rect.fromCenter(
            center: Offset(stemTipX - width * 0.03, stemTipY),
            width: (width * 0.06).clamp(3.0, 9.0),
            height: (width * 0.035).clamp(2.0, 5.5),
          ),
          leafPaint,
        );
        canvas.drawOval(
          Rect.fromCenter(
            center: Offset(stemTipX + width * 0.03, stemTipY - width * 0.01),
            width: (width * 0.06).clamp(3.0, 9.0),
            height: (width * 0.035).clamp(2.0, 5.5),
          ),
          leafPaint,
        );
        break;

      case 'none':
      default:
        break;
    }
  }

  @override
  bool shouldRepaint(covariant _PersonaCharacterPainter oldDelegate) {
    return oldDelegate.spec != spec ||
        oldDelegate.tokens != tokens ||
        oldDelegate.motionProgress != motionProgress ||
        oldDelegate.radius != radius;
  }
}
