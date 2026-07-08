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
import '../theme/app_theme.dart';
import '../theme/responsive.dart';
import '../components/price_tag.dart';
import '../components/recommendation_carousel.dart';
import '../components/contact_conversation_sheet.dart';
import '../utils/platform_utils.dart';

class ListingDetailPage extends StatefulWidget {
  final String listingId;
  final ApiService? apiService;
  final RecommendationService? recommendationService;
  final OrderService? orderService;
  final ChatService? chatService;

  const ListingDetailPage({
    super.key,
    required this.listingId,
    this.apiService,
    this.recommendationService,
    this.orderService,
    this.chatService,
  });

  @override
  State<ListingDetailPage> createState() => _ListingDetailPageState();
}

class _ListingDetailPageState extends State<ListingDetailPage> {
  late final ApiService _apiService;
  late final RecommendationService _recommendationService;
  late final OrderService _orderService;
  late final ChatService _chatService;
  Listing? _listing;
  bool _loading = true;
  String? _error;
  bool _isOperating = false;

  // Similar listings state
  List<Listing> _similarListings = [];
  bool _similarLoading = true;

  @override
  void initState() {
    super.initState();
    _apiService = widget.apiService ?? context.read<ApiService>();
    _recommendationService =
        widget.recommendationService ?? context.read<RecommendationService>();
    _orderService = widget.orderService ?? context.read<OrderService>();
    _chatService = widget.chatService ?? context.read<ChatService>();
    _loadDetail();
  }

  Future<void> _loadDetail() async {
    setState(() => _loading = true);
    try {
      final listing = await _apiService.getListingDetail(widget.listingId);
      if (mounted) {
        setState(() {
          _listing = listing;
          _loading = false;
        });
        _loadSimilarListings();
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = e.toString();
        });
      }
    }
  }

  Future<void> _loadSimilarListings() async {
    setState(() => _similarLoading = true);
    try {
      final similar = await _recommendationService.getSimilarListings(
        widget.listingId,
      );
      if (mounted) {
        setState(() {
          _similarListings = similar;
          _similarLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _similarListings = [];
          _similarLoading = false;
        });
      }
    }
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

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final desktop = MediaQuery.sizeOf(context).width >= AppBreakpoints.desktop;
    return Scaffold(
      appBar: AppBar(
        title: Text(_listing?.title ?? l.listingDetail),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.pop(),
        ),
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
              child: PriceTag(
                priceCny: listing.suggestedPriceCny,
                fontSize: 30,
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
        _DetailRow(label: l.brandLabel, value: listing.brand),
        _DetailRow(
          label: l.conditionLabel,
          value: '${listing.conditionScore}/10',
        ),
        if (listing.defects != null && listing.defects!.isNotEmpty) ...[
          const SizedBox(height: AppTheme.sp16),
          Text(
            l.defectsLabel,
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
                          l.owner,
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
    if (_similarLoading) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }
    if (_similarListings.isEmpty) return const SizedBox.shrink();
    return RecommendationCarousel(
      listings: _similarListings,
      title: l.similarRecommendations,
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

  Widget _buildActionButtons() {
    final l = AppLocalizations.of(context)!;
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
