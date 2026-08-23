import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../components/relationship_space_preview.dart';
import '../components/unified_message_composer.dart';
import '../components/user_avatar.dart';
import '../l10n/app_localizations.dart';
import '../models/models.dart';
import '../services/chat_service.dart';
import '../services/chat_local_seen_storage.dart';
import '../services/user_service.dart';
import '../services/ws_service.dart';
import '../theme/app_theme.dart';
import '../utils/category_utils.dart';

AppLocalizations l10n(BuildContext context) => AppLocalizations.of(context)!;

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
    _wsSubscription = WsService.instance.stream.listen((notification) {
      if (!mounted) return;
      if ({
        'conversation_created',
        'conversation_state_changed',
        'new_message',
        'message_acknowledgement_changed',
        'shared_object_created',
        'shared_object_revoked',
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
        _chatService.getThreads(),
        _chatService.getSpaces(),
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
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = error.toString();
      });
    }
  }

  Future<void> _refreshAll() async {
    await _load();
  }

  Future<ChatThread> _applyLocalSeen(ChatThread thread) async {
    try {
      // The server no longer supplies unread counts.  A local marker is the
      // only source for this badge, so an unseen latest activity is shown as
      // one new item without exposing a reading position remotely.
      final seenAt = await _localSeenStorage
          .read(thread.peerUserId)
          .timeout(const Duration(milliseconds: 100));
      return thread.copyWith(
        unreadCount: seenAt == null || thread.latestActivityAt.isAfter(seenAt)
            ? 1
            : 0,
      );
    } catch (_) {
      // If local storage is unavailable, do not invent a server-derived
      // count; the next successful local read will restore the badge.
      return thread.copyWith(unreadCount: 0);
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
    // Clicking a contact lands on their profile; connect / mail / history
    // are chosen from there.
    context.push('/users/${thread.peerUserId}');
  }

  void _openSpace(_ChatSpace space) {
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

  Future<void> _createSpace() async {
    final l = AppLocalizations.of(context)!;
    final draft = await showDialog<_CreateSpaceDraft>(
      context: context,
      builder: (context) => const _CreateSpaceDialog(),
    );
    if (draft == null) return;
    try {
      final data = await _chatService.createSpace(
        kind: 'group',
        name: draft.name,
        description: draft.description,
      );
      final space = _ChatSpace.fromJson(data);
      if (!mounted) return;
      setState(() {
        _spaces = [space, ..._spaces.where((item) => item.id != space.id)];
      });
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l.conversationCreateGroupSuccess)));
      _openSpace(space);
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
                  _createSpace();
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
            ],
          ),
        ],
      ),
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: _buildInbox(),
        ),
      ),
    );
  }

  Widget _buildInbox() {
    return _buildConversationList();
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
      onRefresh: _refreshAll,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
        children: [
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
              // Keep this state focused on starting a conversation. Publishing
              // remains available from the persistent global destination.
              child: _InlineEmptyMessage(
                icon: Icons.forum_outlined,
                title: l.conversationEmptyTitle,
                subtitle: l.conversationEmptySubtitle,
                action: Wrap(
                  alignment: WrapAlignment.center,
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    TextButton.icon(
                      onPressed: _openUserLookup,
                      icon: const Icon(Icons.person_search_rounded, size: 18),
                      label: Text(l.findClassmate),
                    ),
                    TextButton.icon(
                      onPressed: () => context.go('/'),
                      icon: const Icon(Icons.explore_outlined, size: 18),
                      label: Text(l.postDiscoveryTitle),
                    ),
                  ],
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
                selected: false,
                onTap: () => _openThread(thread),
              ),
            ),
          ],
          ...regular.map(
            (thread) => _PeerThreadCard(
              thread: thread,
              selected: false,
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
                selected: false,
                onTap: () => _openSpace(space),
              ),
            ),
            const SizedBox(height: 12),
          ],
        ],
      ),
    );
  }
}

class ChatThreadPage extends StatelessWidget {
  const ChatThreadPage({
    super.key,
    required this.peerUserId,
    this.initialThread,
    this.chatService,
    this.userService,
  });

