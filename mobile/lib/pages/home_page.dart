import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:go_router/go_router.dart';
import '../l10n/app_localizations.dart';
import '../models/models.dart';
import '../services/intent_service.dart';
import '../services/recommendation_service.dart';
import '../theme/app_theme.dart';
import '../theme/responsive.dart';
import '../components/intent_respond_dialog.dart';
import '../components/price_tag.dart';

class HomePage extends StatefulWidget {
  final RecommendationService? recommendationService;
  final IntentService? intentService;

  const HomePage({super.key, this.recommendationService, this.intentService});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  late final RecommendationService _recommendationService;
  late final IntentService _intentService;
  final _agentPromptController = TextEditingController();
  final _agentPromptFocus = FocusNode();

  // Recommendation state
  List<Listing> _recommendedListings = [];
  bool _recommendationLoading = true;
  bool _feedHasMore = true;
  bool _feedLoading = false;
  String _directionFilter = 'all';

  /// What people have actually said, loaded only when the grid comes back
  /// empty. The publish tab opens the intent composer, so most of what gets
  /// said here never becomes a listing — an empty grid is not an empty campus.
  List<UserIntent> _voices = const [];

  @override
  void initState() {
    super.initState();
    _recommendationService =
        widget.recommendationService ?? context.read<RecommendationService>();
    _intentService = widget.intentService ?? context.read<IntentService>();
    _loadRecommendations();
  }

  Future<void> _loadRecommendations({bool reset = true}) async {
    if (reset) {
      setState(() => _recommendationLoading = true);
    }
    try {
      final recommendations = await _recommendationService
          .getRecommendationFeed(
            limit: 20,
            offset: reset ? 0 : _recommendedListings.length,
            direction: _directionFilter,
          );
      if (mounted) {
        setState(() {
          if (reset) {
            _recommendedListings = recommendations;
          } else {
            _recommendedListings.addAll(recommendations);
          }
          _feedHasMore = recommendations.length == 20;
          _recommendationLoading = false;
          _feedLoading = false;
        });
      }
      if (_recommendedListings.isEmpty) await _loadVoices();
    } catch (error, stackTrace) {
      debugPrint('Failed to load recommendation feed: $error');
      debugPrintStack(stackTrace: stackTrace);
      if (mounted) {
        setState(() {
          _recommendedListings = [];
          _recommendationLoading = false;
          _feedLoading = false;
        });
      }
    }
  }

  /// A failure here costs the section, not the screen: the cold-start card is
  /// still a reasonable thing to land on.
  Future<void> _loadVoices() async {
    try {
      final voices = await _intentService.campusFeed(limit: 8);
      if (mounted) setState(() => _voices = voices);
    } catch (_) {}
  }

  Future<void> _respond(UserIntent intent) async {
    if (await respondToIntentFlow(context, _intentService, intent)) {
      await _loadVoices();
    }
  }

  @override
  void dispose() {
    _agentPromptController.dispose();
    _agentPromptFocus.dispose();
    super.dispose();
  }

