import 'package:flutter/material.dart';

import '../models/models.dart';
import 'social_persona_card.dart';
import 'social_persona_renderer.dart';

/// Recognizable user avatar supporting:
/// 1. Published SocialPersonaAvatar (priority 1 when available and enabled)
/// 2. Stable default system character (priority 2, deterministic fallback for users without published persona)
///
/// Profile photos and avatarUrl rendering are removed: all identity presentation
/// uses the versioned system character or an approved configured persona.
///
/// Follows documented avatar size tokens (24, 48, 160) and other sizes.
/// Motion is local-only idle animation at appropriate sizes and NEVER indicates online/read/typing status.
class UserAvatar extends StatelessWidget {
  const UserAvatar({
    super.key,
    required this.name,
    this.persona,
    this.size = 48,
    this.showPersona = true,
    this.semanticLabel,
    this.enableMotion,
    this.motionCue = AvatarMotionCue.idle,
    this.motionRevision = 0,
    this.renderer,
  }) : assert(size > 0);

  final String name;
  final SocialPersona? persona;
  final double size;
  final bool showPersona;
  final String? semanticLabel;
  final bool? enableMotion;
  final AvatarMotionCue motionCue;
  final int motionRevision;
  final SocialPersonaRenderer? renderer;

  @override
  Widget build(BuildContext context) {
    final trimmedName = name.trim();
    final effectiveLabel =
        semanticLabel ?? (trimmedName.isEmpty ? 'User' : trimmedName);

    Widget avatar;
    // 1. Published SocialPersona has highest priority (when persona is enabled)
    if (showPersona && persona != null && persona!.isPublished) {
      avatar = SocialPersonaAvatar(
        persona: persona!,
        size: size,
        semanticLabel: effectiveLabel,
        enableMotion: enableMotion,
        motionCue: motionCue,
        motionRevision: motionRevision,
        renderer: renderer,
      );
    } else {
      // 2. Stable system-drawn default character (deterministic fallback derived from name)
      final spec = SocialPersonaRenderSpec.fromName(trimmedName);
      avatar = SocialPersonaCharacterView(
        spec: spec,
        size: size,
        enableMotion: enableMotion,
        motionCue: motionCue,
        motionRevision: motionRevision,
        renderer: renderer,
        semanticLabel: effectiveLabel,
      );
    }
    return avatar;
  }
}
