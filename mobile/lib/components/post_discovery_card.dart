import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../models/post.dart';
import '../theme/app_theme.dart';
import '../utils/category_utils.dart';
import '../utils/platform_utils.dart';
import 'feed_feedback_menu.dart';
import 'price_tag.dart';
import 'user_avatar.dart';

/// A compact, visual-first discovery tile. Cards keep their natural height so
/// the homepage can arrange them in a Xiaohongshu-style waterfall grid.
class PostDiscoveryCard extends StatelessWidget {
  const PostDiscoveryCard({
    super.key,
    required this.post,
    required this.onTap,
    this.feedbackMenu,
  });

  final CampusPost post;
  final VoidCallback onTap;
  final Widget? feedbackMenu;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final scheme = Theme.of(context).colorScheme;
    final cover = post.coverImageUrl == null
        ? null
        : resolveDisplayUrl(post.coverImageUrl!);
    final hasCover = cover != null && cover.isNotEmpty;
    final listing = post.listing;
    final typeLabel = post.isListing
        ? switch (listing?.direction) {
            'wanted' => l.listingDirectionWanted,
            'offer' => l.listingDirectionOffer,
            _ => l.postTypeListing,
          }
        : l.postTypeDiscussion;
    final reason =
        (post.rankReason ?? '').isNotEmpty || (post.rankSource ?? '').isNotEmpty
        ? localizedFeedReason(l, post.rankReason, source: post.rankSource)
        : null;

    return Material(
      key: ValueKey('post-card-${post.id}'),
      color: scheme.surface,
      borderRadius: BorderRadius.circular(AppTheme.radiusLg),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Ink(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppTheme.radiusLg),
            border: Border.all(color: scheme.outlineVariant),
            boxShadow: Theme.of(context).brightness == Brightness.dark
                ? const []
                : AppTheme.softShadow,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (hasCover || post.isListing)
                AspectRatio(
                  aspectRatio: post.isListing ? 1.05 : 1.35,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      if (hasCover)
                        Image.network(
                          cover,
                          key: ValueKey('post-cover-${post.id}'),
                          fit: BoxFit.cover,
                          errorBuilder: (_, _, _) =>
                              _PostCoverFallback(isListing: post.isListing),
                        )
                      else
                        _PostCoverFallback(isListing: post.isListing),
                      Positioned(
                        left: AppTheme.sp8,
                        top: AppTheme.sp8,
                        child: _TypePill(
                          label: typeLabel,
                          isListing: post.isListing,
                        ),
                      ),
                    ],
                  ),
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 11, 12, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (!hasCover && !post.isListing)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: _TypePill(
                          label: l.postTypeDiscussion,
                          isListing: false,
                        ),
                      ),
                    Text(
                      post.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: scheme.onSurface,
                        fontSize: 14,
                        fontWeight: FontWeight.w800,
                        height: 1.3,
                      ),
                    ),
                    if (post.displayBody.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Text(
                        post.displayBody,
                        maxLines: post.isListing ? 2 : 3,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: scheme.onSurfaceVariant,
                          fontSize: 12,
                          height: 1.45,
                        ),
                      ),
                    ],
                    if (listing != null) ...[
                      const SizedBox(height: 8),
                      PriceTag(
                        priceCny: listing.suggestedPriceCny,
                        fontSize: 16,
                      ),
                    ],
                    if (post.tags.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 5,
                        runSpacing: 5,
                        children: post.tags
                            .take(3)
                            .map(
                              (tag) => Text(
                                '#$tag',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: scheme.primary,
                                  fontSize: 10,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            )
                            .toList(growable: false),
                      ),
                    ],
                    if (reason != null) ...[
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Icon(
                            Icons.auto_awesome_outlined,
                            size: 13,
                            color: scheme.primary,
                          ),
                          const SizedBox(width: 4),
                          Expanded(
                            child: Text(
                              reason,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: scheme.primary,
                                fontSize: 10,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                    const SizedBox(height: 11),
                    Row(
                      children: [
                        UserAvatar(name: post.author.username, size: 24),
                        const SizedBox(width: 7),
                        Expanded(
                          child: Text(
                            post.author.username.isEmpty
                                ? l.postAnonymousAuthor
                                : post.author.username,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: scheme.onSurfaceVariant,
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        Icon(
                          Icons.mode_comment_outlined,
                          size: 14,
                          color: scheme.onSurfaceVariant,
                        ),
                        const SizedBox(width: 3),
                        Text(
                          '${post.replyCount}',
                          style: TextStyle(
                            color: scheme.onSurfaceVariant,
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        if (feedbackMenu != null) ...[
                          const SizedBox(width: 2),
                          feedbackMenu!,
                        ],
                      ],
                    ),
                    if ((post.category ?? '').isNotEmpty) ...[
                      const SizedBox(height: 7),
                      Text(
                        localizedCategoryLabel(context, post.category!),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: scheme.onSurfaceVariant.withValues(alpha: 0.8),
                          fontSize: 10,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PostCoverFallback extends StatelessWidget {
  const _PostCoverFallback({required this.isListing});

  final bool isListing;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: isListing
              ? const [AppTheme.mint, AppTheme.sand, AppTheme.accentSoft]
              : [scheme.primaryContainer, scheme.secondaryContainer],
        ),
      ),
      child: Center(
        child: Icon(
          isListing ? Icons.inventory_2_outlined : Icons.forum_outlined,
          size: 42,
          color: scheme.primary.withValues(alpha: 0.66),
        ),
      ),
    );
  }
}

class _TypePill extends StatelessWidget {
  const _TypePill({required this.label, required this.isListing});

  final String label;
  final bool isListing;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = isListing ? AppTheme.accent : scheme.primary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: scheme.surface.withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.28)),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 10,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}
