import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../services/api_service.dart';
import '../theme/app_theme.dart';
import '../theme/responsive.dart';

class ModerationCasesPage extends StatefulWidget {
  const ModerationCasesPage({super.key, this.apiService});

  final ApiService? apiService;

  @override
  State<ModerationCasesPage> createState() => _ModerationCasesPageState();
}

class _ModerationCasesPageState extends State<ModerationCasesPage> {
  late final ApiService _apiService;
  List<Map<String, dynamic>> _cases = const [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _apiService = widget.apiService ?? context.read<ApiService>();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final response = await _apiService.getModerationCases(limit: 50);
      if (!mounted) return;
      setState(() {
        _cases = (response['items'] as List<dynamic>? ?? const [])
            .whereType<Map<String, dynamic>>()
            .toList();
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error.toString();
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(title: Text(l.moderationCenter)),
      body: ResponsiveContent(maxWidth: 840, child: _buildBody(context)),
    );
  }

  Widget _buildBody(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(AppTheme.sp24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, size: 44, color: AppTheme.error),
              const SizedBox(height: AppTheme.sp12),
              Text('${l.error}: $_error', textAlign: TextAlign.center),
              const SizedBox(height: AppTheme.sp16),
              FilledButton.icon(
                onPressed: _load,
                icon: const Icon(Icons.refresh),
                label: Text(l.retry),
              ),
            ],
          ),
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _load,
      child: _cases.isEmpty
          ? ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.all(AppTheme.sp24),
              children: [
                const SizedBox(height: 120),
                Icon(
                  Icons.verified_user_outlined,
                  size: 64,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(height: AppTheme.sp16),
                Text(
                  l.moderationNoCases,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            )
          : ListView.separated(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.all(AppTheme.sp16),
              itemCount: _cases.length,
              separatorBuilder: (_, _) => const SizedBox(height: AppTheme.sp12),
              itemBuilder: (context, index) => _CaseCard(
                moderationCase: _cases[index],
                onTap: () => _showCase(_cases[index]),
              ),
            ),
    );
  }

  Future<void> _showCase(Map<String, dynamic> moderationCase) async {
    final l = AppLocalizations.of(context)!;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(
            AppTheme.sp20,
            0,
            AppTheme.sp20,
            AppTheme.sp24 + MediaQuery.viewInsetsOf(sheetContext).bottom,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                l.moderationCase,
                style: Theme.of(sheetContext).textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: AppTheme.sp12),
              _StatusPill(status: moderationCase['status']?.toString()),
              const SizedBox(height: AppTheme.sp20),
              _DetailLine(
                label: l.moderationResource,
                value:
                    '${_resourceLabel(l, moderationCase['resource_type']?.toString())} · ${_shortId(moderationCase['resource_id'])}',
              ),
              _DetailLine(
                label: l.moderationReason,
                value: moderationCase['public_reason']?.toString() ?? '-',
              ),
              _DetailLine(
                label: l.moderationCreatedAt,
                value: _formatTime(moderationCase['created_at']),
              ),
              if (moderationCase['resolution'] != null)
                _DetailLine(
                  label: l.moderationResolution,
                  value: _resolutionLabel(
                    l,
                    moderationCase['resolution']?.toString(),
                  ),
                ),
              const SizedBox(height: AppTheme.sp16),
              if (moderationCase['pending_appeal'] == true)
                _NoticeBanner(
                  icon: Icons.schedule,
                  text: l.moderationPendingAppeal,
                )
              else if (moderationCase['can_appeal'] == true)
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: () async {
                      Navigator.pop(sheetContext);
                      await _submitAppeal(moderationCase);
                    },
                    icon: const Icon(Icons.rate_review_outlined),
                    label: Text(l.moderationAppeal),
                  ),
                )
              else
                _NoticeBanner(
                  icon: Icons.info_outline,
                  text: l.moderationCannotAppeal,
                ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _submitAppeal(Map<String, dynamic> moderationCase) async {
    final l = AppLocalizations.of(context)!;
    final controller = TextEditingController();
    final reason = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l.moderationAppeal),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l.moderationAppealHint),
            const SizedBox(height: AppTheme.sp12),
            TextField(
              controller: controller,
              minLines: 4,
              maxLines: 7,
              maxLength: 2000,
              autofocus: true,
              decoration: InputDecoration(labelText: l.moderationAppeal),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(l.cancel),
          ),
          FilledButton(
            onPressed: () {
              final value = controller.text.trim();
              if (value.characters.length < 10) return;
              Navigator.pop(dialogContext, value);
            },
            child: Text(l.submit),
          ),
        ],
      ),
    );
    controller.dispose();
    if (reason == null || !mounted) return;

    try {
      await _apiService.submitModerationAppeal(
        moderationCase['id'].toString(),
        reason,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l.moderationAppealSubmitted)));
      await _load();
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('${l.error}: $error')));
    }
  }
}