  final String peerUserId;
  final ChatThread? initialThread;
  final ChatService? chatService;
  final UserService? userService;

  @override
  Widget build(BuildContext context) {
    final service = chatService ?? context.read<ChatService>();
    UserService? users = userService;
    if (users == null) {
      // The role layer is optional for embedders and older test hosts. The
      // thread still renders with default system Avatars when no user service is
      // registered.
      try {
        users = context.read<UserService>();
      } catch (_) {}
    }
    return _ChatThreadDetailPane(
      chatService: service,
      userService: users,
      peerUserId: peerUserId,
      initialThread: initialThread,
    );
  }
}

class _ChatThreadDetailPane extends StatefulWidget {
  const _ChatThreadDetailPane({
    required this.chatService,
    this.userService,
    required this.peerUserId,
    this.initialThread,
  });

  final ChatService chatService;
  final UserService? userService;
  final String peerUserId;
  final ChatThread? initialThread;

  @override
  State<_ChatThreadDetailPane> createState() => _ChatThreadDetailPaneState();
}

class _ChatThreadDetailPaneState extends State<_ChatThreadDetailPane> {
  ChatThread? _thread;
  SocialPersona? _selfPersona;
  RelationshipSpace? _relationshipSpace;
  List<Conversation> _conversations = const [];
  ConversationMode? _historyFilter;
  Set<String> _expandedIds = const {};
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _thread = widget.initialThread;
    _loadThread();
    _loadOwnPersona();
    _loadRelationshipSpace();
  }

  @override
  void didUpdateWidget(covariant _ChatThreadDetailPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.peerUserId != widget.peerUserId) {
      _thread = widget.initialThread;
      _conversations = const [];
      _expandedIds = const {};
      _relationshipSpace = null;
      _loadThread();
      _loadRelationshipSpace();
    }
  }

  Future<void> _loadRelationshipSpace() async {
    final peerUserId = widget.peerUserId;
    try {
      final space = await widget.chatService.getRelationshipSpace(peerUserId);
      if (!mounted || widget.peerUserId != peerUserId) return;
      setState(() => _relationshipSpace = space);
    } catch (_) {
      // Failure does not block thread message view
    }
  }

  Future<void> _loadThread({bool silent = false}) async {
    final peerUserId = widget.peerUserId;
    if (!silent) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final detail = await widget.chatService.getThread(peerUserId);
      if (!mounted || widget.peerUserId != peerUserId) {
        return;
      }
      setState(() {
        _thread = detail.thread;
        _conversations = detail.conversations;
        _expandedIds = _defaultExpandedIds(detail.conversations);
        _loading = false;
        _error = null;
      });
    } catch (error) {
      if (!mounted || widget.peerUserId != peerUserId) {
        return;
      }
      setState(() {
        _loading = false;
        _error = error.toString();
      });
    }
  }

  Future<void> _loadOwnPersona() async {
    final service = widget.userService;
    if (service == null) return;
    try {
      final persona = await service.getSocialPersona();
      if (!mounted) return;
      setState(() {
        // A draft or archived record is private presentation state and must
        // never become a shared-space anchor. The default system Avatar remains the
        // safe fallback when the role service is unavailable.
        _selfPersona = persona?.isPublished == true ? persona : null;
      });
    } catch (_) {
      // The role layer is optional; the thread and message history remain
      // usable when the persona endpoint is unavailable.
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

  @override
  Widget build(BuildContext context) {
    final body = Column(
      children: [
        _buildHeader(),
        Expanded(child: _buildContent()),
      ],
    );
    return Scaffold(
      appBar: AppBar(title: Text(_displayName)),
      body: body,
    );
  }

  Widget _buildHistoryFilterRow() {
    final l = AppLocalizations.of(context)!;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: [
          _HistoryFilterChip(
            label: l.conversationFilterAll,
            selected: _historyFilter == null,
            onTap: () => setState(() => _historyFilter = null),
          ),
          const SizedBox(width: 8),
          _HistoryFilterChip(
            label: l.conversationFilterRealtime,
            icon: Icons.bolt_rounded,
            selected: _historyFilter == ConversationMode.realtime,
            onTap: () =>
                setState(() => _historyFilter = ConversationMode.realtime),
          ),
          const SizedBox(width: 8),
          _HistoryFilterChip(
            label: l.conversationFilterMail,
            icon: Icons.mark_email_unread_outlined,
            selected: _historyFilter == ConversationMode.mail,
            onTap: () => setState(() => _historyFilter = ConversationMode.mail),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader() {
    final l = AppLocalizations.of(context)!;
    final scheme = Theme.of(context).colorScheme;
    final thread = _thread;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
      decoration: BoxDecoration(
        color: scheme.surface,
        border: Border(bottom: BorderSide(color: scheme.outlineVariant)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              UserAvatar(
                name: _displayName,
                persona: thread?.peerPersona,
                size: 48,
              ),
              const SizedBox(width: 10),
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
                          : (thread.latestPreview ??
                                l.conversationTimelineFallback),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: scheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
            ],
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
    final visibleConversations = _historyFilter == null
        ? _conversations
        : _conversations
              .where((conversation) => conversation.mode == _historyFilter)
              .toList(growable: false);
    return RefreshIndicator(
      onRefresh: _loadThread,
      child: ListView.builder(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 28),
        itemCount: visibleConversations.length + 1,
        itemBuilder: (context, index) {
          if (index == 0) {
            return _buildHistoryFilterRow();
          }
          final conversation = visibleConversations[index - 1];
          final expanded = _expandedIds.contains(conversation.id);
          final relationshipSpace = _relationshipSpaceFor(conversation.id);
          return _ConversationSegmentCard(
            conversation: conversation,
            initiallyExpanded: expanded,
            onOpen: () => _openConversation(conversation),
            peerName: _displayName,
            peerPersona:
                _thread?.peerPersona ?? widget.initialThread?.peerPersona,
            selfPersona: _selfPersona,
            relationshipSpace: relationshipSpace,
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

  RelationshipSpace? _relationshipSpaceFor(String conversationId) {
    final space = _relationshipSpace;
    if (space == null) return null;
    return RelationshipSpace(
      relationshipKey: space.relationshipKey,
      events: space.events
          .where((event) => event.conversationId == conversationId)
          .toList(growable: false),
      pins: space.pins
          .where((pin) => pin.conversationId == conversationId)
          .toList(growable: false),
      sharedObjects: space.sharedObjects
          .where((object) => object.conversationId == conversationId)
          .toList(growable: false),
      recentConnection: space.recentConnection?.conversationId == conversationId
          ? space.recentConnection
          : null,
      nextCursor: space.nextCursor,
    );
  }

  String get _displayName {
    final name = _thread?.peerUsername ?? widget.initialThread?.peerUsername;
    if (name != null && name.isNotEmpty) return name;
    return AppLocalizations.of(context)!.conversationPeerFallback;
  }

  void _openConversation(Conversation conversation) {
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
    required this.onOpen,
    required this.onExpansionChanged,
    this.peerName,
    this.peerPersona,
    this.selfPersona,
    this.relationshipSpace,
  });

  final Conversation conversation;
  final bool initiallyExpanded;
  final VoidCallback onOpen;
  final ValueChanged<bool> onExpansionChanged;
  final String? peerName;
  final SocialPersona? peerPersona;
  final SocialPersona? selfPersona;
  final RelationshipSpace? relationshipSpace;

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
    final displayName = (peerName != null && peerName!.isNotEmpty)
        ? peerName!
        : (conversation.otherUsername.isNotEmpty
              ? conversation.otherUsername
              : l.conversationPeerFallback);
    final openLabel = '${l.conversationOpenSegment}：$displayName';
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      clipBehavior: Clip.antiAlias,
      child: ExpansionTile(
        key: PageStorageKey('conversation-segment-${conversation.id}'),
        initiallyExpanded: initiallyExpanded,
        onExpansionChanged: onExpansionChanged,
        leading: InkWell(
          onTap: onOpen,
          excludeFromSemantics: true,
          borderRadius: BorderRadius.circular(AppTheme.radiusMd),
          child: UserAvatar(name: displayName, persona: peerPersona, size: 48),
        ),
        title: Semantics(
          button: true,
          label: openLabel,
          hint: title,
          excludeSemantics: true,
          child: InkWell(
            onTap: onOpen,
            borderRadius: BorderRadius.circular(AppTheme.radiusSm),
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w900),
            ),
          ),
        ),
        subtitle: InkWell(
          onTap: onOpen,
          excludeFromSemantics: true,
          borderRadius: BorderRadius.circular(AppTheme.radiusSm),
          child: Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (conversation.lastMessage != null) ...[
                  Text(
                    conversation.lastMessage!,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: scheme.onSurface),
                  ),
                  const SizedBox(height: 6),
                ],
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    _ModeBadge(mode: conversation.mode),
                    Text(
                      _conversationStateLabel(l, conversation),
                      style: TextStyle(color: scheme.onSurfaceVariant),
                    ),
                    if (conversation.mode == ConversationMode.mail &&
                        conversation.mailExpectation == MailExpectation.today)
                      Text(
                        '· ${l.contactMailExpectationToday}',
                        style: TextStyle(color: scheme.onSurfaceVariant),
                      ),
                    if (conversation.unreadCount > 0)
                      _UnreadPill(count: conversation.unreadCount),
                  ],
                ),
              ],
            ),
          ),
        ),
        children: [
          if (conversation.mode == ConversationMode.realtime)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              child: RelationshipSpacePreview(
                otherName: displayName,
                otherPersona: peerPersona,
                selfPersona: selfPersona,
                events: relationshipSpace?.events ?? const [],
                pins: relationshipSpace?.pins ?? const [],
                pinCount: relationshipSpace?.pins.length ?? 0,
                sharedObjects: relationshipSpace?.sharedObjects ?? const [],
                sharedObjectCount: relationshipSpace?.sharedObjects.length ?? 0,
                recentConnection: relationshipSpace?.recentConnection,
                hasRecentConnection:
                    relationshipSpace?.recentConnection != null,
                isConnected: conversation.state.isLiveRealtime,
                initiallyExpanded: true,
                showRecentRecords: false,
              ),
            ),
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
    return InkWell(
      onTap: onOpen,
      borderRadius: const BorderRadius.vertical(bottom: Radius.circular(12)),
      child: Container(
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
            const SizedBox(height: 10),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  isTerminal
                      ? l.conversationViewHistory
                      : l.conversationOpenSegment,
                  style: TextStyle(
                    color: scheme.primary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(width: 4),
                Icon(
                  Icons.arrow_forward_rounded,
                  size: 17,
                  color: scheme.primary,
                ),
              ],
            ),
          ],
        ),
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
  int _loadGeneration = 0;

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

  @override
  void dispose() {
    super.dispose();
  }

  Future<void> _loadSpace({bool silent = false}) async {
    final generation = ++_loadGeneration;
    if (!silent) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final data = await _chatService.getSpace(widget.spaceId);
      if (!mounted || generation != _loadGeneration) return;
      final previous = _space?.toJson() ?? const <String, dynamic>{};
      final next = _ChatSpace.fromJson({...previous, ...data});
      setState(() {
        _space = next;
        _loading = false;
        _error = null;
      });
    } catch (error) {
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        if (_space == null) _error = error.toString();
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
            onRefreshSpace: () => _loadSpace(silent: true),
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
  const _CreateSpaceDialog();

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
      title: Text(l.createGroup),
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
    this.origin,
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
  final String? origin;

  bool get canPost => true;
  String? displayName(AppLocalizations l) =>
      name.trim().isEmpty ? l.unnamedSpace : name;

  _ChatSpace copyWith({String? origin}) {
    return _ChatSpace(
      id: id,
      kind: kind,
      name: name,
      ownerId: ownerId,
      myRole: myRole,
      memberCount: memberCount,
      createdAt: createdAt,
      updatedAt: updatedAt,
      description: description,
      origin: origin ?? this.origin,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'kind': kind,
    'name': name,
    'description': description,
    'owner_id': ownerId,
    'my_role': myRole,
    'member_count': memberCount,
    'origin': origin,
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
      origin: json['origin']?.toString(),
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
    required this.chatService,
    required this.space,
    required this.onRefreshSpace,
  });

  final ChatService chatService;
  final _ChatSpace space;
  final Future<void> Function() onRefreshSpace;

  @override
  State<_SpaceDetailPane> createState() => _SpaceDetailPaneState();
}

class _SpaceDetailPaneState extends State<_SpaceDetailPane> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();
  List<_SpaceMessage> _messages = const [];
  int? _selectedTopicId;
  bool _loading = true;
  bool _sending = false;
  String? _error;
  int _loadGeneration = 0;

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
      _selectedTopicId = null;
      _messages = const [];
      _loadMessages();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  Future<void> _loadMessages({bool silent = false}) async {
    final generation = ++_loadGeneration;
    if (!silent || _messages.isEmpty) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final rows = await widget.chatService.getSpaceMessages(widget.space.id);
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _messages = rows.map(_SpaceMessage.fromJson).toList();
        if (_selectedTopicId != null &&
            !_messages.any(
              (message) =>
                  message.id == _selectedTopicId &&
                  message.replyToMessageId == null,
            )) {
          _selectedTopicId = null;
        }
        _loading = false;
        _error = null;
      });
    } catch (error) {
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        if (_messages.isEmpty) _error = error.toString();
        _loading = false;
      });
    }
  }

  Future<void> _refreshAll() async {
    await Future.wait([_loadMessages(silent: true), widget.onRefreshSpace()]);
  }

  Future<void> _send() async {
    final l = AppLocalizations.of(context)!;
    final text = _controller.text.trim();
    final topic = _selectedTopic;
    if (text.isEmpty || _sending || topic == null) return;
    setState(() => _sending = true);
    try {
      await widget.chatService.sendSpaceMessage(
        widget.space.id,
        content: text,
        replyToMessageId: topic.id.toString(),
      );
      _controller.clear();
      await _refreshAll();
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l.spaceSendFailed(error.toString()))),
      );
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  _SpaceMessage? get _selectedTopic {
    final id = _selectedTopicId;
    if (id == null) return null;
    for (final message in _messages) {
      if (message.id == id && message.replyToMessageId == null) return message;
    }
    return null;
  }

  List<_SpaceMessage> get _topics =>
      _messages.where((message) => message.replyToMessageId == null).toList()
        ..sort((a, b) => b.createdAt.compareTo(a.createdAt));

  List<_SpaceMessage> _repliesFor(int topicId) {
    final replies = _messages
        .where(
          (message) =>
              message.replyToMessageId != null &&
              _rootTopicId(message) == topicId,
        )
        .toList();
    replies.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    return replies;
  }

  int? _rootTopicId(_SpaceMessage message) {
    var parentId = message.replyToMessageId;
    final visited = <int>{message.id};
    while (parentId != null && visited.add(parentId)) {
      _SpaceMessage? parent;
      for (final candidate in _messages) {
        if (candidate.id == parentId) {
          parent = candidate;
          break;
        }
      }
      if (parent == null) return parentId;
      if (parent.replyToMessageId == null) return parent.id;
      parentId = parent.replyToMessageId;
    }
    return null;
  }

  Future<void> _createTopic() async {
    final l = AppLocalizations.of(context)!;
    var draft = '';
    final content = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l.startGroupTopic),
        content: TextField(
          key: const Key('group-topic-field'),
          autofocus: true,
          maxLength: 140,
          maxLines: 3,
          textInputAction: TextInputAction.done,
          decoration: InputDecoration(
            hintText: l.groupTopicTitleHint,
            helperText: l.groupTopicCreateHint,
          ),
          onChanged: (value) => draft = value,
          onSubmitted: (value) {
            final text = value.trim();
            if (text.isNotEmpty) Navigator.pop(dialogContext, text);
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(l.cancel),
          ),
          FilledButton(
            key: const Key('group-topic-create'),
            onPressed: () {
              final text = draft.trim();
              if (text.isNotEmpty) Navigator.pop(dialogContext, text);
            },
            child: Text(l.createTopicAction),
          ),
        ],
      ),
    );
    if (content == null || !mounted) return;
    setState(() => _sending = true);
    try {
      final data = await widget.chatService.sendSpaceMessage(
        widget.space.id,
        content: content,
      );
      final topic = _SpaceMessage.fromJson(data);
      await _refreshAll();
      if (mounted) {
        setState(() => _selectedTopicId = topic.id);
        _focusNode.requestFocus();
      }
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
        Expanded(child: _buildTopicSurface()),
        if (_selectedTopic == null)
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  key: const Key('group-start-topic'),
                  onPressed: _sending ? null : _createTopic,
                  icon: const Icon(Icons.add_comment_outlined),
                  label: Text(l.startGroupTopic),
                ),
              ),
            ),
          )
        else
          _buildComposer(),
      ],
    );
  }

  Widget _buildTopicSurface() {
    final l = AppLocalizations.of(context)!;
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return _CenteredMessage(
        icon: Icons.cloud_off_rounded,
        title: l.spaceMessagesLoadFailedTitle,
        subtitle: _error!,
        action: TextButton(onPressed: _loadMessages, child: Text(l.retry)),
      );
    }
    final selectedTopic = _selectedTopic;
    if (selectedTopic != null) return _buildTopicDiscussion(selectedTopic);
    if (_topics.isEmpty) {
      return _CenteredMessage(
        icon: Icons.topic_outlined,
        title: l.groupTopicEmptyTitle,
        subtitle: l.groupTopicEmptySubtitle,
      );
    }
    return RefreshIndicator(
      onRefresh: _refreshAll,
      child: ListView.separated(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
        itemCount: _topics.length + 1,
        separatorBuilder: (_, _) => const SizedBox(height: 10),
        itemBuilder: (context, index) {
          if (index == 0) {
            return ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.forum_outlined),
              title: Text(
                l.groupTopicsTitle,
                style: const TextStyle(fontWeight: FontWeight.w900),
              ),
              subtitle: Text(l.groupTopicsSubtitle),
            );
          }
          final topic = _topics[index - 1];
          final replyCount = _repliesFor(topic.id).length;
          return _TopicCard(
            topic: topic,
            replyCount: replyCount,
            onTap: () {
              setState(() => _selectedTopicId = topic.id);
              _focusNode.requestFocus();
            },
          );
        },
      ),
    );
  }

  Widget _buildTopicDiscussion(_SpaceMessage topic) {
    final l = AppLocalizations.of(context)!;
    final scheme = Theme.of(context).colorScheme;
    final replies = _repliesFor(topic.id);
    return Column(
      children: [
        Material(
          color: scheme.surfaceContainerLow,
          child: ListTile(
            key: const Key('group-topic-back'),
            leading: const Icon(Icons.arrow_back_rounded),
            title: Text(
              topic.content,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w800),
            ),
            subtitle: Text(l.groupTopicStartedBy(topic.displaySender)),
            onTap: () {
              _controller.clear();
              setState(() => _selectedTopicId = null);
            },
          ),
        ),
        Expanded(
          child: replies.isEmpty
              ? _CenteredMessage(
                  icon: Icons.chat_bubble_outline_rounded,
                  title: l.groupTopicNoRepliesTitle,
                  subtitle: l.groupTopicNoRepliesSubtitle,
                )
              : RefreshIndicator(
                  onRefresh: _refreshAll,
                  child: ListView.separated(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.all(18),
                    itemCount: replies.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 10),
                    itemBuilder: (context, index) =>
                        _TopicReplyCard(message: replies[index]),
                  ),
                ),
        ),
      ],
    );
  }

  Widget _buildComposer() {
    final l = AppLocalizations.of(context)!;
    return UnifiedMessageComposer(
      controller: _controller,
      focusNode: _focusNode,
      hintText: l.groupTopicReplyHint,
      enabled: _selectedTopic != null,
      isSending: _sending,
      onSubmitted: (_) => _send(),
      onSend: _send,
      expandedActions: [
        MessageComposerAction(
          id: 'relay',
          icon: Icons.format_list_numbered_rounded,
          label: l.groupToolRelay,
          onPressed: () => _applySpaceTemplate(l.groupToolRelayTemplate),
        ),
        MessageComposerAction(
          id: 'collection',
          icon: Icons.inventory_2_outlined,
          label: l.groupToolCollection,
          onPressed: () => _applySpaceTemplate(l.groupToolCollectionTemplate),
        ),
        MessageComposerAction(
          id: 'poll',
          icon: Icons.poll_outlined,
          label: l.groupToolPoll,
          onPressed: () => _applySpaceTemplate(l.groupToolPollTemplate),
        ),
      ],
    );
  }

  void _applySpaceTemplate(String template) {
    _controller.value = TextEditingValue(
      text: template,
      selection: TextSelection.collapsed(offset: template.length),
    );
    _focusNode.requestFocus();
  }
}

