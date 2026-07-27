import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
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

  /// null until the first attempt tells us whether this deployment has vision.
  /// An affordance that always fails is worse than no affordance.
  bool _photoAvailable = true;
  bool _readingPhoto = false;
  final _picker = ImagePicker();

  List<UserIntent> _mine = [];
  List<UserIntent> _feed = [];
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
    // The feed loads separately from the caller's own intents so a failure in
    // one does not blank the other. It is also the part a brand-new user has
    // anything to look at, so it must not depend on them having posted.
    try {
      final feed = await _service.campusFeed();
      if (mounted) setState(() => _feed = feed);
    } catch (_) {}
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

  /// One photo of a dorm room, read as a list of things.
  ///
  /// Graduation is twenty items and twenty forms, so none of it gets posted.
  /// Everything the model reads lands as a draft for the author to confirm or
  /// delete — a wrong reading costs a few taps, not a wrong listing.
  Future<void> _fromPhoto() async {
    final l = AppLocalizations.of(context)!;
    final picked = await _picker.pickImage(
      source: ImageSource.gallery,
      imageQuality: 70,
      maxWidth: 1600,
    );
    if (picked == null || !mounted) return;

    setState(() => _readingPhoto = true);
    try {
      final bytes = await picked.readAsBytes();
      final ids = await _service.decomposePhoto(
        imageBase64: base64Encode(bytes),
        mime: picked.mimeType ?? 'image/jpeg',
        // Whatever they typed travels with it, so a failed reading still
        // records their words instead of losing them.
        rawInput: _controller.text.trim().isEmpty
            ? null
            : _controller.text.trim(),
      );
      if (!mounted) return;

      if (ids == null) {
        // No vision provider here. Hide the button rather than letting them
        // press something that cannot work.
        setState(() {
          _photoAvailable = false;
          _readingPhoto = false;
        });
        return;
      }

      _controller.clear();
      setState(() => _readingPhoto = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            ids.length > 1 ? l.intentPhotoSplit : l.intentPhotoNothing,
          ),
        ),
      );
      await _load();
    } catch (e) {
      if (!mounted) return;
      setState(() => _readingPhoto = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l.operationFailed(e.toString()))));
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

  Future<void> _respond(UserIntent intent) async {
    final l = AppLocalizations.of(context)!;
    final content = await showDialog<String>(
      context: context,
      builder: (_) => _RespondDialog(intent: intent),
    );
    if (content == null || content.isEmpty || !mounted) return;

    try {
      await _service.respondToIntent(intent.id, content);
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l.intentRespondSent)));
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
            Row(
              children: [
                Expanded(
                  child: FilledButton(
                    onPressed: (_submitting || _readingPhoto) ? null : _submit,
                    child: Text(_submitting ? l.intentSaving : l.intentSubmit),
                  ),
                ),
                // Only for things being sold, and only where the deployment can
                // actually read a photo.
                if (_photoAvailable && _kind == IntentKind.goodsOffer) ...[
                  const SizedBox(width: 12),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: (_submitting || _readingPhoto)
                          ? null
                          : _fromPhoto,
                      icon: const Icon(Icons.photo_camera_outlined, size: 18),
                      label: Text(
                        _readingPhoto
                            ? l.intentPhotoWorking
                            : l.intentPhotoAction,
                        softWrap: false,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                ],
              ],
            ),
            const Divider(height: 32),
            // Placed above the caller's own intents on purpose: someone who has
            // just arrived and posted nothing should still find something they
            // can answer, which is the other half of the unanswered-post
            // problem.
            Text(
              l.intentFeedHeader,
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            if (_feed.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: Text(
                  l.intentFeedEmpty,
                  style: const TextStyle(
                    fontSize: 13,
                    color: Color(0xFF9CA3AF),
                  ),
                ),
              )
            else
              ..._feed.map(
                (intent) => Card(
                  margin: const EdgeInsets.only(bottom: 8),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                _kindLabel(l, intent.kind),
                                style: const TextStyle(
                                  fontSize: 11,
                                  color: Color(0xFF6B7280),
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                intent.rawInput,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 14),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 8),
                        FilledButton.tonal(
                          onPressed: () => _respond(intent),
                          child: Text(l.intentRespondAction),
                        ),
                      ],
                    ),
                  ),
                ),
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
                  onRespondToMatch: _respond,
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
    required this.onRespondToMatch,
    required this.onConfirm,
    required this.onFulfilled,
    required this.onWithdraw,
  });

  final UserIntent intent;
  final String kindLabel;
  final List<UserIntent>? matches;

  /// Answering a match is the only reason to show one. Without this the list is
  /// a notice that somebody wants what you have and no way to say so.
  final void Function(UserIntent) onRespondToMatch;
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
              // Each one is answerable. The moment the system says somebody
              // here wants what you have is the worst possible moment to give
              // them nothing to press.
              ...matches!
                  .take(3)
                  .map(
                    (m) => InkWell(
                      onTap: () => onRespondToMatch(m),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                '· ${m.slots.subject ?? m.rawInput}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 12),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Text(
                              l.intentRespondAction,
                              style: const TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                                color: AppTheme.primary,
                              ),
                            ),
                          ],
                        ),
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

/// The reply composer.
///
/// A widget rather than an inline `showDialog` body so it owns its
/// `TextEditingController` and disposes it in its own `dispose()`. Disposing it
/// straight after `showDialog` returns throws — the dialog's dismissal animation
/// is still running and rebuilds the field against a dead controller, which
/// happened on every send and every cancel.
class _RespondDialog extends StatefulWidget {
  const _RespondDialog({required this.intent});

  final UserIntent intent;

  @override
  State<_RespondDialog> createState() => _RespondDialogState();
}

class _RespondDialogState extends State<_RespondDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    return AlertDialog(
      title: Text(l.intentRespondTitle),
      // Scrollable: an AlertDialog's content is not, and on a short screen with
      // the keyboard up this column does not fit.
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Their own words, so the responder can see exactly what they are
            // answering rather than a normalised summary.
            Text(
              widget.intent.rawInput,
              style: const TextStyle(fontSize: 13, color: Color(0xFF6B7280)),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _controller,
              autofocus: true,
              maxLines: 3,
              minLines: 2,
              decoration: InputDecoration(
                hintText: l.intentRespondHint,
                border: const OutlineInputBorder(),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l.cancel),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _controller.text.trim()),
          child: Text(l.intentRespondSend),
        ),
      ],
    );
  }
}
