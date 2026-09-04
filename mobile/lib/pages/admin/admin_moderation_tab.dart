import 'dart:convert';

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../services/admin_service.dart';
import '../../theme/app_theme.dart';

class AdminModerationTab extends StatefulWidget {
  const AdminModerationTab({
    super.key,
    required this.adminService,
    required this.canReview,
    this.readOnlyMessage,
  });

  final AdminService adminService;
  final bool canReview;
  final String? readOnlyMessage;

  @override
  State<AdminModerationTab> createState() => _AdminModerationTabState();
}

class _AdminModerationTabState extends State<AdminModerationTab> {
  List<Map<String, dynamic>> _cases = const [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final response = await widget.adminService.getModerationCases(
        limit: 100,
      );
      if (!mounted) return;
      setState(() {
        _cases = (response['cases'] as List<dynamic>? ?? const [])
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
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(child: Text('${l.error}: $_error'));
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: _cases.isEmpty
          ? ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              children: [
                const SizedBox(height: 120),
                Icon(
                  Icons.verified_user_outlined,
                  size: 60,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(height: AppTheme.sp16),
                Center(child: Text(l.moderationNoCases)),
              ],
            )
          : ListView.separated(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.all(AppTheme.sp12),
              itemCount: _cases.length,
              separatorBuilder: (_, _) => const SizedBox(height: AppTheme.sp8),
              itemBuilder: (context, index) => _CaseTile(
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
            AppTheme.sp16,
            0,
            AppTheme.sp16,
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
              _CaseStatus(status: moderationCase['status']?.toString()),
              const SizedBox(height: AppTheme.sp16),
              Text(
                '${l.moderationResource}: ${moderationCase['resource_type']} · ${moderationCase['resource_id']}',
              ),
              const SizedBox(height: AppTheme.sp8),
              Text(
                '${l.moderationReason}: ${moderationCase['public_reason'] ?? '-'}',
              ),
              const SizedBox(height: AppTheme.sp8),
              Text(
                '${l.moderationCreatedAt}: ${moderationCase['created_at'] ?? '-'}',
              ),
              if (_usesSeparatelyAuditedManagement(moderationCase)) ...[
                const SizedBox(height: AppTheme.sp12),
                Container(
                  key: const Key('moderation-managed-enforcement-hint'),
                  padding: const EdgeInsets.all(AppTheme.sp12),
                  decoration: BoxDecoration(
                    color: AppTheme.info.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(AppTheme.radiusMd),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Icon(
                        Icons.admin_panel_settings_outlined,
                        color: AppTheme.info,
                        size: 20,
                      ),
                      const SizedBox(width: AppTheme.sp8),
                      Expanded(child: Text(l.moderationManagedEnforcementHint)),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: AppTheme.sp16),
              ExpansionTile(
                tilePadding: EdgeInsets.zero,
                title: Text(l.moderationInternalEvidence),
                children: [
                  Align(
                    alignment: Alignment.centerLeft,
                    child: SelectableText(
                      const JsonEncoder.withIndent(
                        '  ',
                      ).convert(moderationCase['internal_details'] ?? const {}),
                    ),
                  ),
                ],
              ),
              if (!widget.canReview)
                Padding(
                  padding: const EdgeInsets.only(top: AppTheme.sp12),
                  child: Text(
                    widget.readOnlyMessage ?? l.moderationReadOnly,
                    style: TextStyle(
                      color: Theme.of(
                        sheetContext,
                      ).colorScheme.onSurfaceVariant,
                    ),
                  ),
                )
              else ...[
                const Divider(height: AppTheme.sp24),
                _buildActions(sheetContext, moderationCase),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildActions(
    BuildContext sheetContext,
    Map<String, dynamic> moderationCase,
  ) {
    final l = AppLocalizations.of(context)!;
    final status = moderationCase['status']?.toString();
    final appealId = moderationCase['pending_appeal_id']?.toString();
    final usesSeparateManagement = _usesSeparatelyAuditedManagement(
      moderationCase,
    );
    final actions = <Widget>[];
    if (status == 'open') {
      actions.add(
        _actionButton(
          sheetContext,
          moderationCase,
          'start_review',
          l.moderationStartReview,
          OutlinedButton.styleFrom(foregroundColor: AppTheme.info),
        ),
      );
    }
    if (status == 'open' || status == 'reviewing') {
      actions.add(
        _actionButton(
          sheetContext,
          moderationCase,
          'dismiss',
          l.moderationDismiss,
          OutlinedButton.styleFrom(foregroundColor: AppTheme.success),
        ),
      );
      if (!usesSeparateManagement) {
        actions.add(
          _actionButton(
            sheetContext,
            moderationCase,
            'restrict',
            l.moderationRestrict,
            FilledButton.styleFrom(backgroundColor: AppTheme.error),
          ),
        );
      }
    }
    if (!usesSeparateManagement && status == 'actioned' && appealId == null) {
      actions.add(
        _actionButton(
          sheetContext,
          moderationCase,
          'restore',
          l.moderationRestore,
          OutlinedButton.styleFrom(foregroundColor: AppTheme.primary),
        ),
      );
    }
    if (!usesSeparateManagement && status == 'appealed' && appealId != null) {
      actions.add(
        _appealButton(sheetContext, appealId, 'uphold', l.moderationRestrict),
      );
      actions.add(
        _appealButton(sheetContext, appealId, 'overturn', l.moderationRestore),
      );
    }
    if (actions.isEmpty) return Text(l.moderationCannotAppeal);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var index = 0; index < actions.length; index++) ...[
          if (index > 0) const SizedBox(height: AppTheme.sp8),
          actions[index],
        ],
      ],
    );
  }

  Widget _actionButton(
    BuildContext sheetContext,
    Map<String, dynamic> moderationCase,
    String action,
    String label,
    ButtonStyle style,
  ) {
    return OutlinedButton(
      onPressed: () async {
        final note = await _askNote(sheetContext);
        if (note == null || !mounted || !sheetContext.mounted) return;
        Navigator.pop(sheetContext);
        await _reviewCase(moderationCase['id'].toString(), action, note);
      },
      style: style,
      child: Text(label),
    );
  }

  Widget _appealButton(
    BuildContext sheetContext,
    String appealId,
    String decision,
    String label,
  ) {
    return FilledButton(
      onPressed: () async {
        final note = await _askNote(sheetContext);
        if (note == null || !mounted || !sheetContext.mounted) return;
        Navigator.pop(sheetContext);
        try {
          await widget.adminService.reviewModerationAppeal(
            appealId,
            decision: decision,
            note: note,
          );
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                AppLocalizations.of(context)!.moderationActionSuccess,
              ),
            ),
          );
          await _load();
        } catch (error) {
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('${AppLocalizations.of(context)!.error}: $error'),
            ),
          );
        }
      },
      child: Text(label),
    );
  }

