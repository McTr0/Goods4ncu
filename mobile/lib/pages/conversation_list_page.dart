import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../components/contact_conversation_sheet.dart';
import '../l10n/app_localizations.dart';
import '../models/models.dart';
import '../services/chat_service.dart';
import '../services/chat_local_seen_storage.dart';
import '../services/user_service.dart';
import '../services/ws_service.dart';
import '../utils/category_utils.dart';
import 'chat_page.dart';
import 'user_chat_page.dart';

class ConversationListPage extends StatefulWidget {
  const ConversationListPage({
    super.key,
    this.chatService,
    this.userService,
    this.localSeenStorage,
  });

  final ChatService? chatService;
  final UserService? userService;
  final ChatLocalSeenStorage? localSeenStorage;

  @override
  State<ConversationListPage> createState() => _ConversationListPageState();
}

class _ConversationListPageState extends State<ConversationListPage> {
  late final ChatService _chatService;
  late final UserService _userService;
  late final ChatLocalSeenStorage _localSeenStorage;
  StreamSubscription<WsNotification>? _wsSubscription;
  List<ChatThread> _threads = const [];
  List<_ChatSpace> _spaces = const [];
  AssistantConversationHistory? _assistantHistory;
  ConversationMode? _filter;
  ChatThread? _selectedThread;
  _ChatSpace? _selectedSpace;
  bool _assistantSelected = true;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _chatService = widget.chatService ?? context.read<ChatService>();
    _userService = widget.userService ?? context.read<UserService>();
    _localSeenStorage =
        widget.localSeenStorage ?? SharedPreferencesChatLocalSeenStorage();
    _load();
    _loadAssistantPreview();
    _wsSubscription = WsService.instance.stream.listen((notification) {
      if (!mounted) return;
      if ({
        'conversation_created',
        'conversation_state_changed',
        'new_message',
        'message_acknowledgement_changed',
        'space_message_created',
        'space_member_changed',
      }.contains(notification.eventType)) {
        _load(silent: true);
      }
    });
  }

  @override
  void dispose() {
    _wsSubscription?.cancel();
    super.dispose();
  }

  Future<void> _load({bool silent = false}) async {
    if (!silent) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final results = await Future.wait<Object>([
        _chatService.getThreads(mode: _filter),
        if (_filter == null)
          _chatService.getSpaces()
        else
          Future.value(<Map<String, dynamic>>[]),
      ]);
      final serverThreads = results[0] as List<ChatThread>;
      final threads = await Future.wait(serverThreads.map(_applyLocalSeen));
      final spaces = (results[1] as List<Map<String, dynamic>>)
          .map(_ChatSpace.fromJson)
          .toList();
      if (!mounted) return;
      setState(() {
        _threads = threads;
        _spaces = spaces;
        _loading = false;
        _error = null;
        if (_selectedThread != null) {
          _selectedThread = threads
              .where((item) => item.peerUserId == _selectedThread!.peerUserId)
              .firstOrNull;
        }
        if (_selectedSpace != null) {
          _selectedSpace = spaces
              .where((item) => item.id == _selectedSpace!.id)
              .firstOrNull;
        }
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = error.toString();
      });
    }
  }

  Future<ChatThread> _applyLocalSeen(ChatThread thread) async {
    try {
      // Preference plugins can be unavailable during web bootstrap or tests;
      // do not hold the inbox on a local badge lookup.
      final seenAt = await _localSeenStorage
          .read(thread.peerUserId)
          .timeout(const Duration(milliseconds: 100));
      if (seenAt != null && !thread.latestActivityAt.isAfter(seenAt)) {
        return thread.copyWith(unreadCount: 0);
      }
    } catch (_) {
      // If local storage is unavailable, retain the server count as a
      // conservative fallback without writing any read fact remotely.
    }
    return thread;
  }

  Future<void> _loadAssistantPreview() async {
    try {
      final history = await _chatService.getAssistantHistory(limit: 1);
      if (!mounted) return;
      setState(() => _assistantHistory = history);
    } catch (_) {
      // The system conversation remains available with its static subtitle.
    }
  }

  void _openConversation(Conversation conversation) {
    final thread = ChatThread(
      peerUserId: conversation.otherUserId,
      peerUsername: conversation.otherUsername,
      latestActivityAt: conversation.lastMessageAt ?? DateTime.now(),
      latestPreview: conversation.lastMessage,
      unreadCount: conversation.unreadCount,
      conversationCount: 1,
      mailCount: conversation.mode == ConversationMode.mail ? 1 : 0,
      realtimeCount: conversation.mode == ConversationMode.realtime ? 1 : 0,
      pendingCount: conversation.capabilities.canRespond ? 1 : 0,
      hasActiveRealtime: conversation.state.isLiveRealtime,
      latestListingTitle: conversation.listingTitle,
    );
    _openThread(thread);
  }

  void _openThread(ChatThread thread) {
    if (MediaQuery.sizeOf(context).width >= 1000) {
      setState(() {
        _selectedThread = thread;
        _selectedSpace = null;
        _assistantSelected = false;
      });
      return;
    }
    context.pushNamed(
      'chat-thread',
      pathParameters: {'peerUserId': thread.peerUserId},
      extra: {'thread': thread},
    );
  }

  void _openAssistant() {
    if (MediaQuery.sizeOf(context).width >= 1000) {
      setState(() {
        _assistantSelected = true;
        _selectedThread = null;
        _selectedSpace = null;
      });
      return;
    }
    context.push('/chat');
  }

  void _openSpace(_ChatSpace space) {
    if (MediaQuery.sizeOf(context).width >= 1000) {
      setState(() {
        _selectedSpace = space;
        _selectedThread = null;
        _assistantSelected = false;
      });
      return;
    }
    context.pushNamed(
      'chat-space',
      pathParameters: {'spaceId': space.id},
      extra: space.toJson(),
    );
  }

  Future<void> _openUserLookup() async {
    final conversation = await showDialog<Conversation>(
      context: context,
      builder: (context) => _UserLookupDialog(
        userService: _userService,
        chatService: _chatService,
      ),
    );
    if (!mounted || conversation == null) return;
    await _load(silent: true);
    _openConversation(conversation);
  }

  Future<void> _createSpace(String kind) async {
    final l = AppLocalizations.of(context)!;
    final draft = await showDialog<_CreateSpaceDraft>(
      context: context,
      builder: (context) => _CreateSpaceDialog(kind: kind),
    );
    if (draft == null) return;
    try {
      final data = await _chatService.createSpace(
        kind: kind,
        name: draft.name,
        description: draft.description,
      );
      final space = _ChatSpace.fromJson(data);
      if (!mounted) return;
      setState(() {
        _spaces = [space, ..._spaces.where((item) => item.id != space.id)];
        _selectedSpace = space;
        _selectedThread = null;
        _assistantSelected = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            kind == 'channel'
                ? l.conversationCreateChannelSuccess
                : l.conversationCreateGroupSuccess,
          ),
        ),
      );
      if (MediaQuery.sizeOf(context).width >= 1000) {
        _openSpace(space);
      } else {
        context.pushNamed(
          'chat-space',
          pathParameters: {'spaceId': space.id},
          extra: space.toJson(),
        );
      }
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l.conversationCreateFailed(error.toString()))),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final scheme = Theme.of(context).colorScheme;
    final isDesktop = MediaQuery.sizeOf(context).width >= 1000;
    final inbox = _buildInbox(isDesktop: isDesktop);
    return Scaffold(
      backgroundColor: scheme.surface,
      appBar: AppBar(
        title: Text(l.messagesTab),
        actions: [
          PopupMenuButton<String>(
            tooltip: l.createAction,
            icon: const Icon(Icons.add_rounded),
            onSelected: (value) {
              switch (value) {
                case 'classmate':
                  _openUserLookup();
                  break;
                case 'group':
                  _createSpace('group');
                  break;
                case 'channel':
                  _createSpace('channel');
                  break;
              }
            },
            itemBuilder: (context) => [
              PopupMenuItem(
                value: 'classmate',
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.person_search_rounded),
                  title: Text(l.findClassmate),
                ),
              ),
              PopupMenuItem(
                value: 'group',
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.group_add_outlined),
                  title: Text(l.createGroup),
                ),
              ),
              PopupMenuItem(
                value: 'channel',
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.campaign_outlined),
                  title: Text(l.createChannel),
                ),
              ),
            ],
          ),
        ],
      ),
      body: isDesktop
          ? Row(
              children: [
                SizedBox(width: 360, child: inbox),
                VerticalDivider(width: 1, color: scheme.outlineVariant),
                Expanded(
                  child: _assistantSelected
                      ? ChatPage(
                          key: const ValueKey('assistant-conversation'),
                          chatService: _chatService,
                          embedded: true,
                          onConversationUpdated: _loadAssistantPreview,
                          onExit: _closeAssistant,
                        )
                      : _selectedSpace != null
                      ? _SpaceDetailPane(
                          key: ValueKey(_selectedSpace!.id),
                          chatService: _chatService,
                          space: _selectedSpace!,
                          onMessageSent: () => _load(silent: true),
                        )
                      : _selectedThread == null
                      ? const _ConversationEmptyCanvas()
                      : _ChatThreadDetailPane(
                          key: ValueKey(_selectedThread!.peerUserId),
                          chatService: _chatService,
                          peerUserId: _selectedThread!.peerUserId,
                          initialThread: _selectedThread,
                          mode: _filter,
                          embedded: true,
                          onConversationChanged: () => _load(silent: true),
                        ),
                ),
              ],
            )
          : inbox,
    );
  }

  Widget _buildInbox({required bool isDesktop}) {
    final l = AppLocalizations.of(context)!;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
          child: Row(
            children: [
              _FilterChip(
                label: l.conversationFilterAll,
                selected: _filter == null,
                onTap: () => _setFilter(null),
              ),
              const SizedBox(width: 8),
              _FilterChip(
                label: l.conversationFilterRealtime,
                icon: Icons.bolt_rounded,
                selected: _filter == ConversationMode.realtime,
                onTap: () => _setFilter(ConversationMode.realtime),
              ),
              const SizedBox(width: 8),
              _FilterChip(
                label: l.conversationFilterMail,
                icon: Icons.mark_email_unread_outlined,
                selected: _filter == ConversationMode.mail,
                onTap: () => _setFilter(ConversationMode.mail),
              ),
            ],
          ),
        ),
        Expanded(child: _buildConversationList()),
      ],
    );
  }

  void _setFilter(ConversationMode? filter) {
    if (_filter == filter) return;
    setState(() {
      _filter = filter;
      if (filter != null && _assistantSelected) {
        _assistantSelected = false;
      }
    });
    _load();
  }

  void _closeAssistant() {
    if (!_assistantSelected) return;
    setState(() => _assistantSelected = false);
  }

  Widget _buildConversationList() {
    final l = AppLocalizations.of(context)!;
    final scheme = Theme.of(context).colorScheme;
    if (_loading) return const Center(child: CircularProgressIndicator());
    final actionable = _threads
        .where((thread) => thread.pendingCount > 0)
        .toList();
    final regular = _threads
        .where((thread) => thread.pendingCount == 0)
        .toList();
    final hasInboxData = _threads.isNotEmpty || _spaces.isNotEmpty;
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
        children: [
          if (_filter == null && !hasInboxData) ...[
            ..._buildToolCards(),
            const SizedBox(height: 12),
          ],
          if (_error != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: _InlineEmptyMessage(
                icon: Icons.cloud_off_rounded,
                title: l.conversationLoadFailedTitle,
                subtitle: _error!,
                action: TextButton(onPressed: _load, child: Text(l.retry)),
              ),
            ),
          if (_error == null && !hasInboxData)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              // The old wording pointed at contacting someone from a listing
              // or searching for a classmate — the two paths that do not work
              // on day one, when there are no listings and you do not yet know
              // anyone. Answering an intent is the one that does.
              child: _InlineEmptyMessage(
                icon: Icons.forum_outlined,
                title: l.conversationEmptyTitle,
                subtitle: l.conversationEmptySubtitle,
                action: TextButton(
                  onPressed: () => context.push('/create'),
                  child: Text(l.conversationEmptyAction),
                ),
              ),
            ),
          if (_threads.isNotEmpty) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 10),
              child: Text(
                l.conversationSectionDirect,
                style: TextStyle(
                  fontWeight: FontWeight.w800,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
          if (actionable.isNotEmpty) ...[
            ...actionable.map(
              (thread) => _PeerThreadCard(
                thread: thread,
                selected: _selectedThread?.peerUserId == thread.peerUserId,
                onTap: () => _openThread(thread),
              ),
            ),
          ],
          ...regular.map(
            (thread) => _PeerThreadCard(
              thread: thread,
              selected: _selectedThread?.peerUserId == thread.peerUserId,
              onTap: () => _openThread(thread),
            ),
          ),
          if (_threads.isNotEmpty) const SizedBox(height: 12),
          if (_spaces.isNotEmpty) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 10),
              child: Text(
                l.conversationSectionSpaces,
                style: TextStyle(
                  fontWeight: FontWeight.w800,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
            ..._spaces.map(
              (space) => _SpaceCard(
                space: space,
                selected:
                    !_assistantSelected &&
                    _selectedThread == null &&
                    _selectedSpace?.id == space.id,
                onTap: () => _openSpace(space),
              ),
            ),
            const SizedBox(height: 12),
          ],
          if (_filter == null && hasInboxData) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 10),
              child: Text(
                l.conversationSectionTools,
                style: TextStyle(
                  fontWeight: FontWeight.w800,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
            ..._buildToolCards(),
          ],
        ],
      ),
    );
  }

  List<Widget> _buildToolCards() {
    return [
      _AssistantConversationCard(
        selected:
            MediaQuery.sizeOf(context).width >= 1000 && _assistantSelected,
        latestMessage: _assistantHistory?.latest,
        onTap: _openAssistant,
      ),
    ];
  }
}

