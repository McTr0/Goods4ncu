import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../theme/app_theme.dart';
import '../utils/platform_utils.dart';

class PaymentQrImage extends StatelessWidget {
  const PaymentQrImage({
    super.key,
    required this.url,
    required this.label,
    this.width,
    this.height,
    this.fit = BoxFit.cover,
  });

  final String url;
  final String label;
  final double? width;
  final double? height;
  final BoxFit fit;

  @override
  Widget build(BuildContext context) {
    final displayUrl = resolveDisplayUrl(url);
    return Image.network(
      displayUrl,
      width: width,
      height: height,
      fit: fit,
      errorBuilder: (context, error, stackTrace) {
        final l = AppLocalizations.of(context)!;
        return Container(
          width: width,
          height: height,
          alignment: Alignment.center,
          padding: const EdgeInsets.all(AppTheme.sp8),
          color: AppTheme.primary.withValues(alpha: 0.08),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.broken_image_outlined, color: AppTheme.primary),
              const SizedBox(height: AppTheme.sp4),
              Text(
                l.loadFailed(label),
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: AppTheme.textSecondary,
                  fontSize: 11,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
