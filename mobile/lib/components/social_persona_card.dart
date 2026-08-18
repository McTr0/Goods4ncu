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
/// Uses the [SocialPersonaRenderer] boundary and its safe code-drawn fallback.
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

/// The values returned by the editor are all allow-listed tokens. There is no
/// free-form prompt field in this first version.
class SocialPersonaDraft {
  const SocialPersonaDraft({
    required this.representationMode,
    required this.styleVersion,
    required this.appearanceConfig,
    required this.selfDescriptions,
    required this.contactPosture,
  });

  final String representationMode;
  final String styleVersion;
  final Map<String, String> appearanceConfig;
  final List<String> selfDescriptions;
  final String contactPosture;
}

Future<SocialPersonaDraft?> showSocialPersonaEditor(
  BuildContext context,
  SocialPersona? initial, {
  SocialPersonaCatalog? catalog,
}) {
  return Navigator.of(context, rootNavigator: true).push<SocialPersonaDraft>(
    MaterialPageRoute(
      builder: (_) =>
          _SocialPersonaEditorPage(initial: initial, catalog: catalog),
    ),
  );
}

class _SocialPersonaEditorPage extends StatelessWidget {
  const _SocialPersonaEditorPage({required this.initial, this.catalog});

  final SocialPersona? initial;
  final SocialPersonaCatalog? catalog;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          initial == null ? l.socialPersonaCreate : l.socialPersonaEdit,
        ),
      ),
      body: _SocialPersonaEditorSheet(initial: initial, catalog: catalog),
    );
  }
}

class _SocialPersonaEditorSheet extends StatefulWidget {
  const _SocialPersonaEditorSheet({required this.initial, this.catalog});

  final SocialPersona? initial;
  final SocialPersonaCatalog? catalog;

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
  late String _character;
  late String _contactPosture;
  late Set<String> _selfDescriptions;
  late AvatarActionController _previewActions;

  @override
  void initState() {
    super.initState();
    _previewActions = AvatarActionController();
    final persona = widget.initial;
    _representationMode = _initialValue(
      persona?.representationMode,
      widget.catalog?.representationModes,
      'trait_mapped',
    );
    _palette = _initialValue(
      persona?.appearance.palette,
      widget.catalog?.appearance['palette'],
      'teal',
    );
    _silhouette = _initialValue(
      persona?.appearance.silhouette,
      widget.catalog?.appearance['silhouette'],
      'soft',
    );
    _accessory = _initialValue(
      persona?.appearance.accessory,
      widget.catalog?.appearance['accessory'],
      'none',
    );
    _outfit = _initialValue(
      persona?.appearance.outfit,
      widget.catalog?.appearance['outfit'],
      'campus',
    );
    _character = _initialValue(
      persona?.appearance.character,
      _characterValues,
      'ncu_doro',
    );
    _contactPosture = _initialValue(
      persona?.contactPosture,
      widget.catalog?.contactPostures,
      'leave_message',
    );
    final allowedLabels = widget.catalog?.selfDescriptions ?? _labelCodes;
    _selfDescriptions = {
      ...?persona?.selfDescriptions.where(allowedLabels.contains),
    };
  }

  @override
  void dispose() {
    _previewActions.dispose();
    super.dispose();
  }

  List<String> get _characterValues {
    final values = widget.catalog?.appearance['character'];
    return (values == null || values.isEmpty
            ? const ['ncu_doro', 'ncu_gugugaga', 'ncu_phoebe_chupi']
            : values)
        .where((value) => value != 'classic')
        .toList(growable: false);
  }

  String _initialValue(
    String? current,
    List<String>? allowed,
    String fallback,
  ) {
    final values = allowed == null || allowed.isEmpty ? [fallback] : allowed;
    return current != null && values.contains(current) ? current : values.first;
  }

  List<String> _catalogValues(String key, List<String> fallback) {
    final values = widget.catalog?.appearance[key];
    return values == null || values.isEmpty ? fallback : values;
  }

  Map<String, String> _localizedItems(
    List<String> values,
    String Function(String) labelFor,
  ) => {for (final value in values) value: labelFor(value)};