class ChatThreadPage extends StatelessWidget {
  const ChatThreadPage({
    super.key,
    required this.peerUserId,
    this.initialThread,
    this.chatService,
  });

  final String peerUserId;
  final ChatThread? initialThread;
  final ChatService? chatService;

  @override
  Widget build(BuildContext context) {
    final service = chatService ?? context.read<ChatService>();
    return Scaffold(
      body: _ChatThreadDetailPane(
        chatService: service,
        peerUserId: peerUserId,
        initialThread: initialThread,
      ),
    );
  }
}

class _ChatThreadDetailPane extends StatefulWidget {
  const _ChatThreadDetailPane({
    super.key,
    required this.chatService,
    required this.peerUserId,
    this.initialThread,
    this.mode,
    this.embedded = false,
    this.onConversationChanged,
  });

  final ChatService chatService;
  final String peerUserId;
  final ChatThread? initialThread;
  final ConversationMode? mode;
  final bool embedded;
  final VoidCallback? onConversationChanged;

  @override
  State<_ChatThreadDetailPane> createState() => _ChatThreadDetailPaneState();
}

class _ChatThreadDetailPaneState extends State<_ChatThreadDetailPane> {
  ChatThread? _thread;
  List<Conversation> _conversations = const [];
  Set<String> _expandedIds = const {};
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _thread = widget.initialThread;
    _loadThread();
  }

  @override
  void didUpdateWidget(covariant _ChatThreadDetailPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.peerUserId != widget.peerUserId ||
        oldWidget.mode != widget.mode) {
      _thread = widget.initialThread;
      _conversations = const [];
      _expandedIds = const {};
      _loadThread();
    }
  }

  Future<void> _loadThread({bool silent = false}) async {
    if (!silent) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final detail = await widget.chatService.getThread(
        widget.peerUserId,
        mode: widget.mode,
      );
      if (!mounted) return;
      setState(() {
        _thread = detail.thread;
        _conversations = detail.conversations;
        _expandedIds = _defaultExpandedIds(detail.conversations);
        _loading = false;
        _error = null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = error.toString();
      });
    }
  }

  Set<String> _defaultExpandedIds(List<Conversation> conversations) {
    final ids = <String>{};
    for (var index = 0; index < conversations.length; index += 1) {
      final conversation = conversations[index];
      if (index == 0 ||
          conversation.unreadCount > 0 ||
          conversation.capabilities.canRespond ||
          conversation.capabilities.canSend ||
          conversation.state == ConversationState.open) {
        ids.add(conversation.id);
      }
    }
    return ids;
  }

  Future<void> _startConversation() async {
    final thread = _thread;
    if (thread == null) return;
    final conversation = await showContactConversationSheet(
      context: context,
      chatService: widget.chatService,
      recipientId: thread.peerUserId,
      recipientName: thread.peerUsername,
    );
    if (!mounted || conversation == null) return;
    await _loadThread(silent: true);
    widget.onConversationChanged?.call();
  }

  @override
  Widget build(BuildContext context) {
    final body = Column(
      children: [
        _buildHeader(),
        Expanded(child: _buildContent()),
      ],
    );
    if (widget.embedded) return body;
    return Scaffold(
      appBar: AppBar(title: Text(_displayName)),
      body: body,
    );
  }

  Widget _buildHeader() {
    final l = AppLocalizations.of(context)!;
    final scheme = Theme.of(context).colorScheme;
    final thread = _thread;
    return Container(
      width: double.infinity,
      padding: EdgeInsets.fromLTRB(20, widget.embedded ? 18 : 8, 20, 16),
      decoration: BoxDecoration(
        color: scheme.surface,
        border: Border(bottom: BorderSide(color: scheme.outlineVariant)),
      ),
      child: Row(
        children: [
          _Avatar(name: _displayName),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _displayName,
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  thread == null
                      ? l.conversationThreadLoading
                      : l.conversationThreadStats(
                          thread.realtimeCount,
                          thread.mailCount,
                          thread.conversationCount,
                        ),
                  style: TextStyle(color: scheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          FilledButton.icon(
            onPressed: thread == null ? null : _startConversation,
            icon: const Icon(Icons.add_comment_outlined, size: 18),
            label: Text(l.conversationReconnect),
          ),
        ],
      ),
    );
  }

  Widget _buildContent() {
    final l = AppLocalizations.of(context)!;
    if (_loading && _conversations.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null && _conversations.isEmpty) {
      return _CenteredMessage(
        icon: Icons.cloud_off_rounded,
        title: l.conversationThreadLoadFailedTitle,
        subtitle: _error!,
        action: TextButton(onPressed: _loadThread, child: Text(l.retry)),
      );
    }
    if (_conversations.isEmpty) {
      return _CenteredMessage(
        icon: Icons.chat_bubble_outline_rounded,
        title: l.conversationThreadEmptyTitle,
        subtitle: l.conversationThreadEmptySubtitle,
      );
    }
    return RefreshIndicator(
      onRefresh: _loadThread,
      child: ListView.builder(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 28),
        itemCount: _conversations.length,
        itemBuilder: (context, index) {
          final conversation = _conversations[index];
          final expanded = _expandedIds.contains(conversation.id);
          return _ConversationSegmentCard(
            conversation: conversation,
            initiallyExpanded: expanded,
            embedChat: widget.embedded,
            onOpen: () => _openConversation(conversation),
            onExpansionChanged: (value) {
              setState(() {
                final next = {..._expandedIds};
                if (value) {
                  next.add(conversation.id);
                } else {
                  next.remove(conversation.id);
                }
                _expandedIds = next;
              });
            },
          );
        },
      ),
    );
  }

  String get _displayName {
    final name = _thread?.peerUsername ?? widget.initialThread?.peerUsername;
    if (name != null && name.isNotEmpty) return name;
    return AppLocalizations.of(context)!.conversationPeerFallback;
  }

  void _openConversation(Conversation conversation) {
    if (widget.embedded) return;
    context.pushNamed(
      'user-chat',
      pathParameters: {'conversationId': conversation.id},
      extra: {
        'otherUserId': conversation.otherUserId,
        'otherUsername': conversation.otherUsername,
      },
    );
  }
}

