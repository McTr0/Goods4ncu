import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../models/models.dart';
import '../theme/app_theme.dart';
import 'social_persona_renderer.dart';

/// A token-based preview for a user's role presentation.
///
/// The role and skin always come from the server-owned catalog. There is no
/// user-imported image fallback, so the same selected tokens render
/// deterministically on every device.
class SocialPersonaPreviewCard extends StatelessWidget {
  const SocialPersonaPreviewCard({
    super.key,
    required this.persona,
    this.title,
    this.compact = false,
    this.motionCue = AvatarMotionCue.idle,
    this.motionRevision = 0,
  });

  final SocialPersona persona;
  final String? title;
  final bool compact;
  final AvatarMotionCue motionCue;
  final int motionRevision;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final labels = persona.selfDescriptions
        .map((code) => _labelForCode(l, code))
        .where((label) => label.isNotEmpty)
        .toList(growable: false);
    final content = Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Compact cards are used in profile-adjacent summaries (48); the
        // full role card gets the 160 token that is also used in a space.
        SocialPersonaAvatar(
          persona: persona,
          size: compact ? 48 : 160,
          motionCue: motionCue,
          motionRevision: motionRevision,
        ),
        SizedBox(width: compact ? AppTheme.sp12 : AppTheme.sp16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (title != null) ...[
                Text(
                  title!,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
              ],
              Text(
                _postureLabel(l, persona.contactPosture),
                style: TextStyle(
                  color: _personaAccent(context, persona.appearance.palette),
                  fontWeight: FontWeight.w700,
                  fontSize: compact ? 12 : 13,
                ),
              ),
              if (labels.isNotEmpty) ...[
                const SizedBox(height: AppTheme.sp8),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: labels
                      .map(
                        (label) => Chip(
                          label: Text(label),
                          visualDensity: VisualDensity.compact,
                          materialTapTargetSize:
                              MaterialTapTargetSize.shrinkWrap,
                        ),
                      )
                      .toList(growable: false),
                ),
              ],
              if (!compact) ...[
                const SizedBox(height: AppTheme.sp8),
                Text(
                  l.socialPersonaPreviewRole,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: AppTheme.textSecondary,
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: EdgeInsets.all(compact ? AppTheme.sp12 : AppTheme.sp16),
        child: content,
      ),
    );
  }
}

/// Role token used at list (24), profile (48), and card/space (160) scales.
///
/// Deterministic character presentation with subtle local-only motion in large
/// previews and static behavior under reduced motion.
///
/// Motion is local-only and NEVER reflects online, typing, read, push, or background activity.
///
/// Uses the [SocialPersonaRenderer] boundary (official Doro portrait).
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
      semanticLabel: semanticLabel ?? l.socialPersonaPreviewRole,
    );
  }
}

String _labelForCode(AppLocalizations l, String code) => switch (code) {
  'slow_to_warm' => l.socialPersonaLabelSlowToWarm,
  'business_only' => l.socialPersonaLabelBusinessOnly,
  'meetup_friendly' => l.socialPersonaLabelMeetupFriendly,
  'casual_chat' => l.socialPersonaLabelCasualChat,
  'reply_later' => l.socialPersonaLabelReplyLater,
  'tech_enthusiast' => l.socialPersonaLabelTechEnthusiast,
  _ => '',
};

String _postureLabel(AppLocalizations l, String posture) => switch (posture) {
  'connection_allowed' => l.socialPersonaConnectionAllowed,
  'busy' => l.socialPersonaBusy,
  'later' => l.socialPersonaLater,
  _ => l.socialPersonaLeaveMessage,
};

Color _paletteColor(String palette) => switch (palette) {
  'plum' => const Color(0xff8b5cf6),
  'sun' => const Color(0xffd97706),
  'slate' => const Color(0xff475569),
  _ => const Color(0xff0f766e),
};

Color _personaAccent(BuildContext context, String palette) {
  final base = _paletteColor(palette);
  if (Theme.of(context).brightness != Brightness.dark) return base;
  // Keep the same token identity in dark mode while lifting slate/teal enough
  // to remain legible. The token is still static and does not encode status.
  return Color.lerp(base, Colors.white, 0.22)!;
}
