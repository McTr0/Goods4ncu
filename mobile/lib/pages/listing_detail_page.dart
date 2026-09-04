import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../l10n/app_localizations.dart';
import 'package:go_router/go_router.dart';
import 'package:uuid/uuid.dart';
import '../models/models.dart';
import '../models/post.dart';
import '../services/base_service.dart';
import '../services/listing_service.dart';
import '../services/user_service.dart';
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
import '../components/wanted_response_section.dart';
import '../services/feed_feedback_service.dart';
import '../components/user_avatar.dart';
import '../utils/platform_utils.dart';
import '../services/post_service.dart';

class ListingDetailPage extends StatefulWidget {
  final String listingId;
  final ListingService? listingService;
  final UserService? userService;
  final RecommendationService? recommendationService;
  final OrderService? orderService;
  final ChatService? chatService;
  final ContentReportService? contentReportService;
  final FeedFeedbackService? feedbackService;
  final PostService? postService;

  const ListingDetailPage({
    super.key,
    required this.listingId,
    this.listingService,
    this.userService,
    this.recommendationService,
    this.orderService,
    this.chatService,
    this.contentReportService,
    this.feedbackService,
    this.postService,
  });

  @override
  State<ListingDetailPage> createState() => _ListingDetailPageState();
}

class _ListingDetailPageState extends State<ListingDetailPage> {
  late final ListingService _listingService;
  late final UserService _userService;
  late final RecommendationService _recommendationService;
  late final OrderService _orderService;
  late final ChatService _chatService;
  late final ContentReportService _contentReportService;
  late final FeedFeedbackService _feedbackService;
  PostService? _postService;
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
  List<WantedResponse> _wantedResponses = [];
  bool _wantedResponsesLoading = false;
  String? _wantedResponsesError;
  String? _wantedResponseOperatingId;
  String? _wantedResponsesRequestKey;
  int _wantedResponsesRequestSerial = 0;
  String? _wantedRecommendationFingerprint;
  String? _wantedRecommendationIdempotencyKey;
  String? _currentUserId;
  bool _currentUserLoaded = false;
  int _loadGeneration = 0;

