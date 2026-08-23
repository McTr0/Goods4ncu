import 'package:flutter/material.dart';

import '../models/models.dart';

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

  String get resolvedCharacter => assetId ?? 'doro';

  /// Creates a spec from a published [SocialPersona].
  factory SocialPersonaRenderSpec.fromPersona(
    SocialPersona persona, {
    String? name,
  }) {
    final rawChar = persona.appearance.character;
    final character = rawChar.isEmpty ? 'doro' : rawChar;
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

/// Renders the official Doro portrait from the Live2D model set.
/// The companion stage uses the full Cubism runtime; static contexts
/// (profile, cards, navigation) use this portrait from the same art.
class DoroPortraitPersonaRenderer implements SocialPersonaRenderer {
  const DoroPortraitPersonaRenderer();

  static const String _assetPath = 'assets/live2d/doro/icon.png';

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
    Widget portrait = ClipRRect(
      borderRadius: BorderRadius.circular(size * 0.24),
      child: Image.asset(
        _assetPath,
        width: size,
        height: size,
        fit: BoxFit.cover,
      ),
    );
    if (semanticLabel case final label? when label.isNotEmpty) {
      portrait = Semantics(label: label, image: true, child: portrait);
    }
    return portrait;
  }
}

const defaultPersonaRenderer = DoroPortraitPersonaRenderer();

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
