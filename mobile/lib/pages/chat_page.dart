import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import '../l10n/app_localizations.dart';
import 'package:image_picker/image_picker.dart';
import 'package:uuid/uuid.dart';
import '../services/api_service.dart';
import '../services/chat_service.dart';
import '../services/sse_service.dart';
import '../services/upload_service.dart';
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
import '../components/agent_debug_panel.dart';
import '../components/assistant_markdown.dart';
import '../components/live2d/live2d_character_widget.dart';
import '../components/live2d/live2d_controller.dart';
import '../components/live2d/live2d_lipsync_driver.dart';
import '../components/unified_message_composer.dart';
import 'chat_page_media_sender.dart';
import '../widgets/chat/assistant_header.dart';
import '../widgets/chat/negotiation_card.dart';

class ChatPage extends StatefulWidget {
  final ApiService? apiService;
  final ChatService? chatService;
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
    this.apiService,
    this.chatService,
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
  late final ApiService _apiService;
  late final ChatService _chatService;
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
  String? _focusedAgentPostId;
  Timer? _undoTicker;

  // Agent debug overlay observability buffers. The flag may sit before or
  // after the hash-router fragment, so match the full URL instead of
  // Uri.base.queryParameters (which only sees the pre-# query).
  final bool _agentDebugEnabled = Uri.base.toString().contains(
    'agentDebug=true',
  );
  final List<String> _debugToolCalls = [];
  final List<String> _debugUiActions = [];
  String? _lastToolActivity;
  DateTime? _turnStartedAt;
  Duration? _firstTokenLatency;
  Duration? _lastTurnLatency;

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
    _live2DController = Live2DController();
    _syncBrainWithPageContext();
    _lipSyncDriver = Live2DLipSyncDriver(controller: _live2DController);
    _apiService = widget.apiService ?? context.read<ApiService>();
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
      _apiService
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
    _apiService
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
    if (_agentDebugEnabled) {
      _recordDebugUiAction(type, payload);
    }
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

  void _recordDebugToolCall(String tool) {
    _debugToolCalls.add('${_debugClock()} $tool');
    if (_debugToolCalls.length > 20) _debugToolCalls.removeAt(0);
  }

  void _recordDebugUiAction(String? type, Map<String, dynamic> payload) {
    final detail = payload.entries
        .take(2)
        .map((entry) => '${entry.key}=${entry.value}')
        .join(' ');
    _debugUiActions.add('${type ?? 'UNKNOWN'} $detail');
    if (_debugUiActions.length > 20) _debugUiActions.removeAt(0);
  }

