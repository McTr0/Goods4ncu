import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:go_router/go_router.dart';
import '../l10n/app_localizations.dart';
import '../models/models.dart';
import '../services/intent_service.dart';
import '../services/listing_service.dart';
import '../services/recommendation_service.dart';
import '../theme/app_theme.dart';
import '../theme/responsive.dart';
import '../components/intent_respond_dialog.dart';
import '../components/price_tag.dart';
import '../components/feed_feedback_menu.dart';
import '../services/feed_feedback_service.dart';
import '../models/post.dart';
import '../services/post_service.dart';
import '../components/post_discovery_card.dart';
import '../router/publish_navigation.dart';

class HomePage extends StatefulWidget {
  final RecommendationService? recommendationService;
  final ListingService? listingService;
  final IntentService? intentService;
  final FeedFeedbackService? feedbackService;
  final PostService? postService;

  const HomePage({
    super.key,
    this.recommendationService,
    this.listingService,
    this.intentService,
    this.feedbackService,
    this.postService,
  });

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  late final RecommendationService _recommendationService;
  ListingService? _listingService;
  late final IntentService _intentService;
  late final FeedFeedbackService _feedbackService;
  PostService? _postService;
  final _promptController = TextEditingController();
  final _promptFocus = FocusNode();

  // Recommendation state
  List<Listing> _recommendedListings = [];
  List<CampusPost> _posts = [];
  bool _usingPosts = false;
  bool _recommendationLoading = true;
  bool _feedHasMore = true;
  bool _feedLoading = false;
  String _directionFilter = 'all';
  String _postTypeFilter = 'all';
  String _postSort = 'for_you';
  String? _searchQuery;
  String? _loadError;
  String? _postFeedError;
  bool _postFeedRetryReset = false;
  int _feedRequestEpoch = 0;

  /// Legacy campus requests that are not represented by the listing grid.
  /// They remain a homepage fallback while the standard publish flow writes
  /// offer/wanted listings directly.
  List<UserIntent> _voices = const [];

  @override
  void initState() {
    super.initState();
    _recommendationService =
        widget.recommendationService ?? context.read<RecommendationService>();
    _listingService = _resolveListingService();
    _intentService = widget.intentService ?? context.read<IntentService>();
    _feedbackService =
        widget.feedbackService ?? context.read<FeedFeedbackService>();
    _postService = _resolvePostService();
    _loadRecommendations();
  }

  ListingService? _resolveListingService() {
    if (widget.listingService != null) return widget.listingService;
    try {
      return context.read<ListingService>();
    } catch (_) {
      return null;
    }
  }

