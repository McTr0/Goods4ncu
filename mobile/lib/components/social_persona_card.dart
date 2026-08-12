import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../models/models.dart';
import '../theme/app_theme.dart';

/// A token-based preview for a user's role presentation.
///
/// Approved platform-hosted assets may be shown when the server explicitly
/// projects one. Until then (or if the short-lived URL expires), the same
/// selected tokens render a deterministic fallback on every device.
class SocialPersonaPreviewCard extends StatelessWidget {
  const SocialPersonaPreviewCard({
    super.key,
    required this.persona,
    this.title,
    this.compact = false,
  });

  final SocialPersona persona;
  final String? title;
  final bool compact;

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
        SocialPersonaAvatar(persona: persona, size: compact ? 48 : 160),
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
/// The fallback is deliberately static, and an approved asset is only shown
/// when the server explicitly projects it; neither representation reflects
/// online, typing, read, push, or background activity.
class SocialPersonaAvatar extends StatelessWidget {
  const SocialPersonaAvatar({
    super.key,
    required this.persona,
    this.size = 48,
    this.semanticLabel,
  }) : assert(size > 0);

  final SocialPersona persona;
  final double size;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final color = _personaAccent(context, persona.appearance.palette);
    final radius = switch (persona.appearance.silhouette) {
      'round' => size * 0.37,
      'sharp' => size * 0.13,
      _ => size * 0.24,
    };
    final accessory = switch (persona.appearance.accessory) {
      'glasses' => Icons.visibility_outlined,
      'headphones' => Icons.headphones_outlined,
      'leaf' => Icons.eco_outlined,
      _ => Icons.person_outline_rounded,
    };
    final accessorySize = (size * 0.21).clamp(7.0, 16.0).toDouble();
    final accessoryInset = (size * 0.07).clamp(2.0, 6.0).toDouble();
    final accessoryPadding = (size * 0.04).clamp(1.0, 3.0).toDouble();
    final assetUrl = persona.asset?.url;
    final fallback = Stack(
      alignment: Alignment.center,
      children: [
        Icon(Icons.face_rounded, size: size * 0.62, color: color),
        Positioned(
          right: accessoryInset,
          bottom: accessoryInset,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: Theme.of(context).cardColor,
              shape: BoxShape.circle,
              border: Border.all(color: color.withValues(alpha: 0.28)),
            ),
            child: Padding(
              padding: EdgeInsets.all(accessoryPadding),
              child: Icon(accessory, size: accessorySize, color: color),
            ),
          ),
        ),
      ],
    );

    return Semantics(
      label: semanticLabel ?? l.socialPersonaPreviewRole,
      image: true,
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(radius),
          border: Border.all(color: color.withValues(alpha: 0.42)),
        ),
        child: assetUrl == null || assetUrl.trim().isEmpty
            ? fallback
            : ClipRRect(
                borderRadius: BorderRadius.circular(radius),
                child: Image.network(
                  assetUrl,
                  width: size,
                  height: size,
                  fit: BoxFit.cover,
                  filterQuality: FilterQuality.medium,
                  errorBuilder: (context, error, stackTrace) => fallback,
                ),
              ),
      ),
    );
  }
}

/// The values returned by the editor are all allow-listed tokens. There is no
/// free-form prompt field in this first version.
class SocialPersonaDraft {
  const SocialPersonaDraft({
    required this.representationMode,
    required this.appearanceConfig,
    required this.selfDescriptions,
    required this.contactPosture,
  });

  final String representationMode;
  final Map<String, String> appearanceConfig;
  final List<String> selfDescriptions;
  final String contactPosture;
}

Future<SocialPersonaDraft?> showSocialPersonaEditor(
  BuildContext context,
  SocialPersona? initial,
) {
  return showModalBottomSheet<SocialPersonaDraft>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => _SocialPersonaEditorSheet(initial: initial),
  );
}

class _SocialPersonaEditorSheet extends StatefulWidget {
  const _SocialPersonaEditorSheet({required this.initial});

  final SocialPersona? initial;

  @override
  State<_SocialPersonaEditorSheet> createState() =>
      _SocialPersonaEditorSheetState();
}

class _SocialPersonaEditorSheetState extends State<_SocialPersonaEditorSheet> {
  late String _representationMode;
  late String _palette;
  late String _silhouette;
  late String _accessory;
  late String _outfit;
  late String _contactPosture;
  late Set<String> _selfDescriptions;

  @override
  void initState() {
    super.initState();
    final persona = widget.initial;
    _representationMode = persona?.representationMode ?? 'trait_mapped';
    _palette = persona?.appearance.palette ?? 'teal';
    _silhouette = persona?.appearance.silhouette ?? 'soft';
    _accessory = persona?.appearance.accessory ?? 'none';
    _outfit = persona?.appearance.outfit ?? 'campus';
    _contactPosture = persona?.contactPosture ?? 'leave_message';
    _selfDescriptions = {...?persona?.selfDescriptions};
  }