class _CaseCard extends StatelessWidget {
  const _CaseCard({required this.moderationCase, required this.onTap});

  final Map<String, dynamic> moderationCase;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(AppTheme.sp16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 46,
                height: 46,
                decoration: BoxDecoration(
                  color: _statusColor(
                    moderationCase['status']?.toString(),
                  ).withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(AppTheme.radiusMd),
                ),
                child: Icon(
                  _resourceIcon(moderationCase['resource_type']?.toString()),
                  color: _statusColor(moderationCase['status']?.toString()),
                ),
              ),
              const SizedBox(width: AppTheme.sp14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            _resourceLabel(
                              l,
                              moderationCase['resource_type']?.toString(),
                            ),
                            style: const TextStyle(fontWeight: FontWeight.w800),
                          ),
                        ),
                        _StatusPill(
                          status: moderationCase['status']?.toString(),
                        ),
                      ],
                    ),
                    const SizedBox(height: AppTheme.sp8),
                    Text(
                      moderationCase['public_reason']?.toString() ?? '-',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: AppTheme.sp8),
                    Text(
                      _formatTime(moderationCase['created_at']),
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
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

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.status});

  final String? status;

  @override
  Widget build(BuildContext context) {
    final color = _statusColor(status);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.13),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        _statusLabel(AppLocalizations.of(context)!, status),
        style: TextStyle(
          color: color,
          fontSize: 12,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}

class _DetailLine extends StatelessWidget {
  const _DetailLine({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppTheme.sp8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: AppTheme.sp4),
          Text(value),
        ],
      ),
    );
  }
}

class _NoticeBanner extends StatelessWidget {
  const _NoticeBanner({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppTheme.sp14),
      decoration: BoxDecoration(
        color: scheme.secondaryContainer.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(AppTheme.radiusMd),
      ),
      child: Row(
        children: [
          Icon(icon, color: scheme.onSecondaryContainer),
          const SizedBox(width: AppTheme.sp8),
          Expanded(
            child: Text(
              text,
              style: TextStyle(color: scheme.onSecondaryContainer),
            ),
          ),
        ],
      ),
    );
  }
}

String _statusLabel(AppLocalizations l, String? status) => switch (status) {
  'open' => l.moderationStatusOpen,
  'reviewing' => l.moderationStatusReviewing,
  'actioned' => l.moderationStatusActioned,
  'dismissed' => l.moderationStatusDismissed,
  'appealed' => l.moderationStatusAppealed,
  'resolved' => l.moderationStatusResolved,
  _ => status ?? l.unknown,
};

Color _statusColor(String? status) => switch (status) {
  'open' => AppTheme.warning,
  'reviewing' => AppTheme.info,
  'actioned' => AppTheme.error,
  'dismissed' => AppTheme.success,
  'appealed' => AppTheme.accent,
  'resolved' => AppTheme.primary,
  _ => AppTheme.textSecondary,
};

String _resourceLabel(AppLocalizations l, String? type) => switch (type) {
  'listing_image' => l.listingImage,
  'chat_image' => l.imageMessage,
  'chat_message' => l.messagesTab,
  'avatar' => l.avatar,
  _ => type ?? l.unknown,
};

IconData _resourceIcon(String? type) => switch (type) {
  'listing_image' => Icons.inventory_2_outlined,
  'chat_image' => Icons.image_outlined,
  'chat_message' => Icons.chat_bubble_outline,
  'avatar' => Icons.account_circle_outlined,
  _ => Icons.policy_outlined,
};

String _resolutionLabel(AppLocalizations l, String? resolution) =>
    switch (resolution) {
      'content_restricted' => l.moderationStatusActioned,
      'no_violation' => l.moderationStatusDismissed,
      'restored' => l.moderationRestore,
      'warning' => l.warning,
      'account_action' => l.adminBan,
      _ => resolution ?? l.unknown,
    };

String _shortId(Object? value) {
  final text = value?.toString() ?? '-';
  return text.length <= 12 ? text : '${text.substring(0, 8)}…';
}

String _formatTime(Object? value) {
  final text = value?.toString();
  if (text == null) return '-';
  final parsed = DateTime.tryParse(text)?.toLocal();
  if (parsed == null) return text;
  String two(int value) => value.toString().padLeft(2, '0');
  return '${parsed.year}-${two(parsed.month)}-${two(parsed.day)} '
      '${two(parsed.hour)}:${two(parsed.minute)}';
}
