import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:go_router/go_router.dart';
import '../l10n/app_localizations.dart';
import '../theme/app_theme.dart';
import '../theme/responsive.dart';
import '../components/feed_feedback_menu.dart';
import '../services/feed_feedback_service.dart';
import '../models/post.dart';
import '../services/post_service.dart';
import '../components/post_discovery_card.dart';

class HomePage extends StatefulWidget {
  final FeedFeedbackService? feedbackService;
  final PostService? postService;

  const HomePage({super.key, this.feedbackService, this.postService});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  late final FeedFeedbackService _feedbackService;
  late final PostService _postService;
  final _promptController = TextEditingController();
  final _promptFocus = FocusNode();

  List<CampusPost> _posts = [];
  bool _recommendationLoading = true;
  bool _feedHasMore = true;
  bool _feedLoading = false;
  String _postTypeFilter = 'all';
  String _postSort = 'for_you';
  String? _searchQuery;
  String? _loadError;
  String? _postFeedError;
  bool _postFeedRetryReset = false;
  int _feedRequestEpoch = 0;

  @override
  void initState() {
    super.initState();
    _feedbackService =
        widget.feedbackService ?? context.read<FeedFeedbackService>();
    _postService = widget.postService ?? context.read<PostService>();
    _loadRecommendations();
  }

  Future<void> _loadRecommendations({bool reset = true}) async {
    final requestEpoch = reset ? ++_feedRequestEpoch : _feedRequestEpoch;
    if (reset) {
      setState(() {
        _recommendationLoading = true;
        _loadError = null;
        _postFeedError = null;
        _postFeedRetryReset = false;
      });
    }
    try {
      final response = await _postService.getPosts(
        limit: 20,
        offset: reset ? 0 : _posts.length,
        // Unified posts: filter value IS the post category.
        category: _postTypeFilter,
        search: _searchQuery,
        sort: _postSort,
      );
      if (!mounted || requestEpoch != _feedRequestEpoch) return;
      setState(() {
        _posts = reset ? response.items : [..._posts, ...response.items];
        _feedHasMore = _posts.length < response.total;
        _recommendationLoading = false;
        _feedLoading = false;
        _loadError = null;
        _postFeedError = null;
        _postFeedRetryReset = false;
      });
    } catch (error, stackTrace) {
      if (!mounted || requestEpoch != _feedRequestEpoch) return;
      debugPrint('Failed to load unified post feed: $error');
      debugPrintStack(stackTrace: stackTrace);
      if (mounted) {
        setState(() {
          _recommendationLoading = false;
          _feedLoading = false;
          // Initial load failures replace the page; pagination failures keep
          // the waterfall results and offer an inline retry.
          if (reset || _posts.isEmpty) {
            _loadError = error.toString();
          } else {
            _postFeedError = error.toString();
          }
        });
      }
    }
  }

  void _removePost(CampusPost post) {
    if (!mounted) return;
    setState(() => _posts.removeWhere((item) => item.id == post.id));
  }

  void _openPost(CampusPost post) {
    final listingId = post.listingId;
    final location = post.category != 'discussion' && listingId != null
        ? '/listing/${Uri.encodeComponent(listingId)}'
        : '/posts/${Uri.encodeComponent(post.id)}';
    context.push(location);
  }

  bool get _feedIsEmpty => _posts.isEmpty;

  @override
  void dispose() {
    _promptController.dispose();
    _promptFocus.dispose();
    super.dispose();
  }

  void _submitSearch(String value) {
    final query = value.trim();
    final normalized = query.isEmpty ? null : query;
    _promptFocus.unfocus();
    if (_searchQuery == normalized) return;
    setState(() {
      _searchQuery = normalized;
      _posts = [];
      _feedHasMore = true;
    });
    _loadRecommendations(reset: true);
  }

  void _clearSearch() {
    _promptController.clear();
    _submitSearch('');
  }