class _ConversationSegmentCard extends StatelessWidget {
  const _ConversationSegmentCard({
    required this.conversation,
    required this.initiallyExpanded,
    required this.embedChat,
    required this.onOpen,
    required this.onExpansionChanged,
  });

  final Conversation conversation;
  final bool initiallyExpanded;
  final bool embedChat;
  final VoidCallback onOpen;
  final ValueChanged<bool> onExpansionChanged;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final scheme = Theme.of(context).colorScheme;
    final title =
        conversation.subject ??
        conversation.listingTitle ??
        (conversation.mode == ConversationMode.mail
            ? l.conversationMailThreadTitle
            : l.conversationRealtimeThreadTitle);
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      clipBehavior: Clip.antiAlias,
      child: ExpansionTile(
        key: PageStorageKey('conversation-segment-${conversation.id}'),
        initiallyExpanded: initiallyExpanded,
        onExpansionChanged: onExpansionChanged,
        leading: _ModeBadge(mode: conversation.mode),
        title: Text(
          title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontWeight: FontWeight.w900),
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Wrap(
            spacing: 8,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                _conversationStateLabel(l, conversation),
                style: TextStyle(color: scheme.onSurfaceVariant),
              ),
              if (conversation.lastMessage != null)
                Text(
                  '· ${conversation.lastMessage}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: scheme.onSurfaceVariant),
                ),
              if (conversation.unreadCount > 0)
                _UnreadPill(count: conversation.unreadCount),
            ],
          ),
        ),
        children: embedChat
            ? [
                SizedBox(
                  height: MediaQuery.sizeOf(
                    context,
                  ).height.clamp(480, 720).toDouble(),
                  child: UserChatPage(
                    key: ValueKey('thread-chat-${conversation.id}'),
                    conversationId: conversation.id,
                    otherUserId: conversation.otherUserId,
                    otherUsername: conversation.otherUsername,
                    embedded: true,
                  ),
                ),
              ]
            : [
                _ConversationSegmentSummary(
                  conversation: conversation,
                  onOpen: onOpen,
                ),
              ],
      ),
    );
  }
}