  Future<String?> _askNote(BuildContext parentContext) async {
    final l = AppLocalizations.of(context)!;
    final controller = TextEditingController();
    final note = await showDialog<String>(
      context: parentContext,
      builder: (dialogContext) => AlertDialog(
        title: Text(l.moderationActionNote),
        content: TextField(
          controller: controller,
          minLines: 3,
          maxLines: 6,
          maxLength: 2000,
          autofocus: true,
          decoration: InputDecoration(labelText: l.moderationActionNote),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(l.cancel),
          ),
          FilledButton(
            onPressed: () {
              final value = controller.text.trim();
              if (value.length < 3) return;
              Navigator.pop(dialogContext, value);
            },
            child: Text(l.submit),
          ),
        ],
      ),
    );
    controller.dispose();
    return note;
  }

  Future<void> _reviewCase(String id, String action, String note) async {
    try {
      await widget.adminService.reviewModerationCase(
        id,
        action: action,
        note: note,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(AppLocalizations.of(context)!.moderationActionSuccess),
        ),
      );
      await _load();
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('${AppLocalizations.of(context)!.error}: $error'),
        ),
      );
    }
  }
}

bool _usesSeparatelyAuditedManagement(Map<String, dynamic> moderationCase) =>
    switch (moderationCase['resource_type']?.toString()) {
      'listing' || 'user' => true,
      _ => false,
    };

class _CaseTile extends StatelessWidget {
  const _CaseTile({required this.moderationCase, required this.onTap});

  final Map<String, dynamic> moderationCase;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final color = _adminStatusColor(moderationCase['status']?.toString());
    return Card(
      child: ListTile(
        onTap: onTap,
        leading: CircleAvatar(
          backgroundColor: color.withValues(alpha: 0.14),
          child: Icon(Icons.policy_outlined, color: color),
        ),
        title: Text(
          '${moderationCase['resource_type'] ?? l.moderationCase} · ${moderationCase['source_type'] ?? ''}',
        ),
        subtitle: Text(
          moderationCase['public_reason']?.toString() ?? '-',
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: _CaseStatus(status: moderationCase['status']?.toString()),
      ),
    );
  }
}

class _CaseStatus extends StatelessWidget {
  const _CaseStatus({required this.status});

  final String? status;

  @override
  Widget build(BuildContext context) {
    final color = _adminStatusColor(status);
    return Chip(
      label: Text(
        _adminStatusLabel(AppLocalizations.of(context)!, status),
        style: TextStyle(color: color, fontWeight: FontWeight.w700),
      ),
      side: BorderSide.none,
      backgroundColor: color.withValues(alpha: 0.13),
    );
  }
}

String _adminStatusLabel(AppLocalizations l, String? status) =>
    switch (status) {
      'open' => l.moderationStatusOpen,
      'reviewing' => l.moderationStatusReviewing,
      'actioned' => l.moderationStatusActioned,
      'dismissed' => l.moderationStatusDismissed,
      'appealed' => l.moderationStatusAppealed,
      'resolved' => l.moderationStatusResolved,
      _ => status ?? l.unknown,
    };

Color _adminStatusColor(String? status) => switch (status) {
  'open' => AppTheme.warning,
  'reviewing' => AppTheme.info,
  'actioned' => AppTheme.error,
  'dismissed' => AppTheme.success,
  'appealed' => AppTheme.accent,
  'resolved' => AppTheme.primary,
  _ => AppTheme.textSecondary,
};