class _TopicCard extends StatelessWidget {
  const _TopicCard({
    required this.topic,
    required this.replyCount,
    required this.onTap,
  });

  final _SpaceMessage topic;
  final int replyCount;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final l = AppLocalizations.of(context)!;
    return InkWell(
      key: ValueKey('group-topic-${topic.id}'),
      borderRadius: BorderRadius.circular(18),
      onTap: onTap,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest.withValues(alpha: 0.62),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: scheme.outlineVariant),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              topic.content,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w800, height: 1.35),
            ),
            const SizedBox(height: 9),
            Row(
              children: [
                Expanded(
                  child: Text(
                    '${topic.displaySender} · ${_formatSpaceTime(topic.createdAt)}',
                    style: TextStyle(
                      color: scheme.onSurfaceVariant,
                      fontSize: 12,
                    ),
                  ),
                ),
                const Icon(Icons.chat_bubble_outline_rounded, size: 16),
                const SizedBox(width: 5),
                Text(l.groupTopicReplyCount(replyCount)),
                const SizedBox(width: 4),
                const Icon(Icons.chevron_right_rounded, size: 18),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _TopicReplyCard extends StatelessWidget {
  const _TopicReplyCard({required this.message});

  final _SpaceMessage message;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Align(
      alignment: Alignment.centerLeft,
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
              style: TextStyle(
                color: scheme.primary,
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 5),
            Text(message.content, style: const TextStyle(height: 1.35)),
            const SizedBox(height: 6),
            Text(
              _formatSpaceTime(message.createdAt),
              style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 11),
            ),
          ],
        ),
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

  void _contact(UserLookupMatch match) {
    // Clicking a contact lands on their profile first; connect / mail /
    // history are chosen from there.
    Navigator.of(context).pop();
    context.push('/users/${match.userId}');
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
                UserAvatar(name: match.username, size: 48),
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
        leading: UserAvatar(
          name: thread.peerUsername,
          persona: thread.peerPersona,
          size: 48,
        ),
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
          ],
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 5),
          child: Text(
            space.description?.isNotEmpty == true
                ? space.description!
                : l.spaceFallbackDescription(
                    space.memberCount,
                    l.spaceKindGroupLong,
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
      backgroundColor: scheme.primaryContainer,
      child: Icon(Icons.groups_2_outlined, color: scheme.onPrimaryContainer),
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

class _HistoryFilterChip extends StatelessWidget {
  const _HistoryFilterChip({
    required this.label,
    required this.selected,
    required this.onTap,
    this.icon,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return FilterChip(
      selected: selected,
      onSelected: (_) => onTap(),
      avatar: icon == null
          ? null
          : Icon(
              icon,
              size: 16,
              color: selected ? scheme.onSecondaryContainer : scheme.primary,
            ),
      label: Text(label),
      labelStyle: TextStyle(
        fontWeight: FontWeight.w700,
        color: selected ? scheme.onSecondaryContainer : scheme.onSurfaceVariant,
      ),
      selectedColor: scheme.secondaryContainer,
      checkmarkColor: Colors.transparent,
      showCheckmark: false,
      visualDensity: VisualDensity.compact,
    );
  }
}