  void _openAgent([String? suggestedPrompt]) {
    final prompt = (suggestedPrompt ?? _agentPromptController.text).trim();
    if (prompt.isEmpty) {
      _agentPromptFocus.requestFocus();
      return;
    }
    context.go(
      Uri(path: '/chat', queryParameters: {'prompt': prompt}).toString(),
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
            stops: [0, 0.42, 1],
          ),
        ),
        child: ResponsiveContent(maxWidth: 1320, child: _buildContent(l)),
      ),
    );
  }

  Widget _buildContent(AppLocalizations l) {
    if (_recommendationLoading && _recommendedListings.isEmpty) {
      return CustomScrollView(
        slivers: [
          SliverToBoxAdapter(
            child: _HomeHero(
              promptController: _agentPromptController,
              promptFocus: _agentPromptFocus,
              onSubmit: _openAgent,
            ),
          ),
          const SliverFillRemaining(
            hasScrollBody: false,
            child: _HomeLoadingState(),
          ),
        ],
      );
    }

    if (_recommendedListings.isEmpty) {
      return RefreshIndicator(
        onRefresh: () async {
          await _loadRecommendations(reset: true);
        },
        child: CustomScrollView(
          slivers: [
            SliverToBoxAdapter(
              child: _HomeHero(
                promptController: _agentPromptController,
                promptFocus: _agentPromptFocus,
                onSubmit: _openAgent,
              ),
            ),
            // An empty grid with people talking is not an empty campus, and
            // saying "还没有人发东西" to a community that has been posting all
            // week is the most discouraging thing this screen could do. Most
            // of what gets said never becomes a listing, because the publish
            // tab is the intent composer.
            if (_voices.isNotEmpty && _directionFilter == 'all')
              SliverToBoxAdapter(
                child: _WhatPeopleWant(voices: _voices, onRespond: _respond),
              )
            else
              SliverFillRemaining(
                hasScrollBody: false,
                // Two different situations that used to share one dead-end
                // message. On day one the place really is empty, and that is
                // normal rather than a failure — saying "暂无商品" to the first
                // thirty students frames a new community as a broken shop.
                child: _HomeEmptyState(
                  isColdStart: _directionFilter == 'all',
                  onSaySomething: () => context.push('/create'),
                ),
              ),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: () async {
        await _loadRecommendations(reset: true);
      },
      child: NotificationListener<ScrollNotification>(
        onNotification: (notification) {
          if (notification is ScrollEndNotification &&
              notification.metrics.extentAfter < 200 &&
              _feedHasMore &&
              !_feedLoading) {
            setState(() => _feedLoading = true);
            _loadRecommendations(reset: false);
          }
          return false;
        },
        child: CustomScrollView(
          slivers: [
            SliverToBoxAdapter(
              child: _HomeHero(
                promptController: _agentPromptController,
                promptFocus: _agentPromptFocus,
                onSubmit: _openAgent,
              ),
            ),
            SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.fromLTRB(
                  MediaQuery.sizeOf(context).width >= AppBreakpoints.desktop
                      ? AppTheme.sp24
                      : AppTheme.sp16,
                  AppTheme.sp20,
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
              ),
            ),
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
                  return SliverGrid(
                    gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
                      maxCrossAxisExtent: desktop ? 300 : 320,
                      childAspectRatio: desktop ? 0.76 : 0.66,
                      crossAxisSpacing: desktop ? 18 : 14,
                      mainAxisSpacing: desktop ? 18 : 14,
                    ),
                    delegate: SliverChildBuilderDelegate(
                      (context, i) {
                        if (i >= _recommendedListings.length) {
                          return const Center(
                            child: Padding(
                              padding: EdgeInsets.all(16),
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                          );
                        }
                        final listing = _recommendedListings[i];
                        return ListingCard(
                          listing: listing,
                          onTap: () => context.push('/listing/${listing.id}'),
                        );
                      },
                      childCount:
                          _recommendedListings.length + (_feedHasMore ? 1 : 0),
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

class _HomeHero extends StatelessWidget {
  final TextEditingController promptController;
  final FocusNode promptFocus;
  final ValueChanged<String> onSubmit;

  const _HomeHero({
    required this.promptController,
    required this.promptFocus,
    required this.onSubmit,
  });

  @override
  Widget build(BuildContext context) {
    final desktop = MediaQuery.sizeOf(context).width >= AppBreakpoints.desktop;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        desktop ? AppTheme.sp24 : AppTheme.sp16,
        desktop ? AppTheme.sp12 : AppTheme.sp8,
        desktop ? AppTheme.sp24 : AppTheme.sp16,
        AppTheme.sp4,
      ),
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(AppTheme.radius2xl),
          color: scheme.surface.withValues(alpha: dark ? 0.88 : 0.92),
          border: Border.all(
            color: scheme.outlineVariant.withValues(alpha: dark ? 0.64 : 0.78),
          ),
          boxShadow: [
            BoxShadow(
              color: dark
                  ? Colors.black.withValues(alpha: 0.26)
                  : const Color(0x0A0F172A),
              blurRadius: 32,
              offset: Offset(0, 16),
            ),
          ],
        ),
        child: Padding(
          padding: EdgeInsets.all(desktop ? AppTheme.sp24 : AppTheme.sp20),
          child: _AgentIntro(
            promptController: promptController,
            promptFocus: promptFocus,
            onSubmit: onSubmit,
            desktop: desktop,
          ),
        ),
      ),
    );
  }
}

class _AgentIntro extends StatelessWidget {
  final TextEditingController promptController;
  final FocusNode promptFocus;
  final ValueChanged<String> onSubmit;
  final bool desktop;

  const _AgentIntro({
    required this.promptController,
    required this.promptFocus,
    required this.onSubmit,
    this.desktop = false,
  });

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: scheme.primaryContainer.withValues(alpha: 0.55),
            borderRadius: BorderRadius.circular(AppTheme.radiusMd),
            border: Border.all(color: scheme.primary.withValues(alpha: 0.18)),
          ),
          child: Text(
            l.homeHeroEyebrow,
            style: TextStyle(
              color: scheme.onPrimaryContainer,
              fontSize: 11,
              fontWeight: FontWeight.w900,
              letterSpacing: 0.8,
            ),
          ),
        ),
        const SizedBox(height: AppTheme.sp14),
        Text(
          l.homeHeroTitle,
          style: TextStyle(
            color: scheme.onSurface,
            fontSize: desktop ? 36 : 32,
            height: 1.05,
            fontWeight: FontWeight.w900,
            letterSpacing: desktop ? -1.1 : -0.9,
          ),
        ),
        const SizedBox(height: 10),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 620),
          child: Text(
            l.homeHeroSubtitle,
            style: TextStyle(
              color: scheme.onSurfaceVariant,
              fontSize: 15,
              height: 1.55,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        const SizedBox(height: AppTheme.sp20),
        _AgentPromptBox(
          controller: promptController,
          focusNode: promptFocus,
          desktop: desktop,
          onSubmit: onSubmit,
        ),
        const SizedBox(height: AppTheme.sp12),
        _SuggestionRail(onSubmit: onSubmit, desktop: desktop),
      ],
    );
  }
}

class _AgentPromptBox extends StatelessWidget {
  final TextEditingController controller;
  final FocusNode focusNode;
  final bool desktop;
  final ValueChanged<String> onSubmit;

  const _AgentPromptBox({
    required this.controller,
    required this.focusNode,
    required this.desktop,
    required this.onSubmit,
  });

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;
    return Container(
      constraints: const BoxConstraints(maxWidth: 620),
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(
          alpha: dark ? 0.6 : 0.75,
        ),
        borderRadius: BorderRadius.circular(AppTheme.radiusXl),
        border: Border.all(color: scheme.outlineVariant),
        boxShadow: [
          BoxShadow(
            color: dark
                ? Colors.black.withValues(alpha: 0.18)
                : const Color(0x080F172A),
            blurRadius: 18,
            offset: Offset(0, 8),
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            width: 46,
            height: 46,
            decoration: BoxDecoration(
              color: scheme.primaryContainer,
              borderRadius: BorderRadius.circular(AppTheme.radiusLg),
            ),
            child: Icon(Icons.search_rounded, color: scheme.onPrimaryContainer),
          ),
          const SizedBox(width: AppTheme.sp12),
          Expanded(
            child: TextField(
              key: const ValueKey('home-agent-prompt'),
              controller: controller,
              focusNode: focusNode,
              minLines: 1,
              maxLines: desktop ? 1 : 2,
              textInputAction: TextInputAction.send,
              onSubmitted: onSubmit,
              style: TextStyle(
                color: scheme.onSurface,
                fontSize: 15,
                fontWeight: FontWeight.w700,
              ),
              decoration: InputDecoration(
                hintText: l.homePromptHint,
                hintStyle: TextStyle(
                  color: scheme.onSurfaceVariant,
                  fontWeight: FontWeight.w500,
                ),
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                filled: false,
                contentPadding: EdgeInsets.symmetric(vertical: 12),
              ),
            ),
          ),
          const SizedBox(width: AppTheme.sp8),
          IconButton.filled(
            tooltip: l.homePromptSubmitTooltip,
            onPressed: () => onSubmit(controller.text),
            icon: const Icon(Icons.arrow_forward_rounded),
            style: IconButton.styleFrom(
              backgroundColor: scheme.primary,
              foregroundColor: scheme.onPrimary,
              minimumSize: const Size(46, 46),
            ),
          ),
        ],
      ),
    );
  }
}

