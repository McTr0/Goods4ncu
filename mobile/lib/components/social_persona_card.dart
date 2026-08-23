import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../models/models.dart';
import 'social_persona_renderer.dart';

/// The user's character token: the official Doro portrait at any scale.
///
/// Motion is local-only and NEVER reflects online, typing, read, push, or
/// background activity.
class SocialPersonaAvatar extends StatelessWidget {
  const SocialPersonaAvatar({
    super.key,
    required this.persona,
    this.size = 48,
    this.semanticLabel,
    this.enableMotion,
    this.motionCue = AvatarMotionCue.idle,
    this.motionRevision = 0,
    this.renderer,
  }) : assert(size > 0);

  final SocialPersona persona;
  final double size;
  final String? semanticLabel;
  final bool? enableMotion;
  final AvatarMotionCue motionCue;
  final int motionRevision;
  final SocialPersonaRenderer? renderer;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final spec = SocialPersonaRenderSpec.fromPersona(persona);

    return SocialPersonaCharacterView(
      spec: spec,
      size: size,
      enableMotion: enableMotion,
      motionCue: motionCue,
      motionRevision: motionRevision,
      renderer: renderer,
      semanticLabel: semanticLabel ?? l.publicProfile,
    );
  }
}
