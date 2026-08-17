import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../components/intent_respond_dialog.dart';
import '../l10n/app_localizations.dart';
import '../models/models.dart';
import '../router/publish_navigation.dart';
import '../services/intent_service.dart';
import '../theme/app_theme.dart';
import '../theme/responsive.dart';

class CampusErrandsPage extends StatefulWidget {
  const CampusErrandsPage({super.key, this.intentService});

  final IntentService? intentService;

  @override
  State<CampusErrandsPage> createState() => _CampusErrandsPageState();
}

class _CampusErrandsPageState extends State<CampusErrandsPage> {
  late final IntentService _intentService;
  List<UserIntent> _campus = const [];
  List<UserIntent> _mine = const [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _intentService = widget.intentService ?? context.read<IntentService>();
    _load();
  }

  Future<void> _load() async {
    if (mounted) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final results = await Future.wait([
        _intentService.campusFeed(kind: IntentKind.help, limit: 50),
        _intentService.myIntents(),
      ]);
      if (!mounted) return;
      setState(() {
        _campus = results[0];
        _mine = results[1]
            .where((intent) => intent.kind == IntentKind.help)
            .toList(growable: false);
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = error.toString();
      });
    }
  }

  Future<void> _respond(UserIntent intent) async {
    if (await respondToIntentFlow(context, _intentService, intent)) {
      await _load();
    }
  }

  Future<void> _complete(UserIntent intent) async {
    final l = AppLocalizations.of(context)!;
    try {
      await _intentService.fulfilIntent(intent.id);
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l.errandFulfilled)));
      await _load();
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l.operationFailed(error.toString()))),
      );
    }
  }

  Future<void> _withdraw(UserIntent intent) async {
    final l = AppLocalizations.of(context)!;
    try {
      await _intentService.withdrawIntent(intent.id);
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l.errandWithdrawn)));
      await _load();
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l.operationFailed(error.toString()))),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: Text(l.errandBoardTitle),
          actions: [
            IconButton(
              tooltip: l.errandCreateAction,
              onPressed: () => context.push(PublishNavigation.errand),
              icon: const Icon(Icons.add_task_rounded),
            ),
          ],
          bottom: TabBar(
            tabs: [
              Tab(text: l.errandTabCampus),
              Tab(text: l.errandTabMine),
            ],
          ),
        ),
        body: ResponsiveContent(
          maxWidth: 960,
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : _error != null
              ? _ErrandError(onRetry: _load)
              : TabBarView(
                  children: [
                    _ErrandList(
                      intents: _campus,
                      emptyText: l.errandCampusEmpty,
                      onRefresh: _load,
                      onRespond: _respond,
                    ),
                    _ErrandList(
                      intents: _mine,
                      emptyText: l.errandMineEmpty,
                      onRefresh: _load,
                      onComplete: _complete,
                      onWithdraw: _withdraw,
                    ),
                  ],
                ),
        ),
        floatingActionButton: FloatingActionButton.extended(
          key: const ValueKey('errand-board-create'),
          onPressed: () => context.push(PublishNavigation.errand),
          icon: const Icon(Icons.add_rounded),
          label: Text(l.errandCreateAction),
        ),
      ),
    );
  }
}

class _ErrandList extends StatelessWidget {
  const _ErrandList({
    required this.intents,
    required this.emptyText,
    required this.onRefresh,
    this.onRespond,
    this.onComplete,
    this.onWithdraw,
  });

  final List<UserIntent> intents;
  final String emptyText;
  final Future<void> Function() onRefresh;
  final Future<void> Function(UserIntent)? onRespond;
  final Future<void> Function(UserIntent)? onComplete;
  final Future<void> Function(UserIntent)? onWithdraw;

  @override
  Widget build(BuildContext context) {
    if (intents.isEmpty) {
      return RefreshIndicator(
        onRefresh: onRefresh,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            SizedBox(
              height: 420,
              child: Center(
                child: Text(emptyText, textAlign: TextAlign.center),
              ),
            ),
          ],
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: onRefresh,
      child: ListView.separated(
        padding: const EdgeInsets.fromLTRB(
          AppTheme.sp16,
          AppTheme.sp16,
          AppTheme.sp16,
          96,
        ),
        itemCount: intents.length,
        separatorBuilder: (_, _) => const SizedBox(height: AppTheme.sp8),
        itemBuilder: (context, index) {
          final intent = intents[index];
          return _ErrandBoardCard(
            intent: intent,
            onRespond: onRespond == null ? null : () => onRespond!(intent),
            onComplete: onComplete == null ? null : () => onComplete!(intent),
            onWithdraw: onWithdraw == null ? null : () => onWithdraw!(intent),
          );
        },
      ),
    );
  }
}

