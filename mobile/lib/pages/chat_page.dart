import 'dart:async';
import 'package:flutter/gestures.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import '../components/assistant_memory_panel.dart';
import '../components/price_tag.dart';
import '../l10n/app_localizations.dart';
import 'package:image_picker/image_picker.dart';
import 'package:uuid/uuid.dart';
import '../services/negotiate_service.dart';
import '../services/user_service.dart';
import '../services/chat_service.dart';
import '../services/companion_character_service.dart';
import '../services/agent_stream_event.dart';
import '../services/sse_service.dart';
import '../services/upload_service.dart';
import '../services/companion_memory_service.dart';
import '../companion/cubism/expression_lab.dart';
import '../services/post_service.dart';
import '../services/ws_service.dart';
import '../models/models.dart';
import '../models/post.dart' as post;
import '../companion/companion_config.dart';
import '../companion/companion_events.dart';
import '../companion/environment.dart';
import '../companion/working_memory.dart';
import '../companion/relationship_signals.dart';
import '../companion/cubism/cubism_body.dart';
import '../companion/fallback_body_adapter.dart';
import '../companion/runtime_host.dart';
import '../companion/attention.dart';
import '../companion/state_machine.dart';
import 'package:provider/provider.dart' as p2;
import '../components/assistant_markdown.dart';
import '../components/live2d/live2d_character_widget.dart';
import '../components/live2d/live2d_controller.dart';
import '../components/live2d/live2d_lipsync_driver.dart';
import '../components/unified_message_composer.dart';
import 'chat_page_media_sender.dart';
import '../widgets/chat/assistant_header.dart';
import '../widgets/chat/negotiation_card.dart';

class ChatPage extends StatefulWidget {
  final ChatService? chatService;
  final UserService? userService;
  final NegotiateService? negotiateService;
  final SseService? sseService;
  final UploadService? uploadService;
  final PostService? postService;
  final ChatPageMediaSender? mediaSender;
  final String? initialPrompt;
  final Map<String, dynamic>? pageContext;
  final bool embedded;
  final VoidCallback? onConversationUpdated;

  const ChatPage({
    super.key,
    this.chatService,
    this.userService,
    this.negotiateService,
    this.sseService,
    this.uploadService,
    this.postService,
    this.mediaSender,
    this.initialPrompt,
    this.pageContext,
    this.embedded = false,
    this.onConversationUpdated,
  });

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  static const _uuid = Uuid();
  final TextEditingController _controller = TextEditingController();
  final FocusNode _composerFocusNode = FocusNode();
  final List<ChatMessage> _messages = [];
  late final ChatService _chatService;
  late final UserService _userService;
  late final NegotiateService _negotiateService;
  late final SseService _sseService;
  late final bool _ownsSseService;
  late final UploadService _uploadService;
  late final ChatPageMediaSender _mediaSender;
  final ImagePicker _picker = ImagePicker();

  XFile? _selectedImage;
  Uint8List? _selectedImageBytes;
  bool _isStreaming = false;
  bool _isLoadingHistory = true;
  String? _historyError;
  String? _currentUserId;

  // Active HITL requests shown as cards in the chat.
  List<HitlRequest> _hitlRequests = [];
  List<AgentPlan> _agentPlans = [];
  // Actions the assistant already performed that are still reversible. Kept
  // separate from _agentPlans: those await the user, these have happened.
  List<UndoableAction> _undoableActions = [];
  final List<post.CampusPost> _agentResultPosts = [];
  final ScrollController _agentResultsController = ScrollController();
  _PendingReference? _pendingReference;
  bool _stageExpanded = true;
  final ScrollController _messageListController =
      ScrollController(); // listener attached in initState

  /// Whether the viewport is hugging the bottom edge; only then does the
  /// list auto-jump on rebuild, so streaming never yanks the user upward.
  bool _pinnedToBottom = true;

  /// Quick-suggestion labels pulled from the user's enabled skills.
  List<String> _skillChips = const [];

  String? _chipLabelOf(Map<String, dynamic> skill) {
    if (skill['enabled'] != true) return null;
    final chip = (skill['chip_label'] as String?)?.trim();
    return (chip == null || chip.isEmpty) ? null : chip;
  }

  Future<void> _loadSkillChips() async {
    try {
      final skills = await context.read<CompanionMemoryService>().listSkills();
      if (!mounted) return;
      setState(() {
        _skillChips = [for (final skill in skills) ?_chipLabelOf(skill)];
      });
    } catch (_) {
      // Suggestion chips are cosmetic; never block chat on this.
    }
  }

  String? _focusedAgentPostId;
  Timer? _undoTicker;

  StreamSubscription? _wsSubscription;

  late final Live2DController _live2DController;
  late final Live2DLipSyncDriver _lipSyncDriver;
  late final PostService _postService;
  CompanionRuntimeHost? _companionHost;
  EnvironmentTracker? _environmentTracker;
  final WorkingMemory _workingMemory = WorkingMemory();
  final CompanionRelationshipSignals _relationshipSignals =
      CompanionRelationshipSignals();

  @override
  void initState() {
    super.initState();
    _messageListController.addListener(_onMessageScroll);
    _live2DController = Live2DController();
    _loadSkillChips();
    CompanionCharacterService.instance
      ..load()
      ..addListener(_onCompanionCharacterChanged);
    _syncBrainWithPageContext();
    _lipSyncDriver = Live2DLipSyncDriver(controller: _live2DController);
    _userService = widget.userService ?? context.read<UserService>();
    _negotiateService =
        widget.negotiateService ?? context.read<NegotiateService>();
    _chatService = widget.chatService ?? context.read<ChatService>();
    _ownsSseService = widget.sseService == null;
    _sseService = widget.sseService ?? SseService();
    _uploadService = widget.uploadService ?? context.read<UploadService>();
    _postService = widget.postService ?? context.read<PostService>();
    _mediaSender =
        widget.mediaSender ??
        ChatPageMediaSender(uploadService: _uploadService);
    if (kCompanionEnabled) {
      _companionHost = p2.Provider.of<CompanionRuntimeHost?>(
        context,
        listen: false,
      );
      // Body takeover cut 1: the Director drives 小昌's body. Attach the
      // real Cubism renderer only when the runtime is actually usable;
      // otherwise the legacy sprite adapter keeps the body alive (§74).
      _companionOwnsBodyFlag =
          _companionHost != null && cubismRuntimeSupported();
      if (_companionOwnsBodyFlag) {
        _companionHost!.attachBody(createCubismRendererOrNull()!);
        _companionHost!.mouthSampler = () => _live2DController.mouthOpen;
      } else {
        _companionHost?.attachBody(FallbackBodyRenderer(_live2DController));
        _companionHost?.mouthSampler = () => _live2DController.mouthOpen;
      }
      _live2DController.detachBrain();
      _environmentTracker = EnvironmentTracker(
        state: EnvironmentState(),
        onMeaningfulEvent: (event) {
          _companionHost?.bus.emit(CompanionEventType.environmentChanged, {
            'type': event.type.name,
            ...event.payload,
          });
        },
      );
      _syncEnvironmentTracker();
      // §14: returning to the companion counts once per session.
      _chatService
          .recordCompanionRelationshipEvent('user_returns')
          .catchError((_) => <String, dynamic>{});
    }
    _controller.addListener(_onComposerChanged);
    _connectWs();
    WidgetsBinding.instance.addPostFrameCallback((_) => _initialize());
  }

  Timer? _typingDebounce;

  Map<String, dynamic> _buildPageContext() {
    return {
      'page': 'chat',
      ...?widget.pageContext,
      if (kCompanionEnabled) ..._workingMemory.toPromptFragment(),
    };
  }

