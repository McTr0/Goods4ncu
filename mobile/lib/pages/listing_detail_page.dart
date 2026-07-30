import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../l10n/app_localizations.dart';
import 'package:go_router/go_router.dart';
import '../models/models.dart';
import '../services/api_service.dart';
import '../services/base_service.dart';
import '../services/recommendation_service.dart';
import '../services/order_service.dart';
import '../services/chat_service.dart';
import '../components/price_discovery_sheet.dart';
import '../services/price_discovery_service.dart';
import '../theme/app_theme.dart';
import '../theme/responsive.dart';
import '../components/price_tag.dart';
import '../components/recommendation_carousel.dart';
import '../components/contact_conversation_sheet.dart';
import '../components/content_report_dialog.dart';
import '../services/content_report_service.dart';
import '../components/feed_feedback_menu.dart';
import '../services/feed_feedback_service.dart';
import '../utils/platform_utils.dart';

class ListingDetailPage extends StatefulWidget {
  final String listingId;
  final ApiService? apiService;
  final RecommendationService? recommendationService;
  final OrderService? orderService;
  final ChatService? chatService;
  final ContentReportService? contentReportService;
  final FeedFeedbackService? feedbackService;

  const ListingDetailPage({
    super.key,
    required this.listingId,
    this.apiService,
    this.recommendationService,
    this.orderService,
    this.chatService,
    this.contentReportService,
    this.feedbackService,
  });

  @override
  State<ListingDetailPage> createState() => _ListingDetailPageState();
}

class _ListingDetailPageState extends State<ListingDetailPage> {
  late final ApiService _apiService;
  late final RecommendationService _recommendationService;
  late final OrderService _orderService;
  late final ChatService _chatService;
  late final ContentReportService _contentReportService;
  late final FeedFeedbackService _feedbackService;
  Listing? _listing;
  bool _loading = true;
  String? _error;
  bool _isOperating = false;
  bool _reportFlowActive = false;
  bool _isReporting = false;

  // Similar listings state
  List<Listing> _similarListings = [];
  bool _similarLoading = true;
  List<Listing> _wantedMatches = [];
  bool _wantedMatchesLoading = false;
  String? _currentUserId;
  bool _currentUserLoaded = false;
  int _loadGeneration = 0;

  @override
  void initState() {
    super.initState();
    _apiService = widget.apiService ?? context.read<ApiService>();
    _recommendationService =
        widget.recommendationService ?? context.read<RecommendationService>();
    _orderService = widget.orderService ?? context.read<OrderService>();
    _chatService = widget.chatService ?? context.read<ChatService>();
    _contentReportService =
        widget.contentReportService ?? context.read<ContentReportService>();
    _feedbackService =
        widget.feedbackService ?? context.read<FeedFeedbackService>();
    _loadDetail();
    _loadCurrentUserId();
  }