class _SuggestionRail extends StatelessWidget {
  final ValueChanged<String> onSubmit;
  final bool desktop;

  const _SuggestionRail({required this.onSubmit, required this.desktop});

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          l.homeSuggestionTitle,
          style: TextStyle(
            color: scheme.onSurfaceVariant.withValues(alpha: 0.84),
            fontSize: 12,
            fontWeight: FontWeight.w800,
          ),
        ),
        const SizedBox(height: AppTheme.sp8),
        Wrap(
          spacing: AppTheme.sp8,
          runSpacing: AppTheme.sp8,
          children: _agentThoughts(l)
              .map(
                (thought) => _ThoughtBubble(
                  thought: thought,
                  compact: !desktop,
                  onTap: () => onSubmit(thought.prompt),
                ),
              )
              .toList(),
        ),
      ],
    );
  }
}

class _AgentThought {
  final IconData icon;
  final String label;
  final String prompt;

  const _AgentThought({
    required this.icon,
    required this.label,
    required this.prompt,
  });
}

List<_AgentThought> _agentThoughts(AppLocalizations l) => [
  _AgentThought(
    icon: Icons.laptop_mac_rounded,
    label: l.homeThoughtLaptopLabel,
    prompt: l.homeThoughtLaptopPrompt,
  ),
  _AgentThought(
    icon: Icons.auto_graph_rounded,
    label: l.homeThoughtPriceLabel,
    prompt: l.homeThoughtPricePrompt,
  ),
  _AgentThought(
    icon: Icons.edit_note_rounded,
    label: l.homeThoughtCopyLabel,
    prompt: l.homeThoughtCopyPrompt,
  ),
  _AgentThought(
    icon: Icons.handshake_outlined,
    label: l.homeThoughtNegotiateLabel,
    prompt: l.homeThoughtNegotiatePrompt,
  ),
];

