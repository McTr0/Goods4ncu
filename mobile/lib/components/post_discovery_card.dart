import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../l10n/app_localizations.dart';
import '../models/post.dart';
import '../models/post_taxonomy.dart';
import '../theme/app_theme.dart';
import '../utils/platform_utils.dart';
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
    final listing = post.listing;
    final isGoods = post.category != 'discussion';
    final typeLabel = postCategoryLabel(context, post.category);
    // All available imagery: post cover first, then the product photo.
    final images = <String>{
      if (post.coverImageUrl != null && post.coverImageUrl!.isNotEmpty)
        resolveDisplayUrl(post.coverImageUrl!),
      if (listing?.imageUrl != null && listing!.imageUrl!.isNotEmpty)
        resolveDisplayUrl(listing.imageUrl!),
    }.toList(growable: false);
    final hasImage = images.isNotEmpty;
    final headTag = post.tags.isEmpty ? null : post.tags.first;

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
              if (hasImage || isGoods)
                AspectRatio(
                  aspectRatio: isGoods ? 1.05 : 1.35,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      if (hasImage)
                        _CardImageGallery(
                          key: ValueKey('post-cover-${post.id}'),
                          images: images,
                        )
                      else
                        _PostCoverFallback(isListing: isGoods),
                      Positioned(
                        left: AppTheme.sp8,
                        top: AppTheme.sp8,
                        child: _TypePill(label: typeLabel, isListing: isGoods),
                      ),
                      if (headTag != null)
                        Positioned(
                          right: AppTheme.sp8,
                          top: AppTheme.sp8,
                          child: _TagPill(tagKey: headTag),
                        ),
                    ],
                  ),
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 11, 12, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (!hasImage && !isGoods)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Row(
                          children: [
                            _TypePill(label: typeLabel, isListing: false),
                            const Spacer(),
                            if (headTag != null) _TagPill(tagKey: headTag),
                          ],
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
                        maxLines: isGoods ? 2 : 3,
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
                    if (post.tags.length > 1) ...[
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 5,
                        runSpacing: 5,
                        children: post.tags
                            .skip(1)
                            .take(2)
                            .map(
                              (tag) => Text(
                                postTagLabel(context, tag),
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
                        const SizedBox(width: 6),
                        Icon(
                          Icons.schedule_rounded,
                          size: 13,
                          color: scheme.onSurfaceVariant,
                        ),
                        const SizedBox(width: 3),
                        Text(
                          _lastActivityLabel(context, post.lastActivityAt),
                          style: TextStyle(
                            color: scheme.onSurfaceVariant,
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(width: 6),
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

/// Compact recent-activity stamp for discovery tiles.
String _lastActivityLabel(BuildContext context, DateTime? value) {
  if (value == null) return '';
  final locale = Localizations.localeOf(context).toLanguageTag();
  final local = value.toLocal();
  final now = DateTime.now();
  final diff = now.difference(local);
  if (diff.inMinutes < 1) return '刚刚';
  if (diff.inHours < 24) return '${diff.inHours}小时前';
  if (diff.inDays < 7) return '${diff.inDays}天前';
  if (local.year == now.year) return DateFormat.MMMd(locale).format(local);
  return DateFormat.yMMMd(locale).format(local);
}

/// Swipeable image gallery: post cover first, product photo second.
class _CardImageGallery extends StatefulWidget {
  const _CardImageGallery({super.key, required this.images});

  final List<String> images;

  @override
  State<_CardImageGallery> createState() => _CardImageGalleryState();
}

class _CardImageGalleryState extends State<_CardImageGallery> {
  int _page = 0;

  @override
  Widget build(BuildContext context) {
    final images = widget.images;
    return Stack(
      fit: StackFit.expand,
      children: [
        PageView.builder(
          itemCount: images.length,
          onPageChanged: (page) => setState(() => _page = page),
          itemBuilder: (context, index) => Image.network(
            images[index],
            fit: BoxFit.cover,
            errorBuilder: (_, _, _) => _PostCoverFallback(isListing: index > 0),
          ),
        ),
        if (images.length > 1)
          Positioned(
            right: 8,
            bottom: 8,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
              decoration: BoxDecoration(
                color: Colors.black45,
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                '${_page + 1}/${images.length}',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// Emoji + label tag pill for the card's top-right corner.
class _TagPill extends StatelessWidget {
  const _TagPill({required this.tagKey});

  final String tagKey;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.black45,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        postTagLabel(context, tagKey),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 11,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}
