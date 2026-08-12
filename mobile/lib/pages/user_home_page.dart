import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../components/contact_conversation_sheet.dart';
import '../components/content_report_dialog.dart';
import '../components/payment_qr_image.dart';
import '../components/price_tag.dart';
import '../components/social_persona_card.dart';
import '../l10n/app_localizations.dart';
import '../models/models.dart';
import '../services/chat_service.dart';
import '../services/user_service.dart';
import '../components/handoff_prompt.dart';
import '../services/reputation_service.dart';
import '../services/content_report_service.dart';
import '../theme/app_theme.dart';
import '../theme/responsive.dart';
import '../utils/platform_utils.dart';

class UserHomePage extends StatefulWidget {
  const UserHomePage({
    super.key,
    required this.userId,
    this.userService,
    this.chatService,
    this.reputationService,
    this.contentReportService,
  });

  final String userId;
  final UserService? userService;
  final ChatService? chatService;

  /// Injectable for tests, like the services above it.
  final ReputationService? reputationService;
  final ContentReportService? contentReportService;

  @override
  State<UserHomePage> createState() => _UserHomePageState();
}

class _UserHomePageState extends State<UserHomePage> {
  late final UserService _userService;
  late final ChatService _chatService;
  late final ContentReportService _contentReportService;
  Map<String, dynamic>? _profile;
  List<Listing> _listings = const [];
  SocialPersona? _persona;
  bool _loading = true;
  Reputation? _reputation;
  late final ReputationService _reputationService =
      widget.reputationService ?? context.read<ReputationService>();
  String? _currentUserId;
  bool _currentUserLoaded = false;
  bool _reportFlowActive = false;
  bool _isReporting = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _userService = widget.userService ?? context.read<UserService>();
    _chatService = widget.chatService ?? context.read<ChatService>();
    _contentReportService =
        widget.contentReportService ?? context.read<ContentReportService>();
    _load();
    _loadCurrentUserId();
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
        return;
      }
      final profile = await _userService.getUserProfile();
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

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final results = await Future.wait([
        _userService.getPublicUserProfile(widget.userId),
        _userService.getPublicUserListings(widget.userId, limit: 30),
      ]);
      if (!mounted) return;
      final listingsPayload = results[1];
      setState(() {
        _profile = results[0];
        _listings = (listingsPayload['items'] as List<dynamic>? ?? const [])
            .map((item) => Listing.fromJson(item as Map<String, dynamic>))
            .toList();
        _loading = false;
      });
      // Fetched separately and allowed to fail: a profile that will not open
      // because a reputation lookup failed is worse than a profile without one.
      try {
        final reputation = await _reputationService.of(widget.userId);
        if (mounted) setState(() => _reputation = reputation);
      } catch (_) {}
      // A published role presentation is an optional layer. Its absence or a
      // transient lookup failure must never hide the ordinary public profile.
      try {
        final persona = await _userService.getPublicSocialPersona(
          widget.userId,
        );
        if (mounted) setState(() => _persona = persona);
      } catch (_) {}
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error.toString();
        _loading = false;
      });
    }
  }

  Future<void> _contactUser() async {
    final l = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);
    try {
      final self = await _userService.getUserProfile();
      if (self['user_id']?.toString() == widget.userId) {
        messenger.showSnackBar(SnackBar(content: Text(l.chatWithSelf)));
        return;
      }
      if (!mounted) return;
      final conversation = await showContactConversationSheet(
        context: context,
        chatService: _chatService,
        recipientId: widget.userId,
        recipientName: _profile?['username']?.toString(),
      );
      if (!mounted || conversation == null) return;
      context.pushNamed(
        'user-chat',
        pathParameters: {'conversationId': conversation.id},
        extra: {
          'otherUserId': conversation.otherUserId,
          'otherUsername': conversation.otherUsername,
        },
      );
    } catch (error) {
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(content: Text(l.operationFailed(error.toString()))),
      );
    }
  }

  bool get _canReportUser =>
      _currentUserLoaded &&
      _currentUserId != null &&
      _currentUserId != widget.userId;

  Future<void> _reportUser() async {
    if (_reportFlowActive || !_canReportUser) return;
    _reportFlowActive = true;
    final l = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);
    try {
      final result = await showContentReportDialog(
        context: context,
        title: l.reportUserTitle,
      );
      if (!mounted || result == null) return;
      setState(() => _isReporting = true);
      await _contentReportService.reportUser(
        widget.userId,
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

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(
        title: Text(_profile?['username'] ?? l.publicProfile),
        actions: [
          if (_canReportUser)
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
                key: const Key('user-report-action'),
                tooltip: l.reportUserAction,
                onPressed: _reportUser,
                icon: const Icon(Icons.flag_outlined),
              ),
        ],
      ),
      body: _buildBody(l),
    );
  }

  Widget _buildBody(AppLocalizations l) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(AppTheme.sp24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.cloud_off_rounded, size: 48),
              const SizedBox(height: AppTheme.sp16),
              Text(l.publicProfileLoadFailed, textAlign: TextAlign.center),
              const SizedBox(height: AppTheme.sp8),
              Text(
                _error!,
                textAlign: TextAlign.center,
                style: const TextStyle(color: AppTheme.textSecondary),
              ),
              const SizedBox(height: AppTheme.sp16),
              FilledButton(onPressed: _load, child: Text(l.retry)),
            ],
          ),
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _load,
      child: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(AppTheme.sp16),
        child: ResponsiveContent(
          maxWidth: 1080,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _ProfileHeader(profile: _profile!, onContact: _contactUser),
              if (_persona != null) ...[
                const SizedBox(height: AppTheme.sp12),
                SocialPersonaPreviewCard(
                  persona: _persona!,
                  title: l.socialPersonaTitle,
                ),
              ],
              // Right where someone decides whether to deal with this person.
              // A record kept and never shown is bookkeeping, not trust.
              if (_reputation != null)
                Padding(
                  padding: const EdgeInsets.only(top: AppTheme.sp8),
                  child: ReputationLine(
                    completed: _reputation!.completed,
                    onTime: _reputation!.onTime,
                    hasTrackRecord: _reputation!.hasTrackRecord,
                  ),
                ),
              const SizedBox(height: AppTheme.sp16),
              _PaymentQrSection(profile: _profile!),
              const SizedBox(height: AppTheme.sp24),
              _ListingsSection(listings: _listings),
              const SizedBox(height: AppTheme.sp32),
            ],
          ),
        ),
      ),
    );
  }
}

