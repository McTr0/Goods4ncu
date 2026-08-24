import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../components/price_tag.dart';
import '../components/user_avatar.dart';
import '../l10n/app_localizations.dart';
import '../models/models.dart';
import '../models/post.dart';
import '../services/listing_service.dart';
import '../services/post_service.dart';
import '../theme/app_theme.dart';
import '../theme/responsive.dart';
import '../utils/mutual_aid_utils.dart';
import '../utils/platform_utils.dart';

class PostDetailPage extends StatefulWidget {
  const PostDetailPage({
    super.key,
    this.postId,
    this.listingId,
    this.postService,
    this.listingService,
    this.embedded = false,
    this.omitOriginalPost = false,
  }) : assert(
         postId != null || listingId != null,
         'Either postId or listingId must be provided.',
       );

  final String? postId;
  final String? listingId;
  final PostService? postService;
  final ListingService? listingService;

  /// Renders the thread as part of another detail page. Embedded threads use
  /// their parent's scroll view and keep the reply composer in the document
  /// flow instead of creating a second scaffold/navigation bar.
  final bool embedded;

  /// Listing detail already represents floor #1, so its embedded discussion
  /// can start at the reply heading without repeating the whole listing.
  final bool omitOriginalPost;

  @override
  State<PostDetailPage> createState() => _PostDetailPageState();
}

class _PostDetailPageState extends State<PostDetailPage> {
  late final PostService _postService;
  ListingService? _listingService;
  final _replyController = TextEditingController();
  final _replyFocus = FocusNode();

  CampusPost? _post;
  Listing? _listing;
  List<PostReply> _replies = const [];
  int _replyTotal = 0;
  int _replyOffset = 0;
  bool _repliesHasMore = false;
  bool _repliesLoadingMore = false;
  String? _repliesPageError;
  PostReply? _replyingTo;
  bool _loading = true;
  bool _sending = false;
  String? _error;
  int _loadGeneration = 0;

  @override
  void initState() {
    super.initState();
    _postService = widget.postService ?? context.read<PostService>();
    _listingService = widget.listingService ?? context.read<ListingService?>();
    _loadThread();
  }

