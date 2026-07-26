import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/app_localizations.dart';
import '../models/models.dart';
import '../services/price_discovery_service.dart';
import '../theme/app_theme.dart';

/// Settling a price by private limits.
///
/// The interface exists to make a mechanism trustworthy, so two things are
/// non-negotiable here:
///
/// * **The rule is always on screen.** A pricing black box is worse than
///   haggling — at least haggling is legible. The server ships the rule with
///   every response precisely so this cannot drift from what the code does.
/// * **Nothing about the other side is shown, ever.** Not their limit, not the
///   gap when there is no deal, not whether they have answered yet. There is no
///   field to render even if someone wanted to: the server does not send one.
///
/// Presented as a sheet from the listing rather than a page, because it is a
/// short exchange attached to a specific item.
class PriceDiscoverySheet extends StatefulWidget {
  const PriceDiscoverySheet({
    super.key,
    required this.listingId,
    required this.viewerIsSeller,
    required this.service,
    this.existingSessionId,
  });

  final String listingId;

  /// Changes only the prompt: a seller states their least, a buyer their most.
  /// The mechanism itself is symmetric.
  final bool viewerIsSeller;

  final PriceDiscoveryService service;

  /// When answering an invitation rather than starting one.
  final String? existingSessionId;

  @override
  State<PriceDiscoverySheet> createState() => _PriceDiscoverySheetState();
}

class _PriceDiscoverySheetState extends State<PriceDiscoverySheet> {
  final _controller = TextEditingController();

  PriceDiscoverySession? _session;
  String _rule = '';
  String? _sessionId;
  bool _busy = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _start());
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    try {
      final result = widget.existingSessionId != null
          ? await widget.service.session(widget.existingSessionId!)
          : await widget.service.propose(widget.listingId);
      if (!mounted) return;
      setState(() {
        _session = result.session;
        _rule = result.rule;
        _sessionId = result.sessionId ?? result.session?.id;
        _busy = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _busy = false;
      });
    }
  }

  Future<void> _run(Future<PriceDiscoveryResult> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final result = await action();
      if (!mounted) return;
      setState(() {
        _session = result.session ?? _session;
        if (result.rule.isNotEmpty) _rule = result.rule;
        _sessionId = result.sessionId ?? result.session?.id ?? _sessionId;
        _busy = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _busy = false;
      });
    }
  }

  Future<void> _submitLimit() async {
    final l = AppLocalizations.of(context)!;
    final yuan = double.tryParse(_controller.text.trim());
    // A limit is the whole input; a typo here is a real trade at a wrong price,
    // so it is rejected rather than coerced.
    if (yuan == null || yuan < 0 || yuan > 10_000_000) {
      setState(() => _error = l.priceDiscoveryInvalid);
      return;
    }
    final id = _sessionId;
    if (id == null) return;
    await _run(() => widget.service.stateLimit(id, (yuan * 100).round()));
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final session = _session;

    return Padding(
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 20,
        bottom: 20 + MediaQuery.of(context).viewInsets.bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l.priceDiscoveryTitle,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          // Always visible, and taken from the server so it cannot drift from
          // the rule the code actually applies.
          if (_rule.isNotEmpty)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFFF4F6F4),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                _rule,
                style: const TextStyle(fontSize: 12, color: Color(0xFF4B5563)),
              ),
            ),
          const SizedBox(height: 16),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(
                _error!,
                style: const TextStyle(fontSize: 13, color: Color(0xFFB91C1C)),
              ),
            ),
          if (_busy && session == null)
            const Center(child: CircularProgressIndicator())
          else if (session != null)
            ..._body(l, session),
        ],
      ),
    );
  }

  List<Widget> _body(AppLocalizations l, PriceDiscoverySession session) {
    if (session.isMatched) {
      final price = ((session.matchedCents ?? 0) / 100).toStringAsFixed(2);
      return [
        Text(
          l.priceDiscoveryMatched(price),
          style: const TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w700,
            color: AppTheme.primary,
          ),
        ),
      ];
    }
    if (session.isNoDeal) {
      // Deliberately says nothing about how far apart. "You were 20 short" is a
      // bargaining position handed to one side.
      return [
        Text(l.priceDiscoveryNoDeal, style: const TextStyle(fontSize: 14)),
      ];
    }
    if (session.isDeclined) {
      return [
        Text(l.priceDiscoveryDeclined, style: const TextStyle(fontSize: 14)),
      ];
    }
    if (session.isProposed) {
      // Both sides opt in. Declining keeps the ordinary negotiation flow, which
      // is why it is offered as a peer of agreeing rather than a way out.
      return [
        Text(
          l.priceDiscoveryAcceptInvite,
          style: const TextStyle(fontSize: 14),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: OutlinedButton(
                onPressed: _busy
                    ? null
                    : () => _run(() => widget.service.decline(_sessionId!)),
                child: Text(l.priceDiscoveryPreferHaggle),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: FilledButton(
                onPressed: _busy
                    ? null
                    : () => _run(() => widget.service.accept(_sessionId!)),
                child: Text(l.priceDiscoveryAgree),
              ),
            ),
          ],
        ),
      ];
    }
    if (session.youHaveStated) {
      // Says nothing about whether they have answered: knowing someone is still
      // deciding is itself a small advantage.
      return [
        Text(l.priceDiscoveryWaiting, style: const TextStyle(fontSize: 14)),
      ];
    }
    return [
      TextField(
        controller: _controller,
        autofocus: true,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
        decoration: InputDecoration(
          labelText: l.priceDiscoveryYourLimit,
          hintText: widget.viewerIsSeller
              ? l.priceDiscoverySellerHint
              : l.priceDiscoveryBuyerHint,
          border: const OutlineInputBorder(),
        ),
      ),
      const SizedBox(height: 12),
      SizedBox(
        width: double.infinity,
        child: FilledButton(
          onPressed: _busy ? null : _submitLimit,
          child: Text(l.priceDiscoverySubmit),
        ),
      ),
    ];
  }
}
