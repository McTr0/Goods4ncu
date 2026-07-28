import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../l10n/app_localizations.dart';
import '../models/models.dart';
import '../theme/app_theme.dart';
import '../utils/category_utils.dart';
import '../utils/platform_utils.dart';
import 'feed_feedback_menu.dart';

class PriceTag extends StatelessWidget {
  final double priceCny;
  final double fontSize;
  final FontWeight fontWeight;

  const PriceTag({
    super.key,
    required this.priceCny,
    this.fontSize = 18,
    this.fontWeight = FontWeight.bold,
  });

  @override
  Widget build(BuildContext context) {
    final formatter = NumberFormat.currency(symbol: '\u00A5', decimalDigits: 2);
    return Text(
      formatter.format(priceCny),
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        fontSize: fontSize,
        fontWeight: fontWeight,
        color: AppTheme.accent,
        letterSpacing: -0.3,
      ),
    );
  }
}

class ConditionBadge extends StatelessWidget {
  final int score;
  final Color color;

  const ConditionBadge({super.key, required this.score, required this.color});

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    String label;
    if (score >= 9) {
      label = l.conditionLikeNew;
    } else if (score >= 7) {
      label = l.conditionGood;
    } else if (score >= 5) {
      label = l.conditionFair;
    } else {
      label = l.conditionPoor;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(AppTheme.radiusLg),
        border: Border.all(color: color.withValues(alpha: 0.18)),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: color,
        ),
      ),
    );
  }
}

ConditionBadge conditionBadgeFromScore(int score) {
  Color color;
  if (score >= 9) {
    color = AppTheme.success;
  } else if (score >= 7) {
    color = AppTheme.info;
  } else if (score >= 5) {
    color = AppTheme.warning;
  } else {
    color = AppTheme.error;
  }
  return ConditionBadge(score: score, color: color);
}

class ListingCard extends StatelessWidget {
  final Listing listing;
  final VoidCallback onTap;
  final Widget? feedbackMenu;

  const ListingCard({
    super.key,
    required this.listing,
    required this.onTap,
    this.feedbackMenu,
  });

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final category = listing.category.trim();
    final categoryLabel = localizedCategoryLabel(context, category);
    final brand = listing.brand.trim();
    final hasReason =
        (listing.rankReason ?? '').isNotEmpty ||
        (listing.source ?? '').isNotEmpty;
    final reason = hasReason
        ? localizedFeedReason(l, listing.rankReason, source: listing.source)
        : null;

