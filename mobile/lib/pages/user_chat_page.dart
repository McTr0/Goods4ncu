import 'dart:async';

import 'package:image_picker/image_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../components/agreement_card.dart';
import '../components/handoff_prompt.dart';
import '../services/agreement_service.dart';
import '../services/reputation_service.dart';
import '../models/models.dart';
import '../providers/chat_notifier.dart';
import '../services/chat_service.dart';
import '../services/upload_service.dart';
import '../services/user_service.dart';
import '../services/ws_service.dart';
import '../theme/app_theme.dart';
import '../components/contact_conversation_sheet.dart';
import '../components/relationship_space_preview.dart';
import '../components/user_avatar.dart';
import '../l10n/app_localizations.dart';
import 'user_chat_composer_controller.dart';
import 'user_chat_components.dart';
import 'user_chat_media_sender.dart';
import 'user_chat_session_controller.dart';

export 'user_chat_components.dart' show ConnectionIndicator, MessageBubble;

/// 私聊页面
class UserChatPage extends StatefulWidget {
  final String conversationId;
  final String otherUserId;
  final String otherUsername;
  final ChatService? chatService;

  /// Injectable for tests, like the services above it.
  final AgreementService? agreementService;
  final ReputationService? reputationService;
  final UserService? userService;
  final UploadService? uploadService;
  final ChatNotifier? chatNotifier;
  final UserChatMediaSender? mediaSender;
  final UserChatSessionController? sessionController;
  final UserChatComposerController? composerController;
  final bool embedded;

  const UserChatPage({
    super.key,
    required this.conversationId,
    required this.otherUserId,
    required this.otherUsername,
    this.chatService,
    this.agreementService,
    this.reputationService,
    this.userService,
    this.uploadService,
    this.chatNotifier,
    this.mediaSender,
    this.sessionController,
    this.composerController,
    this.embedded = false,
  }) : assert(
         composerController == null || chatNotifier != null,
         'Injecting composerController also requires injecting chatNotifier.',
       );

  @override
  State<UserChatPage> createState() => _UserChatPageState();
}

class _UserChatPageState extends State<UserChatPage> {
  late final ChatService _chatService;
  late final UserService _userService;
  late final UserChatMediaSender _mediaSender;
  late final UserChatSessionController _sessionController;
  late final bool _ownsSessionController;
  late final bool _ownsChatNotifier;
  late final UserChatComposerController _composerController;
  late final bool _ownsComposerController;
  late final ChatNotifier _chatNotifier;
  late final void Function() _removeChatListener;
  final ImagePicker _imagePicker = ImagePicker();
  final ScrollController _scrollController = ScrollController();
  final ScrollController _relationshipContextScrollController =
      ScrollController();
  ChatViewState _chatState = const ChatViewInitial();
  bool _relationshipContextCanScroll = false;
  bool _relationshipContextAtEnd = false;
  bool _relationshipContextMeasureScheduled = false;

  ChatViewData? get _chatData =>
      _chatState is ChatViewData ? _chatState as ChatViewData : null;

  ChatViewError? get _chatError =>
      _chatState is ChatViewError ? _chatState as ChatViewError : null;

  List<ConversationMessage> get _messages =>
      _chatData?.messages ?? _chatError?.messages ?? const [];

  String? get _currentUserId => _chatData?.currentUserId;

  Agreement? _agreement;
  RelationshipSpace? _relationshipSpace;
  SocialPersona? _otherPersona;
  SocialPersona? _selfPersona;
  String? _otherAvatarUrl;
  bool _awaitingHandoff = false;
  late final AgreementService _agreementService;
  late final ReputationService _reputationService;

  String? get _editingMessageId => _chatData?.editingMessageId;
  ConversationMessage? get _replyingToMessage => _chatData?.replyingToMessage;

  bool get _isLoading =>
      _chatState is ChatViewInitial || _chatState is ChatViewLoading;

  bool get _isSending => _chatData?.isSending ?? false;

  String? get _error => _chatError?.message;

  String? get _connectionStatus => _chatData?.connectionStatus;
  Conversation? get _conversation => _chatData?.conversation;
  bool get _canSend =>
      _conversation?.capabilities.canSend ??
      (_connectionStatus == 'connected' || _connectionStatus == 'active');
  bool get _isMail => _conversation?.mode == ConversationMode.mail;

  bool get _isRecording => _sessionController.isRecording;

  int get _recordingSeconds => _sessionController.recordingSeconds;

  Timer? _countdownTimer;
  List<ReplySuggestion> _replySuggestions = const [];
  bool _suggestionsLoading = false;
  String? _suggestionsError;
  Map<String, String>? _pendingQuote;