  @override
  void didUpdateWidget(covariant PostDetailPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.postId != widget.postId ||
        oldWidget.listingId != widget.listingId) {
      _loadThread();
    }
  }

  @override
  void dispose() {
    _replyController.dispose();
    _replyFocus.dispose();
    super.dispose();
  }

  Future<void> _loadThread() async {
    final generation = ++_loadGeneration;
    setState(() {
      _loading = true;
      _error = null;
      _post = null;
      _listing = null;
      _replies = const [];
      _replyTotal = 0;
      _replyOffset = 0;
      _repliesHasMore = false;
      _repliesLoadingMore = false;
      _repliesPageError = null;
      _replyingTo = null;
    });
    try {
      final post = widget.postId != null
          ? await _postService.getPost(widget.postId!)
          : await _postService.getPostByListing(widget.listingId!);
      final repliesFuture = _postService.getReplies(post.id, limit: 50);
      final listingFuture =
          post.category != 'discussion' &&
              post.listingId != null &&
              !widget.omitOriginalPost &&
              _listingService != null
          ? _listingService!.getListingDetail(post.listingId!)
          : Future<Listing?>.value(null);
      final replies = await repliesFuture;
      Listing? listing;
      try {
        listing = await listingFuture;
      } catch (_) {
        // A stale/deleted commerce projection should not make the discussion
        // unreadable. The linked-listing affordance simply stays hidden.
      }
      if (!mounted || generation != _loadGeneration) return;

      // A marketplace listing has one canonical detail hierarchy. Legacy
      // links to its post projection resolve to the listing page, whose body
      // contains this same thread inline. A plain MaterialApp (for example a
      // widget test or an isolated embed) has no router and retains the local
      // thread rendering as a safe fallback.
      final router = widget.embedded ? null : GoRouter.maybeOf(context);
      if (post.category != 'discussion' &&
          post.listingId != null &&
          router != null) {
        router.go('/listing/${Uri.encodeComponent(post.listingId!)}');
        return;
      }
      setState(() {
        _post = post;
        _listing = listing;
        _replies = replies.items;
        _replyTotal = replies.total;
        _replyOffset = replies.items.length;
        _repliesHasMore = replies.items.length < replies.total;
        _loading = false;
      });
    } catch (error) {
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _loading = false;
        _error = error.toString();
      });
    }
  }

  void _startReply(PostReply reply) {
    setState(() => _replyingTo = reply);
    _replyFocus.requestFocus();
  }

  Future<void> _loadMoreReplies() async {
    final post = _post;
    if (post == null || !_repliesHasMore || _repliesLoadingMore || _loading) {
      return;
    }
    final generation = _loadGeneration;
    setState(() {
      _repliesLoadingMore = true;
      _repliesPageError = null;
    });
    try {
      final response = await _postService.getReplies(
        post.id,
        limit: 50,
        offset: _replyOffset,
      );
      if (!mounted || generation != _loadGeneration || _post?.id != post.id) {
        return;
      }
      final byId = <String, PostReply>{
        for (final reply in _replies) reply.id: reply,
      };
      for (final reply in response.items) {
        byId[reply.id] = reply;
      }
      final merged = byId.values.toList()
        ..sort((a, b) {
          final aTime = a.createdAt ?? DateTime.fromMillisecondsSinceEpoch(0);
          final bTime = b.createdAt ?? DateTime.fromMillisecondsSinceEpoch(0);
          final timeOrder = aTime.compareTo(bTime);
          return timeOrder != 0 ? timeOrder : a.id.compareTo(b.id);
        });
      setState(() {
        _replies = merged;
        _replyOffset += response.items.length;
        _replyTotal = response.total;
        _repliesHasMore =
            response.items.isNotEmpty && _replyOffset < response.total;
        _repliesLoadingMore = false;
      });
    } catch (error) {
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _repliesLoadingMore = false;
        _repliesPageError = error.toString();
      });
    }
  }

  Future<void> _submitReply() async {
    final post = _post;
    final body = _replyController.text.trim();
    if (post == null || post.isLocked || body.isEmpty || _sending) return;
    setState(() => _sending = true);
    try {
      final reply = await _postService.createReply(
        post.id,
        body: body,
        replyToId: _replyingTo?.id,
      );
      if (!mounted) return;
      setState(() {
        _replies = [..._replies, reply];
        _replyTotal += 1;
        if (!_repliesHasMore) _replyOffset += 1;
        _replyController.clear();
        _replyingTo = null;
        _post = post.copyWith(
          replyCount: post.replyCount + 1,
          lastActivityAt: DateTime.now(),
        );
      });
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(AppLocalizations.of(context)!.postReplyFailed),
          backgroundColor: AppTheme.error,
        ),
      );
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _setResolution(String value) async {
    final post = _post;
    if (post == null || !post.isErrand) return;
    try {
      final updated = await _postService.updateResolution(post.id, value);
      if (mounted) setState(() => _post = updated);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error.toString())));
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final post = _post;
    Widget? askAssistant;
    if (!widget.embedded && post != null) {
      askAssistant = IconButton(
        key: const Key('post-ask-assistant'),
        tooltip: l.assistantAskAboutPage,
        onPressed: () => context.push(
          widget.listingId != null
              ? '/chat?listingId=${Uri.encodeComponent(widget.listingId!)}'
              : '/chat?postId=${Uri.encodeComponent(post.id)}',
        ),
        icon: const Icon(Icons.auto_awesome_outlined),
      );
    }
    if (widget.embedded) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildBody(),
          if (post != null && !_loading)
            _ReplyComposer(
              controller: _replyController,
              focusNode: _replyFocus,
              replyingTo: _replyingTo,
              locked: post.isLocked,
              sending: _sending,
              embedded: true,
              onCancelReply: () => setState(() => _replyingTo = null),
              onSubmit: _submitReply,
            ),
        ],
      );
    }
    return Scaffold(
      appBar: AppBar(
        title: Text(
          post != null && post.category != 'discussion'
              ? (post.category == 'wanted'
                    ? l.publishCategoryWanted
                    : l.publishCategoryOffer)
              : l.postDetailTitle,
        ),
        leading: IconButton(
          onPressed: () => context.canPop() ? context.pop() : context.go('/'),
          icon: const Icon(Icons.arrow_back_rounded),
        ),
        actions: [?askAssistant],
      ),
      body: _buildBody(),
      bottomNavigationBar: post == null || _loading
          ? null
          : _ReplyComposer(
              controller: _replyController,
              focusNode: _replyFocus,
              replyingTo: _replyingTo,
              locked: post.isLocked,
              sending: _sending,
              onCancelReply: () => setState(() => _replyingTo = null),
              onSubmit: _submitReply,
            ),
    );
  }

  Widget _buildBody() {
    final l = AppLocalizations.of(context)!;
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null || _post == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(AppTheme.sp24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.forum_outlined, size: 48, color: AppTheme.error),
              const SizedBox(height: AppTheme.sp12),
              Text(l.postLoadFailed, textAlign: TextAlign.center),
              const SizedBox(height: AppTheme.sp16),
              FilledButton.icon(
                onPressed: _loadThread,
                icon: const Icon(Icons.refresh_rounded),
                label: Text(l.retry),
              ),
            ],
          ),
        ),
      );
    }

    final content = ResponsiveContent(
      maxWidth: 960,
      child: _buildThreadContent(_post!),
    );
    if (widget.embedded) {
      return content;
    }
    return RefreshIndicator(
      onRefresh: _loadThread,
      child: ListView(
        padding: EdgeInsets.fromLTRB(
          MediaQuery.sizeOf(context).width >= AppBreakpoints.desktop
              ? AppTheme.sp32
              : AppTheme.sp12,
          AppTheme.sp16,
          MediaQuery.sizeOf(context).width >= AppBreakpoints.desktop
              ? AppTheme.sp32
              : AppTheme.sp12,
          AppTheme.sp32,
        ),
        children: [content],
      ),
    );
  }

  Widget _buildThreadContent(CampusPost post) {
    final l = AppLocalizations.of(context)!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (!widget.omitOriginalPost) ...[
          _ThreadPostCard(
            post: post,
            listing: _listing,
            onSetResolution: _setResolution,
          ),
          const SizedBox(height: AppTheme.sp16),
        ],
        Row(
          children: [
            Text(
              l.postRepliesTitle,
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w900),
            ),
            const SizedBox(width: AppTheme.sp8),
            _CountBadge(count: _replyTotal),
            const Spacer(),
            Text(
              l.postThreadOrder,
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
        const SizedBox(height: AppTheme.sp8),
        if (_replies.isEmpty)
          _ThreadEmptyState(locked: post.isLocked)
        else
          ..._replies.indexed.map(
            (entry) => Padding(
              padding: const EdgeInsets.only(bottom: AppTheme.sp8),
              child: _ThreadReplyCard(
                reply: entry.$2,
                floor: entry.$1 + 2,
                replyingTo: _replyById(entry.$2.replyToId),
                canReply: !post.isLocked,
                onReply: () => _startReply(entry.$2),
              ),
            ),
          ),
        if (_repliesHasMore || _repliesLoadingMore || _repliesPageError != null)
          _ReplyPagination(
            isLoading: _repliesLoadingMore,
            hasError: _repliesPageError != null,
            onLoad: _loadMoreReplies,
          ),
      ],
    );
  }

  PostReply? _replyById(String? id) {
    if (id == null) return null;
    for (final reply in _replies) {
      if (reply.id == id) return reply;
    }
    return null;
  }
}