class _ProfileHeader extends StatelessWidget {
  const _ProfileHeader({required this.profile, required this.onContact});

  final Map<String, dynamic> profile;
  final VoidCallback onContact;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final username = profile['username']?.toString() ?? l.publicProfile;
    final avatarUrl = profile['avatar_url']?.toString();
    final joinedAt = profile['joined_at']?.toString();
    final listingCount = (profile['listing_count'] as num?)?.toInt() ?? 0;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppTheme.sp20),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            CircleAvatar(
              radius: 38,
              backgroundColor: AppTheme.primary.withValues(alpha: 0.14),
              backgroundImage: avatarUrl != null && avatarUrl.isNotEmpty
                  ? NetworkImage(resolveDisplayUrl(avatarUrl))
                  : null,
              child: avatarUrl == null || avatarUrl.isEmpty
                  ? Text(
                      username.isEmpty ? '?' : username[0].toUpperCase(),
                      style: const TextStyle(
                        color: AppTheme.primary,
                        fontWeight: FontWeight.w900,
                        fontSize: 28,
                      ),
                    )
                  : null,
            ),
            const SizedBox(width: AppTheme.sp16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    username,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    [
                      if (joinedAt != null && joinedAt.isNotEmpty)
                        l.memberSince(
                          joinedAt.length >= 10
                              ? joinedAt.substring(0, 10)
                              : joinedAt,
                        ),
                      l.totalListings(listingCount),
                    ].join(' · '),
                    style: const TextStyle(color: AppTheme.textSecondary),
                  ),
                ],
              ),
            ),
            const SizedBox(width: AppTheme.sp12),
            FilledButton.icon(
              onPressed: onContact,
              icon: const Icon(Icons.chat_bubble_outline),
              label: Text(l.contactAction),
            ),
          ],
        ),
      ),
    );
  }
}

class _PaymentQrSection extends StatelessWidget {
  const _PaymentQrSection({required this.profile});