class _ConversationSegmentSummary extends StatelessWidget {
  const _ConversationSegmentSummary({
    required this.conversation,
    required this.onOpen,
  });

  final Conversation conversation;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final scheme = Theme.of(context).colorScheme;
    final isTerminal = conversation.state.isTerminal;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLowest,
        border: Border(top: BorderSide(color: scheme.outlineVariant)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (conversation.listingTitle != null) ...[
            Row(
              children: [
                Icon(
                  Icons.sell_outlined,
                  size: 16,
                  color: scheme.onSurfaceVariant,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    conversation.listingTitle!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: scheme.onSurfaceVariant),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
          ],
          Text(
            isTerminal
                ? l.conversationSegmentHistoryHint
                : l.conversationSegmentOpenHint,
            style: TextStyle(color: scheme.onSurfaceVariant, height: 1.35),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: onOpen,
                  icon: const Icon(Icons.open_in_new_rounded, size: 18),
                  label: Text(
                    isTerminal
                        ? l.conversationViewHistory
                        : l.conversationOpenSegment,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class SpaceChatPage extends StatefulWidget {
  const SpaceChatPage({
    super.key,
    required this.spaceId,
    this.initialSpace,
    this.chatService,
  });

  final String spaceId;
  final Map<String, dynamic>? initialSpace;
  final ChatService? chatService;

  @override
  State<SpaceChatPage> createState() => _SpaceChatPageState();
}

class _SpaceChatPageState extends State<SpaceChatPage> {
  late final ChatService _chatService;
  _ChatSpace? _space;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _chatService = widget.chatService ?? context.read<ChatService>();
    final initial = widget.initialSpace;
    if (initial != null) {
      _space = _ChatSpace.fromJson(initial);
      _loading = false;
    }
    _loadSpace(silent: initial != null);
  }

  Future<void> _loadSpace({bool silent = false}) async {
    if (!silent) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final data = await _chatService.getSpace(widget.spaceId);
      if (!mounted) return;
      setState(() {
        _space = _ChatSpace.fromJson(data);
        _loading = false;
        _error = null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error.toString();
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final space = _space;
    return Scaffold(
      appBar: AppBar(
        title: Text(space?.displayName(l) ?? l.spaceFallbackTitle),
        actions: [
          IconButton(
            tooltip: l.refresh,
            onPressed: _loadSpace,
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: Builder(
        builder: (context) {
          if (_loading && space == null) {
            return const Center(child: CircularProgressIndicator());
          }
          if (_error != null && space == null) {
            return _CenteredMessage(
              icon: Icons.cloud_off_rounded,
              title: l.spaceLoadFailedTitle,
              subtitle: _error!,
              action: TextButton(onPressed: _loadSpace, child: Text(l.retry)),
            );
          }
          if (space == null) {
            return _CenteredMessage(
              icon: Icons.groups_2_outlined,
              title: l.spaceNotFoundTitle,
              subtitle: l.spaceNotFoundSubtitle,
            );
          }
          return _SpaceDetailPane(
            chatService: _chatService,
            space: space,
            onMessageSent: () => _loadSpace(silent: true),
          );
        },
      ),
    );
  }
}

class _CreateSpaceDraft {
  const _CreateSpaceDraft({required this.name, this.description});

  final String name;
  final String? description;
}

class _CreateSpaceDialog extends StatefulWidget {
  const _CreateSpaceDialog({required this.kind});

  final String kind;

  @override
  State<_CreateSpaceDialog> createState() => _CreateSpaceDialogState();
}

class _CreateSpaceDialogState extends State<_CreateSpaceDialog> {
  final _nameController = TextEditingController();
  final _descriptionController = TextEditingController();

  @override
  void dispose() {
    _nameController.dispose();
    _descriptionController.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _nameController.text.trim();
    if (name.isEmpty) return;
    final description = _descriptionController.text.trim();
    Navigator.pop(
      context,
      _CreateSpaceDraft(
        name: name,
        description: description.isEmpty ? null : description,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    return AlertDialog(
      title: Text(widget.kind == 'channel' ? l.createChannel : l.createGroup),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _nameController,
            autofocus: true,
            textInputAction: TextInputAction.next,
            decoration: InputDecoration(labelText: l.spaceNameLabel),
            maxLength: 80,
            onChanged: (_) => setState(() {}),
            onSubmitted: (_) => _submit(),
          ),
          TextField(
            controller: _descriptionController,
            decoration: InputDecoration(
              labelText: l.spaceDescriptionOptionalLabel,
            ),
            maxLines: 2,
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l.cancel),
        ),
        FilledButton(
          onPressed: _nameController.text.trim().isEmpty ? null : _submit,
          child: Text(l.createAction),
        ),
      ],
    );
  }
}

class _ChatSpace {
  const _ChatSpace({
    required this.id,
    required this.kind,
    required this.name,
    required this.ownerId,
    required this.myRole,
    required this.memberCount,
    required this.createdAt,
    required this.updatedAt,
    this.description,
  });

  final String id;
  final String kind;
  final String name;
  final String? description;
  final String ownerId;
  final String myRole;
  final int memberCount;
  final DateTime createdAt;
  final DateTime updatedAt;

  bool get isChannel => kind == 'channel';
  bool get canPost => !isChannel || myRole == 'owner' || myRole == 'admin';
  String? displayName(AppLocalizations l) =>
      name.trim().isEmpty ? l.unnamedSpace : name;

  Map<String, dynamic> toJson() => {
    'id': id,
    'kind': kind,
    'name': name,
    'description': description,
    'owner_id': ownerId,
    'my_role': myRole,
    'member_count': memberCount,
    'created_at': createdAt.toIso8601String(),
    'updated_at': updatedAt.toIso8601String(),
  };

  factory _ChatSpace.fromJson(Map<String, dynamic> json) {
    return _ChatSpace(
      id: json['id']?.toString() ?? '',
      kind: json['kind']?.toString() ?? 'group',
      name: json['name']?.toString() ?? '',
      description: json['description']?.toString(),
      ownerId: json['owner_id']?.toString() ?? '',
      myRole: json['my_role']?.toString() ?? 'member',
      memberCount: (json['member_count'] as num?)?.toInt() ?? 0,
      createdAt:
          DateTime.tryParse(json['created_at']?.toString() ?? '') ??
          DateTime.now(),
      updatedAt:
          DateTime.tryParse(json['updated_at']?.toString() ?? '') ??
          DateTime.now(),
    );
  }
}

class _SpaceMessage {
  const _SpaceMessage({
    required this.id,
    required this.spaceId,
    required this.senderId,
    required this.content,
    required this.createdAt,
    this.senderUsername,
    this.replyToMessageId,
  });

  final int id;
  final String spaceId;
  final String senderId;
  final String? senderUsername;
  final String content;
  final int? replyToMessageId;
  final DateTime createdAt;

  String get displaySender {
    final name = senderUsername?.trim();
    if (name != null && name.isNotEmpty) return name;
    if (senderId.length > 8) return '${senderId.substring(0, 8)}…';
    return senderId;
  }

  factory _SpaceMessage.fromJson(Map<String, dynamic> json) {
    return _SpaceMessage(
      id: (json['id'] as num?)?.toInt() ?? 0,
      spaceId: json['space_id']?.toString() ?? '',
      senderId: json['sender_id']?.toString() ?? '',
      senderUsername: json['sender_username']?.toString(),
      content: json['content']?.toString() ?? '',
      replyToMessageId: (json['reply_to_message_id'] as num?)?.toInt(),
      createdAt:
          DateTime.tryParse(json['created_at']?.toString() ?? '') ??
          DateTime.now(),
    );
  }
}

class _SpaceDetailPane extends StatefulWidget {
  const _SpaceDetailPane({
    super.key,
    required this.chatService,
    required this.space,
    required this.onMessageSent,
  });

  final ChatService chatService;
  final _ChatSpace space;
  final VoidCallback onMessageSent;

  @override
  State<_SpaceDetailPane> createState() => _SpaceDetailPaneState();
}

class _SpaceDetailPaneState extends State<_SpaceDetailPane> {
  final _controller = TextEditingController();
  List<_SpaceMessage> _messages = const [];
  _SpaceMessage? _replyingTo;
  bool _loading = true;
  bool _sending = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadMessages();
  }

  @override
  void didUpdateWidget(covariant _SpaceDetailPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.space.id != widget.space.id) {
      _controller.clear();
      _replyingTo = null;
      _loadMessages();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _loadMessages() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final rows = await widget.chatService.getSpaceMessages(widget.space.id);
      if (!mounted) return;
      setState(() {
        _messages = rows.map(_SpaceMessage.fromJson).toList();
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error.toString();
        _loading = false;
      });
    }
  }

  Future<void> _send() async {
    final l = AppLocalizations.of(context)!;
    final text = _controller.text.trim();
    if (text.isEmpty || _sending || !widget.space.canPost) return;
    final replyTo = _replyingTo;
    setState(() => _sending = true);
    try {
      await widget.chatService.sendSpaceMessage(
        widget.space.id,
        content: text,
        replyToMessageId: replyTo?.id.toString(),
      );
      _controller.clear();
      setState(() => _replyingTo = null);
      await _loadMessages();
      widget.onMessageSent();
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l.spaceSendFailed(error.toString()))),
      );
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final scheme = Theme.of(context).colorScheme;
    return Column(
      children: [
        Container(
          padding: const EdgeInsets.fromLTRB(18, 16, 12, 14),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHighest.withValues(alpha: 0.42),
            border: Border(bottom: BorderSide(color: scheme.outlineVariant)),
          ),
          child: Row(
            children: [
              _SpaceAvatar(space: widget.space),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            widget.space.displayName(l) ?? l.unnamedSpace,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                        ),
                        _SpaceKindBadge(space: widget.space),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      l.spaceMembersRoleLine(
                        widget.space.memberCount,
                        _spaceRoleLabel(l, widget.space.myRole),
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: scheme.onSurfaceVariant,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: l.refresh,
                onPressed: _loadMessages,
                icon: const Icon(Icons.refresh_rounded),
              ),
            ],
          ),
        ),
        if (widget.space.description?.isNotEmpty == true)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(18, 10, 18, 10),
            color: scheme.secondaryContainer.withValues(alpha: 0.24),
            child: Text(
              widget.space.description!,
              style: TextStyle(color: scheme.onSurfaceVariant, height: 1.35),
            ),
          ),
        Expanded(child: _buildMessages()),
        _buildComposer(),
      ],
    );
  }

  Widget _buildMessages() {
    final l = AppLocalizations.of(context)!;
    final scheme = Theme.of(context).colorScheme;
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return _CenteredMessage(
        icon: Icons.cloud_off_rounded,
        title: l.spaceMessagesLoadFailedTitle,
        subtitle: _error!,
        action: TextButton(onPressed: _loadMessages, child: Text(l.retry)),
      );
    }
    if (_messages.isEmpty) {
      return _CenteredMessage(
        icon: widget.space.isChannel
            ? Icons.campaign_outlined
            : Icons.groups_2_outlined,
        title: widget.space.isChannel
            ? l.spaceChannelCreatedTitle
            : l.spaceGroupCreatedTitle,
        subtitle: widget.space.isChannel
            ? l.spaceChannelEmptySubtitle
            : l.spaceGroupEmptySubtitle,
      );
    }
    final ordered = _messages.reversed.toList();
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
      itemCount: ordered.length,
      separatorBuilder: (_, _) => const SizedBox(height: 10),
      itemBuilder: (context, index) {
        final message = ordered[index];
        return Align(
          alignment: Alignment.centerLeft,
          child: GestureDetector(
            onLongPress: () => _showSpaceMessageActions(message),
            child: Container(
              constraints: const BoxConstraints(maxWidth: 620),
              padding: const EdgeInsets.all(13),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest.withValues(alpha: 0.72),
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: scheme.outlineVariant),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    message.displaySender,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: scheme.primary,
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  if (message.replyToMessageId != null) ...[
                    const SizedBox(height: 6),
                    _SpaceReplyPreview(
                      text: _replyPreviewText(message.replyToMessageId!),
                    ),
                  ],
                  const SizedBox(height: 5),
                  Text(message.content, style: const TextStyle(height: 1.35)),
                  const SizedBox(height: 6),
                  Text(
                    _formatSpaceTime(message.createdAt),
                    style: TextStyle(
                      color: scheme.onSurfaceVariant,
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  void _showSpaceMessageActions(_SpaceMessage message) {
    final l = AppLocalizations.of(context)!;
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: ListTile(
          leading: const Icon(Icons.reply_rounded),
          title: Text(l.replyAction),
          subtitle: Text(
            message.content,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          onTap: () {
            Navigator.pop(context);
            setState(() => _replyingTo = message);
          },
        ),
      ),
    );
  }

  String _replyPreviewText(int messageId) {
    final l = AppLocalizations.of(context)!;
    final target = _messages.where((message) => message.id == messageId);
    if (target.isEmpty) return l.replyPreviewMissing(messageId);
    final content = target.first.content.trim();
    return content.isEmpty ? l.replyPreviewMissing(messageId) : content;
  }

  Widget _buildComposer() {
    final l = AppLocalizations.of(context)!;
    final scheme = Theme.of(context).colorScheme;
    if (!widget.space.canPost) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          border: Border(top: BorderSide(color: scheme.outlineVariant)),
        ),
        child: Text(
          l.spaceChannelReadOnlyNotice,
          style: TextStyle(color: scheme.onSurfaceVariant, height: 1.35),
        ),
      );
    }
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 14),
      decoration: BoxDecoration(
        color: scheme.surface,
        border: Border(top: BorderSide(color: scheme.outlineVariant)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_replyingTo != null)
                  Container(
                    width: double.infinity,
                    margin: const EdgeInsets.only(bottom: 8),
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: scheme.primaryContainer.withValues(alpha: 0.52),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.reply_rounded, size: 18),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            _replyingTo!.content,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        IconButton(
                          tooltip: l.cancelReply,
                          onPressed: () => setState(() => _replyingTo = null),
                          icon: const Icon(Icons.close_rounded),
                        ),
                      ],
                    ),
                  ),
                TextField(
                  controller: _controller,
                  minLines: 1,
                  maxLines: 4,
                  textInputAction: TextInputAction.send,
                  onSubmitted: (_) => _send(),
                  decoration: InputDecoration(
                    hintText: widget.space.isChannel
                        ? l.channelComposerHint
                        : l.groupComposerHint,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          IconButton.filled(
            onPressed: _sending ? null : _send,
            icon: _sending
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.send_rounded),
          ),
        ],
      ),
    );
  }
}