  Widget _buildDirectionSection() {
    return Padding(
      padding: EdgeInsets.fromLTRB(
        MediaQuery.sizeOf(context).width >= AppBreakpoints.desktop
            ? AppTheme.sp24
            : AppTheme.sp16,
        AppTheme.sp14,
        MediaQuery.sizeOf(context).width >= AppBreakpoints.desktop
            ? AppTheme.sp24
            : AppTheme.sp16,
        AppTheme.sp8,
      ),
      child: _PostSectionTitle(
        selectedType: _postTypeFilter,
        selectedSort: _postSort,
        onTypeChanged: (value) {
          if (_postTypeFilter == value) return;
          setState(() {
            _postTypeFilter = value;
            _feedHasMore = true;
          });
          _loadRecommendations(reset: true);
        },
        onSortChanged: (value) {
          if (_postSort == value) return;
          setState(() {
            _postSort = value;
            _feedHasMore = true;
          });
          _loadRecommendations(reset: true);
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          l.appTitle,
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
      ),
      body: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: dark
                ? const [
                    AppTheme.surfaceDark,
                    Color(0xFF10211F),
                    AppTheme.surfaceDark,
                  ]
                : [AppTheme.surface, const Color(0xFFF4FBF7), scheme.surface],
            stops: const [0, 0.42, 1],
          ),
        ),
        child: ResponsiveContent(maxWidth: 1320, child: _buildContent(l)),
      ),
    );
  }

  Widget _buildContent(AppLocalizations l) {
    if (_recommendationLoading && _feedIsEmpty) {
      return CustomScrollView(
        slivers: [
          SliverToBoxAdapter(
            child: _HomeTaskHeader(
              promptController: _promptController,
              promptFocus: _promptFocus,
              onSubmit: _submitSearch,
              onClear: _clearSearch,
            ),
          ),
          const SliverFillRemaining(
            hasScrollBody: false,
            child: _HomeLoadingState(),
          ),
        ],
      );
    }

    if (_loadError != null && _feedIsEmpty) {
      return RefreshIndicator(
        onRefresh: () async => _loadRecommendations(reset: true),
        child: CustomScrollView(
          slivers: [
            SliverToBoxAdapter(
              child: _HomeTaskHeader(
                promptController: _promptController,
                promptFocus: _promptFocus,
                onSubmit: _submitSearch,
                onClear: _clearSearch,
              ),
            ),
            SliverFillRemaining(
              hasScrollBody: false,
              child: _HomeErrorState(
                onRetry: () => _loadRecommendations(reset: true),
              ),
            ),
          ],
        ),
      );
    }

    if (_feedIsEmpty) {
      return RefreshIndicator(
        onRefresh: () async => _loadRecommendations(reset: true),
        child: CustomScrollView(
          slivers: [
            SliverToBoxAdapter(
              child: _HomeTaskHeader(
                promptController: _promptController,
                promptFocus: _promptFocus,
                onSubmit: _submitSearch,
                onClear: _clearSearch,
              ),
            ),
            SliverToBoxAdapter(child: _buildDirectionSection()),
            SliverFillRemaining(
              hasScrollBody: false,
              child: _PostEmptyState(
                showCreateAction:
                    _postTypeFilter == 'all' || _postTypeFilter == 'discussion',
              ),
            ),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: () async => _loadRecommendations(reset: true),
      child: NotificationListener<ScrollNotification>(
        onNotification: (notification) {
          if (notification is ScrollEndNotification &&
              notification.metrics.extentAfter < 200 &&
              _feedHasMore &&
              !_feedLoading &&
              _postFeedError == null) {
            setState(() => _feedLoading = true);
            _loadRecommendations(reset: false);
          }
          return false;
        },
        child: CustomScrollView(
          slivers: [
            SliverToBoxAdapter(
              child: _HomeTaskHeader(
                promptController: _promptController,
                promptFocus: _promptFocus,
                onSubmit: _submitSearch,
                onClear: _clearSearch,
              ),
            ),
            SliverToBoxAdapter(child: _buildDirectionSection()),
            if (_recommendationLoading)
              const SliverToBoxAdapter(child: LinearProgressIndicator()),
            SliverToBoxAdapter(
              child: _PostMasonryGrid(
                posts: _posts,
                onTap: _openPost,
                loadingMore: _feedLoading,
                loadError: _postFeedError,
                onRetry: () {
                  final reset = _postFeedRetryReset;
                  setState(() {
                    if (!reset) _feedLoading = true;
                    _postFeedError = null;
                  });
                  _loadRecommendations(reset: reset);
                },
                feedbackMenuBuilder: (post) => FeedFeedbackMenu(
                  service: _feedbackService,
                  resourceType: FeedResourceType.post,
                  resourceId: post.id,
                  compact: true,
                  onApplied: (_) => _removePost(post),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PostMasonryGrid extends StatelessWidget {
  const _PostMasonryGrid({
    required this.posts,
    required this.onTap,
    required this.loadingMore,
    required this.loadError,
    required this.onRetry,
    required this.feedbackMenuBuilder,
  });

  final List<CampusPost> posts;
  final ValueChanged<CampusPost> onTap;
  final bool loadingMore;
  final String? loadError;
  final VoidCallback onRetry;
  final Widget Function(CampusPost post) feedbackMenuBuilder;

  @override
  Widget build(BuildContext context) {
    final desktop = MediaQuery.sizeOf(context).width >= AppBreakpoints.desktop;
    return LayoutBuilder(
      builder: (context, constraints) {
        final columnCount = constraints.maxWidth >= 1040
            ? 4
            : constraints.maxWidth >= 720
            ? 3
            : 2;
        final columns = List.generate(
          columnCount,
          (_) => <Widget>[],
          growable: false,
        );
        for (final entry in posts.indexed) {
          columns[entry.$1 % columnCount].add(
            Padding(
              padding: EdgeInsets.only(
                bottom: desktop ? AppTheme.sp16 : AppTheme.sp12,
              ),
              child: PostDiscoveryCard(
                post: entry.$2,
                onTap: () => onTap(entry.$2),
                feedbackMenu: feedbackMenuBuilder(entry.$2),
              ),
            ),
          );
        }
        return Padding(
          padding: EdgeInsets.fromLTRB(
            desktop ? AppTheme.sp24 : AppTheme.sp12,
            AppTheme.sp4,
            desktop ? AppTheme.sp24 : AppTheme.sp12,
            AppTheme.sp24,
          ),
          child: Column(
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (var i = 0; i < columns.length; i++) ...[
                    if (i > 0)
                      SizedBox(width: desktop ? AppTheme.sp16 : AppTheme.sp8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: columns[i],
                      ),
                    ),
                  ],
                ],
              ),
              if (loadingMore)
                const Padding(
                  padding: EdgeInsets.all(AppTheme.sp24),
                  child: Center(
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                )
              else if (loadError != null)
                _PostFeedRetry(onRetry: onRetry),
            ],
          ),
        );
      },
    );
  }
}

class _PostSectionTitle extends StatelessWidget {
  const _PostSectionTitle({
    required this.selectedType,
    required this.selectedSort,
    required this.onTypeChanged,
    required this.onSortChanged,
  });

  final String selectedType;
  final String selectedSort;
  final ValueChanged<String> onTypeChanged;
  final ValueChanged<String> onSortChanged;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final scheme = Theme.of(context).colorScheme;
    final sortLabel = switch (selectedSort) {
      'for_you' => l.postFilterAll,
      'active' => l.postSortActive,
      'replies' => l.postSortReplies,
      _ => l.postSortLatest,
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    l.postDiscoveryTitle,
                    style: TextStyle(
                      color: scheme.onSurface,
                      fontSize: 18,
                      fontWeight: FontWeight.w900,
                      letterSpacing: -0.3,
                    ),
                  ),
                  const SizedBox(height: AppTheme.sp2),
                  Text(
                    l.postDiscoverySubtitle,
                    style: TextStyle(
                      color: scheme.onSurfaceVariant,
                      fontSize: 12,
                      height: 1.3,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
            PopupMenuButton<String>(
              key: const ValueKey('post-sort-menu'),
              tooltip: sortLabel,
              initialValue: selectedSort,
              onSelected: onSortChanged,
              itemBuilder: (context) => [
                PopupMenuItem(value: 'for_you', child: Text(l.postFilterAll)),
                PopupMenuItem(value: 'latest', child: Text(l.postSortLatest)),
                PopupMenuItem(value: 'active', child: Text(l.postSortActive)),
                PopupMenuItem(value: 'replies', child: Text(l.postSortReplies)),
              ],
              child: Chip(
                avatar: const Icon(Icons.swap_vert_rounded, size: 17),
                label: Text(sortLabel),
                visualDensity: VisualDensity.compact,
              ),
            ),
          ],
        ),
        const SizedBox(height: AppTheme.sp12),
        Wrap(
          spacing: AppTheme.sp8,
          runSpacing: AppTheme.sp8,
          children: [
            _PostFilterChip(
              key: const ValueKey('post-filter-all'),
              label: l.listingDirectionAll,
              selected: selectedType == 'all',
              onSelected: () => onTypeChanged('all'),
            ),
            _PostFilterChip(
              key: const ValueKey('post-filter-discussion'),
              label: l.postFilterDiscussion,
              selected: selectedType == 'discussion',
              onSelected: () => onTypeChanged('discussion'),
            ),
            _PostFilterChip(
              key: const ValueKey('post-filter-offer'),
              label: l.listingDirectionOffer,
              selected: selectedType == 'offer',
              onSelected: () => onTypeChanged('offer'),
            ),
            _PostFilterChip(
              key: const ValueKey('post-filter-wanted'),
              label: l.listingDirectionWanted,
              selected: selectedType == 'wanted',
              onSelected: () => onTypeChanged('wanted'),
            ),
          ],
        ),
      ],
    );
  }
}

class _PostFilterChip extends StatelessWidget {
  const _PostFilterChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onSelected,
  });

  final String label;
  final bool selected;
  final VoidCallback onSelected;

  @override
  Widget build(BuildContext context) {
    return ChoiceChip(
      label: Text(label),
      selected: selected,
      onSelected: (_) => onSelected(),
      showCheckmark: false,
      labelStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
    );
  }
}

class _PostEmptyState extends StatelessWidget {
  const _PostEmptyState({required this.showCreateAction});

  final bool showCreateAction;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppTheme.sp24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.dynamic_feed_outlined, size: 44, color: scheme.primary),
            const SizedBox(height: AppTheme.sp12),
            Text(
              l.postEmptyTitle,
              style: const TextStyle(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: AppTheme.sp6),
            Text(
              showCreateAction ? l.postEmptyBody : l.postEmptyListingBody,
              textAlign: TextAlign.center,
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
            if (showCreateAction) ...[
              const SizedBox(height: AppTheme.sp16),
              FilledButton.icon(
                onPressed: () => context.push('/publish/discussion'),
                icon: const Icon(Icons.edit_rounded),
                label: Text(l.postStartAction),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _PostFeedRetry extends StatelessWidget {
  const _PostFeedRetry({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppTheme.sp16,
        0,
        AppTheme.sp16,
        AppTheme.sp24,
      ),
      child: Center(
        child: OutlinedButton.icon(
          key: const ValueKey('post-feed-retry'),
          onPressed: onRetry,
          icon: Icon(Icons.refresh_rounded, color: scheme.primary),
          label: Text(l.homeLoadFailedRetry),
        ),
      ),
    );
  }
}

/// Compact search bar for the unified campus post feed.
class _HomeTaskHeader extends StatelessWidget {
  final TextEditingController promptController;
  final FocusNode promptFocus;
  final ValueChanged<String> onSubmit;
  final VoidCallback onClear;

  const _HomeTaskHeader({
    required this.promptController,
    required this.promptFocus,
    required this.onSubmit,
    required this.onClear,
  });

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;
    final desktop = MediaQuery.sizeOf(context).width >= AppBreakpoints.desktop;

    return Padding(
      padding: EdgeInsets.fromLTRB(
        desktop ? AppTheme.sp24 : AppTheme.sp16,
        desktop ? AppTheme.sp12 : AppTheme.sp8,
        desktop ? AppTheme.sp24 : AppTheme.sp16,
        AppTheme.sp4,
      ),
      child: Container(
        constraints: const BoxConstraints(minHeight: 48),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest.withValues(
            alpha: dark ? 0.6 : 0.8,
          ),
          borderRadius: BorderRadius.circular(AppTheme.radiusXl),
          border: Border.all(color: scheme.outlineVariant),
        ),
        child: Row(
          children: [
            const SizedBox(width: AppTheme.sp8),
            Icon(Icons.search_rounded, color: scheme.primary, size: 20),
            const SizedBox(width: AppTheme.sp8),
            Expanded(
              child: TextField(
                key: const ValueKey('home-agent-prompt'),
                controller: promptController,
                focusNode: promptFocus,
                maxLines: 1,
                textInputAction: TextInputAction.send,
                onSubmitted: onSubmit,
                style: TextStyle(
                  color: scheme.onSurface,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
                decoration: InputDecoration(
                  hintText: l.homePromptHint,
                  hintStyle: TextStyle(
                    color: scheme.onSurfaceVariant.withValues(alpha: 0.7),
                    fontWeight: FontWeight.w500,
                    fontSize: 13,
                  ),
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  isDense: true,
                  filled: false,
                  contentPadding: const EdgeInsets.symmetric(vertical: 8),
                ),
              ),
            ),
            ValueListenableBuilder<TextEditingValue>(
              valueListenable: promptController,
              builder: (context, value, _) {
                if (value.text.isEmpty) return const SizedBox.shrink();
                return IconButton(
                  key: const ValueKey('home-search-clear'),
                  tooltip: MaterialLocalizations.of(
                    context,
                  ).deleteButtonTooltip,
                  onPressed: onClear,
                  icon: const Icon(Icons.close_rounded, size: 18),
                  visualDensity: VisualDensity.compact,
                );
              },
            ),
            const SizedBox(width: AppTheme.sp4),
            IconButton.filled(
              key: const ValueKey('home-search-submit'),
              tooltip: l.homePromptSubmitTooltip,
              onPressed: () => onSubmit(promptController.text),
              icon: const Icon(Icons.arrow_forward_rounded, size: 16),
              style: IconButton.styleFrom(
                backgroundColor: scheme.primary,
                foregroundColor: scheme.onPrimary,
                minimumSize: const Size(36, 36),
                padding: EdgeInsets.zero,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _HomeLoadingState extends StatelessWidget {
  const _HomeLoadingState();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: SizedBox(
        width: 36,
        height: 36,
        child: CircularProgressIndicator(strokeWidth: 2.5),
      ),
    );
  }
}

class _HomeErrorState extends StatelessWidget {
  final VoidCallback onRetry;

  const _HomeErrorState({required this.onRetry});

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppTheme.sp24),
        child: Container(
          constraints: const BoxConstraints(maxWidth: 480),
          padding: const EdgeInsets.all(AppTheme.sp24),
          decoration: BoxDecoration(
            color: scheme.surface,
            borderRadius: BorderRadius.circular(AppTheme.radius2xl),
            border: Border.all(color: scheme.outlineVariant),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  color: scheme.errorContainer.withValues(alpha: 0.3),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  Icons.cloud_off_rounded,
                  size: 28,
                  color: scheme.error,
                ),
              ),
              const SizedBox(height: AppTheme.sp16),
              Text(
                l.homeLoadFailed,
                textAlign: TextAlign.center,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w800,
                  fontSize: 16,
                ),
              ),
              const SizedBox(height: AppTheme.sp16),
              FilledButton.icon(
                style: FilledButton.styleFrom(
                  minimumSize: const Size(140, 42),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(AppTheme.radiusLg),
                  ),
                  textStyle: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                onPressed: onRetry,
                icon: const Icon(Icons.refresh_rounded, size: 18),
                label: Text(l.homeLoadFailedRetry),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
