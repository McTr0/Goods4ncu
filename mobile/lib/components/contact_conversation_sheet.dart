import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../l10n/app_localizations.dart';
import '../models/models.dart';
import '../services/chat_service.dart';

Future<Conversation?> openContactConversationPage({
  required BuildContext context,
  required ChatService chatService,
  required String recipientId,
  String? listingId,
  String? listingTitle,
  String? recipientName,
}) {
  final route = Uri(
    pathSegments: ['contact', recipientId],
    queryParameters: {
      'listingId': ?listingId,
      'listingTitle': ?listingTitle,
      'recipientName': ?recipientName,
    },
  ).toString();
  return context.push<Conversation>(
    '/$route',
    extra: {'chatService': chatService},
  );
}

class ContactConversationPage extends StatefulWidget {
  const ContactConversationPage({
    super.key,
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
  State<ContactConversationPage> createState() =>
      _ContactConversationPageState();
}

class _ContactConversationPageState extends State<ContactConversationPage> {
  final _subjectController = TextEditingController();
  final _contentController = TextEditingController();
  ConversationMode? _mode;
  MailExpectation _mailExpectation = MailExpectation.ordinary;
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
        mailExpectation: mode == ConversationMode.mail
            ? _mailExpectation
            : null,
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
    final l = AppLocalizations.of(context)!;
    final scheme = Theme.of(context).colorScheme;
    final contextLine = widget.listingTitle == null
        ? l.contactContextUser(widget.recipientName ?? l.contactFallbackUser)
        : l.contactContextListing(widget.listingTitle!);
    return Scaffold(
      appBar: AppBar(title: Text(l.contactModePromptTitle)),
      body: SafeArea(
        top: false,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final horizontalPadding = constraints.maxWidth < 600 ? 16.0 : 28.0;
            return SingleChildScrollView(
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
              padding: EdgeInsets.fromLTRB(
                horizontalPadding,
                18,
                horizontalPadding,
                28 + MediaQuery.viewInsetsOf(context).bottom,
              ),
              child: Center(
                child: ConstrainedBox(
                  key: const ValueKey('contact-page-content'),
                  constraints: const BoxConstraints(maxWidth: 720),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      DecoratedBox(
                        decoration: BoxDecoration(
                          color: scheme.surfaceContainerLow,
                          borderRadius: BorderRadius.circular(18),
                          border: Border.all(color: scheme.outlineVariant),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Row(
                            children: [
                              Icon(
                                widget.listingTitle == null
                                    ? Icons.person_outline_rounded
                                    : Icons.sell_outlined,
                                color: scheme.primary,
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Text(
                                  contextLine,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 18),
                      AnimatedSwitcher(
                        duration: const Duration(milliseconds: 180),
                        child: _mode == null
                            ? _buildModeChoice()
                            : _buildComposer(),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildModeChoice() {
    final l = AppLocalizations.of(context)!;
    final scheme = Theme.of(context).colorScheme;
    return Column(
      key: const ValueKey('contact-mode-choice'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          l.contactModePromptTitle,
          style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 6),
        Text(
          l.contactPageModeHint,
          style: TextStyle(color: scheme.onSurfaceVariant, height: 1.4),
        ),
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
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            IconButton.filledTonal(
              tooltip: l.contactBackAction,
              onPressed: _submitting
                  ? null
                  : () => setState(() => _mode = null),
              icon: const Icon(Icons.arrow_back_rounded),
            ),
            const SizedBox(width: 12),
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
        const SizedBox(height: 18),
        if (isMail) ...[
          TextField(
            key: const ValueKey('mail-subject-field'),
            controller: _subjectController,
            maxLength: 120,
            textInputAction: TextInputAction.next,
            decoration: InputDecoration(
              labelText: l.contactMailSubjectLabel,
              hintText: l.contactMailSubjectHint,
              prefixIcon: const Icon(Icons.subject),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            l.contactMailExpectationLabel,
            style: TextStyle(
              color: scheme.onSurfaceVariant,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              ChoiceChip(
                label: Text(l.contactMailExpectationOrdinary),
                selected: _mailExpectation == MailExpectation.ordinary,
                onSelected: _submitting
                    ? null
                    : (_) => setState(
                        () => _mailExpectation = MailExpectation.ordinary,
                      ),
              ),
              ChoiceChip(
                label: Text(l.contactMailExpectationToday),
                selected: _mailExpectation == MailExpectation.today,
                onSelected: _submitting
                    ? null
                    : (_) => setState(
                        () => _mailExpectation = MailExpectation.today,
                      ),
              ),
            ],
          ),
          const SizedBox(height: 12),
        ],
        TextField(
          key: const ValueKey('conversation-opening-field'),
          controller: _contentController,
          minLines: 5,
          maxLines: 10,
          maxLength: 2000,
          autofocus: true,
          textCapitalization: TextCapitalization.sentences,
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
        FilledButton.icon(
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