class _SpaceReplyPreview extends StatelessWidget {
  const _SpaceReplyPreview({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: scheme.primaryContainer.withValues(alpha: 0.48),
        borderRadius: BorderRadius.circular(10),
        border: Border(left: BorderSide(color: scheme.primary, width: 3)),
      ),
      child: Text(
        text,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12),
      ),
    );
  }
}

class _UserLookupDialog extends StatefulWidget {
  const _UserLookupDialog({
    required this.userService,
    required this.chatService,
  });

  final UserService userService;
  final ChatService chatService;

  @override
  State<_UserLookupDialog> createState() => _UserLookupDialogState();
}

class _UserLookupDialogState extends State<_UserLookupDialog> {
  final _queryController = TextEditingController();
  String _method = 'auto';
  List<UserLookupMatch> _results = const [];
  bool _loading = false;
  bool _searched = false;
  String? _error;

  @override
  void dispose() {
    _queryController.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final query = _queryController.text.trim();
    if (query.isEmpty) return;
    setState(() {
      _loading = true;
      _searched = true;
      _error = null;
    });
    try {
      final results = await widget.userService.lookupUsers(
        query,
        method: _method,
      );
      if (!mounted) return;
      setState(() {
        _results = results;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error.toString();
        _results = const [];
        _loading = false;
      });
    }
  }