class _ThreadPostCard extends StatelessWidget {
  const _ThreadPostCard({
    required this.post,
    required this.listing,
    required this.onSetResolution,
  });

  final CampusPost post;
  final Listing? listing;
  final ValueChanged<String> onSetResolution;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final scheme = Theme.of(context).colorScheme;
    return Container(
      key: const ValueKey('post-original-floor'),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(AppTheme.radiusLg),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(AppTheme.sp16),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest.withValues(alpha: 0.45),
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(AppTheme.radiusLg),
              ),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                UserAvatar(name: post.author.username, size: 44),
                const SizedBox(width: AppTheme.sp12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        post.author.username.isEmpty
                            ? l.postAnonymousAuthor
                            : post.author.username,
                        style: const TextStyle(fontWeight: FontWeight.w800),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        _formatPostDate(context, post.createdAt),
                        style: TextStyle(
                          color: scheme.onSurfaceVariant,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
                _PostTypeChip(post: post),
                const SizedBox(width: AppTheme.sp8),
                Text(
                  '#1',
                  style: TextStyle(
                    color: scheme.onSurfaceVariant,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
          if (post.category == 'discussion' && post.coverImageUrl != null)
            AspectRatio(
              aspectRatio: 4 / 3,
              child: Image.network(
                resolveDisplayUrl(post.coverImageUrl!),
                key: const ValueKey('post-detail-cover'),
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => ColoredBox(
                  color: scheme.surfaceContainerHighest,
                  child: Icon(
                    Icons.broken_image_outlined,
                    color: scheme.onSurfaceVariant,
                    size: 42,
                  ),
                ),
              ),
            ),
          Padding(
            padding: const EdgeInsets.all(AppTheme.sp20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  post.title,
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w900,
                    height: 1.25,
                  ),
                ),
                if (post.tags.isNotEmpty) ...[
                  const SizedBox(height: AppTheme.sp8),
                  Wrap(
                    spacing: 7,
                    runSpacing: 7,
                    children: post.tags
                        .map(
                          (tag) => Chip(
                            label: Text('#$tag'),
                            visualDensity: VisualDensity.compact,
                            side: BorderSide.none,
                          ),
                        )
                        .toList(growable: false),
                  ),
                ],
                if (post.displayBody.isNotEmpty) ...[
                  const SizedBox(height: AppTheme.sp16),
                  SelectionArea(
                    child: Text(
                      post.displayBody,
                      style: TextStyle(
                        color: scheme.onSurface,
                        fontSize: 15,
                        height: 1.72,
                      ),
                    ),
                  ),
                ],
                if (post.isErrand) ...[
                  const SizedBox(height: AppTheme.sp16),
                  _MutualAidSummary(post: post),
                  const SizedBox(height: AppTheme.sp8),
                  Align(
                    alignment: Alignment.centerRight,
                    child: post.canUpdateResolution
                        ? PopupMenuButton<String>(
                            tooltip: l.postResolutionUpdate,
                            initialValue: post.resolutionStatus,
                            onSelected: onSetResolution,
                            itemBuilder: (_) => [
                              PopupMenuItem(
                                value: 'open',
                                child: Text(l.postResolutionOpen),
                              ),
                              PopupMenuItem(
                                value: 'resolved',
                                child: Text(l.postResolutionResolved),
                              ),
                              PopupMenuItem(
                                value: 'closed',
                                child: Text(l.postResolutionClosed),
                              ),
                            ],
                            child: Chip(
                              avatar: const Icon(Icons.flag_outlined, size: 16),
                              label: Text(
                                _resolutionLabel(l, post.resolutionStatus),
                              ),
                            ),
                          )
                        : Chip(
                            avatar: const Icon(Icons.flag_outlined, size: 16),
                            label: Text(
                              _resolutionLabel(l, post.resolutionStatus),
                            ),
                          ),
                  ),
                ],
                if (post.listing != null) ...[
                  const SizedBox(height: AppTheme.sp20),
                  _LinkedListingCard(listing: listing),
                ],
                if (post.isLocked) ...[
                  const SizedBox(height: AppTheme.sp16),
                  Row(
                    children: [
                      Icon(Icons.lock_outline, size: 17, color: scheme.outline),
                      const SizedBox(width: AppTheme.sp6),
                      Text(
                        l.postLockedNotice,
                        style: TextStyle(
                          color: scheme.onSurfaceVariant,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

String _resolutionLabel(AppLocalizations l, String value) => switch (value) {
  'resolved' => l.postResolutionResolved,
  'closed' => l.postResolutionClosed,
  _ => l.postResolutionOpen,
};

class _MutualAidSummary extends StatelessWidget {
  const _MutualAidSummary({required this.post});

  final CampusPost post;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final metadata = post.errandMetadata;
    final details = <String>[
      if (post.category == 'offer')
        l.postMutualAidOffer
      else
        l.postMutualAidWanted,
      if (metadata['service_mode'] != null)
        mutualAidModeLabel(l, metadata['service_mode'].toString()),
      if (metadata['pickup_place'] != null)
        '${l.postMutualAidPickup}: ${metadata['pickup_place']}',
      if (metadata['dropoff_place'] != null)
        '${l.postMutualAidDropoff}: ${metadata['dropoff_place']}',
      if (metadata['time_hint'] != null)
        '${l.postMutualAidTime}: ${metadata['time_hint']}',
      if (metadata['reward_cents'] is num)
        '${l.postMutualAidReward}: ${((metadata['reward_cents'] as num) / 100).toStringAsFixed(0)}',
    ];
    if (details.isEmpty) return const SizedBox.shrink();
    return Wrap(
      spacing: 7,
      runSpacing: 7,
      children: details
          .map(
            (detail) =>
                Chip(label: Text(detail), visualDensity: VisualDensity.compact),
          )
          .toList(growable: false),
    );
  }
}

class _LinkedListingCard extends StatelessWidget {
  const _LinkedListingCard({required this.listing});

  final Listing? listing;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(AppTheme.sp14),
      decoration: BoxDecoration(
        color: AppTheme.accent.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(AppTheme.radiusMd),
        border: Border.all(color: AppTheme.accent.withValues(alpha: 0.2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: scheme.surface,
                  borderRadius: BorderRadius.circular(AppTheme.radiusSm),
                ),
                child: const Icon(Icons.inventory_2_outlined),
              ),
              const SizedBox(width: AppTheme.sp12),
              Expanded(
                child: Text(
                  l.postLinkedListing,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              if (listing != null)
                PriceTag(priceCny: listing!.suggestedPriceCny, fontSize: 19),
            ],
          ),
          if (listing != null) ...[
            const SizedBox(height: AppTheme.sp12),
            Wrap(
              spacing: AppTheme.sp12,
              runSpacing: AppTheme.sp6,
              children: [
                _ListingFact(label: l.categoryLabel, value: listing!.category),
                _ListingFact(label: l.brandLabel, value: listing!.brand),
                _ListingFact(
                  label: l.conditionLabel,
                  value: '${listing!.conditionScore}/10',
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _ListingFact extends StatelessWidget {
  const _ListingFact({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Text.rich(
      TextSpan(
        children: [
          TextSpan(
            text: '$label: ',
            style: TextStyle(color: scheme.onSurfaceVariant),
          ),
          TextSpan(
            text: value,
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
        ],
      ),
      style: const TextStyle(fontSize: 13),
    );
  }
}

class _ThreadReplyCard extends StatelessWidget {
  const _ThreadReplyCard({
    required this.reply,
    required this.floor,
    required this.replyingTo,
    required this.canReply,
    required this.onReply,
  });

  final PostReply reply;
  final int floor;
  final PostReply? replyingTo;
  final bool canReply;
  final VoidCallback onReply;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final scheme = Theme.of(context).colorScheme;
    return Container(
      key: ValueKey('post-floor-$floor'),
      padding: const EdgeInsets.all(AppTheme.sp16),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(AppTheme.radiusMd),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          UserAvatar(name: reply.author.username, size: 38),
          const SizedBox(width: AppTheme.sp12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        reply.author.username.isEmpty
                            ? l.postAnonymousAuthor
                            : reply.author.username,
                        style: const TextStyle(fontWeight: FontWeight.w800),
                      ),
                    ),
                    Text(
                      '#$floor',
                      style: TextStyle(
                        color: scheme.onSurfaceVariant,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  _formatPostDate(context, reply.createdAt),
                  style: TextStyle(
                    color: scheme.onSurfaceVariant,
                    fontSize: 11,
                  ),
                ),
                if (replyingTo != null) ...[
                  const SizedBox(height: AppTheme.sp8),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(AppTheme.sp8),
                    decoration: BoxDecoration(
                      color: scheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(AppTheme.radiusSm),
                    ),
                    child: Text(
                      '${l.postReplyingTo(replyingTo!.author.username)} · ${replyingTo!.body}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: scheme.onSurfaceVariant,
                        fontSize: 12,
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: AppTheme.sp12),
                SelectionArea(
                  child: Text(
                    reply.body,
                    style: const TextStyle(fontSize: 14, height: 1.65),
                  ),
                ),
                if (canReply) ...[
                  const SizedBox(height: AppTheme.sp8),
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton.icon(
                      onPressed: onReply,
                      icon: const Icon(Icons.reply_rounded, size: 16),
                      label: Text(l.postReplyAction),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ReplyComposer extends StatelessWidget {
  const _ReplyComposer({
    required this.controller,
    required this.focusNode,
    required this.replyingTo,
    required this.locked,
    required this.sending,
    required this.onCancelReply,
    required this.onSubmit,
    this.embedded = false,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final PostReply? replyingTo;
  final bool locked;
  final bool sending;
  final VoidCallback onCancelReply;
  final VoidCallback onSubmit;
  final bool embedded;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final scheme = Theme.of(context).colorScheme;
    final composer = Material(
      color: scheme.surface,
      elevation: embedded ? 0 : 8,
      shape: embedded
          ? RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppTheme.radiusMd),
              side: BorderSide(color: scheme.outlineVariant),
            )
          : null,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        child: Align(
          alignment: Alignment.topCenter,
          heightFactor: 1,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 960),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (replyingTo != null)
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          l.postReplyingTo(replyingTo!.author.username),
                          style: TextStyle(
                            color: scheme.primary,
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: l.cancel,
                        onPressed: onCancelReply,
                        icon: const Icon(Icons.close_rounded, size: 18),
                      ),
                    ],
                  ),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Expanded(
                      child: TextField(
                        key: const ValueKey('post-reply-field'),
                        controller: controller,
                        focusNode: focusNode,
                        enabled: !locked && !sending,
                        minLines: 1,
                        maxLines: 4,
                        textInputAction: TextInputAction.newline,
                        decoration: InputDecoration(
                          hintText: locked
                              ? l.postLockedNotice
                              : l.postReplyHint,
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(
                              AppTheme.radiusLg,
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: AppTheme.sp8),
                    IconButton.filled(
                      key: const ValueKey('post-reply-submit'),
                      tooltip: l.postReplyAction,
                      onPressed: locked || sending ? null : onSubmit,
                      icon: sending
                          ? const SizedBox.square(
                              dimension: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.send_rounded),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (embedded) {
      return Padding(
        padding: const EdgeInsets.only(top: AppTheme.sp8),
        child: composer,
      );
    }
    return SafeArea(child: composer);
  }
}

class _ThreadEmptyState extends StatelessWidget {
  const _ThreadEmptyState({required this.locked});

  final bool locked;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    return Container(
      padding: const EdgeInsets.all(AppTheme.sp24),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(AppTheme.radiusMd),
        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
      ),
      child: Text(
        locked ? l.postLockedNotice : l.postNoReplies,
        textAlign: TextAlign.center,
        style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
      ),
    );
  }
}

class _ReplyPagination extends StatelessWidget {
  const _ReplyPagination({
    required this.isLoading,
    required this.hasError,
    required this.onLoad,
  });

  final bool isLoading;
  final bool hasError;
  final VoidCallback onLoad;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    if (isLoading) {
      return const Padding(
        padding: EdgeInsets.all(AppTheme.sp16),
        child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: AppTheme.sp12),
      child: Center(
        child: OutlinedButton.icon(
          key: ValueKey(
            hasError ? 'post-replies-retry' : 'post-replies-load-more',
          ),
          onPressed: onLoad,
          icon: Icon(hasError ? Icons.refresh_rounded : Icons.expand_more),
          label: Text(hasError ? l.retry : l.loadMore),
        ),
      ),
    );
  }
}

class _PostTypeChip extends StatelessWidget {
  const _PostTypeChip({required this.post});

  final CampusPost post;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    return Chip(
      label: Text(switch (post.category) {
        'wanted' => l.publishCategoryWanted,
        'offer' => l.publishCategoryOffer,
        _ => l.publishCategoryDiscussion,
      }),
      visualDensity: VisualDensity.compact,
      side: BorderSide.none,
    );
  }
}

class _CountBadge extends StatelessWidget {
  const _CountBadge({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: scheme.primaryContainer,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        '$count',
        style: TextStyle(
          color: scheme.onPrimaryContainer,
          fontSize: 11,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}

String _formatPostDate(BuildContext context, DateTime? value) {
  if (value == null) return '';
  final locale = Localizations.localeOf(context).toLanguageTag();
  return DateFormat.MMMd(locale).add_Hm().format(value);
}
