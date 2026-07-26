import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../models/models.dart';
import '../services/intent_service.dart';
import '../theme/app_theme.dart';

/// Saying what you want, in your own words.
///
/// This is deliberately not a form. The listing form asks for a title, a
/// category, a brand, a condition score and a price before it will accept
/// anything, and that threshold is why most of what people want on a campus
/// never gets said at all — nobody fills in twenty of them while emptying a dorm
/// room, and nobody fills in one to ask whether anyone fancies a game of
/// badminton.
///
/// So: one text field. The kind is a row of chips because it changes who sees
/// it, not because the system needs it filed. Price and time are offered only
/// when they could matter, and "whatever" and "any time" are real answers rather
/// than skipped fields.
class IntentPage extends StatefulWidget {
  const IntentPage({super.key, this.intentService});

  /// Injectable for tests.
  final IntentService? intentService;

  @override
  State<IntentPage> createState() => _IntentPageState();
}

class _IntentPageState extends State<IntentPage> {
  late final IntentService _service;
  final _controller = TextEditingController();

  IntentKind _kind = IntentKind.goodsOffer;
  PriceSlot? _price;
  bool _flexibleTime = false;
  bool _submitting = false;

  List<UserIntent> _mine = [];
  final Map<String, List<UserIntent>> _matches = {};
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _service = widget.intentService ?? context.read<IntentService>();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final mine = await _service.myIntents();
      if (!mounted) return;
      setState(() {
        _mine = mine;
        _loading = false;
      });
      // Matches are fetched per intent so a slow or failing one cannot hide the
      // rest of the list.
      for (final intent in mine.where((i) => !i.isDraft)) {
        try {
          final matches = await _service.matchesFor(intent.id);
          if (!mounted) return;
          setState(() => _matches[intent.id] = matches);
        } catch (_) {}
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _submit() async {
    final text = _controller.text.trim();
    if (text.isEmpty || _submitting) return;
    final l = AppLocalizations.of(context)!;
    setState(() => _submitting = true);
    try {
      final created = await _service.createIntent(
        kind: _kind,
        rawInput: text,
        slots: IntentSlots(
          price: _kind.hasPrice ? _price : null,
          time: _flexibleTime ? TimeSlot.flexible(l.intentTimeFlexible) : null,
        ),
      );
      if (!mounted) return;
      _controller.clear();
      setState(() {
        _price = null;
        _flexibleTime = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            // Saying so matters: an intent with no price is not shown in the
            // browse grid, and a user who expected it there should be told why
            // rather than concluding it failed.
            created.projectedListingId == null && _kind == IntentKind.goodsOffer
                ? l.intentSavedNotListed
                : l.intentSaved,
          ),
        ),
      );
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l.operationFailed(e.toString()))));
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  Future<void> _resolve(UserIntent intent, {required bool worked}) async {
    final l = AppLocalizations.of(context)!;
    try {
      if (worked) {
        await _service.fulfilIntent(intent.id);
      } else {
        await _service.withdrawIntent(intent.id);
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(worked ? l.intentFulfilled : l.intentWithdrawn)),
      );
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l.operationFailed(e.toString()))));
    }
  }

  String _kindLabel(AppLocalizations l, IntentKind kind) => switch (kind) {
    IntentKind.goodsOffer => l.intentKindGoodsOffer,
    IntentKind.goodsSeek => l.intentKindGoodsSeek,
    IntentKind.companion => l.intentKindCompanion,
    IntentKind.help => l.intentKindHelp,
    IntentKind.activity => l.intentKindActivity,
  };

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(title: Text(l.intentPageTitle)),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(
              l.intentComposerPrompt,
              style: const TextStyle(fontSize: 13, color: Color(0xFF6B7280)),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _controller,
              maxLines: 3,
              minLines: 2,
              textInputAction: TextInputAction.newline,
              decoration: InputDecoration(
                hintText: l.intentComposerHint,
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: IntentKind.values
                  .map(
                    (kind) => ChoiceChip(
                      label: Text(_kindLabel(l, kind)),
                      selected: _kind == kind,
                      onSelected: (_) => setState(() {
                        _kind = kind;
                        if (!kind.hasPrice) _price = null;
                      }),
                    ),
                  )
                  .toList(),
            ),
            const SizedBox(height: 12),
            // Only offered where it could matter, and every option here is a
            // complete answer — including declining to name a figure.
            if (_kind.hasPrice)
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilterChip(
                    label: Text(l.intentPriceWhatever),
                    selected: _price?.kind == 'whatever',
                    onSelected: (on) =>
                        setState(() => _price = on ? PriceSlot.whatever : null),
                  ),
                  FilterChip(
                    label: Text(l.intentPriceFree),
                    selected: _price?.kind == 'free',
                    onSelected: (on) =>
                        setState(() => _price = on ? PriceSlot.free : null),
                  ),
                ],
              ),
            if (_kind != IntentKind.goodsOffer)
              FilterChip(
                label: Text(l.intentTimeFlexible),
                selected: _flexibleTime,
                onSelected: (on) => setState(() => _flexibleTime = on),
              ),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: _submitting ? null : _submit,
              child: Text(_submitting ? l.intentSaving : l.intentSubmit),
            ),
            const Divider(height: 32),
            Text(
              l.intentMineHeader,
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            if (_loading)
              const Center(
                child: Padding(
                  padding: EdgeInsets.all(24),
                  child: CircularProgressIndicator(),
                ),
              )
            else if (_mine.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 24),
                child: Text(
                  l.intentMineEmpty,
                  style: const TextStyle(
                    fontSize: 13,
                    color: Color(0xFF9CA3AF),
                  ),
                ),
              )
            else
              ..._mine.map(
                (intent) => _IntentCard(
                  intent: intent,
                  kindLabel: _kindLabel(l, intent.kind),
                  matches: _matches[intent.id],
                  onConfirm: intent.isDraft
                      ? () async {
                          await _service.confirmIntent(intent.id);
                          await _load();
                        }
                      : null,
                  onFulfilled: () => _resolve(intent, worked: true),
                  onWithdraw: () => _resolve(intent, worked: false),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _IntentCard extends StatelessWidget {
  const _IntentCard({
    required this.intent,
    required this.kindLabel,
    required this.matches,
    required this.onConfirm,
    required this.onFulfilled,
    required this.onWithdraw,
  });

  final UserIntent intent;
  final String kindLabel;
  final List<UserIntent>? matches;
  final Future<void> Function()? onConfirm;
  final VoidCallback onFulfilled;
  final VoidCallback onWithdraw;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final price = intent.slots.price;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Chip(
                  label: Text(kindLabel, style: const TextStyle(fontSize: 11)),
                  visualDensity: VisualDensity.compact,
                ),
                const SizedBox(width: 8),
                if (intent.isDraft)
                  Chip(
                    label: Text(
                      l.intentDraftBadge,
                      style: const TextStyle(fontSize: 11),
                    ),
                    backgroundColor: const Color(0xFFFFF3CD),
                    visualDensity: VisualDensity.compact,
                  ),
              ],
            ),
            const SizedBox(height: 4),
            // The author's own words, not a normalised title. Showing back what
            // someone actually said is how they can tell we understood them.
            Text(intent.rawInput, style: const TextStyle(fontSize: 14)),
            if (price != null) ...[
              const SizedBox(height: 4),
              Text(switch (price.kind) {
                // Their phrasing where we have it, rather than a figure they
                // never chose.
                'whatever' => price.hint ?? l.intentPriceWhatever,
                'free' => l.intentPriceFree,
                'exact' => '¥${((price.cents ?? 0) / 100).toStringAsFixed(2)}',
                _ => l.intentPriceFlexible,
              }, style: const TextStyle(fontSize: 12, color: AppTheme.primary)),
            ],
            if (matches != null) ...[
              const SizedBox(height: 6),
              Text(
                matches!.isEmpty
                    ? l.intentNoMatchesYet
                    : l.intentMatchCount(matches!.length),
                style: const TextStyle(fontSize: 12, color: Color(0xFF6B7280)),
              ),
              ...matches!
                  .take(3)
                  .map(
                    (m) => Padding(
                      padding: const EdgeInsets.only(top: 2, left: 4),
                      child: Text(
                        '· ${m.slots.subject ?? m.rawInput}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                  ),
            ],
            const SizedBox(height: 4),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                if (onConfirm != null)
                  FilledButton(
                    onPressed: () => onConfirm!(),
                    child: Text(l.intentConfirmDraft),
                  ),
                // Two buttons, not one "close": "someone helped me" and "never
                // mind" are opposite outcomes, and merging them would erase the
                // difference the health metrics depend on.
                if (onConfirm == null) ...[
                  TextButton(
                    onPressed: onWithdraw,
                    child: Text(l.intentWithdrawAction),
                  ),
                  TextButton(
                    onPressed: onFulfilled,
                    child: Text(l.intentFulfilAction),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}
