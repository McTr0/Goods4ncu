import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../models/models.dart';
import '../services/chat_service.dart';

Future<Conversation?> showContactConversationSheet({
  required BuildContext context,
  required ChatService chatService,
  required String recipientId,
  String? listingId,
  String? listingTitle,
  String? recipientName,
}) {
  return showModalBottomSheet<Conversation>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (context) => _ContactConversationSheet(
      chatService: chatService,
      recipientId: recipientId,
      listingId: listingId,
      listingTitle: listingTitle,
      recipientName: recipientName,
    ),
  );
}

class _ContactConversationSheet extends StatefulWidget {
  const _ContactConversationSheet({
    required this.chatService,
    required this.recipientId,
    this.listingId,
    this.listingTitle,
    this.recipientName,
  });

  final ChatService chatService;
  final String recipientId;
  final String? listingId;
  final String? listingTitle;
  final String? recipientName;

  @override
  State<_ContactConversationSheet> createState() =>
      _ContactConversationSheetState();
}

class _ContactConversationSheetState extends State<_ContactConversationSheet> {
  final _subjectController = TextEditingController();
  final _contentController = TextEditingController();
  ConversationMode? _mode;
  bool _submitting = false;
  String? _error;

  @override
  void dispose() {
    _subjectController.dispose();
    _contentController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final mode = _mode;
    final subject = _subjectController.text.trim();
    final content = _contentController.text.trim();
    final l = AppLocalizations.of(context)!;
    if (mode == null || content.isEmpty) {
      setState(() => _error = l.contactOpeningRequired);
      return;
    }
    if (mode == ConversationMode.mail && subject.isEmpty) {
      setState(() => _error = l.contactMailSubjectRequired);
      return;
    }
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      final conversation = await widget.chatService.createConversation(
        recipientId: widget.recipientId,
        listingId: widget.listingId,
        mode: mode,
        subject: mode == ConversationMode.mail ? subject : null,
        content: content,
      );
      if (mounted) Navigator.of(context).pop(conversation);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _error = error.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.viewInsetsOf(context).bottom;
    final scheme = Theme.of(context).colorScheme;
    return SafeArea(
      child: Center(
        child: Container(
          width: double.infinity,
          constraints: const BoxConstraints(maxWidth: 680),
          margin: const EdgeInsets.only(top: 48),
          padding: EdgeInsets.fromLTRB(24, 20, 24, 24 + bottom),
          decoration: BoxDecoration(
            color: scheme.surface,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
            border: Border(top: BorderSide(color: scheme.outlineVariant)),
          ),
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 220),
            child: _mode == null ? _buildModeChoice() : _buildComposer(),
          ),
        ),
      ),
    );
  }

  Widget _buildModeChoice() {
    final l = AppLocalizations.of(context)!;
    final scheme = Theme.of(context).colorScheme;
    final contextLine = widget.listingTitle == null
        ? l.contactContextUser(widget.recipientName ?? l.contactFallbackUser)
        : l.contactContextListing(widget.listingTitle!);
    return Column(
      key: const ValueKey('contact-mode-choice'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                l.contactModePromptTitle,
                style: const TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
            IconButton(
              onPressed: () => Navigator.of(context).pop(),
              icon: const Icon(Icons.close),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(contextLine, style: TextStyle(color: scheme.onSurfaceVariant)),
        const SizedBox(height: 22),
        _ModeCard(
          icon: Icons.bolt_rounded,
          color: scheme.primary,
          title: l.contactModeRealtimeTitle,
          description: l.contactModeRealtimeDescription,
          onTap: () => setState(() => _mode = ConversationMode.realtime),
        ),
        const SizedBox(height: 12),
        _ModeCard(
          icon: Icons.mark_email_unread_outlined,
          color: scheme.secondary,
          title: l.contactModeMailTitle,
          description: l.contactModeMailDescription,
          onTap: () => setState(() => _mode = ConversationMode.mail),
        ),
      ],
    );
  }

  Widget _buildComposer() {
    final l = AppLocalizations.of(context)!;
    final scheme = Theme.of(context).colorScheme;
    final isMail = _mode == ConversationMode.mail;
    return Column(
      key: ValueKey('contact-compose-${_mode!.wireValue}'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            IconButton(
              onPressed: _submitting
                  ? null
                  : () => setState(() => _mode = null),
              icon: const Icon(Icons.arrow_back),
            ),
            const SizedBox(width: 4),
            Expanded(
              child: Text(
                isMail
                    ? l.contactMailComposerTitle
                    : l.contactRealtimeComposerTitle,
                style: const TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        if (isMail) ...[
          TextField(
            key: const ValueKey('mail-subject-field'),
            controller: _subjectController,
            maxLength: 120,
            decoration: InputDecoration(
              labelText: l.contactMailSubjectLabel,
              hintText: l.contactMailSubjectHint,
              prefixIcon: const Icon(Icons.subject),
            ),
          ),
          const SizedBox(height: 8),
        ],
        TextField(
          key: const ValueKey('conversation-opening-field'),
          controller: _contentController,
          minLines: 4,
          maxLines: 7,
          maxLength: 2000,
          autofocus: true,
          decoration: InputDecoration(
            labelText: isMail
                ? l.contactMailBodyLabel
                : l.contactRealtimeOpeningLabel,
            hintText: isMail
                ? l.contactMailBodyHint
                : l.contactRealtimeOpeningHint,
            alignLabelWithHint: true,
          ),
        ),
        if (_error != null) ...[
          const SizedBox(height: 4),
          Text(_error!, style: TextStyle(color: scheme.error)),
        ],
        const SizedBox(height: 14),
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            key: const ValueKey('submit-contact-conversation'),
            onPressed: _submitting ? null : _submit,
            icon: _submitting
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Icon(isMail ? Icons.send_outlined : Icons.wifi_tethering),
            label: Text(isMail ? l.contactMailSubmit : l.contactRealtimeSubmit),
          ),
        ),
      ],
    );
  }
}

class _ModeCard extends StatelessWidget {
  const _ModeCard({
    required this.icon,
    required this.color,
    required this.title,
    required this.description,
    required this.onTap,
  });

  final IconData icon;
  final Color color;
  final String title;
  final String description;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: color.withValues(
        alpha: Theme.of(context).brightness == Brightness.dark ? 0.18 : 0.08,
      ),
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Row(
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: color,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Icon(icon, color: Colors.white),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      description,
                      style: TextStyle(
                        color: scheme.onSurfaceVariant,
                        height: 1.35,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                Icons.arrow_forward_ios_rounded,
                size: 16,
                color: scheme.onSurfaceVariant,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