  @override
  void initState() {
    super.initState();
    _chatService = widget.chatService ?? context.read<ChatService>();
    _userService = widget.userService ?? context.read<UserService>();
    _agreementService =
        widget.agreementService ?? context.read<AgreementService>();
    _reputationService =
        widget.reputationService ?? context.read<ReputationService>();
    final uploadService = widget.uploadService ?? context.read<UploadService>();
    _mediaSender =
        widget.mediaSender ?? UserChatMediaSender(uploadService: uploadService);
    _ownsSessionController = widget.sessionController == null;
    _sessionController =
        widget.sessionController ??
        UserChatSessionController(mediaSender: _mediaSender);
    _ownsChatNotifier = widget.chatNotifier == null;
    _chatNotifier =
        widget.chatNotifier ??
        ChatNotifier(
          conversationId: widget.conversationId,
          peerUserId: widget.otherUserId,
          chatService: _chatService,
          userService: _userService,
        );
    _ownsComposerController = widget.composerController == null;
    _composerController =
        widget.composerController ??
        UserChatComposerController(chatNotifier: _chatNotifier);
    _removeChatListener = _chatNotifier.addListener(
      _handleChatStateChange,
      fireImmediately: true,
    );
    _sessionController.addListener(_handleSessionStateChange);
    _chatNotifier.hydrateConnectionStatus();
    _sessionController.connectWs(_handleWsNotification);
    _relationshipContextScrollController.addListener(
      _handleRelationshipContextScroll,
    );
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && _conversation?.expiresAt != null) setState(() {});
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadArrangement();
      _loadRelationshipSpace();
      _loadPersonas();
      _loadOtherAvatar();
    });
  }

  @override
  void dispose() {
    _removeChatListener();
    _sessionController.removeListener(_handleSessionStateChange);
    if (_ownsSessionController) {
      _sessionController.dispose();
    }
    if (_ownsComposerController) {
      _composerController.dispose();
    }
    if (_ownsChatNotifier) {
      _chatNotifier.dispose();
    }
    _scrollController.dispose();
    _relationshipContextScrollController.dispose();
    _countdownTimer?.cancel();
    super.dispose();
  }

  void _handleChatStateChange(ChatViewState state) {
    final previousCount = _messages.length;
    if (!mounted) return;
    setState(() {
      _chatState = state;
    });
    final nextCount = _messages.length;
    if (nextCount != previousCount && nextCount > 0) {
      _scrollToBottom();
    }
  }

  void _handleSessionStateChange() {
    if (!mounted) return;
    setState(() {});
  }

  void _handleRelationshipContextScroll() {
    if (!mounted || !_relationshipContextScrollController.hasClients) return;
    final position = _relationshipContextScrollController.position;
    final canScroll = position.maxScrollExtent > 1;
    final atEnd = !canScroll || position.pixels >= position.maxScrollExtent - 1;
    if (canScroll == _relationshipContextCanScroll &&
        atEnd == _relationshipContextAtEnd) {
      return;
    }
    setState(() {
      _relationshipContextCanScroll = canScroll;
      _relationshipContextAtEnd = atEnd;
    });
  }

  void _scheduleRelationshipContextMeasure() {
    if (_relationshipContextMeasureScheduled) return;
    _relationshipContextMeasureScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _relationshipContextMeasureScheduled = false;
      _handleRelationshipContextScroll();
    });
  }

  void _handleWsNotification(WsNotification notif) {
    if (!mounted) return;

    switch (notif.eventType) {
      case 'conversation_created':
      case 'conversation_state_changed':
      case 'connection_established':
      case 'connection_rejected':
        final eventConversationId =
            notif.conversationId ??
            notif.relatedConversationId ??
            notif.connectionId;
        if (eventConversationId == widget.conversationId) {
          _chatNotifier.handleWsNotification(notif.eventType);
        }
        break;

      case 'new_message':
        _chatNotifier.handleWsNotification(
          notif.eventType,
          messageId: notif.messageId,
          conversationId: notif.conversationId,
        );
        break;

      case 'message_acknowledgement_changed':
      case 'message_reaction_changed':
      case 'message_hidden':
      case 'message_reported':
        _chatNotifier.handleWsNotification(
          notif.eventType,
          messageId: notif.messageId,
          conversationId: notif.conversationId,
        );
        break;

      case 'relationship_pin_changed':
      case 'shared_object_created':
      case 'shared_object_revoked':
        if (notif.conversationId == null ||
            notif.conversationId == widget.conversationId) {
          _loadRelationshipSpace();
        }
        break;
    }
  }

  Future<void> _acceptConnection(String connectionId) async {
    final l = AppLocalizations.of(context)!;
    try {
      await _chatNotifier.acceptConnection(connectionId);
      _showSnackBar(l.chatAcceptedLegacy);
    } catch (e) {
      _showSnackBar(l.chatAcceptFailed(e.toString()));
    }
  }

  Future<void> _rejectConnection(String connectionId) async {
    final l = AppLocalizations.of(context)!;
    try {
      await _chatNotifier.rejectConnection(connectionId);
      _showSnackBar(l.chatRejectedLegacy);
    } catch (e) {
      _showSnackBar(l.chatRejectFailed(e.toString()));
    }
  }

  /// 开始编辑消息
  void _startEditMessage(ConversationMessage msg) {
    _composerController.startEditMessage(msg);
  }

  void _startReplyMessage(ConversationMessage msg) {
    final l = AppLocalizations.of(context)!;
    _composerController.startReplyMessage(msg);
    _showSnackBar(l.replyingToMessage);
  }

  /// 取消编辑
  void _cancelEdit() {
    _composerController.cancelEdit();
  }

  void _cancelReply() {
    _composerController.cancelReply();
  }

  Future<void> _reactToMessage(ConversationMessage msg, String emoji) async {
    final l = AppLocalizations.of(context)!;
    try {
      await _chatNotifier.reactToMessage(msg, emoji);
    } catch (error) {
      _showSnackBar(l.reactionFailed(error.toString()));
    }
  }

  Future<void> _hideMessage(ConversationMessage msg) async {
    final l = AppLocalizations.of(context)!;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l.hideMessageDialogTitle),
        content: Text(l.hideMessageDialogBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(l.deleteAction),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await _chatNotifier.hideMessage(msg);
      _showSnackBar(l.messageHiddenForMe);
    } catch (error) {
      _showSnackBar(l.messageHideFailed(error.toString()));
    }
  }

  Future<void> _reportMessage(ConversationMessage msg) async {
    final l = AppLocalizations.of(context)!;
    final controller = TextEditingController(text: l.reportReasonDefault);
    final detailsController = TextEditingController();
    final result = await showDialog<({String reason, String? details})>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l.reportMessageTitle),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: controller,
              decoration: InputDecoration(labelText: l.reportReasonLabel),
              maxLength: 80,
            ),
            TextField(
              controller: detailsController,
              decoration: InputDecoration(labelText: l.reportDetailsLabel),
              maxLines: 3,
              maxLength: 1000,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(l.cancel),
          ),
          FilledButton(
            onPressed: () {
              final reason = controller.text.trim();
              if (reason.isEmpty) return;
              Navigator.pop(context, (
                reason: reason,
                details: detailsController.text.trim().isEmpty
                    ? null
                    : detailsController.text.trim(),
              ));
            },
            child: Text(l.submitAction),
          ),
        ],
      ),
    );
    controller.dispose();
    detailsController.dispose();
    if (result == null) return;
    try {
      await _chatNotifier.reportMessage(
        msg,
        reason: result.reason,
        details: result.details,
      );
      _showSnackBar(l.reportSubmitted);
    } catch (error) {
      _showSnackBar(l.reportFailed(error.toString()));
    }
  }

  Future<void> _acknowledgeMessage(
    ConversationMessage message,
    MessageAcknowledgementKind kind,
  ) async {
    try {
      await _chatNotifier.acknowledgeMessage(message, kind);
    } catch (error) {
      if (mounted) _showSnackBar('确认失败：$error');
    }
  }

  Future<void> _withdrawMessageAcknowledgement(
    ConversationMessage message,
  ) async {
    try {
      await _chatNotifier.withdrawMessageAcknowledgement(message);
    } catch (error) {
      if (mounted) _showSnackBar('撤销确认失败：$error');
    }
  }

  Future<void> _retryMessage(ConversationMessage message) async {
    final l = AppLocalizations.of(context)!;
    try {
      await _chatNotifier.retryMessage(message);
    } catch (error) {
      if (mounted) _showSnackBar(l.messageSendFailed(error.toString()));
    }
  }

  /// 确认编辑
  Future<void> _confirmEdit() async {
    try {
      final message = await _composerController.confirmEdit();
      if (!mounted || message == null) return;
      _showSnackBar(message);
    } on UserChatComposerException catch (e) {
      if (!mounted) return;
      _showSnackBar(e.message);
    }
  }

  Future<void> _sendMessage() async {
    // 如果正在编辑，先确认编辑
    if (_editingMessageId != null) {
      await _confirmEdit();
      return;
    }

    try {
      final quote = _pendingQuote;
      await _composerController.sendMessage(quote: quote);
      if (quote != null && mounted) {
        setState(() => _pendingQuote = null);
      }
    } on UserChatComposerException catch (e) {
      _showSnackBar(e.message);
    }
  }

  Future<void> _showQuotePicker() async {
    final l = AppLocalizations.of(context)!;
    final conversation = _conversation;
    if (conversation == null) return;
    final listingId = conversation.listingId;
    if (listingId == null || listingId.isEmpty) {
      _showSnackBar(l.quoteUnavailable);
      return;
    }
    final selected = await showModalBottomSheet<Map<String, String>>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                l.quotePickerTitle,
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                l.quotePickerSubtitle,
                style: const TextStyle(
                  color: AppTheme.textSecondary,
                  height: 1.35,
                ),
              ),
              const SizedBox(height: 12),
              ListTile(
                leading: const Icon(Icons.sell_outlined),
                title: Text(
                  conversation.listingTitle ?? l.quoteListingFallback,
                ),
                subtitle: Text(l.quoteListingSubtitle),
                onTap: () => Navigator.pop(context, {
                  'kind': 'listing',
                  'ref_id': listingId,
                }),
              ),
            ],
          ),
        ),
      ),
    );
    if (!mounted || selected == null) return;
    setState(() => _pendingQuote = selected);
  }

  void _clearPendingQuote() {
    setState(() => _pendingQuote = null);
  }

  Future<void> _pickAndSendImage() async {
    final l = AppLocalizations.of(context)!;
    if (!_canSend) {
      _showSnackBar(l.conversationCannotSendMessage);
      return;
    }

    final picked = await _imagePicker.pickImage(
      source: ImageSource.gallery,
      imageQuality: 65,
      maxWidth: 1280,
    );
    if (picked == null) {
      return;
    }

    try {
      await _mediaSender.sendPickedImage(
        picked,
        sendMessage:
            ({
              required String content,
              String? imageBase64,
              String? audioBase64,
              String? imageUrl,
              String? audioUrl,
            }) => _chatNotifier.sendMessage(
              content: content,
              imageBase64: imageBase64,
              audioBase64: audioBase64,
              imageUrl: imageUrl,
              audioUrl: audioUrl,
            ),
      );
    } on UserChatMediaSendException catch (e) {
      _showSnackBar(e.message);
    } catch (e) {
      _showSnackBar(l.messageSendFailed(e.toString()));
    }
  }

  /// 切换录音状态
  Future<void> _toggleRecording() async {
    await _sessionController.toggleRecording(
      canSendMedia: () => _canSend,
      sendMessage:
          ({
            required String content,
            String? imageBase64,
            String? audioBase64,
            String? imageUrl,
            String? audioUrl,
          }) => _chatNotifier.sendMessage(
            content: content,
            imageBase64: imageBase64,
            audioBase64: audioBase64,
            imageUrl: imageUrl,
            audioUrl: audioUrl,
          ),
      onError: _showSnackBar,
    );
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _showSnackBar(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 2)),
    );
  }

  Future<void> _loadReplySuggestions() async {
    if (!_canSend || _suggestionsLoading) return;
    setState(() {
      _suggestionsLoading = true;
      _suggestionsError = null;
    });
    try {
      final suggestions = await _chatNotifier.getReplySuggestions();
      if (!mounted) return;
      setState(() {
        _replySuggestions = suggestions;
        _suggestionsLoading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _suggestionsLoading = false;
        _suggestionsError = AppLocalizations.of(
          context,
        )!.replyAssistantUnavailable;
      });
    }
  }

  void _useSuggestion(ReplySuggestion suggestion) {
    _composerController.textController
      ..text = suggestion.text
      ..selection = TextSelection.collapsed(offset: suggestion.text.length);
    setState(() => _replySuggestions = const []);
  }

  Future<void> _closeConversation() async {
    final l = AppLocalizations.of(context)!;
    try {
      await _chatNotifier.closeConversation();
    } catch (error) {
      if (mounted) _showSnackBar(l.closeConversationFailed(error.toString()));
    }
  }

  Future<void> _blockUser() async {
    final l = AppLocalizations.of(context)!;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l.blockUserTitle),
        content: Text(l.blockUserBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(l.blockAction),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await _chatNotifier.blockOtherUser();
    } catch (error) {
      if (mounted) _showSnackBar(l.blockFailed(error.toString()));
    }
  }

  Future<void> _startCall(String media) async {
    final l = AppLocalizations.of(context)!;
    final conversation = _conversation;
    if (conversation == null ||
        conversation.state != ConversationState.active) {
      _showSnackBar(l.callRequiresActiveConversation);
      return;
    }
    try {
      await _chatService.createCall(
        conversationId: conversation.id,
        media: media,
        offerSdp:
            'goods4ncu-webrtc-offer-placeholder-${DateTime.now().millisecondsSinceEpoch}',
      );
      _showSnackBar(
        media == 'video' ? l.videoCallSignalSent : l.audioCallSignalSent,
      );
    } catch (error) {
      _showSnackBar(l.callStartFailed(error.toString()));
    }
  }

  Future<void> _restartConversation() async {
    final conversation = _conversation;
    if (conversation == null || !conversation.capabilities.canRestart) return;
    final next = await showContactConversationSheet(
      context: context,
      chatService: _chatService,
      recipientId: conversation.otherUserId,
      listingId: conversation.listingId,
      listingTitle: conversation.listingTitle,
      recipientName: conversation.otherUsername,
    );
    if (!mounted || next == null) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute<void>(
        builder: (_) => UserChatPage(
          conversationId: next.id,
          otherUserId: next.otherUserId,
          otherUsername: next.otherUsername,
        ),
      ),
    );
  }

  @override
  void didUpdateWidget(UserChatPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    // The same page object can be reused for a different conversation, in which
    // case initState does not run again. Without this the card from the
    // previous conversation stays on screen — showing one person's arrangement
    // inside another person's thread.
    if (oldWidget.conversationId != widget.conversationId ||
        oldWidget.otherUserId != widget.otherUserId) {
      setState(() {
        _agreement = null;
        _relationshipSpace = null;
        _otherPersona = null;
        _selfPersona = null;
        _otherAvatarUrl = null;
        _awaitingHandoff = false;
        _relationshipContextCanScroll = false;
        _relationshipContextAtEnd = false;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_relationshipContextScrollController.hasClients) {
          _relationshipContextScrollController.jumpTo(0);
        }
      });
      _loadArrangement();
      _loadRelationshipSpace();
      _loadPersonas();
      _loadOtherAvatar();
    }
  }

  /// The arrangement card and the handoff question, loaded lazily.
  ///
  /// Failures here are swallowed: neither is worth taking the conversation down
  /// for, and a chat that will not open because a card failed to load is a much
  /// worse outcome than a missing card.
  Future<void> _loadArrangement() async {
    try {
      final agreement = await _agreementService.ensure(
        widget.conversationId,
        'deal',
      );
      if (!mounted) return;
      setState(() => _agreement = agreement);
      if (agreement.isSettled) {
        final pending = await _reputationService.pending();
        if (!mounted) return;
        setState(() => _awaitingHandoff = pending.contains(agreement.id));
      }
    } catch (_) {}
  }

  Future<void> _loadRelationshipSpace() async {
    try {
      final space = await _chatService.getRelationshipSpace(widget.otherUserId);
      if (!mounted) return;
      setState(() => _relationshipSpace = space);
    } catch (_) {
      // The message path remains usable when the projection is unavailable;
      // this is an additive rail, never a second chat dependency.
    }
  }

  Future<void> _loadPersonas() async {
    final conversationId = widget.conversationId;
    final otherUserId = widget.otherUserId;
    final personas = await Future.wait<SocialPersona?>([
      _loadPublicPersona(otherUserId),
      _loadOwnPersona(),
    ]);
    if (!mounted ||
        widget.conversationId != conversationId ||
        widget.otherUserId != otherUserId) {
      return;
    }
    setState(() {
      _otherPersona = personas[0];
      _selfPersona = personas[1];
    });
  }

  Future<SocialPersona?> _loadPublicPersona(String userId) async {
    try {
      final persona = await _userService.getPublicSocialPersona(userId);
      // Public endpoints should already filter this server-side, but keep the
      // client fail-closed so a rolling upgrade or malformed response cannot
      // expose a draft/archived role in a relationship space.
      return persona?.isPublished == true ? persona : null;
    } catch (_) {
      // The role layer is optional. A public persona outage must not hide the
      // relationship timeline or make a message path fail.
      return null;
    }
  }

  Future<SocialPersona?> _loadOwnPersona() async {
    try {
      final persona = await _userService.getSocialPersona();
      // A private draft is useful on the profile editor, never as a public
      // anchor beside a message. Archive means ordinary avatar fallback.
      return persona?.isPublished == true ? persona : null;
    } catch (_) {
      return null;
    }
  }

  Future<void> _loadOtherAvatar() async {
    final conversationId = widget.conversationId;
    final otherUserId = widget.otherUserId;
    try {
      final profile = await _userService.getPublicUserProfile(otherUserId);
      if (!mounted ||
          widget.conversationId != conversationId ||
          widget.otherUserId != otherUserId) {
        return;
      }
      final avatarUrl = profile['avatar_url']?.toString();
      if (avatarUrl != null && avatarUrl.isNotEmpty) {
        setState(() {
          _otherAvatarUrl = avatarUrl;
        });
      }
    } catch (_) {
      // Safe fallback, failure does not block messaging
    }
  }

  bool _isMessagePinnedByMe(ConversationMessage message) {
    final currentUserId = _currentUserId;
    final messageId = int.tryParse(message.id);
    if (currentUserId == null ||
        messageId == null ||
        _relationshipSpace == null) {
      return false;
    }
    return _relationshipSpace!.pins.any(
      (pin) => pin.messageId == messageId && pin.actorId == currentUserId,
    );
  }

  Future<void> _togglePinMessage(ConversationMessage message) async {
    final l = AppLocalizations.of(context)!;
    try {
      if (_isMessagePinnedByMe(message)) {
        await _chatService.unpinMessage(message.id);
      } else {
        await _chatService.pinMessage(message.id);
      }
      await _loadRelationshipSpace();
    } catch (error) {
      if (mounted) _showSnackBar('${l.relationshipSpacePin}: $error');
    }
  }

  @override
  Widget build(BuildContext context) {
    final relationshipContext = <Widget>[
      if (!widget.embedded)
        RelationshipSpacePreview(
          otherName: _displayName,
          otherAvatarUrl: _otherAvatarUrl,
          otherPersona: _otherPersona,
          selfPersona: _selfPersona,
          events: _relationshipSpace?.events ?? const [],
          pins: _relationshipSpace?.pins ?? const [],
          pinCount: _relationshipSpace?.pins.length ?? 0,
          sharedObjects: _relationshipSpace?.sharedObjects ?? const [],
          sharedObjectCount: _relationshipSpace?.sharedObjects.length ?? 0,
          recentConnection: _relationshipSpace?.recentConnection,
          hasRecentConnection: _relationshipSpace?.recentConnection != null,
          isConnected: _conversation?.state == ConversationState.active,
          compact: true,
        ),
      // Pinned above the messages: the whole point is that "how much, when,
      // where" stops living in the scrollback.
      if (_agreement != null)
        AgreementCard(
          agreement: _agreement!,
          service: _agreementService,
          currentUserId: _currentUserId ?? '',
          onChanged: (updated) => setState(() {
            _agreement = updated;
            if (updated.isSettled) _awaitingHandoff = true;
          }),
        ),
      // Asked only after the arrangement was settled, and only once.
      if (_awaitingHandoff && _agreement != null)
        HandoffPrompt(
          agreementId: _agreement!.id,
          service: _reputationService,
          onAnswered: () => setState(() => _awaitingHandoff = false),
        ),
      if (_conversation != null)
        _ConversationProtocolBanner(
          conversation: _conversation!,
          onAccept: () => _acceptConnection(widget.conversationId),
          onDecline: () => _rejectConnection(widget.conversationId),
          onClose: _closeConversation,
          onRestart: _restartConversation,
        ),
    ];
    final relationshipContextMaxHeight =
        MediaQuery.sizeOf(context).height * (widget.embedded ? 0.5 : 0.44);
    if (relationshipContext.isNotEmpty) {
      _scheduleRelationshipContextMeasure();
    }
    final contextScheme = Theme.of(context).colorScheme;
    final pageBackground = Theme.of(context).scaffoldBackgroundColor;
    final body = Column(
      children: [
        if (widget.embedded) _buildEmbeddedHeader(),
        if (relationshipContext.isNotEmpty)
          ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: relationshipContextMaxHeight,
            ),
            child: Stack(
              children: [
                SingleChildScrollView(
                  controller: _relationshipContextScrollController,
                  key: const Key('relationship-context-scroll'),
                  child: Column(children: relationshipContext),
                ),
                if (_relationshipContextCanScroll && !_relationshipContextAtEnd)
                  Positioned(
                    key: const Key('relationship-context-scroll-hint'),
                    left: 0,
                    right: 0,
                    bottom: 6,
                    child: IgnorePointer(
                      child: Semantics(
                        label: AppLocalizations.of(
                          context,
                        )!.relationshipContextScrollHint,
                        excludeSemantics: true,
                        child: Align(
                          alignment: Alignment.bottomCenter,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: contextScheme.surfaceContainerHighest
                                  .withValues(alpha: 0.96),
                              border: Border.all(
                                color: contextScheme.outlineVariant,
                              ),
                              borderRadius: BorderRadius.circular(999),
                            ),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 5,
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    Icons.swipe_up_alt_rounded,
                                    size: 16,
                                    color: contextScheme.onSurfaceVariant,
                                  ),
                                  const SizedBox(width: 4),
                                  Text(
                                    AppLocalizations.of(
                                      context,
                                    )!.relationshipContextScrollHint,
                                    style: TextStyle(
                                      color: contextScheme.onSurfaceVariant,
                                      fontSize: 12,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        Expanded(
          child: UserChatMessageList(
            isLoading: _isLoading,
            error: _error,
            messages: _messages,
            currentUserId: _currentUserId,
            connectionStatus: _canSend ? 'connected' : _connectionStatus,
            scrollController: _scrollController,
            onRetry: _chatNotifier.loadMessages,
            onEditMessage: _startEditMessage,
            onReplyMessage: _startReplyMessage,
            onReactMessage: _reactToMessage,
            onAcknowledgeMessage: _acknowledgeMessage,
            onWithdrawAcknowledgement: _withdrawMessageAcknowledgement,
            onHideMessage: _hideMessage,
            onReportMessage: _reportMessage,
            onRetryMessage: _retryMessage,
            onTogglePinMessage: _togglePinMessage,
            isPinned: _isMessagePinnedByMe,
            allowEditing:
                !_isMail && _conversation?.state == ConversationState.active,
            deliveryOnly: _isMail,
          ),
        ),
        if (_canSend) _buildSuggestionArea(),
        UserChatInputArea(
          connectionStatus: _canSend ? 'connected' : _connectionStatus,
          unavailableMessage: _unavailableMessage,
          isRecording: _isRecording,
          recordingSeconds: _recordingSeconds,
          isSending: _isSending,
          isEditing: _editingMessageId != null,
          replyingToMessage: _replyingToMessage,
          structuredQuoteLabel: _pendingQuoteLabel,
          textController: _composerController.textController,
          onPickImage: _pickAndSendImage,
          onToggleRecording: _toggleRecording,
          onPickQuote: _showQuotePicker,
          onCancelQuote: _clearPendingQuote,
          onCancelEdit: _cancelEdit,
          onCancelReply: _cancelReply,
          onChanged: (_) {},
          onSubmitted: (_) => _sendMessage(),
          onSend: _editingMessageId != null ? _confirmEdit : _sendMessage,
        ),
      ],
    );
    if (widget.embedded) {
      return ColoredBox(color: pageBackground, child: body);
    }
    return Scaffold(
      backgroundColor: pageBackground,
      appBar: AppBar(
        title: Text(_displayName),
        actions: [_buildConversationMenu()],
      ),
      body: body,
    );
  }

  String? get _pendingQuoteLabel {
    final l = AppLocalizations.of(context)!;
    final quote = _pendingQuote;
    if (quote == null) return null;
    final kind = quote['kind'];
    if (kind == 'listing') {
      return l.quoteListingLabel(
        _conversation?.listingTitle ?? l.quoteListingFallback,
      );
    }
    if (kind == 'order') return l.quoteOrder;
    if (kind == 'hitl_offer') return l.quoteHitlOffer;
    return l.quoteGeneric;
  }

  String get _displayName {
    final l = AppLocalizations.of(context)!;
    final name = _conversation?.otherUsername ?? widget.otherUsername;
    return name.isEmpty ? l.conversationFallbackTitle : name;
  }

  String get _unavailableMessage {
    final l = AppLocalizations.of(context)!;
    final conversation = _conversation;
    if (conversation == null) return l.conversationLoadingState;
    if (conversation.isBlocked) return l.conversationUnavailable;
    return switch (conversation.state) {
      ConversationState.synSent =>
        conversation.isInitiator
            ? l.conversationWaitingPeer
            : l.conversationAcceptToReply,
      ConversationState.synAck => l.conversationCompletingHandshake,
      ConversationState.declined => l.conversationDeclinedTitle,
      ConversationState.cancelled => l.conversationCancelledTitle,
      ConversationState.expired => l.conversationExpiredTitle,
      ConversationState.closed => l.conversationClosedTitle,
      _ => l.conversationCannotSendMessage,
    };
  }

  Widget _buildEmbeddedHeader() {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final isActive = _conversation?.state == ConversationState.active;
    return Container(
      constraints: const BoxConstraints(minHeight: 64),
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
      decoration: BoxDecoration(
        color:
            theme.cardTheme.color ??
            (isDark ? AppTheme.surfaceDark : Colors.white),
        border: Border(
          bottom: BorderSide(color: theme.dividerColor.withValues(alpha: 0.5)),
        ),
      ),
      child: Row(
        children: [
          UserAvatar(
            name: _displayName,
            persona: _otherPersona,
            avatarUrl: _otherAvatarUrl,
            size: 48,
            showPersona: !isActive,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              _displayName,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
            ),
          ),
          _buildConversationMenu(),
        ],
      ),
    );
  }

  Widget _buildConversationMenu() {
    final l = AppLocalizations.of(context)!;
    return PopupMenuButton<String>(
      onSelected: (value) {
        if (value == 'close') {
          _closeConversation();
        }
        if (value == 'block') {
          _blockUser();
        }
        if (value == 'call_audio') {
          _startCall('audio');
        }
        if (value == 'call_video') {
          _startCall('video');
        }
      },
      itemBuilder: (context) => [
        if (_conversation?.state == ConversationState.active) ...[
          PopupMenuItem(value: 'call_audio', child: Text(l.audioCallMvp)),
          PopupMenuItem(value: 'call_video', child: Text(l.videoCallMvp)),
        ],
        if (_conversation?.capabilities.canClose == true)
          PopupMenuItem(value: 'close', child: Text(l.closeConversationAction)),
        PopupMenuItem(value: 'block', child: Text(l.blockAction)),
      ],
    );
  }

  Widget _buildSuggestionArea() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 4),
      color: const Color(0xFFFFF8ED),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_replySuggestions.isEmpty)
            TextButton.icon(
              onPressed: _suggestionsLoading ? null : _loadReplySuggestions,
              icon: _suggestionsLoading
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.auto_awesome_rounded, size: 18),
              label: Text(AppLocalizations.of(context)!.replyAssistantButton),
            )
          else
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: _replySuggestions
                  .map(
                    (suggestion) => ActionChip(
                      avatar: const Icon(Icons.chat_bubble_outline, size: 15),
                      label: Text(suggestion.text),
                      onPressed: () => _useSuggestion(suggestion),
                    ),
                  )
                  .toList(),
            ),
          if (_suggestionsError != null)
            Padding(
              padding: const EdgeInsets.only(left: 10, bottom: 4),
              child: Text(
                _suggestionsError!,
                style: const TextStyle(
                  fontSize: 12,
                  color: AppTheme.textSecondary,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _ConversationProtocolBanner extends StatelessWidget {
  const _ConversationProtocolBanner({
    required this.conversation,
    required this.onAccept,
    required this.onDecline,
    required this.onClose,
    required this.onRestart,
  });

  final Conversation conversation;
  final VoidCallback onAccept;
  final VoidCallback onDecline;
  final VoidCallback onClose;
  final VoidCallback onRestart;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    if (conversation.mode == ConversationMode.mail) {
      return _banner(
        color: const Color(0xFFC66B32),
        icon: Icons.mark_email_unread_outlined,
        title: conversation.subject ?? l.mailFallbackTitle,
        subtitle: l.mailProtocolSubtitle,
      );
    }
    final remaining = _remaining(context, conversation.expiresAt);
    switch (conversation.state) {
      case ConversationState.synSent:
        if (conversation.capabilities.canRespond) {
          return _banner(
            color: AppTheme.primary,
            icon: Icons.wifi_tethering,
            title: l.incomingRealtimeTitle,
            subtitle: remaining == null
                ? l.incomingRealtimeSubtitle
                : l.incomingRealtimeExpiring(remaining),
            actions: [
              TextButton(onPressed: onDecline, child: Text(l.notConvenientNow)),
              FilledButton(onPressed: onAccept, child: Text(l.connectAction)),
            ],
          );
        }
        return _banner(
          color: AppTheme.warning,
          icon: Icons.radar_rounded,
          title: l.waitingPeerTitle,
          subtitle: remaining == null
              ? l.invitationDelivered
              : l.timeRemaining(remaining),
          actions: [
            TextButton(onPressed: onClose, child: Text(l.cancelInvitation)),
          ],
        );
      case ConversationState.synAck:
        return _banner(
          color: AppTheme.warning,
          icon: Icons.sync_rounded,
          title: conversation.isInitiator
              ? l.confirmingConnectionTitle
              : l.peerRespondedWaitingTitle,
          subtitle: remaining == null
              ? l.confirmingConnectionSubtitle
              : l.connectionReleaseAfter(remaining),
        );
      case ConversationState.active:
        return _banner(
          color: AppTheme.success,
          icon: Icons.bolt_rounded,
          title: l.realtimeConnectedTitle,
          subtitle: remaining == null
              ? l.realtimeConnectedSubtitle
              : l.realtimeExpiresAfterIdle(remaining),
          actions: [TextButton(onPressed: onClose, child: Text(l.endAction))],
        );
      case ConversationState.declined:
      case ConversationState.cancelled:
      case ConversationState.expired:
      case ConversationState.closed:
        return _banner(
          color: AppTheme.textSecondary,
          icon: Icons.check_circle_outline,
          title: _terminalTitle(l, conversation.state),
          subtitle: l.conversationTerminalSubtitle,
          actions: !conversation.capabilities.canRestart
              ? const []
              : [
                  TextButton(
                    onPressed: onRestart,
                    child: Text(l.conversationReconnect),
                  ),
                ],
        );
      case ConversationState.open:
        return const SizedBox.shrink();
    }
  }

  Widget _banner({
    required Color color,
    required IconData icon,
    required String title,
    required String subtitle,
    List<Widget> actions = const [],
  }) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 10, 12, 10),
      color: color.withValues(alpha: 0.09),
      child: Row(
        children: [
          Icon(icon, color: color, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(color: color, fontWeight: FontWeight.w800),
                ),
                Text(
                  subtitle,
                  style: const TextStyle(
                    fontSize: 12,
                    color: AppTheme.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          ...actions,
        ],
      ),
    );
  }

  String? _remaining(BuildContext context, DateTime? expiry) {
    final l = AppLocalizations.of(context)!;
    if (expiry == null) return null;
    final duration = expiry.difference(DateTime.now());
    if (duration.isNegative) return '0:00';
    if (duration.inHours > 0) {
      return l.durationHoursMinutes(
        duration.inHours,
        duration.inMinutes.remainder(60),
      );
    }
    return '${duration.inMinutes}:${duration.inSeconds.remainder(60).toString().padLeft(2, '0')}';
  }

  String _terminalTitle(AppLocalizations l, ConversationState state) =>
      switch (state) {
        ConversationState.declined => l.conversationDeclinedTitle,
        ConversationState.cancelled => l.conversationCancelledTitle,
        ConversationState.expired => l.conversationNaturallyEndedTitle,
        _ => l.conversationClosedTitle,
      };
}