  @override
  void didUpdateWidget(covariant ListingDetailPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.listingId != widget.listingId) {
      _loadDetail();
    }
  }

  Future<void> _loadCurrentUserId() async {
    try {
      final token = await _apiService.getToken();
      if (token == null || token.isEmpty) {
        if (!mounted) return;
        setState(() {
          _currentUserId = null;
          _currentUserLoaded = true;
        });
        return;
      }
      final profile = await _apiService.getUserProfile();
      if (!mounted) return;
      setState(() {
        _currentUserId = profile['user_id']?.toString();
        _currentUserLoaded = true;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _currentUserId = null;
        _currentUserLoaded = true;
      });
    }
  }

  Future<void> _loadDetail() async {
    final listingId = widget.listingId;
    final generation = ++_loadGeneration;
    setState(() {
      _listing = null;
      _loading = true;
      _error = null;
      _similarListings = [];
      _similarLoading = true;
      _wantedMatches = [];
      _wantedMatchesLoading = false;
      _isOperating = false;
      _reportFlowActive = false;
      _isReporting = false;
    });
    try {
      final listing = await _apiService.getListingDetail(listingId);
      if (mounted &&
          generation == _loadGeneration &&
          listingId == widget.listingId) {
        setState(() {
          _listing = listing;
          _loading = false;
        });
        if (listing.isWanted) {
          _loadWantedMatches(listingId, generation);
        } else {
          _loadSimilarListings(listingId, generation);
        }
      }
    } catch (e) {
      if (mounted &&
          generation == _loadGeneration &&
          listingId == widget.listingId) {
        setState(() {
          _loading = false;
          _error = e.toString();
        });
      }
    }
  }

  Future<void> _loadSimilarListings(String listingId, int generation) async {
    setState(() => _similarLoading = true);
    try {
      final similar = await _recommendationService.getSimilarListings(
        listingId,
      );
      if (mounted &&
          generation == _loadGeneration &&
          listingId == widget.listingId) {
        setState(() {
          _similarListings = similar;
          _similarLoading = false;
        });
      }
    } catch (e) {
      if (mounted &&
          generation == _loadGeneration &&
          listingId == widget.listingId) {
        setState(() {
          _similarListings = [];
          _similarLoading = false;
        });
      }
    }
  }

  Future<void> _loadWantedMatches(String listingId, int generation) async {
    setState(() => _wantedMatchesLoading = true);
    try {
      final response = await _apiService.getWantedMatches(listingId);
      if (mounted &&
          generation == _loadGeneration &&
          listingId == widget.listingId) {
        setState(() {
          _wantedMatches = response.items;
          _wantedMatchesLoading = false;
        });
      }
    } catch (_) {
      if (mounted &&
          generation == _loadGeneration &&
          listingId == widget.listingId) {
        setState(() {
          _wantedMatches = [];
          _wantedMatchesLoading = false;
        });
      }
    }
  }

  void _removeRecommendation(Listing listing) {
    if (!mounted) return;
    setState(() {
      _similarListings.removeWhere((item) => item.id == listing.id);
      _wantedMatches.removeWhere((item) => item.id == listing.id);
    });
  }

  RecommendationFeedbackMenuBuilder? get _feedbackMenuBuilder {
    final currentUserId = _currentUserId;
    if (!_currentUserLoaded || currentUserId == null || currentUserId.isEmpty) {
      return null;
    }
    return (listing) => FeedFeedbackMenu(
      service: _feedbackService,
      resourceType: FeedResourceType.listing,
      resourceId: listing.id,
      compact: true,
      onApplied: (_) => _removeRecommendation(listing),
    );
  }

  /// Open the private-limit price sheet for this listing.
  Future<void> _handlePriceDiscovery() async {
    final id = widget.listingId;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => PriceDiscoverySheet(
        listingId: id,
        // The viewer reached this from someone else's listing, so they are the
        // buyer; the seller starts a session from the conversation instead.
        viewerIsSeller: false,
        service: context.read<PriceDiscoveryService>(),
      ),
    );
  }

  Future<void> _handleContactSeller(BuildContext context) async {
    final l = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);
    final router = GoRouter.of(context);
    if (_isOperating) return;
    final listing = _listing;
    if (listing == null || listing.ownerId == null) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(l.cannotContactSeller),
          backgroundColor: AppTheme.error,
        ),
      );
      return;
    }

    setState(() => _isOperating = true);

    try {
      final profile = await _apiService.getUserProfile();
      if (!mounted || !context.mounted) return;
      final currentUserId = profile['user_id']?.toString();
      if (currentUserId == listing.ownerId) {
        messenger.showSnackBar(SnackBar(content: Text(l.chatWithSelf)));
        setState(() => _isOperating = false);
        return;
      }

      setState(() => _isOperating = false);
      final conversation = await showContactConversationSheet(
        context: context,
        chatService: _chatService,
        recipientId: listing.ownerId!,
        listingId: listing.id,
        listingTitle: listing.title,
      );
      if (!mounted || conversation == null) return;
      router.pushNamed(
        'user-chat',
        pathParameters: {'conversationId': conversation.id},
        extra: {
          'conversationId': conversation.id,
          'otherUserId': conversation.otherUserId,
          'otherUsername': conversation.otherUsername,
        },
      );
    } catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(
          content: Text(l.operationFailed(e.toString())),
          backgroundColor: AppTheme.error,
        ),
      );
    } finally {
      if (mounted) setState(() => _isOperating = false);
    }
  }

  bool get _canReportListing {
    final listing = _listing;
    return _currentUserLoaded &&
        _currentUserId != null &&
        listing?.ownerId != null &&
        listing!.ownerId != _currentUserId;
  }

  Future<void> _handleReportListing() async {
    if (_reportFlowActive || !_canReportListing) return;
    _reportFlowActive = true;
    final l = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);
    try {
      final result = await showContentReportDialog(
        context: context,
        title: l.reportListingTitle,
      );
      if (!mounted || result == null) return;
      setState(() => _isReporting = true);
      await _contentReportService.reportListing(
        widget.listingId,
        reason: result.reason,
        details: result.details,
      );
      if (mounted) {
        messenger.showSnackBar(SnackBar(content: Text(l.reportSubmitted)));
      }
    } catch (error) {
      if (mounted) {
        messenger.showSnackBar(
          SnackBar(
            content: Text(l.reportFailed(error.toString())),
            backgroundColor: AppTheme.error,
          ),
        );
      }
    } finally {
      _reportFlowActive = false;
      if (mounted) setState(() => _isReporting = false);
    }
  }

  Future<void> _handleBuyNow() async {
    final l = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);
    final router = GoRouter.of(context);
    if (_isOperating) return;
    final listing = _listing;
    if (listing == null) return;

    setState(() => _isOperating = true);
    try {
      Map<String, dynamic> userProfile;
      try {
        userProfile = await _apiService.getUserProfile();
      } on AuthException {
        if (!mounted) return;
        messenger.showSnackBar(SnackBar(content: Text(l.sessionExpired)));
        return;
      } catch (e) {
        if (!mounted) return;
        messenger.showSnackBar(
          SnackBar(
            content: Text(l.operationFailed(e.toString())),
            backgroundColor: AppTheme.error,
          ),
        );
        return;
      }

      if (userProfile['user_id'] == listing.ownerId) {
        messenger.showSnackBar(SnackBar(content: Text(l.chatWithSelf)));
        return;
      }

      if (!mounted) return;

      final confirm = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(l.buyNow),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('${l.priceLabel}: ¥${listing.suggestedPriceCny}'),
              const SizedBox(height: 12),
              Text(
                l.platformNoEscrowShort,
                style: Theme.of(
                  ctx,
                ).textTheme.bodySmall?.copyWith(color: AppTheme.textSecondary),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(l.cancel),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(l.confirm),
            ),
          ],
        ),
      );

      if (confirm != true) return;

      final res = await _orderService.createOrder(
        listingId: listing.id,
        offeredPriceCny: listing.suggestedPriceCny,
      );
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(
          content: Text(l.purchaseSuccess),
          backgroundColor: AppTheme.success,
        ),
      );
      router.push('/orders/${res['id']}');
    } catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(
          content: Text(l.operationFailed(e.toString())),
          backgroundColor: AppTheme.error,
        ),
      );
    } finally {
      if (mounted) setState(() => _isOperating = false);
    }
  }

  Future<void> _handleRecommendMyOffer() async {
    final l = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);
    final listing = _listing;
    if (_isOperating || listing == null) return;

    setState(() => _isOperating = true);
    try {
      final profile = await _apiService.getUserProfile();
      if (!mounted) return;
      if (profile['user_id']?.toString() == listing.ownerId) {
        messenger.showSnackBar(SnackBar(content: Text(l.wantedOwnerHint)));
        return;
      }

      final myListings = await _apiService.getUserListings(limit: 50);
      final rawItems = myListings['items'] as List<dynamic>? ?? [];
      final myOffers = rawItems
          .map((item) => Listing.fromJson(item as Map<String, dynamic>))
          .where((item) => item.isOffer && item.status == 'active')
          .toList();
      if (!mounted) return;
      if (myOffers.isEmpty) {
        messenger.showSnackBar(
          SnackBar(content: Text(l.wantedNoOfferToRecommend)),
        );
        return;
      }

      final selected = await showModalBottomSheet<Listing>(
        context: context,
        showDragHandle: true,
        builder: (ctx) => SafeArea(
          child: ListView.separated(
            shrinkWrap: true,
            padding: const EdgeInsets.all(AppTheme.sp16),
            itemCount: myOffers.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (context, index) {
              final offer = myOffers[index];
              return ListTile(
                leading: CircleAvatar(
                  backgroundColor: AppTheme.primary.withValues(alpha: 0.12),
                  child: const Icon(Icons.inventory_2_outlined),
                ),
                title: Text(offer.title),
                subtitle: Text(
                  '¥${offer.suggestedPriceCny.toStringAsFixed(2)}',
                ),
                onTap: () => Navigator.pop(ctx, offer),
              );
            },
          ),
        ),
      );
      if (selected == null || !mounted) return;

      final message = await _apiService.recommendOfferForWanted(
        wantedId: listing.id,
        offerListingId: selected.id,
      );
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(
          content: Text(message.isEmpty ? l.wantedRecommendSuccess : message),
          backgroundColor: AppTheme.success,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(
          content: Text(l.operationFailed(e.toString())),
          backgroundColor: AppTheme.error,
        ),
      );
    } finally {
      if (mounted) setState(() => _isOperating = false);
    }
  }

  void _handleBack() {
    context.go('/');
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final desktop = MediaQuery.sizeOf(context).width >= AppBreakpoints.desktop;
    return Scaffold(
      appBar: AppBar(
        title: Text(_listing?.title ?? l.listingDetail),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: _handleBack,
        ),
        actions: [
          if (_canReportListing)
            if (_isReporting)
              const Padding(
                padding: EdgeInsets.all(AppTheme.sp16),
                child: SizedBox.square(
                  dimension: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              )
            else
              IconButton(
                key: const Key('listing-report-action'),
                tooltip: l.reportListingAction,
                onPressed: _handleReportListing,
                icon: const Icon(Icons.flag_outlined),
              ),
        ],
      ),
      body: _buildBody(desktop: desktop),
      bottomNavigationBar: _listing != null && !desktop
          ? _buildBottomBar()
          : null,
    );
  }

  Widget _buildBody({required bool desktop}) {
    final l = AppLocalizations.of(context)!;
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_error != null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.error_outline, size: 48, color: AppTheme.error),
            const SizedBox(height: 16),
            Text(_error!, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            ElevatedButton(onPressed: _loadDetail, child: Text(l.retry)),
          ],
        ),
      );
    }

    final listing = _listing!;
    return SingleChildScrollView(
      padding: EdgeInsets.all(desktop ? AppTheme.sp32 : AppTheme.sp16),
      child: ResponsiveContent(
        maxWidth: 1180,
        child: desktop
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        flex: 6,
                        child: _buildListingImage(listing, height: 520),
                      ),
                      const SizedBox(width: AppTheme.sp32),
                      Expanded(
                        flex: 5,
                        child: Container(
                          padding: const EdgeInsets.all(AppTheme.sp24),
                          decoration: BoxDecoration(
                            color: Theme.of(context).cardTheme.color,
                            borderRadius: BorderRadius.circular(
                              AppTheme.radiusXl,
                            ),
                            border: Border.all(
                              color: Theme.of(context).dividerColor,
                            ),
                            boxShadow: AppTheme.softShadow,
                          ),
                          child: _buildListingInformation(
                            listing,
                            l,
                            showActions: true,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: AppTheme.sp32),
                  _buildSimilarSection(l),
                  const SizedBox(height: AppTheme.sp32),
                ],
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildListingImage(listing, height: 300),
                  const SizedBox(height: AppTheme.sp20),
                  _buildListingInformation(listing, l),
                  const SizedBox(height: AppTheme.sp24),
                  _buildSimilarSection(l),
                  const SizedBox(height: 100),
                ],
              ),
      ),
    );
  }

  Widget _buildListingImage(Listing listing, {required double height}) {
    final imageUrl = listing.imageUrl == null
        ? null
        : resolveDisplayUrl(listing.imageUrl!);
    final hasImage = imageUrl != null && imageUrl.isNotEmpty;
    return Container(
      height: height,
      width: double.infinity,
      decoration: BoxDecoration(
        color: AppTheme.primary.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(AppTheme.radiusXl),
        border: Border.all(color: Theme.of(context).dividerColor),
        boxShadow: AppTheme.softShadow,
      ),
      clipBehavior: Clip.antiAlias,
      child: hasImage
          ? Image.network(
              imageUrl,
              fit: BoxFit.cover,
              errorBuilder: (context, error, stackTrace) =>
                  const _DetailImageFallback(),
              loadingBuilder: (context, child, progress) => progress == null
                  ? child
                  : const _DetailImageFallback(loading: true),
            )
          : const _DetailImageFallback(),
    );
  }

  Widget _buildListingInformation(
    Listing listing,
    AppLocalizations l, {
    bool showActions = false,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Chip(
          label: Text(
            listing.isWanted
                ? l.listingDirectionWanted
                : l.listingDirectionOffer,
          ),
          backgroundColor: listing.isWanted
              ? AppTheme.accent.withValues(alpha: 0.12)
              : AppTheme.primary.withValues(alpha: 0.12),
          side: BorderSide.none,
          labelStyle: TextStyle(
            color: listing.isWanted ? AppTheme.accent : AppTheme.primary,
            fontWeight: FontWeight.w900,
          ),
        ),
        const SizedBox(height: AppTheme.sp8),
        Text(
          listing.title,
          style: const TextStyle(
            fontSize: 24,
            fontWeight: FontWeight.w900,
            height: 1.3,
          ),
        ),
        const SizedBox(height: AppTheme.sp12),
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Flexible(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    listing.isWanted ? l.wantedBudgetShort : l.priceLabel,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  PriceTag(priceCny: listing.suggestedPriceCny, fontSize: 30),
                ],
              ),
            ),
            const SizedBox(width: 12),
            conditionBadgeFromScore(listing.conditionScore),
          ],
        ),
        const SizedBox(height: AppTheme.sp20),
        const Divider(),
        const SizedBox(height: AppTheme.sp16),
        _DetailRow(
          label: l.categoryLabel,
          value: _getCategoryDisplayName(context, listing.category),
        ),
        _DetailRow(
          label: listing.isWanted ? l.createWantedBrandLabel : l.brandLabel,
          value: listing.brand,
        ),
        _DetailRow(
          label: listing.isWanted ? l.wantedMinimumCondition : l.conditionLabel,
          value: '${listing.conditionScore}/10',
        ),
        if (listing.defects != null && listing.defects!.isNotEmpty) ...[
          const SizedBox(height: AppTheme.sp16),
          Text(
            listing.isWanted ? l.createWantedRequirementsLabel : l.defectsLabel,
            style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: listing.defects!
                .map(
                  (d) => Chip(
                    label: Text(d, style: const TextStyle(fontSize: 13)),
                    backgroundColor: AppTheme.error.withValues(alpha: 0.1),
                    labelStyle: const TextStyle(color: AppTheme.error),
                    side: BorderSide.none,
                  ),
                )
                .toList(),
          ),
        ],
        if (listing.description != null && listing.description!.isNotEmpty) ...[
          const SizedBox(height: AppTheme.sp16),
          Text(
            l.descriptionLabel,
            style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
          ),
          const SizedBox(height: 8),
          Text(
            listing.description!,
            style: const TextStyle(
              fontSize: 14,
              color: AppTheme.textSecondary,
              height: 1.6,
            ),
          ),
        ],
        if (listing.ownerUsername != null) ...[
          const SizedBox(height: AppTheme.sp20),
          const Divider(),
          const SizedBox(height: AppTheme.sp16),
          InkWell(
            onTap: listing.ownerId == null
                ? null
                : () => context.push('/users/${listing.ownerId}'),
            borderRadius: BorderRadius.circular(AppTheme.radiusMd),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: AppTheme.sp4),
              child: Row(
                children: [
                  CircleAvatar(
                    backgroundColor: AppTheme.primary.withValues(alpha: 0.15),
                    child: const Icon(Icons.person, color: AppTheme.primary),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          listing.isWanted ? l.wantedRequester : l.owner,
                          style: const TextStyle(
                            fontSize: 12,
                            color: AppTheme.textSecondary,
                          ),
                        ),
                        Text(
                          listing.ownerUsername!,
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                      ],
                    ),
                  ),
                  if (listing.ownerId != null)
                    Text(
                      l.viewPublicProfile,
                      style: const TextStyle(
                        color: AppTheme.primary,
                        fontWeight: FontWeight.w700,
                        fontSize: 12,
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
        const SizedBox(height: AppTheme.sp20),
        Container(
          padding: const EdgeInsets.all(AppTheme.sp12),
          decoration: BoxDecoration(
            color: Colors.orange.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(AppTheme.radiusSm),
            border: Border.all(color: Colors.orange.withValues(alpha: 0.3)),
          ),
          child: Row(
            children: [
              const Icon(Icons.info_outline, color: Colors.orange, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  l.infoDisclaimer,
                  style: const TextStyle(fontSize: 13, color: Colors.orange),
                ),
              ),
            ],
          ),
        ),
        if (showActions) ...[
          const SizedBox(height: AppTheme.sp24),
          _buildActionButtons(),
        ],
      ],
    );
  }

  Widget _buildSimilarSection(AppLocalizations l) {
    if (_listing?.isWanted == true) {
      if (_wantedMatchesLoading) {
        return const Center(child: CircularProgressIndicator(strokeWidth: 2));
      }
      if (_wantedMatches.isEmpty) return const SizedBox.shrink();
      return RecommendationCarousel(
        listings: _wantedMatches,
        title: l.wantedMatchesTitle,
        feedbackMenuBuilder: _feedbackMenuBuilder,
      );
    }
    if (_similarLoading) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }
    if (_similarListings.isEmpty) return const SizedBox.shrink();
    return RecommendationCarousel(
      listings: _similarListings,
      title: l.similarRecommendations,
      feedbackMenuBuilder: _feedbackMenuBuilder,
    );
  }

  String _getCategoryDisplayName(BuildContext context, String key) {
    final l = AppLocalizations.of(context)!;
    switch (key) {
      case 'electronics':
        return l.electronics;
      case 'books':
        return l.books;
      case 'digitalAccessories':
        return l.digitalAccessories;
      case 'dailyGoods':
        return l.dailyGoods;
      case 'clothingShoes':
        return l.clothingShoes;
      case 'other':
        return l.other;
      default:
        return key;
    }
  }

  Widget _buildBottomBar() {
    return Container(
      padding: const EdgeInsets.all(AppTheme.sp16),
      decoration: BoxDecoration(
        color: Theme.of(context).cardTheme.color,
        border: Border(top: BorderSide(color: Theme.of(context).dividerColor)),
      ),
      child: SafeArea(child: _buildActionButtons()),
    );
  }

  Future<void> _handleFulfillWanted() async {
    final l = AppLocalizations.of(context)!;
    setState(() => _isOperating = true);
    try {
      await _apiService.fulfillWanted(_listing!.id);
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l.wantedFulfilledToast)));
      await _loadDetail();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l.operationFailed(e.toString()))));
    } finally {
      if (mounted) setState(() => _isOperating = false);
    }
  }

  Future<void> _handleReopenWanted() async {
    final l = AppLocalizations.of(context)!;
    setState(() => _isOperating = true);
    try {
      await _apiService.relistListing(_listing!.id);
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l.wantedReopenedToast)));
      await _loadDetail();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l.operationFailed(e.toString()))));
    } finally {
      if (mounted) setState(() => _isOperating = false);
    }
  }

  Widget _buildActionButtons() {
    final l = AppLocalizations.of(context)!;
    final listing = _listing;
    if (!_currentUserLoaded) {
      return const SizedBox.shrink();
    }
    final isOwner =
        listing?.ownerId != null && listing?.ownerId == _currentUserId;
    if (listing?.isWanted == true) {
      if (isOwner) {
        final isFulfilled = listing?.status == 'fulfilled';
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(AppTheme.sp14),
              decoration: BoxDecoration(
                color: AppTheme.primary.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(AppTheme.radiusMd),
                border: Border.all(
                  color: AppTheme.primary.withValues(alpha: 0.2),
                ),
              ),
              child: Row(
                children: [
                  const Icon(
                    Icons.check_circle_outline,
                    color: AppTheme.primary,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      isFulfilled ? l.wantedFulfilledHint : l.wantedOwnerHint,
                      style: const TextStyle(
                        color: AppTheme.primary,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 10),
            ElevatedButton.icon(
              onPressed: _isOperating
                  ? null
                  : (isFulfilled ? _handleReopenWanted : _handleFulfillWanted),
              icon: Icon(isFulfilled ? Icons.replay : Icons.task_alt),
              label: Text(
                isFulfilled ? l.reopenWantedAction : l.fulfillWantedAction,
              ),
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 14),
                backgroundColor: AppTheme.primary,
                foregroundColor: Colors.white,
              ),
            ),
          ],
        );
      }
      return Row(
        children: [
          Expanded(
            child: OutlinedButton.icon(
              onPressed: _isOperating
                  ? null
                  : () => _handleContactSeller(context),
              icon: const Icon(Icons.chat_bubble_outline),
              label: Text(l.contactRequester),
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: ElevatedButton.icon(
              onPressed: _isOperating ? null : _handleRecommendMyOffer,
              icon: const Icon(Icons.inventory_2_outlined),
              label: Text(l.recommendMyOffer),
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 14),
                backgroundColor: AppTheme.primary,
                foregroundColor: Colors.white,
              ),
            ),
          ),
        ],
      );
    }
    if (isOwner) {
      return SizedBox(
        width: double.infinity,
        child: ElevatedButton.icon(
          onPressed: () => context.push('/my-listings'),
          icon: const Icon(Icons.edit_note_outlined),
          label: Text(l.myListings),
          style: ElevatedButton.styleFrom(
            padding: const EdgeInsets.symmetric(vertical: 14),
            backgroundColor: AppTheme.primary,
            foregroundColor: Colors.white,
          ),
        ),
      );
    }
    final isSold = _listing?.status == 'sold';
    return Row(
      children: [
        Expanded(
          child: OutlinedButton.icon(
            onPressed: _isOperating
                ? null
                : () => _handleContactSeller(context),
            icon: const Icon(Icons.chat_bubble_outline),
            label: Text(l.contactSeller),
            style: OutlinedButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 14),
            ),
          ),
        ),
        const SizedBox(width: 12),
        // Offered beside haggling rather than instead of it: both sides have to
        // choose this mechanism, and someone who would rather talk keeps that.
        Expanded(
          child: OutlinedButton.icon(
            onPressed: (isSold || _isOperating) ? null : _handlePriceDiscovery,
            icon: const Icon(Icons.balance_outlined),
            label: Text(l.priceDiscoveryStart, softWrap: false),
            style: OutlinedButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 14),
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: ElevatedButton.icon(
            onPressed: (isSold || _isOperating) ? null : _handleBuyNow,
            icon: Icon(isSold ? Icons.done : Icons.handshake_outlined),
            label: Text(isSold ? l.sold : l.buyNow),
            style: ElevatedButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 14),
              backgroundColor: isSold ? Colors.grey : AppTheme.primary,
              foregroundColor: Colors.white,
            ),
          ),
        ),
      ],
    );
  }
}

class _DetailImageFallback extends StatelessWidget {
  final bool loading;

  const _DetailImageFallback({this.loading = false});

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [AppTheme.mint, AppTheme.sand, AppTheme.accentSoft],
        ),
      ),
      child: Center(
        child: loading
            ? const CircularProgressIndicator(strokeWidth: 3)
            : Icon(
                Icons.inventory_2_outlined,
                size: 88,
                color: AppTheme.primary.withValues(alpha: 0.35),
              ),
      ),
    );
  }
}

class _DetailRow extends StatelessWidget {
  final String label;
  final String value;

  const _DetailRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 80,
            child: Text(
              label,
              style: const TextStyle(
                color: AppTheme.textSecondary,
                fontSize: 14,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
            ),
          ),
        ],
      ),
    );
  }
}
