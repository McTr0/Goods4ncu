import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../l10n/app_localizations.dart';
import '../models/models.dart';
import '../services/chat_service.dart';

Future<Conversation?> openContactConversationPage({
  required BuildContext context,
  required ChatService chatService,
  required String recipientId,
  required ConversationMode mode,
  String? listingId,
  String? listingTitle,
  String? recipientName,
}) {
  final route = Uri(
    pathSegments: ['contact', recipientId],
    queryParameters: {
      'mode': mode.wireValue,
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
    required this.initialMode,
    this.listingId,
    this.listingTitle,
    this.recipientName,
  });

  final ChatService chatService;
  final String recipientId;
  final ConversationMode initialMode;
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
  late final ConversationMode _mode = widget.initialMode;
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
    final subject = _subjectController.text.trim();
    final content = _contentController.text.trim();
    final l = AppLocalizations.of(context)!;
    if (content.isEmpty) {
      setState(() => _error = l.contactOpeningRequired);
      return;
    }
    if (_mode == ConversationMode.mail && subject.isEmpty) {
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
        mode: _mode,
        subject: _mode == ConversationMode.mail ? subject : null,
        mailExpectation: _mode == ConversationMode.mail
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
      appBar: AppBar(title: Text(l.contactPageTitle)),
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
                      _buildComposer(),
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

  Widget _buildComposer() {
    final l = AppLocalizations.of(context)!;
    final isMail = _mode == ConversationMode.mail;
    return Column(
      key: ValueKey('contact-compose-${_mode.wireValue}'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
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
              color: Theme.of(context).colorScheme.onSurfaceVariant,
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
          Text(
            _error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
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
