import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../l10n/app_localizations.dart';
import '../models/models.dart';
import '../theme/app_theme.dart';
import '../services/analytics_service.dart';
import 'feed_feedback_menu.dart';
import 'price_tag.dart';

typedef RecommendationFeedbackMenuBuilder = Widget Function(Listing listing);

/// Horizontal scrollable carousel showing recommended listings.
class RecommendationCarousel extends StatelessWidget {
  final List<Listing> listings;
  final String title;
  final AnalyticsService? analytics;
  final RecommendationFeedbackMenuBuilder? feedbackMenuBuilder;

  const RecommendationCarousel({
    super.key,
    required this.listings,
    this.title = '为你推荐',
    this.analytics,
    this.feedbackMenuBuilder,
  });

  @override
  Widget build(BuildContext context) {
    if (listings.isEmpty) {
      return const SizedBox.shrink();
    }
    final textScale = MediaQuery.textScalerOf(
      context,
    ).scale(1).clamp(1.0, 2.0).toDouble();
    final cardHeight = 264 + (textScale - 1) * 116;
    final cardWidth = 176 + (textScale - 1) * 52;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppTheme.sp16),
          child: Row(
            children: [
              const Icon(Icons.recommend, color: AppTheme.primary, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: AppTheme.textPrimary,
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        SizedBox(
          height: cardHeight,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: AppTheme.sp16),
            itemCount: listings.length,
            separatorBuilder: (context, index) => const SizedBox(width: 12),
            itemBuilder: (context, i) {
              final listing = listings[i];
              return _RecommendationCard(
                listing: listing,
                width: cardWidth,
                imageHeight: 112 + (textScale - 1) * 16,
                feedbackMenu: feedbackMenuBuilder?.call(listing),
                onTap: () {
                  analytics?.trackClick(listing.id);
                  context.push('/listing/${listing.id}');
                },
              );
            },
          ),
        ),
      ],
    );
  }
}

class _RecommendationCard extends StatelessWidget {
  final Listing listing;
  final VoidCallback onTap;
  final double width;
  final double imageHeight;
  final Widget? feedbackMenu;

  const _RecommendationCard({
    required this.listing,
    required this.onTap,
    required this.width,
    required this.imageHeight,
    required this.feedbackMenu,
  });

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final reasons = localizedFeedReasons(
      l,
      codes: listing.matchSummary,
      rankReason: listing.rankReason,
      source: listing.source,
    );
    final reasonText = reasons.join(' · ');
    final semanticsLabel = [
      listing.title,
      if (reasonText.isNotEmpty) reasonText,
      '${l.priceLabel} ¥${listing.suggestedPriceCny.toStringAsFixed(2)}',
      '${l.conditionLabel} ${listing.conditionScore}/10',
    ].join('. ');
    final borderRadius = BorderRadius.circular(AppTheme.radiusMd);

    return SizedBox(
      key: ValueKey('recommendation-card-${listing.id}'),
      width: width,
      child: Stack(
        children: [
          Positioned.fill(
            child: Semantics(
              button: true,
              excludeSemantics: true,
              label: semanticsLabel,
              child: Material(
                color: Theme.of(context).cardTheme.color,
                borderRadius: borderRadius,
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  onTap: onTap,
                  borderRadius: borderRadius,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      borderRadius: borderRadius,
                      border: Border.all(
                        color: Theme.of(context).dividerColor,
                        width: 1,
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(
                          height: imageHeight,
                          width: double.infinity,
                          child: ColoredBox(
                            color: AppTheme.primary.withValues(alpha: 0.08),
                            child: Center(
                              child: Icon(
                                Icons.inventory_2_outlined,
                                size: 40,
                                color: AppTheme.primary.withValues(alpha: 0.4),
                              ),
                            ),
                          ),
                        ),
                        Expanded(
                          child: Padding(
                            padding: const EdgeInsets.all(AppTheme.sp8),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  listing.title,
                                  key: ValueKey(
                                    'recommendation-title-${listing.id}',
                                  ),
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w600,
                                    fontSize: 12,
                                    height: 1.3,
                                  ),
                                ),
                                if (reasonText.isNotEmpty) ...[
                                  const SizedBox(height: AppTheme.sp4),
                                  Text(
                                    reasonText,
                                    key: ValueKey(
                                      'recommendation-reason-${listing.id}',
                                    ),
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      color: AppTheme.primary.withValues(
                                        alpha: 0.82,
                                      ),
                                      fontSize: 10,
                                      fontWeight: FontWeight.w600,
                                      height: 1.3,
                                    ),
                                  ),
                                ],
                                const Spacer(),
                                Wrap(
                                  key: ValueKey(
                                    'recommendation-details-${listing.id}',
                                  ),
                                  spacing: AppTheme.sp6,
                                  runSpacing: AppTheme.sp6,
                                  alignment: WrapAlignment.spaceBetween,
                                  crossAxisAlignment: WrapCrossAlignment.end,
                                  children: [
                                    PriceTag(
                                      priceCny: listing.suggestedPriceCny,
                                      fontSize: 13,
                                    ),
                                    conditionBadgeFromScore(
                                      listing.conditionScore,
                                    ),
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
          ),
          if (feedbackMenu != null)
            Positioned(
              top: AppTheme.sp8,
              right: AppTheme.sp8,
              child: Material(
                color: Theme.of(
                  context,
                ).colorScheme.surface.withValues(alpha: 0.94),
                shape: const CircleBorder(),
                clipBehavior: Clip.antiAlias,
                child: feedbackMenu,
              ),
            ),
        ],
      ),
    );
  }
}