class _ThoughtBubble extends StatelessWidget {
  final _AgentThought thought;
  final VoidCallback onTap;
  final bool compact;

  const _ThoughtBubble({
    required this.thought,
    required this.onTap,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;
    return Material(
      color: compact
          ? scheme.surfaceContainerHighest.withValues(alpha: dark ? 0.55 : 0.7)
          : scheme.secondaryContainer.withValues(alpha: dark ? 0.32 : 0.5),
      borderRadius: BorderRadius.circular(AppTheme.radiusLg),
      child: InkWell(
        onTap: onTap,
        mouseCursor: SystemMouseCursors.click,
        borderRadius: BorderRadius.circular(AppTheme.radiusLg),
        child: Container(
          padding: EdgeInsets.symmetric(
            horizontal: compact ? AppTheme.sp12 : AppTheme.sp14,
            vertical: compact ? AppTheme.sp8 : AppTheme.sp12,
          ),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppTheme.radiusLg),
            border: Border.all(
              color: scheme.outlineVariant.withValues(alpha: 0.88),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                thought.icon,
                size: compact ? 16 : 18,
                color: scheme.primary,
              ),
              const SizedBox(width: AppTheme.sp8),
              Flexible(
                child: Text(
                  thought.label,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: scheme.onSurface,
                    fontSize: compact ? 12 : 13,
                    height: 1.3,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ],
          ),
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
                l.homeRecentTitle,
                style: TextStyle(
                  color: scheme.onSurface,
                  fontSize: 19,
                  fontWeight: FontWeight.w900,
                  letterSpacing: -0.35,
                ),
              ),
              const SizedBox(height: AppTheme.sp4),
              Text(
                l.homeRecentSubtitle,
                style: TextStyle(
                  color: scheme.onSurfaceVariant,
                  fontSize: 12,
                  height: 1.35,
                  fontWeight: FontWeight.w600,
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
              const EdgeInsets.symmetric(horizontal: AppTheme.sp12),
            ),
            visualDensity: VisualDensity.compact,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            textStyle: WidgetStateProperty.all(
              const TextStyle(fontSize: 12, fontWeight: FontWeight.w800),
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
        width: 42,
        height: 42,
        child: CircularProgressIndicator(strokeWidth: 3),
      ),
    );
  }
}

/// What a student sees when there is nothing to show.
///
/// This is the most important screen a cold-start community has, and it used to
/// say "暂无商品" — announcing that the place is empty, offering nothing to do,
/// and framing the product as a shop that has run out of stock. The first
/// thirty students decide from this screen whether to come back.
///
/// Two situations, deliberately distinguished. On day one the grid is empty
/// because nobody has posted, which is not a fault and has exactly one useful
/// response: be the first to say something. A filter that matched nothing is a
/// different problem and gets a different answer.
class _HomeEmptyState extends StatelessWidget {
  /// True when nothing is being filtered, so the emptiness is the community's
  /// rather than the query's.
  final bool isColdStart;
  final VoidCallback onSaySomething;

  const _HomeEmptyState({
    required this.isColdStart,
    required this.onSaySomething,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppTheme.sp24),
        child: Container(
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
                width: 76,
                height: 76,
                decoration: BoxDecoration(
                  color: scheme.secondaryContainer,
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  isColdStart
                      ? Icons.waving_hand_outlined
                      : Icons.search_off_outlined,
                  size: 38,
                  color: scheme.onSecondaryContainer,
                ),
              ),
              const SizedBox(height: AppTheme.sp16),
              if (isColdStart)
                Text(
                  AppLocalizations.of(context)!.homeColdStartTitle,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              if (isColdStart) const SizedBox(height: AppTheme.sp8),
              Text(
                isColdStart
                    ? AppLocalizations.of(context)!.homeColdStartBody
                    : AppLocalizations.of(context)!.homeFilterEmpty,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: isColdStart ? 14 : 16,
                  fontWeight: isColdStart ? FontWeight.w400 : FontWeight.w700,
                  color: scheme.onSurfaceVariant,
                ),
              ),
              // Telling someone the first voice matters and then giving them
              // nowhere to speak says nothing at all.
              if (isColdStart) ...[
                const SizedBox(height: AppTheme.sp16),
                FilledButton(
                  onPressed: onSaySomething,
                  child: Text(
                    AppLocalizations.of(context)!.homeColdStartAction,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// What people are after, shown on the screen everyone lands on.
///
/// The grid is listings, and listings are the minority of what gets said here:
/// a badminton partner, a hand moving a fridge, and anything offered without a
/// price never become one. Leaving those off the home screen meant the busiest
/// week of a new community could still open on "还没有人发东西".
class _WhatPeopleWant extends StatelessWidget {
  const _WhatPeopleWant({required this.voices, required this.onRespond});

  final List<UserIntent> voices;
  final void Function(UserIntent) onRespond;

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
                // The reply is the point. A wall of things people want with no
                // way to answer any of them is the same dead end as an empty
                // grid, dressed up as content.
                trailing: FilledButton.tonal(
                  onPressed: () => onRespond(intent),
                  child: Text(l.intentRespondAction),
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