  Future<void> _contact(UserLookupMatch match) async {
    final conversation = await showContactConversationSheet(
      context: context,
      chatService: widget.chatService,
      recipientId: match.userId,
      recipientName: match.username,
    );
    if (!mounted || conversation == null) return;
    Navigator.of(context).pop(conversation);
  }

  void _showListings(UserLookupMatch match) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => _PublicUserListingsSheet(
        userService: widget.userService,
        userId: match.userId,
        username: match.username,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final scheme = Theme.of(context).colorScheme;
    return Dialog(
      backgroundColor: scheme.surface,
      surfaceTintColor: Colors.transparent,
      insetPadding: const EdgeInsets.all(20),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560, maxHeight: 720),
        child: Padding(
          padding: const EdgeInsets.all(22),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      l.lookupDialogTitle,
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
              const SizedBox(height: 6),
              Text(
                l.lookupDialogSubtitle,
                style: TextStyle(color: scheme.onSurfaceVariant, height: 1.35),
              ),
              const SizedBox(height: 18),
              TextField(
                controller: _queryController,
                autofocus: true,
                textInputAction: TextInputAction.search,
                onSubmitted: (_) => _search(),
                decoration: InputDecoration(
                  labelText: l.lookupFieldLabel,
                  hintText: l.lookupFieldHint,
                  prefixIcon: const Icon(Icons.search_rounded),
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      initialValue: _method,
                      decoration: InputDecoration(
                        labelText: l.lookupMethodLabel,
                      ),
                      items: [
                        DropdownMenuItem(
                          value: 'auto',
                          child: Text(l.lookupMethodAuto),
                        ),
                        DropdownMenuItem(
                          value: 'username',
                          child: Text(l.lookupMethodUsername),
                        ),
                        DropdownMenuItem(
                          value: 'student_id',
                          child: Text(l.lookupMethodStudentId),
                        ),
                        DropdownMenuItem(
                          value: 'email',
                          child: Text(l.lookupMethodEmail),
                        ),
                      ],
                      onChanged: (value) =>
                          setState(() => _method = value ?? 'auto'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  FilledButton.icon(
                    onPressed: _loading ? null : _search,
                    icon: _loading
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.person_search_rounded),
                    label: Text(l.lookupSearchAction),
                  ),
                ],
              ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(_error!, style: TextStyle(color: scheme.error)),
              ],
              const SizedBox(height: 18),
              Flexible(child: _buildResults()),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildResults() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (!_searched) {
      return const _LookupHintCard();
    }
    if (_results.isEmpty) {
      return const _LookupEmptyCard();
    }
    return ListView.separated(
      shrinkWrap: true,
      itemCount: _results.length,
      separatorBuilder: (_, _) => const SizedBox(height: 10),
      itemBuilder: (context, index) {
        final match = _results[index];
        return _LookupResultCard(
          match: match,
          onContact: match.canStartConversation ? () => _contact(match) : null,
          onViewListings: () => _showListings(match),
        );
      },
    );
  }
}

class _PublicUserListingsSheet extends StatefulWidget {
  const _PublicUserListingsSheet({
    required this.userService,
    required this.userId,
    required this.username,
  });

  final UserService userService;
  final String userId;
  final String username;

