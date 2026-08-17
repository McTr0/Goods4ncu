import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../models/models.dart';
import '../services/intent_service.dart';

/// The reply composer, and the flow around it.
///
/// Shared rather than private to the intent page because answering somebody has
/// to be possible wherever their words are shown. A copy per surface is how one
/// of them ends up as a list you can read and not reply to.
///
/// A widget rather than an inline `showDialog` body so it owns its
/// `TextEditingController` and disposes it in its own `dispose()`. Disposing it
/// straight after `showDialog` returns throws — the dialog's dismissal animation
/// is still running and rebuilds the field against a dead controller, which
/// happened on every send and every cancel.
class IntentRespondDialog extends StatefulWidget {
  const IntentRespondDialog({super.key, required this.intent});

  final UserIntent intent;

  @override
  State<IntentRespondDialog> createState() => _IntentRespondDialogState();
}

class _IntentRespondDialogState extends State<IntentRespondDialog> {
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
      title: Text(
        widget.intent.kind == IntentKind.help
            ? l.errandRespondTitle
            : l.intentRespondTitle,
      ),
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
                hintText: widget.intent.kind == IntentKind.help
                    ? l.errandRespondHint
                    : l.intentRespondHint,
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

/// Ask what to say, send it, and report what happened.
///
/// Returns true when something was sent, so a caller can refresh. An empty reply
/// is not sent: opening a conversation with nothing in it wastes both people's
/// time.
Future<bool> respondToIntentFlow(
  BuildContext context,
  IntentService service,
  UserIntent intent,
) async {
  final l = AppLocalizations.of(context)!;
  final messenger = ScaffoldMessenger.of(context);
  final content = await showDialog<String>(
    context: context,
    builder: (_) => IntentRespondDialog(intent: intent),
  );
  if (content == null || content.isEmpty || !context.mounted) return false;

  try {
    await service.respondToIntent(intent.id, content);
    messenger.showSnackBar(SnackBar(content: Text(l.intentRespondSent)));
    return true;
  } catch (e) {
    messenger.showSnackBar(
      SnackBar(content: Text(l.operationFailed(e.toString()))),
    );
    return false;
  }
}