  SocialPersona get _previewPersona => SocialPersona(
    representationMode: _representationMode,
    styleVersion:
        widget.catalog?.styleVersion ?? widget.initial?.styleVersion ?? 'v1',
    appearance: SocialPersonaAppearance(
      palette: _palette,
      silhouette: _silhouette,
      accessory: _accessory,
      outfit: _outfit,
      character: _character,
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
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    l.socialPersonaDescription,
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                  const SizedBox(height: AppTheme.sp16),
                  ListenableBuilder(
                    listenable: _previewActions,
                    builder: (context, _) => SocialPersonaPreviewCard(
                      persona: _previewPersona,
                      motionCue: _previewActions.cue,
                      motionRevision: _previewActions.revision,
                    ),
                  ),
                  const SizedBox(height: AppTheme.sp8),
                  Wrap(
                    alignment: WrapAlignment.center,
                    spacing: AppTheme.sp8,
                    runSpacing: AppTheme.sp8,
                    children: [
                      ActionChip(
                        avatar: const Icon(
                          Icons.waving_hand_outlined,
                          size: 18,
                        ),
                        label: Text(l.socialPersonaActionWave),
                        onPressed: () =>
                            _previewActions.play(AvatarMotionCue.wave),
                      ),
                      ActionChip(
                        avatar: const Icon(
                          Icons.celebration_outlined,
                          size: 18,
                        ),
                        label: Text(l.socialPersonaActionCelebrate),
                        onPressed: () =>
                            _previewActions.play(AvatarMotionCue.celebrate),
                      ),
                      ActionChip(
                        avatar: const Icon(Icons.psychology_outlined, size: 18),
                        label: Text(l.socialPersonaActionThinking),
                        onPressed: () =>
                            _previewActions.play(AvatarMotionCue.thinking),
                      ),
                    ],
                  ),
                  const SizedBox(height: AppTheme.sp16),
                  Text(
                    l.socialPersonaCharacter,
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  const SizedBox(height: AppTheme.sp8),
                  Wrap(
                    spacing: AppTheme.sp8,
                    runSpacing: AppTheme.sp8,
                    children: _characterValues
                        .map(
                          (character) => _characterChoice(
                            context,
                            character: character,
                            label: switch (character) {
                              'ncu_gugugaga' =>
                                l.socialPersonaCharacterGugugaga,
                              'ncu_doro' => l.socialPersonaCharacterDoro,
                              'ncu_phoebe_chupi' =>
                                l.socialPersonaCharacterPhoebeChupi,
                              _ => l.socialPersonaCharacterClassic,
                            },
                          ),
                        )
                        .toList(growable: false),
                  ),
                  const SizedBox(height: AppTheme.sp16),
                  _dropdown(
                    label: l.socialPersonaRepresentationMode,
                    value: _representationMode,
                    items: _localizedItems(
                      widget.catalog?.representationModes ??
                          const ['trait_mapped', 'role_character'],
                      (value) => switch (value) {
                        'role_character' => l.socialPersonaRoleCharacter,
                        'trait_mapped' => l.socialPersonaTraitMapped,
                        _ => value,
                      },
                    ),
                    onChanged: (value) => setState(
                      () => _representationMode = value ?? _representationMode,
                    ),
                  ),
                  if (_character == 'classic') ...[
                    _dropdown(
                      label: l.socialPersonaPalette,
                      value: _palette,
                      items: _localizedItems(
                        _catalogValues('palette', const [
                          'teal',
                          'plum',
                          'sun',
                          'slate',
                        ]),
                        (value) => switch (value) {
                          'teal' => l.socialPersonaPaletteTeal,
                          'plum' => l.socialPersonaPalettePlum,
                          'sun' => l.socialPersonaPaletteSun,
                          'slate' => l.socialPersonaPaletteSlate,
                          _ => value,
                        },
                      ),
                      onChanged: (value) =>
                          setState(() => _palette = value ?? _palette),
                    ),
                    _dropdown(
                      label: l.socialPersonaSilhouette,
                      value: _silhouette,
                      items: _localizedItems(
                        _catalogValues('silhouette', const [
                          'soft',
                          'round',
                          'sharp',
                        ]),
                        (value) => switch (value) {
                          'soft' => l.socialPersonaSilhouetteSoft,
                          'round' => l.socialPersonaSilhouetteRound,
                          'sharp' => l.socialPersonaSilhouetteSharp,
                          _ => value,
                        },
                      ),
                      onChanged: (value) =>
                          setState(() => _silhouette = value ?? _silhouette),
                    ),
                    _dropdown(
                      label: l.socialPersonaAccessory,
                      value: _accessory,
                      items: _localizedItems(
                        _catalogValues('accessory', const [
                          'none',
                          'glasses',
                          'headphones',
                          'leaf',
                        ]),
                        (value) => switch (value) {
                          'none' => l.socialPersonaAccessoryNone,
                          'glasses' => l.socialPersonaAccessoryGlasses,
                          'headphones' => l.socialPersonaAccessoryHeadphones,
                          'leaf' => l.socialPersonaAccessoryLeaf,
                          _ => value,
                        },
                      ),
                      onChanged: (value) =>
                          setState(() => _accessory = value ?? _accessory),
                    ),
                    _dropdown(
                      label: l.socialPersonaOutfit,
                      value: _outfit,
                      items: _localizedItems(
                        _catalogValues('outfit', const [
                          'campus',
                          'workwear',
                          'casual',
                          'lab',
                        ]),
                        (value) => switch (value) {
                          'campus' => l.socialPersonaOutfitCampus,
                          'workwear' => l.socialPersonaOutfitWorkwear,
                          'casual' => l.socialPersonaOutfitCasual,
                          'lab' => l.socialPersonaOutfitLab,
                          _ => value,
                        },
                      ),
                      onChanged: (value) =>
                          setState(() => _outfit = value ?? _outfit),
                    ),
                  ],
                  const SizedBox(height: AppTheme.sp8),
                  Text(
                    l.socialPersonaContactPosture,
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  const SizedBox(height: AppTheme.sp4),
                  _dropdown(
                    label: l.socialPersonaContactPosture,
                    value: _contactPosture,
                    items: _localizedItems(
                      widget.catalog?.contactPostures ??
                          const [
                            'leave_message',
                            'connection_allowed',
                            'busy',
                            'later',
                          ],
                      (value) => switch (value) {
                        'leave_message' => l.socialPersonaLeaveMessage,
                        'connection_allowed' =>
                          l.socialPersonaConnectionAllowed,
                        'busy' => l.socialPersonaBusy,
                        'later' => l.socialPersonaLater,
                        _ => value,
                      },
                    ),
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
                    children: (widget.catalog?.selfDescriptions ?? _labelCodes)
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
                        styleVersion:
                            widget.catalog?.styleVersion ??
                            widget.initial?.styleVersion ??
                            'v1',
                        appearanceConfig: {
                          'palette': _palette,
                          'silhouette': _silhouette,
                          'accessory': _accessory,
                          'outfit': _outfit,
                          'character': _character,
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

  Widget _characterChoice(
    BuildContext context, {
    required String character,
    required String label,
  }) {
    final selected = _character == character;
    final colors = Theme.of(context).colorScheme;
    final spec = SocialPersonaRenderSpec(
      palette: _palette,
      silhouette: _silhouette,
      accessory: _accessory,
      outfit: _outfit,
      assetId: character == 'classic' ? null : character,
    );
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      child: InkWell(
        key: ValueKey('persona_character_$character'),
        onTap: () {
          setState(() => _character = character);
          _previewActions.play(AvatarMotionCue.selected);
        },
        borderRadius: BorderRadius.circular(16),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          width: 104,
          padding: const EdgeInsets.fromLTRB(8, 8, 8, 10),
          decoration: BoxDecoration(
            color: selected
                ? colors.primaryContainer.withValues(alpha: 0.55)
                : colors.surfaceContainerLow,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: selected ? colors.primary : colors.outlineVariant,
              width: selected ? 2 : 1,
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SocialPersonaCharacterView(
                spec: spec,
                size: 64,
                enableMotion: selected,
                motionCue: selected
                    ? AvatarMotionCue.selected
                    : AvatarMotionCue.idle,
              ),
              const SizedBox(height: 4),
              Text(
                label,
                maxLines: 2,
                textAlign: TextAlign.center,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
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