  final Map<String, dynamic> profile;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final paymentQr =
        (profile['payment_qr'] as Map?)?.cast<String, dynamic>() ??
        const <String, dynamic>{};
    final items = <_PaymentQrItem>[
      if ((paymentQr['wechat_url'] as String?)?.isNotEmpty == true)
        _PaymentQrItem(l.wechatPayQr, paymentQr['wechat_url'] as String),
      if ((paymentQr['alipay_url'] as String?)?.isNotEmpty == true)
        _PaymentQrItem(l.alipayQr, paymentQr['alipay_url'] as String),
    ];
    if (items.isEmpty) return const SizedBox.shrink();

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppTheme.sp16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l.paymentQrSectionTitle,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: AppTheme.sp6),
            Text(
              l.paymentQrSectionSubtitle,
              style: const TextStyle(
                color: AppTheme.textSecondary,
                height: 1.35,
              ),
            ),
            const SizedBox(height: AppTheme.sp12),
            Wrap(
              spacing: AppTheme.sp12,
              runSpacing: AppTheme.sp12,
              children: items
                  .map((item) => _PaymentQrPreviewCard(item: item))
                  .toList(),
            ),
            const SizedBox(height: AppTheme.sp12),
            Container(
              padding: const EdgeInsets.all(AppTheme.sp12),
              decoration: BoxDecoration(
                color: AppTheme.accent.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(AppTheme.radiusMd),
              ),
              child: Row(
                children: [
                  const Icon(Icons.info_outline, color: AppTheme.accent),
                  const SizedBox(width: AppTheme.sp8),
                  Expanded(
                    child: Text(
                      l.paymentQrPublicNotice,
                      style: const TextStyle(
                        color: AppTheme.textSecondary,
                        height: 1.35,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PaymentQrItem {
  const _PaymentQrItem(this.label, this.url);
  final String label;
  final String url;
}

class _PaymentQrPreviewCard extends StatelessWidget {
  const _PaymentQrPreviewCard({required this.item});

  final _PaymentQrItem item;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () => showDialog<void>(
        context: context,
        builder: (context) => Dialog(
          child: Padding(
            padding: const EdgeInsets.all(AppTheme.sp16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  item.label,
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: AppTheme.sp12),
                PaymentQrImage(
                  url: item.url,
                  label: item.label,
                  width: 280,
                  height: 280,
                ),
              ],
            ),
          ),
        ),
      ),
      borderRadius: BorderRadius.circular(AppTheme.radiusLg),
      child: Container(
        width: 154,
        padding: const EdgeInsets.all(AppTheme.sp12),
        decoration: BoxDecoration(
          border: Border.all(color: Theme.of(context).dividerColor),
          borderRadius: BorderRadius.circular(AppTheme.radiusLg),
        ),
        child: Column(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(AppTheme.radiusMd),
              child: PaymentQrImage(
                url: item.url,
                label: item.label,
                width: 112,
                height: 112,
                fit: BoxFit.cover,
              ),
            ),
            const SizedBox(height: AppTheme.sp8),
            Text(
              item.label,
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
          ],
        ),
      ),
    );
  }
}

class _ListingsSection extends StatelessWidget {
  const _ListingsSection({required this.listings});

  final List<Listing> listings;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          l.publicProfileListingsTitle,
          style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w900),
        ),
        const SizedBox(height: AppTheme.sp12),
        if (listings.isEmpty)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(AppTheme.sp24),
              child: Center(child: Text(l.publicProfileListingsEmpty)),
            ),
          )
        else
          LayoutBuilder(
            builder: (context, constraints) {
              final desktop = constraints.maxWidth >= AppBreakpoints.desktop;
              return GridView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: listings.length,
                gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: desktop ? 300 : 320,
                  childAspectRatio: desktop ? 0.76 : 0.66,
                  crossAxisSpacing: desktop ? 18 : 14,
                  mainAxisSpacing: desktop ? 18 : 14,
                ),
                itemBuilder: (context, index) {
                  final listing = listings[index];
                  return ListingCard(
                    listing: listing,
                    onTap: () => context.push('/listing/${listing.id}'),
                  );
                },
              );
            },
          ),
      ],
    );
  }
}