  PostService? _resolvePostService() {
    if (widget.postService != null) return widget.postService;
    try {
      return context.read<PostService>();
    } catch (_) {
      return null;
    }
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
      final postService = _postService;
      if (postService != null) {
        try {
          final response = await postService.getPosts(
            limit: 20,
            offset: reset ? 0 : _posts.length,
            postType: switch (_postTypeFilter) {
              'offer' || 'wanted' => 'listing',
              _ => _postTypeFilter,
            },
            direction: switch (_postTypeFilter) {
              'offer' || 'wanted' => _postTypeFilter,
              _ => null,
            },
            search: _searchQuery,
            sort: _postSort,
          );
          if (!mounted || requestEpoch != _feedRequestEpoch) return;
          setState(() {
            if (reset) {
              _posts = response.items;
            } else {
              _posts = [..._posts, ...response.items];
            }
            _recommendedListings = [];
            _usingPosts = true;
            _feedHasMore = _posts.length < response.total;
            _recommendationLoading = false;
            _feedLoading = false;
            _loadError = null;
            _postFeedError = null;
            _postFeedRetryReset = false;
          });
          return;
        } catch (error) {
          if (!mounted || requestEpoch != _feedRequestEpoch) return;
          final requiresUnifiedPosts =
              _usingPosts ||
              _searchQuery != null ||
              _postTypeFilter != 'all' ||
              _postSort != 'for_you';
          if (requiresUnifiedPosts) {
            debugPrint('Unified posts feed unavailable: $error');
            setState(() {
              _usingPosts = true;
              _recommendationLoading = false;
              _feedLoading = false;
              _postFeedError = error.toString();
              _postFeedRetryReset = reset;
              if (reset && _feedIsEmpty) _loadError = error.toString();
            });
            return;
          }
          debugPrint(
            'Unified posts feed unavailable, using listing feed: $error',
          );
        }
      }
      var recommendations = await _recommendationService.getRecommendationFeed(
        limit: 20,
        offset: reset ? 0 : _recommendedListings.length,
        direction: _directionFilter,
      );
      if (!mounted || requestEpoch != _feedRequestEpoch) return;

      // Deterministic campus fallback if recommendation feed is empty
      if (recommendations.isEmpty && reset && _listingService != null) {
        final fallbackResponse = await _listingService!.getListings(
          limit: 20,
          offset: 0,
          direction: _directionFilter,
          allowAnonymousFallback: false,
        );
        if (!mounted || requestEpoch != _feedRequestEpoch) return;
        recommendations = fallbackResponse.items;
      }

      if (mounted) {
        setState(() {
          if (reset) {
            _recommendedListings = recommendations;
            _posts = [];
          } else {
            _recommendedListings.addAll(recommendations);
          }
          _usingPosts = false;
          _feedHasMore = recommendations.length == 20;
          _recommendationLoading = false;
          _feedLoading = false;
          _loadError = null;
          _postFeedError = null;
          _postFeedRetryReset = false;
        });
      }
      if (_recommendedListings.isEmpty && _posts.isEmpty) await _loadVoices();
    } catch (error, stackTrace) {
      if (!mounted || requestEpoch != _feedRequestEpoch) return;
      debugPrint('Failed to load recommendation feed: $error');
      debugPrintStack(stackTrace: stackTrace);
      if (mounted) {
        setState(() {
          _recommendationLoading = false;
          _feedLoading = false;
          _loadError = error.toString();
        });
      }
    }
  }

  Future<void> _loadVoices() async {
    try {
      final voices = await _intentService.campusFeed(limit: 8);
      if (mounted) {
        setState(
          () => _voices = voices
              .where(
                (intent) =>
                    intent.kind == IntentKind.goodsOffer ||
                    intent.kind == IntentKind.goodsSeek,
              )
              .toList(),
        );
      }
    } catch (_) {}
  }

  Future<void> _respond(UserIntent intent) async {
    if (await respondToIntentFlow(context, _intentService, intent)) {
      await _loadVoices();
    }
  }

  void _removeVoice(UserIntent intent) {
    if (!mounted) return;
    setState(() => _voices.removeWhere((item) => item.id == intent.id));
  }

  void _removeListing(Listing listing) {
    if (!mounted) return;
    setState(
      () => _recommendedListings.removeWhere((item) => item.id == listing.id),
    );
    if (_recommendedListings.isEmpty) _loadVoices();
  }

  void _removePost(CampusPost post) {
    if (!mounted) return;
    setState(() => _posts.removeWhere((item) => item.id == post.id));
  }

  void _openPost(CampusPost post) {
    final listingId = post.listingId;
    final location = post.isListing && listingId != null
        ? '/listing/${Uri.encodeComponent(listingId)}'
        : '/posts/${Uri.encodeComponent(post.id)}';
    context.push(location);
  }

  bool get _feedIsEmpty => _posts.isEmpty && _recommendedListings.isEmpty;

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
      _recommendedListings = [];
      _feedHasMore = true;
    });
    _loadRecommendations(reset: true);
  }

  void _clearSearch() {
    _promptController.clear();
    _submitSearch('');
  }

  Widget _buildDirectionSection() {
    if (_usingPosts) {
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
      child: _SectionTitle(
        selectedDirection: _directionFilter,
        onDirectionChanged: (direction) {
          if (_directionFilter == direction) return;
          setState(() {
            _directionFilter = direction;
            _recommendedListings = [];
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
            if (_voices.isNotEmpty && _directionFilter == 'all' && !_usingPosts)
              SliverToBoxAdapter(
                child: _WhatPeopleWant(
                  voices: _voices,
                  onRespond: _respond,
                  feedbackService: _feedbackService,
                  onFeedbackApplied: _removeVoice,
                ),
              )
            else if (_usingPosts)
              SliverFillRemaining(
                hasScrollBody: false,
                child: _PostEmptyState(
                  showCreateAction:
                      _postTypeFilter == 'all' ||
                      _postTypeFilter == 'discussion',
                ),
              )
            else
              SliverFillRemaining(
                hasScrollBody: false,
                child: _HomeEmptyState(
                  isColdStart: _directionFilter == 'all',
                  onOffer: () => context.push(
                    PublishNavigation.listing(direction: 'offer'),
                  ),
                  onWanted: () => context.push(
                    PublishNavigation.listing(direction: 'wanted'),
                  ),
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
            if (_usingPosts && _recommendationLoading)
              const SliverToBoxAdapter(child: LinearProgressIndicator()),
            if (_usingPosts)
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
              )
            else
              SliverPadding(
                padding: EdgeInsets.fromLTRB(
                  MediaQuery.sizeOf(context).width >= AppBreakpoints.desktop
                      ? AppTheme.sp24
                      : AppTheme.sp16,
                  AppTheme.sp4,
                  MediaQuery.sizeOf(context).width >= AppBreakpoints.desktop
                      ? AppTheme.sp24
                      : AppTheme.sp16,
                  AppTheme.sp24,
                ),
                sliver: SliverLayoutBuilder(
                  builder: (context, constraints) {
                    final desktop = constraints.crossAxisExtent >= 820;
                    final textScale = MediaQuery.textScalerOf(
                      context,
                    ).scale(1).clamp(1.0, 2.0);
                    final baseAspectRatio = desktop ? 0.76 : 0.60;
                    return SliverGrid(
                      gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
                        maxCrossAxisExtent: desktop ? 300 : 320,
                        childAspectRatio:
                            baseAspectRatio / (1 + (textScale - 1) * 0.75),
                        crossAxisSpacing: desktop ? 18 : 14,
                        mainAxisSpacing: desktop ? 18 : 14,
                      ),
                      delegate: SliverChildBuilderDelegate(
                        (context, i) {
                          if (i >= _recommendedListings.length) {
                            return const Center(
                              child: Padding(
                                padding: EdgeInsets.all(16),
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              ),
                            );
                          }
                          final listing = _recommendedListings[i];
                          return ListingCard(
                            listing: listing,
                            onTap: () => context.push('/listing/${listing.id}'),
                            feedbackMenu: FeedFeedbackMenu(
                              service: _feedbackService,
                              resourceType: FeedResourceType.listing,
                              resourceId: listing.id,
                              onApplied: (_) => _removeListing(listing),
                            ),
                          );
                        },
                        childCount:
                            _recommendedListings.length +
                            (_feedHasMore ? 1 : 0),
                      ),
                    );
                  },
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

class _SectionTitle extends StatelessWidget {
  const _SectionTitle({
    required this.selectedDirection,
    required this.onDirectionChanged,
  });

  final String selectedDirection;
  final ValueChanged<String> onDirectionChanged;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final scheme = Theme.of(context).colorScheme;
    final desktop = MediaQuery.sizeOf(context).width >= AppBreakpoints.desktop;
    return Wrap(
      spacing: AppTheme.sp12,
      runSpacing: 10,
      crossAxisAlignment: WrapCrossAlignment.center,
      alignment: desktop ? WrapAlignment.spaceBetween : WrapAlignment.start,
      children: [
        ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: desktop ? 620 : double.infinity,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                l.homeSectionTitle,
                style: TextStyle(
                  color: scheme.onSurface,
                  fontSize: 18,
                  fontWeight: FontWeight.w900,
                  letterSpacing: -0.3,
                ),
              ),
              const SizedBox(height: AppTheme.sp2),
              Text(
                l.homeSectionSubtitle,
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
        SegmentedButton<String>(
          showSelectedIcon: false,
          segments: [
            ButtonSegment(
              value: 'all',
              label: Text(l.listingDirectionAll, softWrap: false),
            ),
            ButtonSegment(
              value: 'offer',
              label: Text(l.listingDirectionOffer, softWrap: false),
            ),
            ButtonSegment(
              value: 'wanted',
              label: Text(l.listingDirectionWanted, softWrap: false),
            ),
          ],
          selected: {selectedDirection},
          onSelectionChanged: (values) => onDirectionChanged(values.first),
          style: ButtonStyle(
            padding: WidgetStateProperty.all(
              const EdgeInsets.symmetric(horizontal: AppTheme.sp14),
            ),
            visualDensity: VisualDensity.standard,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            textStyle: WidgetStateProperty.all(
              const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
            ),
          ),
        ),
      ],
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

class _HomeEmptyState extends StatelessWidget {
  final bool isColdStart;
  final VoidCallback onOffer;
  final VoidCallback onWanted;

  const _HomeEmptyState({
    required this.isColdStart,
    required this.onOffer,
    required this.onWanted,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;
    final l = AppLocalizations.of(context)!;

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppTheme.sp24),
        child: Container(
          constraints: const BoxConstraints(maxWidth: 560),
          padding: const EdgeInsets.all(AppTheme.sp24),
          decoration: BoxDecoration(
            color: scheme.surface,
            borderRadius: BorderRadius.circular(AppTheme.radius2xl),
            border: Border.all(color: scheme.outlineVariant),
            boxShadow: dark ? const [] : AppTheme.softShadow,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  color: scheme.secondaryContainer,
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  isColdStart
                      ? Icons.inventory_2_outlined
                      : Icons.search_off_outlined,
                  size: 28,
                  color: scheme.onSecondaryContainer,
                ),
              ),
              const SizedBox(height: AppTheme.sp16),
              if (isColdStart)
                Text(
                  l.homeColdStartTitle,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                    fontSize: 16,
                  ),
                ),
              if (isColdStart) const SizedBox(height: AppTheme.sp8),
              Text(
                isColdStart ? l.homeColdStartBody : l.homeFilterEmpty,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: isColdStart ? FontWeight.w400 : FontWeight.w600,
                  color: scheme.onSurfaceVariant,
                  height: 1.4,
                ),
              ),
              if (isColdStart) ...[
                const SizedBox(height: AppTheme.sp20),
                Wrap(
                  spacing: AppTheme.sp12,
                  runSpacing: AppTheme.sp8,
                  alignment: WrapAlignment.center,
                  children: [
                    FilledButton.icon(
                      style: FilledButton.styleFrom(
                        minimumSize: const Size(140, 42),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 10,
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(
                            AppTheme.radiusLg,
                          ),
                        ),
                        textStyle: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      onPressed: onOffer,
                      icon: const Icon(Icons.north_east_rounded, size: 18),
                      label: Text(l.homeActionOffer),
                    ),
                    OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size(140, 42),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 10,
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(
                            AppTheme.radiusLg,
                          ),
                        ),
                        textStyle: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      onPressed: onWanted,
                      icon: const Icon(Icons.south_west_rounded, size: 18),
                      label: Text(l.homeActionWanted),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _WhatPeopleWant extends StatelessWidget {
  const _WhatPeopleWant({
    required this.voices,
    required this.onRespond,
    required this.feedbackService,
    required this.onFeedbackApplied,
  });

  final List<UserIntent> voices;
  final void Function(UserIntent) onRespond;
  final FeedFeedbackService feedbackService;
  final void Function(UserIntent) onFeedbackApplied;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppTheme.sp16,
        AppTheme.sp8,
        AppTheme.sp16,
        AppTheme.sp24,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l.homeVoicesTitle,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: AppTheme.sp4),
          Text(
            l.homeVoicesBody,
            style: TextStyle(
              fontSize: 13,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: AppTheme.sp12),
          ...voices.map(
            (intent) => Card(
              margin: const EdgeInsets.only(bottom: AppTheme.sp8),
              child: ListTile(
                title: Text(
                  intent.rawInput,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 14),
                ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    FeedFeedbackMenu(
                      service: feedbackService,
                      resourceType: FeedResourceType.intent,
                      resourceId: intent.id,
                      compact: true,
                      onApplied: (_) => onFeedbackApplied(intent),
                    ),
                    const SizedBox(width: AppTheme.sp4),
                    FilledButton.tonal(
                      onPressed: () => onRespond(intent),
                      child: Text(l.intentRespondAction),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: AppTheme.sp8),
          Center(
            child: OutlinedButton(
              onPressed: () => context.push('/create'),
              child: Text(l.homeColdStartAction),
            ),
          ),
        ],
      ),
    );
  }
}
