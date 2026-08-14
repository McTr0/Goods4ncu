import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';

/// Lightweight, deterministic avatar representing the platform Agent "小昌" (Xiaochang).
///
/// This component presents the verifiable AI assistant identity across headers,
/// tool actions, and system entries. It is strictly a static, lightweight skin
/// for platform tool state — not a user persona (SocialPersona), nor a virtual pet.
class XiaochangAvatar extends StatelessWidget {
  const XiaochangAvatar({
    super.key,
    this.size = 48,
    this.semanticLabel,
    this.borderRadius,
  }) : assert(size > 0);

  final double size;
  final String? semanticLabel;
  final BorderRadius? borderRadius;

  static const String assetPath = 'assets/characters/xiaochang.png';

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final fallbackLabel = l != null
        ? '${l.assistantName} · ${l.assistantSystemBadge}'
        : '小昌 · AI 助手';
    final effectiveLabel = semanticLabel ?? fallbackLabel;

    final effectiveRadius = borderRadius ?? BorderRadius.circular(size * 0.24);

    return Semantics(
      label: effectiveLabel,
      image: true,
      container: true,
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: const Color(0xFFE1F4EF),
          borderRadius: effectiveRadius,
          border: Border.all(
            color: const Color(0xFF0F766E).withValues(alpha: 0.25),
            width: size >= 48 ? 1.5 : 1.0,
          ),
        ),
        child: ClipRRect(
          borderRadius: effectiveRadius,
          child: Image.asset(
            assetPath,
            width: size,
            height: size,
            fit: BoxFit.cover,
            errorBuilder: (context, error, stackTrace) =>
                _FallbackIcon(size: size),
          ),
        ),
      ),
    );
  }
}

class _FallbackIcon extends StatelessWidget {
  const _FallbackIcon({required this.size});

  final double size;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Icon(
        Icons.auto_awesome_rounded,
        size: size * 0.55,
        color: const Color(0xFF0F766E),
      ),
    );
  }
}

/// Convenience alias for XiaochangAvatar.
typedef AgentAvatar = XiaochangAvatar;