  SocialPersona get _previewPersona => SocialPersona(
    representationMode: _representationMode,
    styleVersion: 'v1',
    appearance: SocialPersonaAppearance(
      palette: _palette,
      silhouette: _silhouette,
      accessory: _accessory,
      outfit: _outfit,
    ),
    selfDescriptions: _selfDescriptions.toList(growable: false),
    contactPosture: _contactPosture,
    status: 'draft',
  );

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final bottom = MediaQuery.viewInsetsOf(context).bottom;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          AppTheme.sp16,
          0,
          AppTheme.sp16,
          AppTheme.sp16 + bottom,
        ),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 760),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  widget.initial == null
                      ? l.socialPersonaCreate
                      : l.socialPersonaEdit,
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: AppTheme.sp8),
                Text(
                  l.socialPersonaDescription,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                const SizedBox(height: AppTheme.sp16),
                SocialPersonaPreviewCard(persona: _previewPersona),
                const SizedBox(height: AppTheme.sp16),
                _dropdown(
                  label: l.socialPersonaRepresentationMode,
                  value: _representationMode,
                  items: {
                    'trait_mapped': l.socialPersonaTraitMapped,
                    'role_character': l.socialPersonaRoleCharacter,
                  },
                  onChanged: (value) => setState(
                    () => _representationMode = value ?? _representationMode,
                  ),
                ),
                _dropdown(
                  label: l.socialPersonaPalette,
                  value: _palette,
                  items: {
                    'teal': l.socialPersonaPaletteTeal,
                    'plum': l.socialPersonaPalettePlum,
                    'sun': l.socialPersonaPaletteSun,
                    'slate': l.socialPersonaPaletteSlate,
                  },
                  onChanged: (value) =>
                      setState(() => _palette = value ?? _palette),
                ),
                _dropdown(
                  label: l.socialPersonaSilhouette,
                  value: _silhouette,
                  items: {
                    'soft': l.socialPersonaSilhouetteSoft,
                    'round': l.socialPersonaSilhouetteRound,
                    'sharp': l.socialPersonaSilhouetteSharp,
                  },
                  onChanged: (value) =>
                      setState(() => _silhouette = value ?? _silhouette),
                ),
                _dropdown(
                  label: l.socialPersonaAccessory,
                  value: _accessory,
                  items: {
                    'none': l.socialPersonaAccessoryNone,
                    'glasses': l.socialPersonaAccessoryGlasses,
                    'headphones': l.socialPersonaAccessoryHeadphones,
                    'leaf': l.socialPersonaAccessoryLeaf,
                  },
                  onChanged: (value) =>
                      setState(() => _accessory = value ?? _accessory),
                ),
                _dropdown(
                  label: l.socialPersonaOutfit,
                  value: _outfit,
                  items: {
                    'campus': l.socialPersonaOutfitCampus,
                    'workwear': l.socialPersonaOutfitWorkwear,
                    'casual': l.socialPersonaOutfitCasual,
                    'lab': l.socialPersonaOutfitLab,
                  },
                  onChanged: (value) =>
                      setState(() => _outfit = value ?? _outfit),
                ),
                const SizedBox(height: AppTheme.sp8),
                Text(
                  l.socialPersonaContactPosture,
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                const SizedBox(height: AppTheme.sp4),
                _dropdown(
                  label: l.socialPersonaContactPosture,
                  value: _contactPosture,
                  items: {
                    'leave_message': l.socialPersonaLeaveMessage,
                    'connection_allowed': l.socialPersonaConnectionAllowed,
                    'busy': l.socialPersonaBusy,
                    'later': l.socialPersonaLater,
                  },
                  onChanged: (value) => setState(
                    () => _contactPosture = value ?? _contactPosture,
                  ),
                ),
                const SizedBox(height: AppTheme.sp8),
                Text(
                  l.socialPersonaLabels,
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                const SizedBox(height: AppTheme.sp4),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: _labelCodes
                      .map(
                        (code) => FilterChip(
                          label: Text(_labelForCode(l, code)),
                          selected: _selfDescriptions.contains(code),
                          onSelected: (selected) {
                            if (selected &&
                                _selfDescriptions.length >= 3 &&
                                !_selfDescriptions.contains(code)) {
                              return;
                            }
                            setState(() {
                              if (selected) {
                                _selfDescriptions.add(code);
                              } else {
                                _selfDescriptions.remove(code);
                              }
                            });
                          },
                        ),
                      )
                      .toList(growable: false),
                ),
                const SizedBox(height: AppTheme.sp4),
                Text(
                  l.socialPersonaSelectHint,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: AppTheme.textSecondary,
                  ),
                ),
                const SizedBox(height: AppTheme.sp16),
                FilledButton.icon(
                  onPressed: () => Navigator.pop(
                    context,
                    SocialPersonaDraft(
                      representationMode: _representationMode,
                      appearanceConfig: {
                        'palette': _palette,
                        'silhouette': _silhouette,
                        'accessory': _accessory,
                        'outfit': _outfit,
                      },
                      selfDescriptions: _selfDescriptions.toList(),
                      contactPosture: _contactPosture,
                    ),
                  ),
                  icon: const Icon(Icons.save_outlined),
                  label: Text(l.socialPersonaSaveDraft),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _dropdown({
    required String label,
    required String value,
    required Map<String, String> items,
    required ValueChanged<String?> onChanged,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppTheme.sp8),
      child: DropdownButtonFormField<String>(
        initialValue: value,
        decoration: InputDecoration(labelText: label),
        items: items.entries
            .map(
              (entry) => DropdownMenuItem<String>(
                value: entry.key,
                child: Text(entry.value),
              ),
            )
            .toList(growable: false),
        onChanged: onChanged,
      ),
    );
  }
}

const _labelCodes = [
  'slow_to_warm',
  'business_only',
  'meetup_friendly',
  'casual_chat',
  'reply_later',
  'tech_enthusiast',
];

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