    return Stack(
      children: [
        Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(AppTheme.radiusLg),
            mouseCursor: SystemMouseCursors.click,
            onTap: onTap,
            child: Ink(
              decoration: BoxDecoration(
                color: Theme.of(context).cardTheme.color,
                borderRadius: BorderRadius.circular(AppTheme.radiusLg),
                border: Border.all(
                  color: Theme.of(context).dividerColor.withValues(alpha: 0.82),
                  width: 1,
                ),
                boxShadow: AppTheme.softShadow,
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(AppTheme.radiusLg),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      flex: 3,
                      child: _ListingImageHeader(
                        imageUrl: listing.imageUrl,
                        category: categoryLabel,
                        directionKey: ValueKey(
                          'listing-direction-${listing.id}',
                        ),
                        feedbackMenu: feedbackMenu,
                        directionLabel: listing.isWanted
                            ? l.listingDirectionWanted
                            : l.listingDirectionOffer,
                        icon: _iconForCategory(category),
                      ),
                    ),
                    Expanded(
                      flex: 2,
                      child: Padding(
                        padding: const EdgeInsets.all(AppTheme.sp12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              listing.title,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontWeight: FontWeight.w800,
                                fontSize: 13,
                                height: 1.25,
                                color: AppTheme.textPrimary,
                              ),
                            ),
                            if (brand.isNotEmpty) ...[
                              const SizedBox(height: 3),
                              Text(
                                brand,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                  color: AppTheme.textSecondary,
                                ),
                              ),
                            ],
                            if (reason != null) ...[
                              const SizedBox(height: 3),
                              Text(
                                reason,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.w600,
                                  color: AppTheme.primary.withValues(
                                    alpha: 0.75,
                                  ),
                                ),
                              ),
                            ],
                            const Spacer(),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: [
                                Flexible(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        listing.isWanted
                                            ? l.wantedBudgetShort
                                            : l.priceLabel,
                                        style: const TextStyle(
                                          fontSize: 10,
                                          fontWeight: FontWeight.w700,
                                          color: AppTheme.textSecondary,
                                        ),
                                      ),
                                      PriceTag(
                                        priceCny: listing.suggestedPriceCny,
                                        fontSize: 15,
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(width: 4),
                                conditionBadgeFromScore(listing.conditionScore),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  IconData _iconForCategory(String category) {
    final normalized = category.toLowerCase();
    if (normalized.contains('书') || normalized.contains('book')) {
      return Icons.menu_book_outlined;
    }
    if (normalized.contains('电') ||
        normalized.contains('数码') ||
        normalized.contains('tech')) {
      return Icons.devices_other_outlined;
    }
    if (normalized.contains('衣') || normalized.contains('服')) {
      return Icons.checkroom_outlined;
    }
    if (normalized.contains('车') || normalized.contains('bike')) {
      return Icons.pedal_bike_outlined;
    }
    if (normalized.contains('家具') || normalized.contains('home')) {
      return Icons.chair_outlined;
    }
    return Icons.inventory_2_outlined;
  }
}

class _ListingImageHeader extends StatelessWidget {
  final String? imageUrl;
  final String category;
  final Key directionKey;
  final Widget? feedbackMenu;
  final String directionLabel;
  final IconData icon;

  const _ListingImageHeader({
    required this.imageUrl,
    required this.category,
    required this.directionKey,
    required this.feedbackMenu,
    required this.directionLabel,
    required this.icon,
  });

  @override
  Widget build(BuildContext context) {
    final url = imageUrl == null ? null : resolveDisplayUrl(imageUrl!);
    final hasImage = url != null && url.isNotEmpty;

    return Stack(
      fit: StackFit.expand,
      children: [
        if (hasImage)
          Image.network(
            url,
            fit: BoxFit.cover,
            errorBuilder: (context, error, stackTrace) =>
                _ListingImageFallback(icon: icon),
            loadingBuilder: (context, child, progress) {
              if (progress == null) return child;
              return _ListingImageFallback(icon: icon);
            },
          )
        else
          _ListingImageFallback(icon: icon),
        Positioned.fill(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.transparent,
                  Colors.black.withValues(alpha: hasImage ? 0.18 : 0),
                ],
              ),
            ),
          ),
        ),
        Positioned(
          left: AppTheme.sp12,
          top: AppTheme.sp12,
          child: _ListingPill(label: category.isEmpty ? '闲置好物' : category),
        ),
        Positioned(
          right: AppTheme.sp12,
          top: AppTheme.sp12,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              _ListingPill(
                key: directionKey,
                label: directionLabel,
                strong: true,
              ),
              if (feedbackMenu != null) ...[
                const SizedBox(height: AppTheme.sp6),
                Material(
                  color: Theme.of(
                    context,
                  ).colorScheme.surface.withValues(alpha: 0.92),
                  shape: const CircleBorder(),
                  clipBehavior: Clip.antiAlias,
                  child: feedbackMenu!,
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _ListingImageFallback extends StatelessWidget {
  final IconData icon;

  const _ListingImageFallback({required this.icon});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [AppTheme.mint, AppTheme.sand, AppTheme.accentSoft],
        ),
      ),
      child: Stack(
        children: [
          Positioned(
            right: -18,
            top: -18,
            child: Container(
              width: 84,
              height: 84,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.48),
                shape: BoxShape.circle,
              ),
            ),
          ),
          Center(
            child: Container(
              width: 70,
              height: 70,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.72),
                borderRadius: BorderRadius.circular(AppTheme.radiusXl),
                border: Border.all(color: Colors.white.withValues(alpha: 0.78)),
              ),
              child: Icon(
                icon,
                size: 36,
                color: AppTheme.primaryDark.withValues(alpha: 0.72),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ListingPill extends StatelessWidget {
  final String label;
  final bool strong;

  const _ListingPill({super.key, required this.label, this.strong = false});

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(maxWidth: 92),
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: strong
            ? AppTheme.primaryDark.withValues(alpha: 0.9)
            : Colors.white.withValues(alpha: 0.82),
        borderRadius: BorderRadius.circular(AppTheme.radiusLg),
        border: Border.all(
          color: strong
              ? AppTheme.primaryDark.withValues(alpha: 0.92)
              : Colors.white.withValues(alpha: 0.86),
        ),
      ),
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(
          color: AppTheme.primaryDark,
          fontSize: 11,
          fontWeight: FontWeight.w800,
        ).copyWith(color: strong ? Colors.white : AppTheme.primaryDark),
      ),
    );
  }
}