  @override
  State<_PublicUserListingsSheet> createState() =>
      _PublicUserListingsSheetState();
}

class _PublicUserListingsSheetState extends State<_PublicUserListingsSheet> {
  List<Map<String, dynamic>> _items = const [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final data = await widget.userService.getPublicUserListings(
        widget.userId,
        limit: 20,
      );
      if (!mounted) return;
      setState(() {
        _items = (data['items'] as List<dynamic>? ?? const [])
            .cast<Map<String, dynamic>>();
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error.toString();
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final scheme = Theme.of(context).colorScheme;
    return SafeArea(
      child: Center(
        child: Container(
          width: double.infinity,
          constraints: const BoxConstraints(maxWidth: 640, maxHeight: 620),
          margin: const EdgeInsets.fromLTRB(16, 48, 16, 16),
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: scheme.surface,
            borderRadius: const BorderRadius.all(Radius.circular(26)),
            border: Border.all(color: scheme.outlineVariant),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      l.classmateActiveListingsTitle(widget.username),
                      style: const TextStyle(
                        fontSize: 22,
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
              const SizedBox(height: 10),
              Flexible(child: _buildBody()),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBody() {
    final l = AppLocalizations.of(context)!;
    final scheme = Theme.of(context).colorScheme;
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return _CenteredMessage(
        icon: Icons.cloud_off_rounded,
        title: l.classmateListingsLoadFailedTitle,
        subtitle: _error!,
        action: TextButton(onPressed: _load, child: Text(l.retry)),
      );
    }
    if (_items.isEmpty) {
      return _CenteredMessage(
        icon: Icons.inventory_2_outlined,
        title: l.classmateListingsEmptyTitle,
        subtitle: l.classmateListingsEmptySubtitle,
      );
    }
    return ListView.separated(
      shrinkWrap: true,
      itemCount: _items.length,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (context, index) {
        final item = _items[index];
        final title = item['title']?.toString() ?? l.unnamedListing;
        final category = localizedCategoryLabel(
          context,
          item['category']?.toString(),
        );
        final price = (item['suggested_price_cny'] as num?)?.toDouble();
        return Card(
          margin: EdgeInsets.zero,
          child: ListTile(
            leading: Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: scheme.primaryContainer,
                borderRadius: BorderRadius.circular(14),
              ),
              child: Icon(
                Icons.inventory_2_outlined,
                color: scheme.onPrimaryContainer,
              ),
            ),
            title: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            subtitle: Text(
              price == null
                  ? category
                  : l.listingPriceLine(category, price.toStringAsFixed(2)),
            ),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () {
              Navigator.of(context).pop();
              context.push('/listing/${item['id']}');
            },
          ),
        );
      },
    );
  }
}

class _LookupHintCard extends StatelessWidget {
  const _LookupHintCard();

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: scheme.primaryContainer.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Text(
        l.lookupHint,
        style: TextStyle(color: scheme.onSurfaceVariant, height: 1.4),
      ),
    );
  }
}

class _LookupEmptyCard extends StatelessWidget {
  const _LookupEmptyCard();

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: scheme.secondaryContainer.withValues(alpha: 0.46),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Text(
        l.lookupEmpty,
        style: TextStyle(color: scheme.onSurfaceVariant, height: 1.4),
      ),
    );
  }
}

class _LookupResultCard extends StatelessWidget {
  const _LookupResultCard({
    required this.match,
    required this.onContact,
    required this.onViewListings,
  });