  String _debugClock() {
    final now = DateTime.now();
    String two(int value) => value.toString().padLeft(2, '0');
    return '${two(now.hour)}:${two(now.minute)}:'
        '${two(now.second)}.${now.millisecond.toString().padLeft(3, '0')}';
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
    return Container(
      color: const Color(0xFFF0FAF7),
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
                color: const Color(0xFF0F766E),
              ),
            ),
          ),
          SizedBox(
            height: 150,
            child: ListView.builder(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              scrollDirection: Axis.horizontal,
              itemCount: _agentResultPosts.length,
              itemBuilder: (context, index) {
                final post = _agentResultPosts[index];
                final focused = post.id == _focusedAgentPostId;
                return SizedBox(
                  width: 220,
                  child: Card(
                    margin: const EdgeInsets.only(right: 8),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                      side: BorderSide(
                        color: focused
                            ? const Color(0xFF0F766E)
                            : Colors.transparent,
                        width: focused ? 2 : 0,
                      ),
                    ),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(14),
                      onTap: post.listingId != null
                          ? () => context.push('/listing/${post.listingId}')
                          : () => context.push('/posts/${post.id}'),
                      child: Padding(
                        padding: const EdgeInsets.all(10),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              post.title,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontWeight: FontWeight.w700,
                                fontSize: 13,
                              ),
                            ),
                            const Spacer(),
                            Text(
                              post.displayBody.isEmpty
                                  ? post.category ?? l.assistantFallbackCategory
                                  : post.displayBody,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 11,
                                color: Colors.grey.shade700,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              },
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
                color: Colors.grey.shade100,
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
                color: Colors.grey.shade100,
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
      final profile = await _apiService.getUserProfile();
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
      final requests = await _apiService.getNegotiations();
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
      final plans = await _apiService.getAgentPlans();
      if (!mounted) return;
      setState(() => _agentPlans = plans);
    } catch (_) {}
  }

  Future<void> _loadUndoableActions() async {
    try {
      final actions = await _apiService.getUndoableActions();
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
      final result = await _apiService.undoAction(action.id);
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

      var outcome = await _apiService.confirmAgentPlan(plan.id, token);
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
        outcome = await _apiService.confirmAgentPlan(plan.id, token);
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
      await _apiService.cancelAgentPlan(plan.id);
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

  @override
  void dispose() {
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

      final userMsg = ChatMessage(
        sender: 'user',
        content: text.isEmpty ? '[Multimedia Message]' : text,
        imageUrl: uploadedMedia.imageUrl,
        timestamp: DateTime.now(),
      );

      setState(() {
        _messages.add(userMsg);
        _controller.clear();
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
      if (_agentDebugEnabled) {
        setState(() {
          _turnStartedAt = DateTime.now();
          _firstTokenLatency = null;
          _lastTurnLatency = null;
        });
      }
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
      await for (final token in _sseService.stream) {
        if (!mounted) break;
        if (token.error != null) {
          throw Exception(token.error);
        }
        // Dispatch agent UI actions (e.g. SHOW_POSTS, SCROLL_TO_POST).
        if (token.uiAction != null) {
          _handleUiAction(token.uiAction!);
          _companionOnUiAction(token.uiAction!['type']?.toString() ?? '');
        }
        if (token.toolActivity != null) {
          final activity = token.toolActivity!;
          if (_useLegacyBrain) {
            _live2DController.brain.onToolStarted(activity);
          }
          _companionOnTool(activity);
          _relationshipSignals.onToolActivity();
          _environmentTracker?.track(
            EnvironmentEvent(EnvironmentEventType.postListUpdated),
          );
          setState(() => _lastToolActivity = activity);
          if (_agentDebugEnabled) _recordDebugToolCall(activity);
          // Surface a friendly progress line until real reply text arrives.
          if (fullReply.isEmpty) {
            final label = _toolActivityLabel(
              AppLocalizations.of(context)!,
              activity,
            );
            _live2DController.showSpeechBubble(label);
          }
        }
        if (!companionSawFirstToken && token.token.isNotEmpty) {
          companionSawFirstToken = true;
          _companionOnFirstToken();
        }
        if (token.token.isNotEmpty &&
            _firstTokenLatency == null &&
            _turnStartedAt != null) {
          _firstTokenLatency = DateTime.now().difference(_turnStartedAt!);
        }
        _lipSyncDriver.feedStreamingChunk(token.token);
        if (_useLegacyBrain) {
          _live2DController.brain.onResponseToken(token.token);
        }
        fullReply += token.token;
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
      _lipSyncDriver.onStreamComplete();
      _companionOnStreamEnd(failed: false);
      final relationshipEvent = _relationshipSignals.eventForCompletedTurn(
        userMsg.content,
      );
      if (relationshipEvent != null) {
        _recordRelationshipEvent(relationshipEvent);
      }
      if (_turnStartedAt != null) {
        _lastTurnLatency = DateTime.now().difference(_turnStartedAt!);
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

  void _showHistorySheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) {
        return DraggableScrollableSheet(
          initialChildSize: 0.75,
          minChildSize: 0.45,
          maxChildSize: 0.95,
          expand: false,
          builder: (context, scrollController) {
            final l = AppLocalizations.of(context)!;
            return Column(
              children: [
                Container(
                  width: 40,
                  height: 4,
                  margin: const EdgeInsets.symmetric(vertical: 12),
                  decoration: BoxDecoration(
                    color: Colors.grey.withValues(alpha: 0.3),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 18,
                    vertical: 4,
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        l.assistantHistorySheetTitle,
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          color: Color(0xFF0F766E),
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.close_rounded),
                        onPressed: () => Navigator.pop(context),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  child: _isLoadingHistory
                      ? const Center(child: CircularProgressIndicator())
                      : _messages.isEmpty
                      ? Center(
                          child: Text(
                            l.assistantHistoryEmpty,
                            style: TextStyle(color: Colors.grey),
                          ),
                        )
                      : ListView.builder(
                          controller: scrollController,
                          padding: const EdgeInsets.all(16),
                          itemCount: _messages.length,
                          itemBuilder: (context, index) {
                            final msg = _messages[index];
                            return _ChatBubble(
                              message: msg,
                              isUser: msg.sender == 'user',
                              hitlRequests: _hitlRequests,
                              currentUserId: _currentUserId ?? '',
                              apiService: _apiService,
                              onHitlUpdated: _loadNegotiations,
                            );
                          },
                        ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Widget _buildQuickSuggestionChips() {
    final l = AppLocalizations.of(context)!;
    final chips = [
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
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF0F766E),
                ),
              ),
              backgroundColor: Colors.white.withValues(alpha: 0.9),
              side: BorderSide(
                color: const Color(0xFF0F766E).withValues(alpha: 0.25),
              ),
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
    final agentResults = _agentResultsStrip;
    final page = Column(
      children: [
        AssistantDigitalHumanHeader(onOpenHistory: _showHistorySheet),
        ?agentResults,
        if (_historyError != null)
          Container(
            width: double.infinity,
            color: const Color(0xFFFFF3CD),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Text(
              l.assistantHistoryLoadFailed,
              style: const TextStyle(fontSize: 12, color: Color(0xFF765A16)),
            ),
          ),
        // Pending agent action plans
        if (_agentPlans.isNotEmpty)
          Container(
            color: const Color(0xFFF1F5FF),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  l.agentPlanPendingHeader,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF3F51B5),
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
                              ? const Color(0xFFB45309)
                              : const Color(0xFF3F51B5),
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
            color: const Color(0xFFF4F6F4),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  l.undoDoneHeader,
                  style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF5F6B5F),
                  ),
                ),
                ..._undoableActions.map((action) {
                  final remaining = action.remaining();
                  return Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Row(
                      children: [
                        const Icon(
                          Icons.check_circle_outline,
                          size: 16,
                          color: Color(0xFF5F6B5F),
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
                            style: const TextStyle(
                              fontSize: 11,
                              color: Color(0xFF8A968A),
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
        // Main Digital Human Virtual Avatar Stage
        Expanded(
          child: Container(
            width: double.infinity,
            decoration: const BoxDecoration(
              gradient: RadialGradient(
                center: Alignment(0, -0.1),
                radius: 0.85,
                colors: [Color(0xFFE1F4EF), Color(0xFFFFFBF5)],
              ),
            ),
            child: SingleChildScrollView(
              physics: const BouncingScrollPhysics(),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  const SizedBox(height: 10),
                  // Body selection (§74): real Cubism model on web when the
                  // runtime is usable and the companion owns the body. The
                  // stage internally falls back to the legacy sprite body if
                  // the model fails after mount.
                  if (_companionOwnsBody)
                    createCubismStage(
                          fallback: (context) => Live2DCharacterWidget(
                            controller: _live2DController,
                            size: 260,
                            showSpeechBubble: true,
                            enableTouchTracking: true,
                          ),
                          width: 300,
                          height: 340,
                        ) ??
                        Live2DCharacterWidget(
                          controller: _live2DController,
                          size: 260,
                          showSpeechBubble: true,
                          enableTouchTracking: true,
                        )
                  else
                    Live2DCharacterWidget(
                      controller: _live2DController,
                      size: 260,
                      showSpeechBubble: true,
                      enableTouchTracking: true,
                    ),
                  const SizedBox(height: 18),
                  // Quick suggestion chips
                  _buildQuickSuggestionChips(),
                  const SizedBox(height: 10),
                ],
              ),
            ),
          ),
        ),
        // Bottom Input Message Composer
        Container(
          decoration: BoxDecoration(
            color: Colors.white,
            boxShadow: [
              BoxShadow(
                color: const Color(0xFF0F766E).withValues(alpha: 0.08),
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
            onChanged: (_) {
              if (_useLegacyBrain) _live2DController.brain.onUserTyping();
            },
            onSubmitted: (_) => _sendMessage(),
            onSend: _sendMessage,
            primaryActions: [
              MessageComposerAction(
                id: 'image',
                icon: Icons.image_outlined,
                label: l.composerImageAction,
                onPressed: _pickImage,
              ),
            ],
            expandedActions: [
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
              if (_selectedImageBytes != null) _buildSelectedImagePreview(l),
            ],
          ),
        ),
      ],
    );
    if (!_agentDebugEnabled) return page;
    return Stack(
      children: [
        page,
        Positioned(
          top: 12,
          right: 12,
          child: AgentDebugPanel(
            brain: _live2DController.brain,
            pageContext: _buildPageContext(),
            toolCalls: _debugToolCalls,
            uiActions: _debugUiActions,
            pendingConfirmations: _hitlRequests.length + _agentPlans.length,
            currentTool: _lastToolActivity,
            firstTokenLatency: _firstTokenLatency,
            lastTurnLatency: _lastTurnLatency,
          ),
        ),
      ],
    );
  }

  void _applyAssistantPrompt(String prompt) {
    _controller.value = TextEditingValue(
      text: prompt,
      selection: TextSelection.collapsed(offset: prompt.length),
    );
    _composerFocusNode.requestFocus();
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
            apiService: _apiService,
            onUpdated: _loadNegotiations,
          ),
        ),
      ),
    );
  }
}

class _ChatBubble extends StatelessWidget {
  final ChatMessage message;
  final bool isUser;
  final List<HitlRequest> hitlRequests;
  final String currentUserId;
  final ApiService apiService;
  final VoidCallback onHitlUpdated;

  const _ChatBubble({
    required this.message,
    required this.isUser,
    required this.hitlRequests,
    required this.currentUserId,
    required this.apiService,
    required this.onHitlUpdated,
  });

  @override
  Widget build(BuildContext context) {
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
            apiService: apiService,
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
            constraints: BoxConstraints(
              maxWidth: MediaQuery.of(context).size.width * 0.75,
            ),
            margin: const EdgeInsets.symmetric(vertical: 4),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: isUser ? const Color(0xFF6366F1) : Colors.grey[200],
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
                if ((message.imageUrl != null &&
                        message.imageUrl!.isNotEmpty) ||
                    (message.imageBase64 != null &&
                        message.imageBase64!.isNotEmpty))
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8.0),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child:
                          message.imageUrl != null &&
                              message.imageUrl!.isNotEmpty
                          ? Image.network(
                              message.imageUrl!,
                              errorBuilder: (context, error, stackTrace) {
                                if (message.imageBase64 != null &&
                                    message.imageBase64!.isNotEmpty) {
                                  return Image.memory(
                                    base64Decode(message.imageBase64!),
                                  );
                                }
                                return const SizedBox.shrink();
                              },
                            )
                          : Image.memory(base64Decode(message.imageBase64!)),
                    ),
                  ),
                if (!isUser && !message.isPartial)
                  AssistantMarkdown(data: message.content)
                else
                  Text(
                    message.content,
                    style: TextStyle(
                      color: isUser ? Colors.white : Colors.black87,
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