class _ErrandBoardCard extends StatelessWidget {
  const _ErrandBoardCard({
    required this.intent,
    this.onRespond,
    this.onComplete,
    this.onWithdraw,
  });

  final UserIntent intent;
  final VoidCallback? onRespond;
  final VoidCallback? onComplete;
  final VoidCallback? onWithdraw;

  String _modeLabel(AppLocalizations l) => switch (intent.slots.serviceMode) {
    'pickup' => l.errandModePickup,
    'buy' => l.errandModeBuy,
    'queue' => l.errandModeQueue,
    'print' => l.errandModePrint,
    'return' => l.errandModeReturn,
    _ => l.errandModeOther,
  };

  String _directionLabel(AppLocalizations l) => intent.slots.isServiceOffer
      ? l.errandServiceOffer
      : l.errandServiceWanted;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final pickup = intent.slots.pickupPlace?.trim();
    final dropoff = intent.slots.dropoffPlace?.trim();
    final time = intent.slots.time?.hint?.trim();
    final reward = intent.slots.price?.cents;
    return Card(
      key: ValueKey('errand-board-card-${intent.id}'),
      child: Padding(
        padding: const EdgeInsets.all(AppTheme.sp16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              intent.slots.subject?.trim().isNotEmpty == true
                  ? intent.slots.subject!.trim()
                  : intent.rawInput,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: AppTheme.sp8),
            Wrap(
              spacing: AppTheme.sp8,
              runSpacing: AppTheme.sp8,
              children: [
                Chip(
                  avatar: Icon(
                    intent.slots.isServiceOffer
                        ? Icons.north_east_rounded
                        : Icons.south_west_rounded,
                    size: 16,
                  ),
                  label: Text(_directionLabel(l)),
                ),
                Chip(label: Text(_modeLabel(l))),
                if (reward != null && reward > 0)
                  Chip(label: Text('${(reward / 100).toStringAsFixed(0)} 元')),
                if (intent.validUntil != null)
                  Chip(
                    avatar: const Icon(Icons.schedule_outlined, size: 16),
                    label: Text(l.errandExpiresLabel),
                  ),
              ],
            ),
            if (pickup?.isNotEmpty == true)
              _DetailLine(
                icon: Icons.upload_outlined,
                label: '${l.errandPickupShort} $pickup',
              ),
            if (dropoff?.isNotEmpty == true)
              _DetailLine(
                icon: Icons.download_outlined,
                label: '${l.errandDropoffShort} $dropoff',
              ),
            if (time?.isNotEmpty == true)
              _DetailLine(
                icon: Icons.schedule_outlined,
                label: '${l.errandTimeShort} $time',
              ),
            const SizedBox(height: AppTheme.sp8),
            Wrap(
              alignment: WrapAlignment.end,
              spacing: AppTheme.sp8,
              runSpacing: AppTheme.sp8,
              children: [
                if (onRespond != null)
                  FilledButton.tonalIcon(
                    key: ValueKey('errand-board-respond-${intent.id}'),
                    onPressed: onRespond,
                    icon: const Icon(Icons.handshake_outlined),
                    label: Text(
                      intent.slots.isServiceOffer
                          ? l.errandNeedServiceAction
                          : l.errandRespondAction,
                    ),
                  ),
                if (onComplete != null)
                  FilledButton.icon(
                    key: ValueKey('errand-board-complete-${intent.id}'),
                    onPressed: onComplete,
                    icon: const Icon(Icons.check_rounded),
                    label: Text(l.errandFulfilAction),
                  ),
                if (onWithdraw != null)
                  TextButton.icon(
                    key: ValueKey('errand-board-withdraw-${intent.id}'),
                    onPressed: onWithdraw,
                    icon: const Icon(Icons.close_rounded),
                    label: Text(l.errandWithdrawAction),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _DetailLine extends StatelessWidget {
  const _DetailLine({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.only(top: AppTheme.sp6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 17, color: color),
          const SizedBox(width: AppTheme.sp8),
          Expanded(
            child: Text(label, style: TextStyle(color: color)),
          ),
        ],
      ),
    );
  }
}

class _ErrandError extends StatelessWidget {
  const _ErrandError({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.error_outline_rounded, size: 36),
          const SizedBox(height: AppTheme.sp12),
          Text(l.errandLoadFailed),
          const SizedBox(height: AppTheme.sp12),
          FilledButton.tonal(onPressed: onRetry, child: Text(l.retry)),
        ],
      ),
    );
  }
}