  final UserLookupMatch match;
  final VoidCallback? onContact;
  final VoidCallback onViewListings;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final scheme = Theme.of(context).colorScheme;
    final matchedBy = _lookupMethodLabel(l, match.matchedBy);
    final subtitle = match.maskedIdentifier == null
        ? l.lookupMatchedWithListings(matchedBy, match.listingCount)
        : l.lookupMatchedIdentifierWithListings(
            matchedBy,
            match.maskedIdentifier!,
            match.listingCount,
          );
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                _Avatar(name: match.username),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        match.username,
                        style: TextStyle(
                          color: scheme.onSurface,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        subtitle,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: scheme.onSurfaceVariant,
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: onViewListings,
                    child: Text(l.viewClassmateListings),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: FilledButton(
                    onPressed: onContact,
                    child: Text(l.contactAction),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _AssistantConversationCard extends StatelessWidget {
  const _AssistantConversationCard({
    required this.selected,
    required this.latestMessage,
    required this.onTap,
  });

  final bool selected;
  final ChatMessage? latestMessage;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Card(
      color: selected
          ? scheme.primaryContainer.withValues(alpha: 0.52)
          : scheme.surface,
      margin: EdgeInsets.zero,
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
        onTap: onTap,
        leading: Container(
          width: 46,
          height: 46,
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0xFF0F766E), Color(0xFF2AA897)],
            ),
            borderRadius: BorderRadius.circular(15),
          ),
          child: const Icon(Icons.auto_awesome_rounded, color: Colors.white),
        ),
        title: Row(
          children: [
            Expanded(
              child: Text(
                l.assistantName,
                style: const TextStyle(fontWeight: FontWeight.w800),
              ),
            ),
            const _SystemBadge(),
          ],
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 5),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  latestMessage?.content ?? l.assistantInboxSubtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: scheme.onSurfaceVariant),
                ),
              ),
              if (latestMessage != null) ...[
                const SizedBox(width: 8),
                Text(
                  _formatTime(latestMessage!.timestamp),
                  style: TextStyle(
                    color: scheme.onSurfaceVariant,
                    fontSize: 11,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  String _formatTime(DateTime value) {
    final local = value.toLocal();
    final now = DateTime.now();
    if (local.year == now.year &&
        local.month == now.month &&
        local.day == now.day) {
      return '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
    }
    return '${local.month}/${local.day}';
  }
}

class _SystemBadge extends StatelessWidget {
  const _SystemBadge();

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: scheme.primaryContainer,
        borderRadius: BorderRadius.circular(9),
      ),
      child: Text(
        l.assistantSystemBadge,
        style: TextStyle(
          color: scheme.onPrimaryContainer,
          fontSize: 11,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _PeerThreadCard extends StatelessWidget {
  const _PeerThreadCard({
    required this.thread,
    required this.selected,
    required this.onTap,
  });

  final ChatThread thread;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final scheme = Theme.of(context).colorScheme;
    final hasPending = thread.pendingCount > 0;
    final preview = thread.latestPreview?.trim();
    return Card(
      color: selected
          ? scheme.primaryContainer.withValues(alpha: 0.5)
          : hasPending
          ? scheme.tertiaryContainer.withValues(alpha: 0.32)
          : scheme.surface,
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        onTap: onTap,
        leading: _Avatar(name: thread.peerUsername),
        title: Row(
          children: [
            Expanded(
              child: Text(
                thread.peerUsername.isEmpty
                    ? l.conversationPeerFallback
                    : thread.peerUsername,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w900),
              ),
            ),
            if (hasPending) ...[
              const SizedBox(width: 8),
              _SmallStatusPill(
                label: l.conversationPendingCount(thread.pendingCount),
                color: scheme.tertiary,
                foreground: scheme.onTertiary,
              ),
            ],
          ],
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      preview == null || preview.isEmpty
                          ? (thread.latestListingTitle ??
                                l.conversationTimelineFallback)
                          : preview,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: scheme.onSurfaceVariant),
                    ),
                  ),
                  if (thread.unreadCount > 0) ...[
                    const SizedBox(width: 8),
                    _UnreadPill(count: thread.unreadCount),
                  ],
                ],
              ),
              const SizedBox(height: 7),
              Wrap(
                spacing: 6,
                runSpacing: 4,
                children: [
                  if (thread.realtimeCount > 0)
                    _SmallStatusPill(
                      label: l.conversationRealtimeCount(thread.realtimeCount),
                      color: scheme.primaryContainer,
                      foreground: scheme.onPrimaryContainer,
                    ),
                  if (thread.mailCount > 0)
                    _SmallStatusPill(
                      label: l.conversationMailCount(thread.mailCount),
                      color: scheme.secondaryContainer,
                      foreground: scheme.onSecondaryContainer,
                    ),
                  _SmallStatusPill(
                    label: l.conversationSegmentCount(thread.conversationCount),
                    color: scheme.surfaceContainerHighest,
                    foreground: scheme.onSurfaceVariant,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _UnreadPill extends StatelessWidget {
  const _UnreadPill({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: scheme.secondary,
        borderRadius: const BorderRadius.all(Radius.circular(12)),
      ),
      child: Text(
        '$count',
        style: TextStyle(
          color: scheme.onSecondary,
          fontSize: 12,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}

class _SmallStatusPill extends StatelessWidget {
  const _SmallStatusPill({
    required this.label,
    required this.color,
    required this.foreground,
  });

  final String label;
  final Color color;
  final Color foreground;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color,
        borderRadius: const BorderRadius.all(Radius.circular(999)),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: foreground,
          fontSize: 11,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}

class _SpaceCard extends StatelessWidget {
  const _SpaceCard({
    required this.space,
    required this.selected,
    required this.onTap,
  });

  final _ChatSpace space;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final scheme = Theme.of(context).colorScheme;
    return Card(
      color: selected
          ? scheme.primaryContainer.withValues(alpha: 0.5)
          : scheme.surface,
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        onTap: onTap,
        leading: _SpaceAvatar(space: space),
        title: Row(
          children: [
            Expanded(
              child: Text(
                space.displayName(l) ?? l.unnamedSpace,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w800),
              ),
            ),
            const SizedBox(width: 8),
            _SpaceKindBadge(space: space),
          ],
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 5),
          child: Text(
            space.description?.isNotEmpty == true
                ? space.description!
                : l.spaceFallbackDescription(
                    space.memberCount,
                    space.isChannel
                        ? l.spaceKindChannelLong
                        : l.spaceKindGroupLong,
                  ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: scheme.onSurfaceVariant),
          ),
        ),
        trailing: const Icon(Icons.chevron_right_rounded),
      ),
    );
  }
}

class _SpaceAvatar extends StatelessWidget {
  const _SpaceAvatar({required this.space});

  final _ChatSpace space;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return CircleAvatar(
      backgroundColor: space.isChannel
          ? scheme.secondaryContainer
          : scheme.primaryContainer,
      child: Icon(
        space.isChannel ? Icons.campaign_outlined : Icons.groups_2_outlined,
        color: space.isChannel
            ? scheme.onSecondaryContainer
            : scheme.onPrimaryContainer,
      ),
    );
  }
}

class _SpaceKindBadge extends StatelessWidget {
  const _SpaceKindBadge({required this.space});

  final _ChatSpace space;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final scheme = Theme.of(context).colorScheme;
    final color = space.isChannel ? scheme.secondary : scheme.primary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(9),
      ),
      child: Text(
        space.isChannel ? l.spaceKindChannel : l.spaceKindGroup,
        style: TextStyle(
          color: color,
          fontSize: 11,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _ModeBadge extends StatelessWidget {
  const _ModeBadge({required this.mode});
  final ConversationMode mode;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final scheme = Theme.of(context).colorScheme;
    final realtime = mode == ConversationMode.realtime;
    final color = realtime ? scheme.primary : scheme.secondary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(9),
      ),
      child: Text(
        _modeLabel(l, mode),
        style: TextStyle(
          color: color,
          fontSize: 11,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _Avatar extends StatelessWidget {
  const _Avatar({required this.name});
  final String name;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return CircleAvatar(
      backgroundColor: scheme.primaryContainer,
      child: Text(
        name.isEmpty ? '?' : name.characters.first.toUpperCase(),
        style: TextStyle(
          color: scheme.onPrimaryContainer,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}

class _FilterChip extends StatelessWidget {
  const _FilterChip({
    required this.label,
    required this.selected,
    required this.onTap,
    this.icon,
  });
  final String label;
  final IconData? icon;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ChoiceChip(
      label: Text(label),
      avatar: icon == null ? null : Icon(icon, size: 16),
      selected: selected,
      onSelected: (_) => onTap(),
    );
  }
}

String _lookupMethodLabel(AppLocalizations l, String method) =>
    switch (method) {
      'email' => l.lookupMethodEmail,
      'student_id' => l.lookupMethodStudentId,
      _ => l.lookupMethodUsername,
    };

String _modeLabel(AppLocalizations l, ConversationMode mode) {
  return mode == ConversationMode.realtime ? l.modeRealtime : l.modeMail;
}

String _conversationStateLabel(AppLocalizations l, Conversation conversation) {
  if (conversation.mode == ConversationMode.mail) {
    return l.conversationStateDelivered;
  }
  return switch (conversation.state) {
    ConversationState.synSent => l.conversationStateSynSent,
    ConversationState.synAck => l.conversationStateSynAck,
    ConversationState.active => l.conversationStateActive,
    ConversationState.declined => l.conversationStateDeclined,
    ConversationState.cancelled => l.conversationStateCancelled,
    ConversationState.expired => l.conversationStateExpired,
    ConversationState.closed => l.conversationStateClosed,
    ConversationState.open => l.conversationStateDelivered,
  };
}

String _spaceRoleLabel(AppLocalizations l, String role) {
  return switch (role) {
    'owner' => l.spaceRoleOwner,
    'admin' => l.spaceRoleAdmin,
    'banned' => l.spaceRoleBanned,
    _ => l.spaceRoleMember,
  };
}

String _formatSpaceTime(DateTime value) {
  final local = value.toLocal();
  final now = DateTime.now();
  if (local.year == now.year &&
      local.month == now.month &&
      local.day == now.day) {
    return '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
  }
  return '${local.month}/${local.day} ${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
}

class _ConversationEmptyCanvas extends StatelessWidget {
  const _ConversationEmptyCanvas();

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    return _CenteredMessage(
      icon: Icons.forum_outlined,
      title: l.conversationChooseTitle,
      subtitle: l.conversationChooseSubtitle,
    );
  }
}

class _InlineEmptyMessage extends StatelessWidget {
  const _InlineEmptyMessage({
    required this.icon,
    required this.title,
    required this.subtitle,
    this.action,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 4),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 28, 24, 28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 42, color: scheme.onSurfaceVariant),
            const SizedBox(height: 12),
            Text(
              title,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: scheme.onSurface,
                fontSize: 17,
                fontWeight: FontWeight.w900,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: TextStyle(color: scheme.onSurfaceVariant, height: 1.35),
            ),
            if (action != null) ...[const SizedBox(height: 16), action!],
          ],
        ),
      ),
    );
  }
}

class _CenteredMessage extends StatelessWidget {
  const _CenteredMessage({
    required this.icon,
    required this.title,
    required this.subtitle,
    this.action,
  });
  final IconData icon;
  final String title;
  final String subtitle;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (context, constraints) {
        return SingleChildScrollView(
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: constraints.maxHeight),
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(icon, size: 48, color: scheme.onSurfaceVariant),
                    const SizedBox(height: 14),
                    Text(
                      title,
                      style: TextStyle(
                        color: scheme.onSurface,
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      subtitle,
                      textAlign: TextAlign.center,
                      style: TextStyle(color: scheme.onSurfaceVariant),
                    ),
                    if (action != null) ...[
                      const SizedBox(height: 12),
                      action!,
                    ],
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
