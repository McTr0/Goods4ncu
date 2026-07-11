import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../models/models.dart';
import '../theme/app_theme.dart';
import '../services/analytics_service.dart';
import 'price_tag.dart';

/// Horizontal scrollable carousel showing recommended listings.
class RecommendationCarousel extends StatelessWidget {
  final List<Listing> listings;
  final String title;
  final AnalyticsService? analytics;

  const RecommendationCarousel({
    super.key,
    required this.listings,
    this.title = '为你推荐',
    this.analytics,
  });

  @override
  Widget build(BuildContext context) {
    if (listings.isEmpty) {
      return const SizedBox.shrink();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppTheme.sp16),
          child: Row(
            children: [
              const Icon(Icons.recommend, color: AppTheme.primary, size: 20),
              const SizedBox(width: 8),
              Text(
                title,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: AppTheme.textPrimary,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        SizedBox(
          height: 220,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: AppTheme.sp16),
            itemCount: listings.length,
            separatorBuilder: (context, index) => const SizedBox(width: 12),
            itemBuilder: (context, i) {
              final listing = listings[i];
              return _RecommendationCard(
                listing: listing,
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

  const _RecommendationCard({required this.listing, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 150,
        decoration: BoxDecoration(
          color: Theme.of(context).cardTheme.color,
          borderRadius: BorderRadius.circular(AppTheme.radiusMd),
          border: Border.all(color: Theme.of(context).dividerColor, width: 1),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Thumbnail placeholder
            Expanded(
              flex: 3,
              child: Container(
                width: double.infinity,
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
            // Info
            Expanded(
              flex: 2,
              child: Padding(
                padding: const EdgeInsets.all(AppTheme.sp8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      listing.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 12,
                        height: 1.3,
                      ),
                    ),
                    const Spacer(),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Flexible(
                          child: PriceTag(
                            priceCny: listing.suggestedPriceCny,
                            fontSize: 13,
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
    );
  }
}
