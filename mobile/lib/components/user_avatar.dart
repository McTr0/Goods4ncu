import 'package:flutter/material.dart';

import '../models/models.dart';
import 'social_persona_card.dart';

/// Recognizable user avatar supporting:
/// 1. Published SocialPersonaAvatar (priority 1 when available and enabled)
/// 2. Moderation-approved standard avatar image URL (priority 2)
/// 3. Stable, system-drawn vector avatar fallback (priority 3, offline/failure safe)
///
/// Follows documented avatar size tokens (24, 48, 160).
class UserAvatar extends StatelessWidget {
  const UserAvatar({
    super.key,
    required this.name,
    this.persona,
    this.avatarUrl,
    this.size = 48,
    this.showPersona = true,
    this.semanticLabel,
  }) : assert(size > 0);

  final String name;
  final SocialPersona? persona;
  final String? avatarUrl;
  final double size;
  final bool showPersona;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final trimmedName = name.trim();
    final effectiveLabel =
        semanticLabel ?? (trimmedName.isEmpty ? 'User' : trimmedName);

    // 1. Published SocialPersona has highest priority (when persona is enabled)
    if (showPersona && persona != null && persona!.isPublished) {
      return SocialPersonaAvatar(
        persona: persona!,
        size: size,
        semanticLabel: effectiveLabel,
      );
    }

    // 2. Moderation-approved standard avatar URL
    final hasImage = avatarUrl != null && avatarUrl!.trim().isNotEmpty;
    if (hasImage) {
      final radius = BorderRadius.circular(size * 0.24);
      final scheme = Theme.of(context).colorScheme;
      return Semantics(
        label: effectiveLabel,
        image: true,
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            borderRadius: radius,
            border: Border.all(
              color: scheme.outlineVariant.withValues(alpha: 0.7),
            ),
          ),
          child: ClipRRect(
            borderRadius: radius,
            child: Image.network(
              avatarUrl!,
              width: size,
              height: size,
              fit: BoxFit.cover,
              errorBuilder: (context, error, stackTrace) => _SystemDrawnAvatar(
                name: trimmedName,
                size: size,
                semanticLabel: effectiveLabel,
              ),
            ),
          ),
        ),
      );
    }

    // 3. Stable system-drawn fallback avatar
    return _SystemDrawnAvatar(
      name: trimmedName,
      size: size,
      semanticLabel: effectiveLabel,
    );
  }
}

class _SystemDrawnAvatar extends StatelessWidget {
  const _SystemDrawnAvatar({
    required this.name,
    required this.size,
    this.semanticLabel,
  });

  final String name;
  final double size;
  final String? semanticLabel;

  static int _stableHash(String text) {
    var hash = 0x811c9dc5;
    for (var i = 0; i < text.length; i++) {
      hash ^= text.codeUnitAt(i);
      hash = (hash * 0x01000193) & 0x7fffffff;
    }
    return hash;
  }

  // The fallback is a single system role token. Only its deterministic color
  // varies by name; changing icon silhouettes made two people look like
  // unrelated sticker packs and was especially confusing beside personas.
  static const List<
    ({Color bgLight, Color bgDark, Color fgLight, Color fgDark})
  >
  _systemPalette = [
    (
      bgLight: Color(0xFFE6F4EA),
      bgDark: Color(0xFF1E3A2B),
      fgLight: Color(0xFF137333),
      fgDark: Color(0xFF81C995),
    ),
    (
      bgLight: Color(0xFFE8F0FE),
      bgDark: Color(0xFF1E2D4A),
      fgLight: Color(0xFF1A73E8),
      fgDark: Color(0xFF8AB4F8),
    ),
    (
      bgLight: Color(0xFFFEF7E0),
      bgDark: Color(0xFF3C2F15),
      fgLight: Color(0xFFB06000),
      fgDark: Color(0xFFFDD663),
    ),
    (
      bgLight: Color(0xFFFCE8E6),
      bgDark: Color(0xFF3C1F1E),
      fgLight: Color(0xFFC5221F),
      fgDark: Color(0xFFF28B82),
    ),
    (
      bgLight: Color(0xFFF3E8FD),
      bgDark: Color(0xFF332047),
      fgLight: Color(0xFF7627BB),
      fgDark: Color(0xFFC58AF9),
    ),
    (
      bgLight: Color(0xFFE0F2F1),
      bgDark: Color(0xFF163835),
      fgLight: Color(0xFF00695C),
      fgDark: Color(0xFF80CBC4),
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final radius = BorderRadius.circular(size * 0.24);
    final iconSize = (size * 0.58).clamp(14.0, 96.0).toDouble();

    final trimmed = name.trim();
    final index = trimmed.isEmpty
        ? 0
        : (_stableHash(trimmed) % _systemPalette.length);
    final token = _systemPalette[index];
    final bgColor = isDark ? token.bgDark : token.bgLight;
    final fgColor = isDark ? token.fgDark : token.fgLight;

    return Semantics(
      label: semanticLabel ?? (trimmed.isEmpty ? 'User' : trimmed),
      image: true,
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: bgColor,
          borderRadius: radius,
          border: Border.all(color: fgColor.withValues(alpha: 0.24)),
        ),
        child: Center(
          child: Icon(
            Icons.person_outline_rounded,
            size: iconSize,
            color: fgColor,
          ),
        ),
      ),
    );
  }
}