  @override
  void initState() {
    super.initState();
    _listingService = widget.listingService ?? context.read<ListingService>();
    _userService = widget.userService ?? context.read<UserService>();
    _recommendationService =
        widget.recommendationService ?? context.read<RecommendationService>();
    _orderService = widget.orderService ?? context.read<OrderService>();
    _chatService = widget.chatService ?? context.read<ChatService>();
    _contentReportService =
        widget.contentReportService ?? context.read<ContentReportService>();
    _feedbackService =
        widget.feedbackService ?? context.read<FeedFeedbackService>();
    _postService = widget.postService ?? context.read<PostService?>();
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
      final token = await _userService.getToken();
      if (token == null || token.isEmpty) {
        if (!mounted) return;
        setState(() {
          _currentUserId = null;
          _currentUserLoaded = true;
        });
        await _loadWantedResponsesIfReady();
        return;
      }
      final profile = await _userService.getUserProfile();
      if (!mounted) return;
      setState(() {
        _currentUserId = profile['user_id']?.toString();
        _currentUserLoaded = true;
      });
      await _loadWantedResponsesIfReady();
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _currentUserId = null;
        _currentUserLoaded = true;
      });
      await _loadWantedResponsesIfReady();
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
      _wantedResponses = [];
      _wantedResponsesLoading = false;
      _wantedResponsesError = null;
      _wantedResponseOperatingId = null;
      _wantedResponsesRequestKey = null;
      _wantedResponsesRequestSerial += 1;
      _wantedRecommendationFingerprint = null;
      _wantedRecommendationIdempotencyKey = null;
      _isOperating = false;
      _reportFlowActive = false;
      _isReporting = false;
    });
    try {
      final listing = await _listingService.getListingDetail(listingId);
      if (mounted &&
          generation == _loadGeneration &&
          listingId == widget.listingId) {
        setState(() {
          _listing = listing;
          _loading = false;
        });
        if (listing.isWanted) {
          if (!listing.isRestricted && listing.status == 'active') {
            _loadWantedMatches(listingId, generation);
          } else {
            setState(() => _wantedMatchesLoading = false);
          }
          await _loadWantedResponsesIfReady();
        } else if (!listing.isRestricted && listing.status == 'active') {
          _loadSimilarListings(listingId, generation);
        } else {
          setState(() => _similarLoading = false);
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

  Future<void> _loadWantedResponsesIfReady({bool force = false}) async {
    final listing = _listing;
    final currentUserId = _currentUserId;
    if (!_currentUserLoaded ||
        currentUserId == null ||
        currentUserId.isEmpty ||
        listing == null ||
        !listing.isWanted) {
      if (mounted && _currentUserLoaded) {
        setState(() {
          _wantedResponses = [];
          _wantedResponsesLoading = false;
          _wantedResponsesError = null;
        });
      }
      return;
    }

    final generation = _loadGeneration;
    final listingId = listing.id;
    final role = listing.ownerId == currentUserId ? 'requester' : 'responder';
    final requestKey = '$generation:$listingId:$role';
    if (!force && _wantedResponsesRequestKey == requestKey) return;

    final requestSerial = ++_wantedResponsesRequestSerial;
    _wantedResponsesRequestKey = requestKey;
    setState(() {
      _wantedResponsesLoading = true;
      _wantedResponsesError = null;
    });

    try {
      final response = await _listingService.getWantedResponses(
        role: role,
        wantedListingId: listingId,
        limit: 100,
      );
      if (!mounted ||
          generation != _loadGeneration ||
          listingId != widget.listingId ||
          requestSerial != _wantedResponsesRequestSerial) {
        return;
      }
      setState(() {
        _wantedResponses = response.items;
        _wantedResponsesLoading = false;
      });
    } catch (error) {
      if (!mounted ||
          generation != _loadGeneration ||
          listingId != widget.listingId ||
          requestSerial != _wantedResponsesRequestSerial) {
        return;
      }
      setState(() {
        _wantedResponsesLoading = false;
        _wantedResponsesError = error.toString();
      });
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
      final response = await _listingService.getWantedMatches(listingId);
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
    if (_listing?.allowsAction(Listing.actionPriceDiscovery) != true) return;
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
    if (listing == null ||
        listing.ownerId == null ||
        !listing.allowsAction(Listing.actionContact)) {
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
      final profile = await _userService.getUserProfile();
      if (!mounted || !context.mounted) return;
      final currentUserId = profile['user_id']?.toString();
      if (currentUserId == listing.ownerId) {
        messenger.showSnackBar(SnackBar(content: Text(l.chatWithSelf)));
        setState(() => _isOperating = false);
        return;
      }

      setState(() => _isOperating = false);
      final conversation = await openContactConversationPage(
        context: context,
        chatService: _chatService,
        recipientId: listing.ownerId!,
        mode: ConversationMode.mail,
        listingId: listing.id,
        listingTitle: listing.title,
      );
      if (!mounted || conversation == null) return;
      router.pushNamed(
        'dm',
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
    if (listing == null || !listing.allowsAction(Listing.actionBuy)) return;

    setState(() => _isOperating = true);
    try {
      Map<String, dynamic> userProfile;
      try {
        userProfile = await _userService.getUserProfile();
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
    if (_isOperating ||
        listing == null ||
        !listing.allowsAction(Listing.actionRecommendOffer)) {
      return;
    }

    setState(() => _isOperating = true);
    try {
      final profile = await _userService.getUserProfile();
      if (!mounted) return;
      if (profile['user_id']?.toString() == listing.ownerId) {
        messenger.showSnackBar(SnackBar(content: Text(l.wantedOwnerHint)));
        return;
      }

      final myListings = await _userService.getUserListings(limit: 50);
      final rawItems = myListings['items'] as List<dynamic>? ?? [];
      final myOffers = rawItems
          .map((item) => Listing.fromJson(item as Map<String, dynamic>))
          .where(
            (item) =>
                item.isOffer && item.status == 'active' && !item.isRestricted,
          )
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

      final fingerprint = '${listing.id}\u0000${selected.id}\u0000';
      if (_wantedRecommendationFingerprint != fingerprint) {
        _wantedRecommendationFingerprint = fingerprint;
        _wantedRecommendationIdempotencyKey = const Uuid().v4();
      }
      final message = await _listingService.recommendOfferForWanted(
        wantedId: listing.id,
        offerListingId: selected.id,
        idempotencyKey: _wantedRecommendationIdempotencyKey,
      );
      if (!mounted) return;
      _wantedRecommendationFingerprint = null;
      _wantedRecommendationIdempotencyKey = null;
      messenger.showSnackBar(
        SnackBar(
          content: Text(message.isEmpty ? l.wantedRecommendSuccess : message),
          backgroundColor: AppTheme.success,
        ),
      );
      await _loadWantedResponsesIfReady(force: true);
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
          IconButton(
            key: const Key('listing-ask-assistant'),
            tooltip: l.assistantAskAboutPage,
            onPressed: () => context.push(
              '/agent?listingId=${Uri.encodeComponent(widget.listingId)}',
            ),
            icon: const Icon(Icons.auto_awesome_outlined),
          ),
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
                  _buildDiscussionSection(),
                  if (_postService != null)
                    const SizedBox(height: AppTheme.sp32),
                  _buildWantedResponseSection(l),
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
                  _buildDiscussionSection(),
                  if (_postService != null)
                    const SizedBox(height: AppTheme.sp24),
                  _buildWantedResponseSection(l),
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
        if (listing.status != 'active' || listing.isRestricted) ...[
          const SizedBox(height: AppTheme.sp8),
          Wrap(
            spacing: AppTheme.sp8,
            runSpacing: AppTheme.sp8,
            children: [
              if (listing.status != 'active')
                _ListingStateChip(
                  key: const Key('listing-lifecycle-status'),
                  label: _listingLifecycleLabel(l, listing.status),
                  color: AppTheme.textSecondary,
                ),
              if (listing.isRestricted)
                _ListingStateChip(
                  key: const Key('listing-restriction-status'),
                  label: l.listingRestrictedBadge,
                  color: AppTheme.error,
                ),
            ],
          ),
        ],
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
                  UserAvatar(name: listing.ownerUsername ?? '', size: 40),
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

  Widget _buildDiscussionSection() {
    final postService = _postService;
    if (postService == null) return const SizedBox.shrink();
    final l = AppLocalizations.of(context)!;
    final scheme = Theme.of(context).colorScheme;
    return Container(
      key: const ValueKey('listing-inline-discussion'),
      width: double.infinity,
      padding: const EdgeInsets.all(AppTheme.sp16),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(AppTheme.radiusLg),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(Icons.forum_outlined, color: scheme.primary),
              const SizedBox(width: AppTheme.sp8),
              Expanded(
                child: Text(
                  l.postTypeDiscussion,
                  style: Theme.of(
                    context,
                  ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w900),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppTheme.sp4),
          Text(
            l.listingDiscussionHint,
            style: TextStyle(
              color: scheme.onSurfaceVariant,
              fontSize: 13,
              height: 1.45,
            ),
          ),
          const SizedBox(height: AppTheme.sp16),
          FutureBuilder<CampusPost>(
            future: postService.getPostByListing(widget.listingId),
            builder: (context, snapshot) {
              if (snapshot.connectionState != ConnectionState.done) {
                return const Center(
                  child: Padding(
                    padding: EdgeInsets.all(8),
                    child: SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ),
                );
              }
              final post = snapshot.data;
              if (post == null) return const SizedBox.shrink();
              return FilledButton.icon(
                key: const ValueKey('listing-open-discussion'),
                onPressed: () =>
                    context.push('/posts/${Uri.encodeComponent(post.id)}'),
                icon: const Icon(Icons.forum_rounded),
                label: Text(l.postRepliesTitle),
              );
            },
          ),
        ],
      ),
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

  Widget _buildWantedResponseSection(AppLocalizations l) {
    final listing = _listing;
    final currentUserId = _currentUserId;
    if (listing == null ||
        !listing.isWanted ||
        !_currentUserLoaded ||
        currentUserId == null ||
        currentUserId.isEmpty) {
      return const SizedBox.shrink();
    }

    final isOwner = listing.ownerId == currentUserId;
    final wantedIsActive = listing.status == 'active' && !listing.isRestricted;
    return WantedResponseSection(
      key: ValueKey('wanted-responses-${listing.id}'),
      role: isOwner
          ? WantedResponseRole.requester
          : WantedResponseRole.responder,
      responses: _wantedResponses,
      isLoading: _wantedResponsesLoading,
      errorMessage: _wantedResponsesError == null
          ? null
          : l.wantedResponseLoadFailed,
      onRetry: () => _loadWantedResponsesIfReady(force: true),
      busyResponseIds: _wantedResponseOperatingId == null
          ? const <String>{}
          : {_wantedResponseOperatingId!},
      onOpenOffer: (response) =>
          context.push('/listing/${response.offerListingId}'),
      onAccept: isOwner && wantedIsActive
          ? (response) => _handleWantedResponseAction(response, 'accept')
          : null,
      onDismiss: isOwner && wantedIsActive
          ? (response) => _handleWantedResponseAction(response, 'dismiss')
          : null,
      onWithdraw: !isOwner && wantedIsActive
          ? (response) => _handleWantedResponseAction(response, 'withdraw')
          : null,
    );
  }

  Future<void> _handleWantedResponseAction(
    WantedResponse response,
    String action,
  ) async {
    if (_wantedResponseOperatingId != null) return;
    final l = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);
    final generation = _loadGeneration;
    final listingId = widget.listingId;
    setState(() => _wantedResponseOperatingId = response.id);
    try {
      late final WantedResponseActionResult result;
      late final String successMessage;
      switch (action) {
        case 'accept':
          result = await _listingService.acceptWantedResponse(response.id);
          successMessage = l.wantedResponseAcceptedToast;
          break;
        case 'dismiss':
          result = await _listingService.dismissWantedResponse(response.id);
          successMessage = l.wantedResponseDismissedToast;
          break;
        case 'withdraw':
          result = await _listingService.withdrawWantedResponse(response.id);
          successMessage = l.wantedResponseWithdrawnToast;
          break;
        default:
          throw ArgumentError.value(action, 'action');
      }
      if (mounted &&
          generation == _loadGeneration &&
          listingId == widget.listingId) {
        setState(() {
          _wantedResponses = _wantedResponses
              .map(
                (item) => item.id == response.id
                    ? item.copyWith(
                        status: result.status,
                        respondedAt: DateTime.now().toUtc(),
                      )
                    : item,
              )
              .toList(growable: false);
        });
        messenger.showSnackBar(
          SnackBar(
            content: Text(successMessage),
            backgroundColor: result.status == 'accepted'
                ? AppTheme.success
                : null,
          ),
        );
        await _loadWantedResponsesIfReady(force: true);
      }
    } catch (error) {
      final roundClosed =
          error is ConflictException &&
          error.serverCode == 'wanted_response_round_closed';
      if (roundClosed &&
          mounted &&
          generation == _loadGeneration &&
          listingId == widget.listingId) {
        await _refreshAfterWantedRoundClosed(
          response.id,
          generation,
          listingId,
        );
      }
      if (mounted &&
          generation == _loadGeneration &&
          listingId == widget.listingId) {
        messenger.showSnackBar(
          SnackBar(
            content: Text(
              roundClosed
                  ? l.wantedResponseRoundClosedToast
                  : l.wantedResponseActionFailed(error.toString()),
            ),
            backgroundColor: AppTheme.error,
          ),
        );
      }
    } finally {
      if (mounted && _wantedResponseOperatingId == response.id) {
        setState(() => _wantedResponseOperatingId = null);
      }
    }
  }

  Future<void> _refreshAfterWantedRoundClosed(
    String responseId,
    int generation,
    String listingId,
  ) async {
    void markResponseReadOnly() {
      if (!mounted ||
          generation != _loadGeneration ||
          listingId != widget.listingId) {
        return;
      }
      setState(() {
        _wantedResponses = _wantedResponses
            .map(
              (item) => item.id == responseId && item.isPending
                  ? item.copyWith(
                      roundState: 'closed',
                      availableActions: const <String>{},
                    )
                  : item,
            )
            .toList(growable: false);
      });
    }

    // The conflict is authoritative even if either refresh fails or a replica
    // briefly returns the older row.
    markResponseReadOnly();

    try {
      final refreshedListing = await _listingService.getListingDetail(listingId);
      if (mounted &&
          generation == _loadGeneration &&
          listingId == widget.listingId) {
        setState(() {
          _listing = refreshedListing;
          if (refreshedListing.status != 'active') {
            _wantedMatches = [];
            _wantedMatchesLoading = false;
          }
        });
      }
    } catch (_) {
      // Keep the current detail visible and still refresh the response list.
    }

    if (mounted &&
        generation == _loadGeneration &&
        listingId == widget.listingId) {
      await _loadWantedResponsesIfReady(force: true);
      markResponseReadOnly();
    }
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
    if (_isOperating || _listing == null) return;
    final listingId = _listing!.id;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l.wantedFulfillConfirmTitle),
        content: Text(l.wantedFulfillConfirmBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(l.cancel),
          ),
          FilledButton(
            key: const Key('wanted-fulfill-confirm'),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(l.confirm),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted || listingId != widget.listingId) return;
    setState(() => _isOperating = true);
    try {
      await _listingService.fulfillWanted(listingId);
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l.wantedFulfilledToast)));
      await _loadDetail();
    } catch (error) {
      await _handleListingMutationError(error);
    } finally {
      if (mounted) setState(() => _isOperating = false);
    }
  }

  Future<void> _handleReopenWanted() async {
    final l = AppLocalizations.of(context)!;
    setState(() => _isOperating = true);
    try {
      await _listingService.relistListing(_listing!.id);
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l.wantedReopenedToast)));
      await _loadDetail();
    } catch (error) {
      await _handleListingMutationError(error);
    } finally {
      if (mounted) setState(() => _isOperating = false);
    }
  }

  Future<void> _handleRelistListing() async {
    final l = AppLocalizations.of(context)!;
    if (_isOperating || _listing == null) return;
    setState(() => _isOperating = true);
    try {
      await _listingService.relistListing(_listing!.id);
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l.listingRelistedToast)));
      await _loadDetail();
    } catch (error) {
      await _handleListingMutationError(error);
    } finally {
      if (mounted) setState(() => _isOperating = false);
    }
  }

  Future<void> _handleDeleteListing() async {
    final l = AppLocalizations.of(context)!;
    final listing = _listing;
    if (_isOperating || listing == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l.deleteListingConfirmTitle),
        content: Text(l.deleteConfirm),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(l.cancel),
          ),
          FilledButton(
            key: const Key('listing-delete-confirm'),
            onPressed: () => Navigator.pop(dialogContext, true),
            style: FilledButton.styleFrom(backgroundColor: AppTheme.error),
            child: Text(l.deleteListingAction),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _isOperating = true);
    try {
      await _listingService.deleteListing(
        listing.id,
        expectedContentRevision: listing.contentRevision,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l.listingDeletedToast)));
      await _loadDetail();
    } catch (error) {
      await _handleListingMutationError(error);
    } finally {
      if (mounted) setState(() => _isOperating = false);
    }
  }

  Future<void> _handleListingMutationError(Object error) async {
    if (!mounted) return;
    final l = AppLocalizations.of(context)!;
    final conflictCode = error is ConflictException ? error.serverCode : null;
    if (conflictCode == 'listing_restricted' ||
        conflictCode == 'listing_action_stale') {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l.listingPolicyChangedToast)));
      await _loadDetail();
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(l.operationFailed(error.toString()))),
    );
  }

  Widget _buildRestrictionNotice(Listing listing, AppLocalizations l) {
    final reason = listing.restriction?.reason;
    final canOpenCase =
        listing.restriction?.canAppeal == true &&
        listing.restriction?.moderationCaseId?.isNotEmpty == true;
    return Container(
      key: const Key('listing-restriction-notice'),
      width: double.infinity,
      padding: const EdgeInsets.all(AppTheme.sp14),
      decoration: BoxDecoration(
        color: AppTheme.error.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(AppTheme.radiusMd),
        border: Border.all(color: AppTheme.error.withValues(alpha: 0.25)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.gpp_maybe_outlined, color: AppTheme.error),
              const SizedBox(width: AppTheme.sp8),
              Expanded(
                child: Text(
                  l.listingRestrictionTitle,
                  style: const TextStyle(
                    color: AppTheme.error,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppTheme.sp8),
          Text(
            reason == null || reason.isEmpty
                ? l.listingRestrictionGeneric
                : reason,
          ),
          if (canOpenCase) ...[
            const SizedBox(height: AppTheme.sp8),
            OutlinedButton.icon(
              key: const Key('listing-view-moderation-case'),
              onPressed: () => context.push('/moderation'),
              icon: const Icon(Icons.policy_outlined),
              label: Text(l.viewModerationCase),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildActionButtons() {
    final l = AppLocalizations.of(context)!;
    final listing = _listing;
    if (!_currentUserLoaded) {
      return const SizedBox.shrink();
    }
    final isOwner =
        listing?.ownerId != null && listing?.ownerId == _currentUserId;
    if (listing == null) return const SizedBox.shrink();
    if (listing.isRestricted) {
      final canDelete = isOwner && listing.allowsAction(Listing.actionDelete);
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildRestrictionNotice(listing, l),
          if (canDelete) ...[
            const SizedBox(height: AppTheme.sp8),
            OutlinedButton.icon(
              key: const Key('listing-delete-action'),
              onPressed: _isOperating ? null : _handleDeleteListing,
              icon: const Icon(Icons.delete_outline),
              label: Text(l.deleteListingAction),
              style: OutlinedButton.styleFrom(foregroundColor: AppTheme.error),
            ),
          ],
        ],
      );
    }
    if (listing.isWanted) {
      if (isOwner) {
        final canFulfill = listing.allowsAction(Listing.actionFulfill);
        final canRelist = listing.allowsAction(Listing.actionRelist);
        final canDelete = listing.allowsAction(Listing.actionDelete);
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
                      listing.status == 'fulfilled'
                          ? l.wantedFulfilledHint
                          : l.wantedOwnerHint,
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
            if (canFulfill)
              ElevatedButton.icon(
                key: const Key('listing-fulfill-action'),
                onPressed: _isOperating ? null : _handleFulfillWanted,
                icon: const Icon(Icons.task_alt),
                label: Text(l.fulfillWantedAction),
              ),
            if (canRelist)
              ElevatedButton.icon(
                key: const Key('listing-relist-action'),
                onPressed: _isOperating ? null : _handleReopenWanted,
                icon: const Icon(Icons.replay),
                label: Text(l.reopenWantedAction),
              ),
            if ((canFulfill || canRelist) && canDelete)
              const SizedBox(height: AppTheme.sp8),
            if (canDelete)
              OutlinedButton.icon(
                key: const Key('listing-delete-action'),
                onPressed: _isOperating ? null : _handleDeleteListing,
                icon: const Icon(Icons.delete_outline),
                label: Text(l.deleteListingAction),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppTheme.error,
                ),
              ),
          ],
        );
      }
      if (!listing.allowsAction(Listing.actionContact) &&
          !listing.allowsAction(Listing.actionRecommendOffer)) {
        return Container(
          width: double.infinity,
          padding: const EdgeInsets.all(AppTheme.sp14),
          decoration: BoxDecoration(
            color: Theme.of(
              context,
            ).colorScheme.surfaceContainerHighest.withValues(alpha: 0.65),
            borderRadius: BorderRadius.circular(AppTheme.radiusMd),
          ),
          child: Row(
            children: [
              Icon(
                Icons.lock_clock_outlined,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  l.wantedClosedResponderHint,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
        );
      }
      return Row(
        children: [
          Expanded(
            child: OutlinedButton.icon(
              onPressed: _isOperating
                  ? null
                  : (listing.allowsAction(Listing.actionContact)
                        ? () => _handleContactSeller(context)
                        : null),
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
              onPressed:
                  _isOperating ||
                      !listing.allowsAction(Listing.actionRecommendOffer)
                  ? null
                  : _handleRecommendMyOffer,
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
      final canDelete = listing.allowsAction(Listing.actionDelete);
      final canRelist = listing.allowsAction(Listing.actionRelist);
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (canRelist)
            ElevatedButton.icon(
              key: const Key('listing-relist-action'),
              onPressed: _isOperating ? null : _handleRelistListing,
              icon: const Icon(Icons.replay),
              label: Text(l.relistListingAction),
            ),
          if (canDelete)
            OutlinedButton.icon(
              key: const Key('listing-delete-action'),
              onPressed: _isOperating ? null : _handleDeleteListing,
              icon: const Icon(Icons.delete_outline),
              label: Text(l.deleteListingAction),
              style: OutlinedButton.styleFrom(foregroundColor: AppTheme.error),
            ),
          OutlinedButton.icon(
            onPressed: () => context.push('/my-listings'),
            icon: const Icon(Icons.edit_note_outlined),
            label: Text(l.myListings),
          ),
        ],
      );
    }
    final canContact = listing.allowsAction(Listing.actionContact);
    final canDiscover = listing.allowsAction(Listing.actionPriceDiscovery);
    final canBuy = listing.allowsAction(Listing.actionBuy);
    if (!canContact && !canDiscover && !canBuy) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(AppTheme.sp14),
        child: Text(l.wantedClosedResponderHint),
      );
    }
    final primaryAction = canBuy
        ? _ListingViewerAction.buy
        : canContact
        ? _ListingViewerAction.contact
        : _ListingViewerAction.priceDiscovery;
    final secondaryActions = <_ListingViewerAction>[
      if (canContact && primaryAction != _ListingViewerAction.contact)
        _ListingViewerAction.contact,
      if (canDiscover && primaryAction != _ListingViewerAction.priceDiscovery)
        _ListingViewerAction.priceDiscovery,
    ];
    return Row(
      children: [
        Expanded(
          child: ElevatedButton.icon(
            key: const ValueKey('listing-primary-action'),
            onPressed: _isOperating
                ? null
                : switch (primaryAction) {
                    _ListingViewerAction.buy => _handleBuyNow,
                    _ListingViewerAction.contact => () => _handleContactSeller(
                      context,
                    ),
                    _ListingViewerAction.priceDiscovery =>
                      _handlePriceDiscovery,
                  },
            icon: Icon(switch (primaryAction) {
              _ListingViewerAction.buy => Icons.handshake_outlined,
              _ListingViewerAction.contact => Icons.chat_bubble_outline,
              _ListingViewerAction.priceDiscovery => Icons.balance_outlined,
            }),
            label: Text(switch (primaryAction) {
              _ListingViewerAction.buy => l.buyNow,
              _ListingViewerAction.contact => l.contactSeller,
              _ListingViewerAction.priceDiscovery => l.priceDiscoveryStart,
            }),
            style: ElevatedButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 14),
              backgroundColor: AppTheme.primary,
              foregroundColor: Colors.white,
            ),
          ),
        ),
        if (secondaryActions.isNotEmpty) ...[
          const SizedBox(width: AppTheme.sp8),
          PopupMenuButton<_ListingViewerAction>(
            key: const ValueKey('listing-secondary-actions'),
            tooltip: MaterialLocalizations.of(context).moreButtonTooltip,
            enabled: !_isOperating,
            onSelected: (action) {
              switch (action) {
                case _ListingViewerAction.contact:
                  _handleContactSeller(context);
                case _ListingViewerAction.priceDiscovery:
                  _handlePriceDiscovery();
                case _ListingViewerAction.buy:
                  _handleBuyNow();
              }
            },
            itemBuilder: (context) => secondaryActions
                .map(
                  (action) => PopupMenuItem(
                    value: action,
                    child: ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(
                        action == _ListingViewerAction.contact
                            ? Icons.chat_bubble_outline
                            : Icons.balance_outlined,
                      ),
                      title: Text(
                        action == _ListingViewerAction.contact
                            ? l.contactSeller
                            : l.priceDiscoveryStart,
                      ),
                    ),
                  ),
                )
                .toList(growable: false),
            icon: const Icon(Icons.more_horiz_rounded),
            style: IconButton.styleFrom(
              side: BorderSide(color: Theme.of(context).dividerColor),
              minimumSize: const Size(48, 48),
            ),
          ),
        ],
      ],
    );
  }
}

enum _ListingViewerAction { buy, contact, priceDiscovery }

String _listingLifecycleLabel(AppLocalizations l, String status) =>
    switch (status) {
      'active' => l.listingLifecycleActive,
      'fulfilled' => l.listingLifecycleFulfilled,
      'sold' => l.listingLifecycleSold,
      'deleted' => l.listingLifecycleOwnerDeleted,
      _ => l.listingLifecycleUnknown,
    };

class _ListingStateChip extends StatelessWidget {
  const _ListingStateChip({
    super.key,
    required this.label,
    required this.color,
  });

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Chip(
      label: Text(label),
      backgroundColor: color.withValues(alpha: 0.12),
      side: BorderSide(color: color.withValues(alpha: 0.25)),
      labelStyle: TextStyle(color: color, fontWeight: FontWeight.w800),
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