  @override
  void didUpdateWidget(covariant ChatPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.pageContext != widget.pageContext) {
      _syncBrainWithPageContext();
      _syncEnvironmentTracker();
      _focusedAgentPostId = widget.pageContext?['postId']?.toString();
    }
  }

  void _syncEnvironmentTracker() {
    final tracker = _environmentTracker;
    if (tracker == null) return;
    final ctx = widget.pageContext;
    if (ctx == null) return;
    final page = ctx['page']?.toString() ?? 'chat';
    final listingId = ctx['listingId']?.toString();
    final postId = ctx['postId']?.toString();
    tracker.track(
      EnvironmentEvent(
        EnvironmentEventType.pageChanged,
        payload: {'page': page},
      ),
    );
    if (listingId != null || postId != null) {
      tracker.trackPostOpened(postId: postId, listingId: listingId);
    }
  }

  /// When the companion owns the body, legacy brain feeds must stay silent.
  bool get _useLegacyBrain => !(kCompanionEnabled && _companionHost != null);

  bool _companionOwnsBodyFlag = false;

  /// Companion owns the body AND the real Cubism model is renderable here.
  bool get _companionOwnsBody =>
      _useLegacyBrain == false && _companionOwnsBodyFlag;

  static final RegExp _thanksPattern = RegExp(
    r'谢谢|感谢|thx|thanks',
    caseSensitive: false,
  );

  void _recordRelationshipEvent(String event) {
    _chatService
        .recordCompanionRelationshipEvent(event)
        .then(
          (_) => _companionHost?.bus.emit(
            CompanionEventType.relationshipChanged,
            {'event': event},
          ),
        )
        .catchError((_) => <String, dynamic>{});
  }

  void _companionTurnStart() {
    final host = _companionHost;
    if (host == null) return;
    host.machine.transition(CompanionState.listening);
  }

  void _companionOnTool(String tool) {
    _companionHost?.bus.emit(CompanionEventType.toolStarted, {'tool': tool});
    _companionHost?.onSignal('tool_using_$tool');
  }

  void _companionOnUiAction(String type) {
    final host = _companionHost;
    host?.onSignal(type);
    switch (type) {
      case 'SHOW_POSTS' || 'SHOW_RELATED_POSTS':
        host?.attention.lookAt(AttentionTarget.postList);
      case 'HIGHLIGHT_POST' || 'SCROLL_TO_POST' || 'OPEN_POST':
        host?.attention.lookAt(AttentionTarget.post);
      case 'OPEN_PROFILE':
        host?.attention.lookAt(AttentionTarget.none);
    }
  }

  void _companionOnFirstToken() {
    _companionHost?.machine.transition(CompanionState.speaking);
    _companionHost?.bus.emit(CompanionEventType.agentResponseStart);
  }

  void _companionOnStreamEnd({required bool failed}) {
    final host = _companionHost;
    if (host == null) return;
    host.bus.emit(
      failed
          ? CompanionEventType.interrupted
          : CompanionEventType.agentResponseEnd,
      {},
    );
    host.machine.transition(
      failed ? CompanionState.error : CompanionState.idle,
    );
    if (!failed) {
      host.machine.transition(CompanionState.idle);
    }
  }

  void _syncBrainWithPageContext() {
    final pageContext = widget.pageContext;
    if (pageContext == null) {
      if (_useLegacyBrain) _live2DController.brain.onPageChanged('chat');
      return;
    }
    final page = pageContext['page']?.toString() ?? 'chat';
    final listingId = pageContext['listingId']?.toString();
    if (_useLegacyBrain) {
      _live2DController.brain.onPageChanged(page, listingId: listingId);
    }
  }

  void _handleUiAction(Map<String, dynamic> action) {
    final type = action['type'] as String?;
    final payload = action['payload'] as Map<String, dynamic>?;
    if (payload == null) return;
    switch (type) {
      case 'SHOW_POSTS' || 'SHOW_RELATED_POSTS':
        final ids = payload['postIds'];
        if (ids is List && ids.isNotEmpty) {
          _loadAgentResultPosts(
            ids,
            relatedToPostId: type == 'SHOW_RELATED_POSTS'
                ? payload['sourcePostId']?.toString()
                : null,
          );
        }
      case 'HIGHLIGHT_POST' || 'SCROLL_TO_POST':
        final postId = payload['postId']?.toString();
        if (postId != null && postId.isNotEmpty) {
          if (_useLegacyBrain) _live2DController.brain.onFocusPost(postId);
          _loadFocusedAgentPost(postId);
        }
      case 'OPEN_POST':
        final postId = payload['postId']?.toString();
        if (postId != null && postId.isNotEmpty) {
          _openAgentPost(postId);
        }
      case 'OPEN_PROFILE':
        final userId = payload['userId']?.toString();
        if (userId != null && userId.isNotEmpty) {
          context.push('/users/$userId');
        }
      case 'OPEN_COMMENT_DRAFT':
        final commentDraft = payload['draftText']?.toString();
        final targetPostId = payload['postId']?.toString();
        if (commentDraft != null &&
            targetPostId != null &&
            targetPostId.isNotEmpty) {
          if (_useLegacyBrain) _live2DController.brain.onDraftReady();
          _showCommentDraftConfirmation(commentDraft, targetPostId);
        }
      case 'OPEN_MESSAGE_DRAFT':
        final draftText = payload['draftText']?.toString();
        final listingId = payload['listingId']?.toString();
        final receiverId = payload['receiverId']?.toString();
        if (draftText != null && listingId != null && receiverId != null) {
          if (_useLegacyBrain) _live2DController.brain.onDraftReady();
          _showDraftConfirmation(draftText, listingId, receiverId);
        }
    }
  }

  /// Friendly per-tool status shown while 小昌 works (never raw tool JSON).
  String _toolActivityLabel(AppLocalizations l, String tool) {
    switch (tool) {
      case 'search_inventory':
        return l.agentToolSearchingPosts;
      case 'get_listing_details':
        return l.agentToolInspectingListing;
      case 'find_related_posts':
        return l.agentToolFindingRelated;
      case 'get_user_posts':
        return l.agentToolBrowsingUserPosts;
      case 'get_comments':
        return l.agentToolReadingComments;
      case 'get_my_listings':
        return l.agentToolOrganizingListings;
      case 'draft_message':
        return l.agentToolDraftingMessage;
      case 'create_listing':
        return l.agentToolPreparingPublish;
      case 'negotiate_item':
        return l.agentToolPreparingOffer;
      default:
        return l.agentToolWorking;
    }
  }

  Future<void> _loadAgentResultPosts(
    List<dynamic> ids, {
    String? relatedToPostId,
  }) async {
    final posts = await Future.wait([
      for (final id in ids.take(8)) _loadAgentPost(id.toString()),
    ]);
    if (!mounted) return;
    setState(() {
      _agentResultPosts
        ..clear()
        ..addAll(posts.whereType<post.CampusPost>());
      _focusedAgentPostId = null;
    });
    if (_useLegacyBrain) {
      _live2DController.brain.onSearchResultsShown(
        count: _agentResultPosts.length,
        relatedToPostId: relatedToPostId,
      );
    }
  }

  Future<post.CampusPost?> _loadAgentPost(String id) async {
    try {
      return await _postService.getPostByListing(id);
    } catch (_) {
      try {
        return await _postService.getPost(id);
      } catch (_) {
        return null;
      }
    }
  }

  Future<void> _openAgentPost(String postId) async {
    final post = await _loadAgentPost(postId);
    if (!mounted) return;
    final listingId = post?.listingId;
    if (listingId != null && listingId.isNotEmpty) {
      await context.push('/listing/$listingId');
    } else {
      await context.push('/posts/$postId');
    }
  }

  void _loadFocusedAgentPost(String listingId) {
    _loadAgentPost(listingId).then((focusedPost) {
      if (!mounted || focusedPost == null) return;
      setState(() {
        if (!_agentResultPosts.any(
          (candidate) => candidate.id == focusedPost.id,
        )) {
          _agentResultPosts.add(focusedPost);
        }
        _focusedAgentPostId = focusedPost.id;
      });
    });
  }

  Widget? get _agentResultsStrip {
    if (_agentResultPosts.isEmpty) return null;
    final l = AppLocalizations.of(context)!;
    final scheme = Theme.of(context).colorScheme;
    return Container(
      color: scheme.surfaceContainerLow,
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Text(
              l.assistantAgentResultTitle,
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                fontWeight: FontWeight.w700,
                color: scheme.primary,
              ),
            ),
          ),
          SizedBox(
            height: 172,
            child: ScrollConfiguration(
              behavior: ScrollConfiguration.of(context).copyWith(
                dragDevices: const {
                  PointerDeviceKind.mouse,
                  PointerDeviceKind.touch,
                  PointerDeviceKind.stylus,
                  PointerDeviceKind.trackpad,
                },
              ),
              child: Scrollbar(
                controller: _agentResultsController,
                thumbVisibility: false,
                child: ListView.builder(
                  controller: _agentResultsController,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  scrollDirection: Axis.horizontal,
                  itemCount: _agentResultPosts.length,
                  itemBuilder: (context, index) {
                    final post = _agentResultPosts[index];
                    final focused = post.id == _focusedAgentPostId;
                    return _AgentResultCard(
                      item: post,
                      focused: focused,
                      onReference: () => _attachPostReference(post),
                    );
                  },
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _showDraftConfirmation(
    String text,
    String listingId,
    String receiverId,
  ) {
    final l = AppLocalizations.of(context);
    _live2DController.showSpeechBubble(l?.assistantDraftReadyBubble ?? '');
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l!.assistantConfirmSendMessage),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Theme.of(ctx).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(12),
              ),
              child: SelectableText(text),
            ),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () {
                    _live2DController.setExpression(Live2DExpression.idle);
                    Navigator.of(ctx).pop();
                  },
                  child: Text(l.cancel),
                ),
                OutlinedButton(
                  onPressed: () {
                    Navigator.of(ctx).pop();
                    // Let user edit in composer before sending
                    _controller.text = text;
                    _live2DController.showSpeechBubble(
                      l.assistantDraftEditBubble,
                    );
                  },
                  child: Text(l.edit),
                ),
                const SizedBox(width: 4),
                FilledButton(
                  onPressed: () async {
                    Navigator.of(ctx).pop();
                    await _sendAgentMessage(text, listingId, receiverId);
                  },
                  child: Text(l.send),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  void _showCommentDraftConfirmation(String text, String postId) {
    final l = AppLocalizations.of(context);
    _live2DController.showSpeechBubble(l?.assistantDraftReadyBubble ?? '');
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l!.assistantConfirmSendReply),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Theme.of(ctx).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(12),
              ),
              child: SelectableText(text),
            ),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () {
                    _live2DController.setExpression(Live2DExpression.idle);
                    Navigator.of(ctx).pop();
                  },
                  child: Text(l.cancel),
                ),
                OutlinedButton(
                  onPressed: () {
                    Navigator.of(ctx).pop();
                    // Let user edit in composer before posting
                    _controller.text = text;
                    _live2DController.showSpeechBubble(
                      l.assistantDraftEditBubble,
                    );
                  },
                  child: Text(l.edit),
                ),
                const SizedBox(width: 4),
                FilledButton(
                  onPressed: () async {
                    Navigator.of(ctx).pop();
                    await _publishAgentReply(text, postId);
                  },
                  child: Text(l.send),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _publishAgentReply(String text, String postId) async {
    try {
      await _postService.createReply(postId, body: text);
      if (!mounted) return;
      final l = AppLocalizations.of(context)!;
      if (_useLegacyBrain) {
        _live2DController.brain.onDraftSendComplete(succeeded: true);
      }
      _live2DController.setExpression(Live2DExpression.happy);
      _live2DController.showSpeechBubble(l.assistantSentBubble);
    } catch (e) {
      if (!mounted) return;
      final l = AppLocalizations.of(context)!;
      if (_useLegacyBrain) {
        _live2DController.brain.onDraftSendComplete(succeeded: false);
      }
      _live2DController.setExpression(Live2DExpression.surprised);
      _live2DController.showSpeechBubble(l.assistantSendFailedBubble);
    }
  }

  Future<void> _sendAgentMessage(
    String text,
    String listingId,
    String receiverId,
  ) async {
    try {
      await _chatService.sendMessage('listing:$listingId', content: text);
      if (!mounted) return;
      final l = AppLocalizations.of(context)!;
      if (_useLegacyBrain) {
        _live2DController.brain.onDraftSendComplete(succeeded: true);
      }
      _live2DController.setExpression(Live2DExpression.happy);
      _live2DController.showSpeechBubble(l.assistantSentBubble);
    } catch (e) {
      if (!mounted) return;
      final l = AppLocalizations.of(context)!;
      if (_useLegacyBrain) {
        _live2DController.brain.onDraftSendComplete(succeeded: false);
      }
      _live2DController.setExpression(Live2DExpression.surprised);
      _live2DController.showSpeechBubble(l.assistantSendFailedBubble);
    }
  }

  void _onComposerChanged() {
    if (_useLegacyBrain) {
      _live2DController.brain.onUserTyping();
    } else {
      _companionHost?.attention.lookAt(
        AttentionTarget.chat,
        lockFor: const Duration(seconds: 1),
      );
    }
    _typingDebounce?.cancel();
    _typingDebounce = Timer(const Duration(milliseconds: 1500), () {
      if (_useLegacyBrain) _live2DController.brain.onUserTypingStopped();
    });
  }

  Future<void> _initialize() async {
    await Future.wait([_loadCurrentUser(), _loadAssistantHistory()]);
    if (!mounted) return;
    if (_messages.isEmpty) {
      final l = AppLocalizations.of(context)!;
      _live2DController.showSpeechBubble(l.aiGreeting);
      setState(() {
        _messages.add(
          ChatMessage(
            sender: 'bot',
            content: l.aiGreeting,
            timestamp: DateTime.now(),
          ),
        );
      });
    } else {
      final lastBot = _messages.reversed.firstWhere(
        (m) => m.sender == 'bot',
        orElse: () => _messages.last,
      );
      _live2DController.showSpeechBubble(lastBot.content);
    }
    final initialPrompt = widget.initialPrompt?.trim();
    if (initialPrompt != null && initialPrompt.isNotEmpty) {
      _controller.text = initialPrompt;
      await _sendMessage();
    }
  }

  Future<void> _loadAssistantHistory() async {
    try {
      final history = await _chatService.getAssistantHistory();
      if (!mounted) return;
      setState(() {
        _messages
          ..clear()
          ..addAll(history.messages);
        _isLoadingHistory = false;
        _historyError = null;
      });
      if (_messages.isNotEmpty) {
        final lastBot = _messages.reversed.firstWhere(
          (m) => m.sender == 'bot',
          orElse: () => _messages.last,
        );
        _live2DController.showSpeechBubble(lastBot.content);
      }
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _isLoadingHistory = false;
        _historyError = error.toString();
      });
    }
  }

  Future<void> _loadCurrentUser() async {
    try {
      final profile = await _userService.getUserProfile();
      if (!mounted) return;
      setState(() {
        _currentUserId = profile['user_id']?.toString();
      });
      await _loadNegotiations();
      await _loadAgentPlans();
      await _loadUndoableActions();
    } catch (_) {}
  }

  Future<void> _loadNegotiations() async {
    try {
      final requests = await _negotiateService.getNegotiations();
      if (!mounted) return;
      setState(() {
        _hitlRequests = requests
            .where((r) => r.isPending || r.isCountered || r.isExpired)
            .toList();
      });
    } catch (_) {}
  }

  Future<void> _loadAgentPlans() async {
    try {
      final plans = await _chatService.getAgentPlans();
      if (!mounted) return;
      setState(() => _agentPlans = plans);
    } catch (_) {}
  }

  Future<void> _loadUndoableActions() async {
    try {
      final actions = await _chatService.getUndoableActions();
      if (!mounted) return;
      setState(() {
        _undoableActions = actions.where((a) => !a.expired).toList();
      });
      _syncUndoTicker();
    } catch (_) {}
  }

  /// Drives the countdown, and only while something is actually undoable — a
  /// permanent one-second timer would repaint the whole chat forever.
  void _syncUndoTicker() {
    if (_undoableActions.isEmpty) {
      _undoTicker?.cancel();
      _undoTicker = null;
      return;
    }
    _undoTicker ??= Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      final live = _undoableActions.where((a) => !a.expired).toList();
      setState(() => _undoableActions = live);
      if (live.isEmpty) _syncUndoTicker();
    });
  }

  Future<void> _undo(UndoableAction action) async {
    final l = AppLocalizations.of(context)!;
    // Drop it from the strip immediately: leaving a button the user already
    // pressed invites a second press, and the answer will be the same anyway.
    setState(
      () => _undoableActions = _undoableActions
          .where((a) => a.id != action.id)
          .toList(),
    );
    try {
      final result = await _chatService.undoAction(action.id);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            result.message.isEmpty
                ? (result.undone ? l.undoSucceeded : l.undoConflict)
                : result.message,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l.undoFailed)));
    }
    await _loadUndoableActions();
  }

  Future<void> _confirmAgentPlan(AgentPlan plan) async {
    final l = AppLocalizations.of(context)!;
    try {
      // An armed plan has already consumed its primary token. This can happen
      // after a reload, a lost first response, or when the user dismissed the
      // second-confirmation dialog earlier. Never send its execution token
      // until the user has explicitly accepted the high-risk dialog.
      String token = plan.confirmationToken;
      if (plan.isHighRisk && plan.isArmed) {
        final proceed = await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: Text(l.agentPlanSecondConfirmTitle),
            content: Text(plan.summary),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: Text(l.cancel),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(dialogContext, true),
                child: Text(l.agentPlanSecondConfirmAction),
              ),
            ],
          ),
        );
        if (proceed != true || !mounted) {
          await _loadAgentPlans();
          return;
        }
      }

      var outcome = await _chatService.confirmAgentPlan(plan.id, token);
      if (!mounted) return;
      if (outcome.needsSecondConfirmation) {
        // The primary token can only arm an L3 plan. Execution requires the
        // freshly rotated token returned by that transition; reusing the
        // primary token must remain a transport-idempotent no-op.
        final secondToken = outcome.confirmationToken;
        if (secondToken == null || secondToken.isEmpty) {
          await _loadAgentPlans();
          throw StateError('Second confirmation token was not returned');
        }

        final proceed = await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: Text(l.agentPlanSecondConfirmTitle),
            content: Text(plan.summary),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: Text(l.cancel),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(dialogContext, true),
                child: Text(l.agentPlanSecondConfirmAction),
              ),
            ],
          ),
        );
        if (proceed != true || !mounted) {
          await _loadAgentPlans();
          return;
        }
        token = secondToken;
        outcome = await _chatService.confirmAgentPlan(plan.id, token);
        if (!mounted) return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            outcome.result.isEmpty ? l.agentPlanExecuted : outcome.result,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l.operationFailed(e.toString()))));
    }
    await _loadAgentPlans();
  }

  Future<void> _cancelAgentPlan(AgentPlan plan) async {
    final l = AppLocalizations.of(context)!;
    try {
      await _chatService.cancelAgentPlan(plan.id);
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l.agentPlanCancelled)));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l.operationFailed(e.toString()))));
    }
    await _loadAgentPlans();
  }

  void _connectWs() {
    _wsSubscription = WsService.instance.stream.listen((notification) {
      _handleWsNotification(notification);
    });
  }

  void _handleWsNotification(WsNotification notif) {
    if (!mounted) return;
    // Show a snackbar for real-time negotiation updates.
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('${notif.title}: ${notif.body}'),
        duration: const Duration(seconds: 4),
        action: notif.negotiationId != null
            ? SnackBarAction(
                label: AppLocalizations.of(context)!.viewAction,
                onPressed: _loadNegotiations,
              )
            : null,
      ),
    );
    // Refresh negotiation list if relevant.
    if (notif.eventType.startsWith('negotiation')) {
      _loadNegotiations();
    }
  }

  void _onCompanionCharacterChanged() {
    if (mounted) setState(() {});
  }

  void _onMessageScroll() {
    final position = _messageListController.position;
    if (!position.hasContentDimensions) return;
    final atBottom = position.maxScrollExtent - position.pixels < 120;
    if (atBottom != _pinnedToBottom && mounted) {
      setState(() => _pinnedToBottom = atBottom);
    }
  }

  @override
  void dispose() {
    _agentResultsController.dispose();
    _messageListController.removeListener(_onMessageScroll);
    _messageListController.dispose();
    CompanionCharacterService.instance.removeListener(
      _onCompanionCharacterChanged,
    );
    _lipSyncDriver.dispose();
    _live2DController.dispose();
    _typingDebounce?.cancel();
    _controller.dispose();
    _composerFocusNode.dispose();
    if (_ownsSseService) _sseService.dispose();
    _wsSubscription?.cancel();
    _undoTicker?.cancel();
    super.dispose();
  }

  Future<void> _pickImage() async {
    final XFile? image = await _picker.pickImage(
      source: ImageSource.gallery,
      imageQuality: 50,
      maxWidth: 1024,
    );
    if (image != null) {
      final bytes = await image.readAsBytes();
      setState(() {
        _selectedImage = image;
        _selectedImageBytes = bytes;
      });
    }
  }

  /// Send a message using SSE streaming (token-by-token render).
  void _attachPostReference(post.CampusPost item) {
    final isListing = item.listingId != null && item.listingId!.isNotEmpty;
    setState(() {
      _pendingReference = _PendingReference(
        kind: isListing ? 'listing' : 'post',
        refId: (isListing ? item.listingId : item.id) ?? item.id,
        title: item.title,
      );
    });
  }

  /// Bottom-sheet picker: recently-viewed posts plus keyword search.
  Future<void> _showReferencePicker() async {
    final picked = await showModalBottomSheet<post.CampusPost>(
      context: context,
      useSafeArea: true,
      showDragHandle: true,
      constraints: const BoxConstraints(maxWidth: 640),
      builder: (sheetContext) => _ReferencePickerSheet(
        postService: _postService,
        recentIds: List<String>.from(_workingMemory.recentPostIds),
      ),
    );
    if (picked == null || !mounted) return;
    _attachPostReference(picked);
  }

  Future<void> _stopStreaming() async {
    if (!_isStreaming) return;
    // Signal the server to cancel the turn using the assistant conversation.
    try {
      await _sseService.cancelTurn('__agent__');
    } catch (_) {}
    // Close the local SSE stream so no more chunks arrive.
    _sseService.disconnect();
    setState(() => _isStreaming = false);
  }

  Future<void> _sendMessage() async {
    final localizations = AppLocalizations.of(context);
    final text = _controller.text.trim();
    final selectedImage = _selectedImage;
    final selectedImageBytes = _selectedImageBytes;
    if (text.isEmpty && selectedImageBytes == null) {
      return;
    }

    setState(() {
      _isStreaming = true;
    });

    try {
      final uploadedMedia = await _mediaSender.uploadSelectedMedia(
        pickedImage: selectedImage,
        imageBytes: selectedImageBytes,
      );

      final reference = _pendingReference;
      final referencePrefix = reference == null
          ? ''
          : '[${reference.kind == 'listing' ? '引用商品' : '引用帖子'}：${reference.title} (${reference.refId})]\n\n';
      final effectiveText = '$referencePrefix$text';

      final userMsg = ChatMessage(
        sender: 'user',
        content: effectiveText.isEmpty ? '[Multimedia Message]' : effectiveText,
        imageUrl: uploadedMedia.imageUrl,
        timestamp: DateTime.now(),
      );

      setState(() {
        _messages.add(userMsg);
        _controller.clear();
        _pendingReference = null;
        _selectedImage = null;
        _selectedImageBytes = null;
      });

      // Append a placeholder streaming message.
      final botMsgIndex = _messages.length;
      _messages.add(
        ChatMessage(
          sender: 'bot',
          content: '',
          timestamp: DateTime.now(),
          isPartial: true,
        ),
      );

      // Connect SSE stream with timeout.
      final proposalIdempotencyKey = _uuid.v4();
      bool connected;
      try {
        await _sseService
            .connect(
              message: userMsg.content,
              conversationId: '__agent__',
              pageContext: _buildPageContext(),
              imageUrl: uploadedMedia.imageUrl,
              idempotencyKey: proposalIdempotencyKey,
            )
            .timeout(const Duration(seconds: 30));
        connected = true;
      } catch (_) {
        connected = false;
      }
      if (!connected && mounted) {
        final l = AppLocalizations.of(context)!;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(l.connectionFailedNetwork),
            backgroundColor: Colors.red,
          ),
        );
        setState(() {
          _isStreaming = false;
          if (botMsgIndex < _messages.length) {
            _messages.removeAt(botMsgIndex);
          }
        });
        return;
      }

      if (_useLegacyBrain) {
        _live2DController.brain.onMessageSent(userMsg.content);
      }
      _companionTurnStart();
      _relationshipSignals.onTurnStart();
      if (_thanksPattern.hasMatch(userMsg.content)) {
        _recordRelationshipEvent('user_thanks');
      }
      _environmentTracker?.track(
        EnvironmentEvent(EnvironmentEventType.messageSent),
      );
      _live2DController.showSpeechBubble(
        localizations?.assistantThinkingBubble ?? '',
      );
      String fullReply = '';
      var companionSawFirstToken = false;
      var turnCompleted = false;
      await for (final event in _sseService.stream) {
        if (!mounted) break;
        if (event.type == 'turn_completed') {
          turnCompleted = true;
        }
        if (event.type == 'turn_failed') {
          throw Exception(event.errorMessage ?? 'Turn failed');
        }
        if (event.type == 'turn_cancelled') {
          throw Exception(event.cancelReason ?? 'Turn cancelled');
        }
        // Dispatch agent UI actions (e.g. SHOW_POSTS, SCROLL_TO_POST).
        if (event.actionType != null) {
          _handleUiAction({
            'type': event.actionType,
            'payload': event.actionPayload,
          });
          _companionOnUiAction(event.actionType!);
        }
        if (event.toolName != null && event.toolStatus == 'started') {
          final activity = event.toolName!;
          if (_useLegacyBrain) {
            _live2DController.brain.onToolStarted(activity);
          }
          _companionOnTool(activity);
          _relationshipSignals.onToolActivity();
          _environmentTracker?.track(
            EnvironmentEvent(EnvironmentEventType.postListUpdated),
          );
          // Surface a friendly progress line until real reply text arrives.
          if (fullReply.isEmpty) {
            final label = _toolActivityLabel(
              AppLocalizations.of(context)!,
              activity,
            );
            _live2DController.showSpeechBubble(label);
          }
        }
        final delta = event.text ?? '';
        if (!companionSawFirstToken && delta.isNotEmpty) {
          companionSawFirstToken = true;
          _companionOnFirstToken();
        }
        if (delta.isNotEmpty) {
          _lipSyncDriver.feedStreamingChunk(delta);
          if (_useLegacyBrain) {
            _live2DController.brain.onResponseToken(delta);
          }
          fullReply += delta;
          _live2DController.showSpeechBubble(fullReply);
          setState(() {
            if (botMsgIndex < _messages.length) {
              _messages[botMsgIndex] = _messages[botMsgIndex].copyWith(
                content: fullReply,
                isPartial: true,
              );
            }
          });
        }
      }

      if (!turnCompleted) {
        throw const StreamTruncatedException(
          'Agent turn completed without terminal turn_completed event',
        );
      }
      _lipSyncDriver.onStreamComplete();
      _companionOnStreamEnd(failed: false);
      final relationshipEvent = _relationshipSignals.eventForCompletedTurn(
        userMsg.content,
      );
      if (relationshipEvent != null) {
        _recordRelationshipEvent(relationshipEvent);
      }
      if (_useLegacyBrain) {
        _live2DController.brain.onResponseComplete(
          isError: false,
          reply: fullReply,
        );
      }
      _live2DController.showSpeechBubble(
        fullReply.isEmpty
            ? (localizations?.assistantIdleReplyBubble ?? '')
            : fullReply,
      );

      // Finalize the message (no longer partial).
      if (mounted && botMsgIndex < _messages.length) {
        setState(() {
          if (botMsgIndex < _messages.length) {
            _messages[botMsgIndex] = _messages[botMsgIndex].copyWith(
              content: fullReply.isEmpty
                  ? AppLocalizations.of(context)!.emptyReplyPlaceholder
                  : fullReply,
              isPartial: false,
            );
          }
        });
      }

      // Refresh negotiations and pending plans after chat (the agent may have
      // created a HITL request or proposed an action awaiting confirmation).
      await _loadNegotiations();
      await _loadAgentPlans();
      // The turn may have carried out a reversible write, so surface the undo
      // affordance right after the reply that caused it.
      await _loadUndoableActions();
      widget.onConversationUpdated?.call();
    } on ChatPageMediaUploadException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.message), backgroundColor: Colors.red),
      );
      setState(() {
        _isStreaming = false;
        _selectedImage = selectedImage;
        _selectedImageBytes = selectedImageBytes;
      });
      return;
    } catch (e) {
      _companionOnStreamEnd(failed: true);
      // Goal §49: the user sees a friendly line, never raw SQL/provider
      // internals. Full detail goes to the debug console only.
      debugPrint('chat stream failed: $e');
      final botMsgIndex = _messages.isEmpty ? -1 : _messages.length - 1;
      if (mounted && botMsgIndex >= 0 && botMsgIndex < _messages.length) {
        final l = AppLocalizations.of(context)!;
        setState(() {
          _messages[botMsgIndex] = _messages[botMsgIndex].copyWith(
            content: l.aiError,
            isPartial: false,
          );
        });
      }
      if (_useLegacyBrain) {
        _live2DController.brain.onResponseComplete(isError: true);
      }
    } finally {
      await _sseService.disconnect();
      if (mounted) {
        setState(() => _isStreaming = false);
      }
    }
  }

  Widget _buildAssistantMessageList() {
    final l = AppLocalizations.of(context)!;
    if (_messages.isEmpty) {
      return Center(
        child: Text(
          l.assistantMessagesEmpty,
          style: const TextStyle(color: Colors.grey),
        ),
      );
    }
    if (_pinnedToBottom) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_messageListController.hasClients &&
            _messageListController.position.maxScrollExtent > 0) {
          _messageListController.jumpTo(
            _messageListController.position.maxScrollExtent,
          );
        }
      });
    }
    return ListView.builder(
      key: const Key('assistant-message-list'),
      controller: _messageListController,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      itemCount: _messages.length,
      itemBuilder: (context, index) {
        final message = _messages[index];
        return _ChatBubble(
          message: message,
          isUser: message.sender == 'user',
          hitlRequests: _hitlRequests,
          currentUserId: _currentUserId ?? '',
          negotiateService: _negotiateService,
          onHitlUpdated: _loadNegotiations,
        );
      },
    );
  }

  Future<void> _clearAssistantHistory() async {
    final l = AppLocalizations.of(context)!;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l.assistantClearHistoryTitle),
        content: Text(l.assistantClearHistoryBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(l.cancel),
          ),
          FilledButton(
            key: const Key('assistant-clear-confirm'),
            onPressed: () => Navigator.pop(dialogContext, true),
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            child: Text(l.assistantClearHistoryAction),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await _chatService.clearAssistantHistory();
      if (!mounted) return;
      setState(() {
        _messages.clear();
        _historyError = null;
      });
      await _loadAssistantHistory();
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l.assistantHistoryCleared)));
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(error.toString()), backgroundColor: Colors.red),
      );
    }
  }

  void _showExpressionLab() {
    if (!ExpressionLab.enabled()) return;
    final names = ExpressionLab.names();
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Doro 原生表情/动作调试',
                  style: Theme.of(sheetContext).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final name in names)
                      ActionChip(
                        key: ValueKey('exp-$name'),
                        label: Text(name),
                        onPressed: () => ExpressionLab.setExpression(name),
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    FilledButton.tonalIcon(
                      key: const ValueKey('motion-idle'),
                      onPressed: () => ExpressionLab.idle(),
                      icon: const Icon(Icons.play_circle_outline),
                      label: const Text('Idle 重播'),
                    ),
                    OutlinedButton.icon(
                      key: const ValueKey('exp-reset'),
                      onPressed: () => ExpressionLab.reset(),
                      icon: const Icon(Icons.restart_alt_rounded),
                      label: const Text('恢复默认脸'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _showHistorySheet() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      constraints: const BoxConstraints(maxWidth: 640),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetContext) {
        final l = AppLocalizations.of(sheetContext)!;
        final height = MediaQuery.sizeOf(sheetContext).height;
        return FractionallySizedBox(
          key: const Key('assistant-history-sheet'),
          heightFactor: height < 700 ? 0.94 : 0.86,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 4, 8, 10),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        l.assistantHistorySheetTitle,
                        style: Theme.of(sheetContext).textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w800),
                      ),
                    ),
                    IconButton(
                      tooltip: l.cancel,
                      icon: const Icon(Icons.close_rounded),
                      onPressed: () => Navigator.pop(sheetContext),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: _isLoadingHistory
                    ? const Center(child: CircularProgressIndicator())
                    : _messages.isEmpty
                    ? Center(child: Text(l.assistantHistoryEmpty))
                    : ListView.builder(
                        keyboardDismissBehavior:
                            ScrollViewKeyboardDismissBehavior.onDrag,
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                        itemCount: _messages.length,
                        itemBuilder: (context, index) {
                          final msg = _messages[index];
                          return _ChatBubble(
                            message: msg,
                            isUser: msg.sender == 'user',
                            hitlRequests: _hitlRequests,
                            currentUserId: _currentUserId ?? '',
                            negotiateService: _negotiateService,
                            onHitlUpdated: _loadNegotiations,
                          );
                        },
                      ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildQuickSuggestionChips() {
    final l = AppLocalizations.of(context)!;
    final scheme = Theme.of(context).colorScheme;
    final chips = [
      ..._skillChips.take(3),
      l.assistantSuggestionVehicles,
      l.assistantSuggestionTextbooks,
      l.assistantSuggestionGadgets,
      l.assistantSuggestionOrders,
    ];

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: chips.map((prompt) {
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: ActionChip(
              label: Text(
                prompt,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: scheme.onSurface,
                ),
              ),
              backgroundColor: scheme.surfaceContainerHigh.withValues(
                alpha: 0.94,
              ),
              side: BorderSide(color: scheme.primary.withValues(alpha: 0.35)),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
              onPressed: () {
                _controller.text = prompt.replaceAll(RegExp(r'^[^\s]+\s*'), '');
                _sendMessage();
              },
            ),
          );
        }).toList(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final scheme = Theme.of(context).colorScheme;
    final agentResults = _agentResultsStrip;
    final page = Column(
      children: [
        AssistantDigitalHumanHeader(
          onOpenHistory: _showHistorySheet,
          onOpenMemoryPanel: () => AssistantMemoryPanel.show(context),
          onClearHistory: _clearAssistantHistory,
          onOpenExpressionLab: kIsWeb ? _showExpressionLab : null,
        ),
        ?agentResults,
        if (_historyError != null)
          Container(
            width: double.infinity,
            color: scheme.errorContainer,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Text(
              l.assistantHistoryLoadFailed,
              style: TextStyle(fontSize: 12, color: scheme.onErrorContainer),
            ),
          ),
        // Pending agent action plans
        if (_agentPlans.isNotEmpty)
          Container(
            color: scheme.secondaryContainer,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  l.agentPlanPendingHeader,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: scheme.onSecondaryContainer,
                  ),
                ),
                ..._agentPlans.map(
                  (plan) => Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Row(
                      children: [
                        Icon(
                          plan.isHighRisk
                              ? Icons.warning_amber_rounded
                              : Icons.pending_actions,
                          size: 18,
                          color: plan.isHighRisk
                              ? scheme.error
                              : scheme.onSecondaryContainer,
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            plan.summary,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 13),
                          ),
                        ),
                        TextButton(
                          onPressed: () {
                            _cancelAgentPlan(plan);
                            _recordRelationshipEvent('user_cancels_action');
                          },
                          child: Text(l.cancel),
                        ),
                        FilledButton(
                          onPressed: () => _confirmAgentPlan(plan),
                          child: Text(l.agentPlanConfirmAction),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        // Reversible writes undo strip
        if (_undoableActions.isNotEmpty)
          Container(
            color: scheme.surfaceContainerHigh,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  l.undoDoneHeader,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                ..._undoableActions.map((action) {
                  final remaining = action.remaining();
                  return Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Row(
                      children: [
                        Icon(
                          Icons.check_circle_outline,
                          size: 16,
                          color: scheme.primary,
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            action.summary,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 12),
                          ),
                        ),
                        if (remaining != null)
                          Text(
                            l.undoRemainingSeconds(remaining.inSeconds),
                            style: TextStyle(
                              fontSize: 11,
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        TextButton(
                          onPressed: () => _undo(action),
                          child: Text(l.undoAction),
                        ),
                      ],
                    ),
                  );
                }),
              ],
            ),
          ),
        // Negotiation cards strip
        if (_hitlRequests.isNotEmpty)
          SizedBox(
            height: 60,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              itemCount: _hitlRequests.length,
              itemBuilder: (context, index) {
                final req = _hitlRequests[index];
                return SizedBox(
                  width: 200,
                  child: HitlChip(
                    request: req,
                    onTap: () => _showNegotiationCard(req),
                  ),
                );
              },
            ),
          ),
        // Collapsible companion banner + persistent message history.
        InkWell(
          key: const Key('assistant-stage-toggle'),
          onTap: () => setState(() => _stageExpanded = !_stageExpanded),
          child: Container(
            key: const Key('assistant-stage-background'),
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 6),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  scheme.primaryContainer.withValues(alpha: 0.55),
                  scheme.surface,
                ],
              ),
            ),
            child: Column(
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      _stageExpanded
                          ? Icons.keyboard_arrow_up_rounded
                          : Icons.keyboard_arrow_down_rounded,
                      size: 18,
                      color: scheme.primary,
                    ),
                    Text(
                      _stageExpanded ? '' : l.assistantStageCollapsed,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: scheme.primary,
                      ),
                    ),
                  ],
                ),
                AnimatedCrossFade(
                  duration: const Duration(milliseconds: 200),
                  crossFadeState: _stageExpanded
                      ? CrossFadeState.showFirst
                      : CrossFadeState.showSecond,
                  firstChild: SizedBox(
                    width: double.infinity,
                    child: SingleChildScrollView(
                      physics: const NeverScrollableScrollPhysics(),
                      child: Column(
                        children: [
                          if (_companionOwnsBody)
                            KeyedSubtree(
                              key: ValueKey(
                                'cubism-stage-'
                                '${CompanionCharacterService.instance.character}',
                              ),
                              child:
                                  createCubismStage(
                                    fallback: (context) =>
                                        Live2DCharacterWidget(
                                          controller: _live2DController,
                                          size: 220,
                                          showSpeechBubble: true,
                                          enableTouchTracking: true,
                                        ),
                                    width: 240,
                                    height: 260,
                                  ) ??
                                  Live2DCharacterWidget(
                                    controller: _live2DController,
                                    size: 220,
                                    showSpeechBubble: true,
                                    enableTouchTracking: true,
                                  ),
                            )
                          else
                            Live2DCharacterWidget(
                              controller: _live2DController,
                              size: 220,
                              showSpeechBubble: true,
                              enableTouchTracking: true,
                            ),
                          _buildQuickSuggestionChips(),
                        ],
                      ),
                    ),
                  ),
                  secondChild: const SizedBox(
                    width: double.infinity,
                    height: 8,
                  ),
                ),
              ],
            ),
          ),
        ),
        Expanded(child: _buildAssistantMessageList()),
        // Bottom Input Message Composer
        Container(
          decoration: BoxDecoration(
            color: scheme.surface,
            boxShadow: [
              BoxShadow(
                color: scheme.shadow.withValues(alpha: 0.16),
                blurRadius: 16,
                offset: const Offset(0, -4),
              ),
            ],
          ),
          child: UnifiedMessageComposer(
            controller: _controller,
            focusNode: _composerFocusNode,
            hintText: l.assistantComposerHint,
            isSending: _isStreaming,
            onStop: () => _stopStreaming(),
            onChanged: (_) {
              if (_useLegacyBrain) _live2DController.brain.onUserTyping();
            },
            onSubmitted: (_) => _sendMessage(),
            onSend: _sendMessage,
            expandedActions: [
              MessageComposerAction(
                id: 'image',
                icon: Icons.image_outlined,
                label: l.composerImageAction,
                onPressed: _pickImage,
              ),
              MessageComposerAction(
                id: 'reference',
                icon: Icons.format_quote_outlined,
                label: l.composerReferenceAction,
                onPressed: _showReferencePicker,
              ),
              MessageComposerAction(
                id: 'assistant-find',
                icon: Icons.search_rounded,
                label: l.assistantToolFind,
                onPressed: () =>
                    _applyAssistantPrompt(l.assistantToolFindPrompt),
              ),
              MessageComposerAction(
                id: 'assistant-estimate',
                icon: Icons.price_check_outlined,
                label: l.assistantToolEstimate,
                onPressed: () =>
                    _applyAssistantPrompt(l.assistantToolEstimatePrompt),
              ),
            ],
            contextContent: [
              if (_pendingReference != null) _buildPendingReferenceChip(l),
              if (_selectedImageBytes != null) _buildSelectedImagePreview(l),
            ],
          ),
        ),
      ],
    );
    return page;
  }

  void _applyAssistantPrompt(String prompt) {
    _controller.value = TextEditingValue(
      text: prompt,
      selection: TextSelection.collapsed(offset: prompt.length),
    );
    _composerFocusNode.requestFocus();
  }

  Widget _buildPendingReferenceChip(AppLocalizations l) {
    final reference = _pendingReference;
    if (reference == null) return const SizedBox.shrink();
    final label = reference.kind == 'listing'
        ? l.referenceChipListing
        : l.referenceChipPost;
    return Align(
      alignment: Alignment.centerLeft,
      child: InputChip(
        key: const Key('pending-reference-chip'),
        avatar: Icon(
          reference.kind == 'listing'
              ? Icons.sell_outlined
              : Icons.article_outlined,
          size: 16,
        ),
        label: Text('$label：${reference.title}'),
        onDeleted: () => setState(() => _pendingReference = null),
      ),
    );
  }

  Widget _buildSelectedImagePreview(AppLocalizations l) {
    return Align(
      alignment: Alignment.centerLeft,
      child: SizedBox(
        height: 84,
        child: Stack(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Image.memory(_selectedImageBytes!),
            ),
            Positioned(
              right: 0,
              top: 0,
              child: IconButton(
                icon: const Icon(Icons.close, size: 18),
                onPressed: () {
                  setState(() {
                    _selectedImage = null;
                    _selectedImageBytes = null;
                  });
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showNegotiationCard(HitlRequest req) {
    showDialog(
      context: context,
      builder: (context) => Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: NegotiationCard(
            request: req,
            currentUserId: _currentUserId ?? '',
            negotiateService: _negotiateService,
            onUpdated: _loadNegotiations,
          ),
        ),
      ),
    );
  }
}

/// Image-first result card for agent recommendation strips.
class _AgentResultCard extends StatelessWidget {
  const _AgentResultCard({
    required this.item,
    required this.focused,
    this.onReference,
  });

  final post.CampusPost item;
  final bool focused;
  final VoidCallback? onReference;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final price = item.listing?.suggestedPriceCny;

    return SizedBox(
      key: ValueKey('agent-result-card-${item.id}'),
      width: 220,
      child: Card(
        margin: const EdgeInsets.only(right: 8),
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(
            color: focused ? const Color(0xFF0F766E) : Colors.transparent,
            width: focused ? 2 : 0,
          ),
        ),
        child: InkWell(
          onTap: item.listingId != null && item.listingId!.isNotEmpty
              ? () => context.push('/listing/${item.listingId}')
              : () => context.push('/posts/${item.id}'),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                height: 84,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    _buildCover(scheme),
                    if (onReference != null)
                      Positioned(
                        right: 4,
                        top: 4,
                        child: Material(
                          color: Colors.black54,
                          shape: const CircleBorder(),
                          child: InkWell(
                            customBorder: const CircleBorder(),
                            onTap: onReference,
                            child: const Padding(
                              padding: EdgeInsets.all(4),
                              child: Icon(
                                Icons.format_quote_outlined,
                                size: 14,
                                color: Colors.white,
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 13,
                      ),
                    ),
                    const Spacer(),
                    Row(
                      children: [
                        if (price != null)
                          PriceTag(priceCny: price, fontSize: 12)
                        else
                          Expanded(
                            child: Text(
                              item.category,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 11,
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                          ),
                        if (item.rankReason != null &&
                            item.rankReason!.isNotEmpty) ...[
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              item.rankReason!,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              textAlign: TextAlign.end,
                              style: TextStyle(
                                fontSize: 10,
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCover(ColorScheme scheme) {
    final url = item.coverImageUrl;
    if (url == null || url.isEmpty) return _placeholder(scheme);
    return Image.network(
      url,
      fit: BoxFit.cover,
      errorBuilder: (context, error, stackTrace) => _placeholder(scheme),
    );
  }

  Widget _placeholder(ColorScheme scheme) => ColoredBox(
    color: scheme.primary.withValues(alpha: 0.08),
    child: Icon(Icons.inventory_2_outlined, color: scheme.primary, size: 28),
  );
}

class _ChatBubble extends StatelessWidget {
  final ChatMessage message;
  final bool isUser;
  final List<HitlRequest> hitlRequests;
  final String currentUserId;
  final NegotiateService negotiateService;
  final VoidCallback onHitlUpdated;

  const _ChatBubble({
    required this.message,
    required this.isUser,
    required this.hitlRequests,
    required this.currentUserId,
    required this.negotiateService,
    required this.onHitlUpdated,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // Show negotiation cards after bot messages.
    Widget? trailingCard;
    if (!isUser && message.content.isNotEmpty && !message.isPartial) {
      // Detect if this message contains a HITL request and show a card.
      // The backend injects system messages with negotiation context.
      if (message.content.contains('议价')) {
        final relatedReqs = hitlRequests
            .where((r) => r.isPending && r.sellerId == currentUserId)
            .toList();
        if (relatedReqs.isNotEmpty) {
          trailingCard = NegotiationCard(
            request: relatedReqs.first,
            currentUserId: currentUserId,
            negotiateService: negotiateService,
            onUpdated: onHitlUpdated,
          );
        }
      }
    }

    return Column(
      crossAxisAlignment: isUser
          ? CrossAxisAlignment.end
          : CrossAxisAlignment.start,
      children: [
        Align(
          alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
          child: Container(
            key: Key(
              isUser ? 'assistant-user-bubble' : 'assistant-reply-bubble',
            ),
            constraints: BoxConstraints(
              maxWidth: MediaQuery.of(context).size.width * 0.75,
            ),
            margin: const EdgeInsets.symmetric(vertical: 4),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: isUser ? scheme.primary : scheme.surfaceContainerHighest,
              border: isUser ? null : Border.all(color: scheme.outlineVariant),
              borderRadius: BorderRadius.circular(16).copyWith(
                bottomRight: isUser
                    ? const Radius.circular(0)
                    : const Radius.circular(16),
                bottomLeft: !isUser
                    ? const Radius.circular(0)
                    : const Radius.circular(16),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (message.imageUrl != null &&
                    message.imageUrl!.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8.0),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: Image.network(
                        message.imageUrl!,
                        errorBuilder: (context, error, stackTrace) =>
                            const SizedBox.shrink(),
                      ),
                    ),
                  ),
                if (!isUser && !message.isPartial)
                  AssistantMarkdown(data: message.content)
                else
                  Text(
                    message.content,
                    style: TextStyle(
                      color: isUser ? scheme.onPrimary : scheme.onSurface,
                      fontSize: 16,
                    ),
                    softWrap: true,
                  ),
                if (message.isPartial)
                  const Text(
                    '▊',
                    style: TextStyle(color: Colors.grey),
                  ), // Typing cursor
              ],
            ),
          ),
        ),
        ?trailingCard,
      ],
    );
  }
}

/// A post/listing the user attached to the next outgoing message.
class _PendingReference {
  const _PendingReference({
    required this.kind,
    required this.refId,
    required this.title,
  });

  final String kind; // 'post' | 'listing'
  final String refId;
  final String title;
}

/// Pick a post/listing to quote: recently-viewed first, then keyword search.
class _ReferencePickerSheet extends StatefulWidget {
  const _ReferencePickerSheet({
    required this.postService,
    required this.recentIds,
  });

  final PostService postService;
  final List<String> recentIds;

  @override
  State<_ReferencePickerSheet> createState() => _ReferencePickerSheetState();
}

class _ReferencePickerSheetState extends State<_ReferencePickerSheet> {
  final TextEditingController _searchController = TextEditingController();
  List<post.CampusPost>? _results;
  bool _searching = false;
  int _searchGeneration = 0;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadRecent();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadRecent() async {
    final generation = ++_searchGeneration;
    final posts = await Future.wait([
      for (final id in widget.recentIds.take(6)) _safeLoad(id),
    ]);
    if (!mounted ||
        generation != _searchGeneration ||
        _searchController.text.isNotEmpty) {
      return;
    }
    final loaded = posts.whereType<post.CampusPost>().toList(growable: false);
    setState(() {
      _results = loaded;
      _error = null;
    });
  }

  Future<post.CampusPost?> _safeLoad(String id) async {
    try {
      return await widget.postService.getPost(id);
    } catch (_) {
      return null;
    }
  }

  Future<void> _runSearch(String query) async {
    final trimmed = query.trim();
    final generation = ++_searchGeneration;
    if (trimmed.isEmpty) {
      // Reset spinner/error synchronously so clearing the field never shows
      // stale search state while "recent" reloads.
      setState(() {
        _searching = false;
        _results = null;
        _error = null;
      });
      await _loadRecent();
      return;
    }
    setState(() {
      _searching = true;
      _error = null;
    });
    try {
      final response = await widget.postService.getPosts(
        search: trimmed,
        limit: 12,
      );
      if (!mounted || generation != _searchGeneration) return;
      setState(() {
        _results = response.items;
        _searching = false;
      });
    } catch (error) {
      if (!mounted || generation != _searchGeneration) return;
      setState(() {
        _searching = false;
        _error = error.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.72,
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                l.referencePickerTitle,
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _searchController,
                decoration: InputDecoration(
                  hintText: l.referencePickerSearchHint,
                  prefixIcon: const Icon(Icons.search_rounded),
                  suffixIcon: _searchController.text.isEmpty
                      ? null
                      : IconButton(
                          icon: const Icon(Icons.close_rounded),
                          onPressed: () {
                            _searchController.clear();
                            _runSearch('');
                          },
                        ),
                  border: const OutlineInputBorder(),
                  isDense: true,
                ),
                textInputAction: TextInputAction.search,
                onSubmitted: _runSearch,
                onChanged: (value) {
                  if (value.isEmpty) _runSearch('');
                },
              ),
              const SizedBox(height: 8),
              if (_searching)
                const Padding(
                  padding: EdgeInsets.all(24),
                  child: Center(child: CircularProgressIndicator()),
                )
              else if (_error != null)
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    _error!,
                    style: const TextStyle(color: Colors.red),
                  ),
                )
              else
                Expanded(child: _buildResults(l)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildResults(AppLocalizations l) {
    final items = _results ?? const <post.CampusPost>[];
    if (items.isEmpty) {
      return Center(child: Text(l.conversationEmptyTitle));
    }
    final showRecentHeader = _searchController.text.isEmpty && items.isNotEmpty;
    return ListView.builder(
      shrinkWrap: true,
      itemCount: items.length + (showRecentHeader ? 1 : 0),
      itemBuilder: (context, index) {
        if (showRecentHeader && index == 0) {
          return Padding(
            padding: const EdgeInsets.only(top: 4, bottom: 4, left: 4),
            child: Text(
              l.referenceRecentSection,
              style: TextStyle(
                color: Theme.of(context).hintColor,
                fontSize: 12,
              ),
            ),
          );
        }
        final item = items[index - (showRecentHeader ? 1 : 0)];
        return ListTile(
          dense: true,
          leading: item.coverImageUrl != null && item.coverImageUrl!.isNotEmpty
              ? ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: Image.network(
                    item.coverImageUrl!,
                    width: 40,
                    height: 40,
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) =>
                        const Icon(Icons.article_outlined),
                  ),
                )
              : const Icon(Icons.article_outlined),
          title: Text(item.title, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(
            item.listing?.title ?? '',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          onTap: () => Navigator.pop(context, item),
        );
      },
    );
  }
}
