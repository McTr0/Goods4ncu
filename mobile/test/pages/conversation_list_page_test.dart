import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:goods4ncu_mobile/components/social_persona_card.dart';
import 'package:goods4ncu_mobile/components/user_avatar.dart';
import 'package:goods4ncu_mobile/l10n/app_localizations.dart';
import 'package:goods4ncu_mobile/models/location_space.dart';
import 'package:goods4ncu_mobile/models/models.dart';
import 'package:goods4ncu_mobile/pages/conversation_list_page.dart';
import 'package:goods4ncu_mobile/services/chat_service.dart';
import 'package:goods4ncu_mobile/services/campus_location_service.dart';
import 'package:goods4ncu_mobile/services/user_service.dart';
import 'package:goods4ncu_mobile/theme/app_theme.dart';

class _FakeChatService extends ChatService {
  _FakeChatService({
    this.failConversations = false,
    List<ChatThread>? threads,
    this.conversations = const [],
    this.locationSpaces = const [],
    this.locationRecommendation,
  }) : threads = threads ?? const [];

  final bool failConversations;
  final List<ChatThread> threads;
  final List<Conversation> conversations;
  final List<CampusLocationSpace> locationSpaces;
  final CampusLocationSpace? locationRecommendation;
  String? joinedLocationSpaceId;
  int locationPresenceCalls = 0;
  final List<Map<String, dynamic>> spaces = [];
  final List<Map<String, dynamic>> spaceMessages = [];

  @override
  Future<List<CampusLocationSpace>> getLocationSpaces() async => locationSpaces;

  @override
  Future<CampusLocationRecommendation> recommendLocationSpace({
    required double latitude,
    required double longitude,
  }) async {
    return CampusLocationRecommendation(
      matched: locationRecommendation != null,
      space: locationRecommendation,
    );
  }

  @override
  Future<Map<String, dynamic>> joinLocationSpace(String spaceId) async {
    joinedLocationSpaceId = spaceId;
    return {
      'id': spaceId,
      'kind': 'group',
      'name': locationRecommendation?.name ?? '地点聊天室',
      'my_role': 'member',
      'member_count': 2,
      'created_at': '2026-08-16T10:00:00Z',
      'updated_at': '2026-08-16T10:00:00Z',
    };
  }

  @override
  Future<Map<String, dynamic>> enterLocationSpace(String spaceId) async {
    joinedLocationSpaceId = spaceId;
    return {
      'id': spaceId,
      'kind': 'group',
      'name': locationRecommendation?.name ?? '地点聊天室',
      'my_role': 'visitor',
      'member_count': 12,
      'online_count': 4,
      'is_location_space': true,
      'origin': 'campus_location',
      'created_at': '2026-08-16T10:00:00Z',
      'updated_at': '2026-08-16T10:00:00Z',
    };
  }

  @override
  Future<CampusLocationPresence> setLocationSpacePresence(
    String spaceId, {
    required bool active,
  }) async {
    if (active) locationPresenceCalls++;
    return const CampusLocationPresence(onlineCount: 4, expiresInSeconds: 30);
  }

  void seedSpace({
    String id = 'space-seeded',
    String kind = 'group',
    String name = '已存在群组',
    String? description,
  }) {
    spaces.insert(0, {
      'id': id,
      'kind': kind,
      'name': name,
      'description': description,
      'owner_id': 'b0000000-0000-0000-0000-000000000001',
      'my_role': 'owner',
      'member_count': 1,
      'created_at': '2026-07-06T10:00:00Z',
      'updated_at': '2026-07-06T10:00:00Z',
    });
  }

  @override
  Future<List<ChatThread>> getThreads({
    ConversationMode? mode,
    int limit = 50,
  }) async {
    if (failConversations) throw Exception('direct chat unavailable');
    return threads.where((thread) {
      if (mode == ConversationMode.realtime) return thread.realtimeCount > 0;
      if (mode == ConversationMode.mail) return thread.mailCount > 0;
      return true;
    }).toList();
  }

  @override
  Future<ChatThreadDetail> getThread(
    String peerUserId, {
    ConversationMode? mode,
  }) async {
    final thread = threads.firstWhere((item) => item.peerUserId == peerUserId);
    return ChatThreadDetail(thread: thread, conversations: conversations);
  }

  @override
  Future<Map<String, dynamic>> createSpace({
    required String kind,
    required String name,
    String? description,
  }) async {
    seedSpace(
      id: 'space-${spaces.length + 1}',
      kind: kind,
      name: name,
      description: description,
    );
    return spaces.first;
  }

  @override
  Future<List<Map<String, dynamic>>> getSpaces({String? kind}) async {
    return spaces
        .where((item) => kind == null || item['kind'] == kind)
        .toList();
  }

  @override
  Future<List<Map<String, dynamic>>> getSpaceMessages(
    String spaceId, {
    int limit = 50,
    int offset = 0,
  }) async {
    return spaceMessages
        .where((message) => message['space_id'] == spaceId)
        .toList();
  }

  @override
  Future<Map<String, dynamic>> sendSpaceMessage(
    String spaceId, {
    required String content,
    String? replyToMessageId,
  }) async {
    final message = <String, dynamic>{
      'id': spaceMessages.length + 1,
      'space_id': spaceId,
      'sender_id': 'b0000000-0000-0000-0000-000000000001',
      'sender_username': '测试同学',
      'content': content,
      if (replyToMessageId != null)
        'reply_to_message_id': int.parse(replyToMessageId),
      'created_at': '2026-08-17T10:00:00Z',
    };
    spaceMessages.insert(0, message);
    return message;
  }

  @override
  Future<Map<String, dynamic>> getSpace(String spaceId) async => {
    'id': spaceId,
    'kind': 'group',
    'name': '前湖北院',
    'my_role': 'visitor',
    'member_count': 99,
    'online_count': 4,
    'is_location_space': true,
    'origin': 'campus_location',
    'location_kind': 'area',
    'created_at': '2026-08-16T10:00:00Z',
    'updated_at': '2026-08-16T10:00:00Z',
  };

  @override
  Future<AssistantConversationHistory> getAssistantHistory({
    int limit = 50,
    int offset = 0,
  }) async {
    return AssistantConversationHistory(
      messages: [
        ChatMessage(
          sender: 'bot',
          content: '上次我们聊到高数教材。',
          timestamp: DateTime(2026, 7, 1, 10),
        ),
      ],
      total: 1,
    );
  }
}

class _FakeUserService extends UserService {
  @override
  Future<SocialPersona?> getSocialPersona() async => const SocialPersona(
    representationMode: 'role_character',
    styleVersion: 'v1',
    appearance: SocialPersonaAppearance(
      palette: 'teal',
      silhouette: 'soft',
      accessory: 'leaf',
      outfit: 'campus',
    ),
    selfDescriptions: [],
    contactPosture: 'leave_message',
    status: 'published',
    publishedAt: '2026-08-12T10:00:00Z',
  );
}

class _FakeCampusLocationService extends CampusLocationService {
  _FakeCampusLocationService(this.position);

  final CoarseCampusPosition position;

  @override
  Future<CoarseCampusPosition> determineCoarsePosition() async => position;
}

const _publishedPeerPersona = SocialPersona(
  representationMode: 'role_character',
  styleVersion: 'v1',
  appearance: SocialPersonaAppearance(
    palette: 'plum',
    silhouette: 'round',
    accessory: 'leaf',
    outfit: 'campus',
  ),
  selfDescriptions: ['slow_to_warm'],
  contactPosture: 'leave_message',
  status: 'published',
  publishedAt: '2026-08-12T10:00:00Z',
);

Widget _buildPage(
  ChatService service, {
  Locale locale = const Locale('zh'),
  ThemeMode themeMode = ThemeMode.light,
  double textScale = 1,
  CampusLocationService? locationService,
}) {
  return MaterialApp(
    theme: AppTheme.light,
    darkTheme: AppTheme.dark,
    themeMode: themeMode,
    locale: locale,
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(textScaler: TextScaler.linear(textScale)),
      child: child!,
    ),
    home: ConversationListPage(
      chatService: service,
      userService: _FakeUserService(),
      locationService: locationService,
    ),
  );
}

void main() {
  testWidgets('Xiaochang is not duplicated inside the inbox', (tester) async {
    await tester.pumpWidget(_buildPage(_FakeChatService()));
    await tester.pumpAndSettle();

    expect(find.text('小昌'), findsNothing);
    expect(find.text('AI 助手'), findsNothing);
    expect(find.text('上次我们聊到高数教材。'), findsNothing);
    expect(find.byTooltip('问小昌'), findsNothing);
    expect(find.text('校园发现'), findsOneWidget);
    expect(find.text('发布出 / 收'), findsNothing);

    await tester.tap(find.text('连接'));
    await tester.pumpAndSettle();

    expect(find.text('小昌'), findsNothing);
    expect(find.byTooltip('问小昌'), findsNothing);
  });

  testWidgets('inbox failure does not add a duplicate Xiaochang action', (
    tester,
  ) async {
    await tester.pumpWidget(
      _buildPage(_FakeChatService(failConversations: true)),
    );
    await tester.pumpAndSettle();

    expect(find.text('小昌'), findsNothing);
    expect(find.byTooltip('问小昌'), findsNothing);
    expect(find.text('消息暂时没有加载出来'), findsOneWidget);
  });

  testWidgets('conversation inbox localizes controls in English', (
    tester,
  ) async {
    await tester.pumpWidget(
      _buildPage(_FakeChatService(), locale: const Locale('en')),
    );
    await tester.pumpAndSettle();

    expect(find.text('Xiaochang'), findsNothing);
    expect(find.byTooltip('Ask Xiaochang'), findsNothing);
    expect(find.text('Connections'), findsOneWidget);
    expect(find.text('No conversations'), findsOneWidget);
    expect(find.text('找同学'), findsNothing);
  });

  testWidgets('direct conversations are grouped by peer thread', (
    tester,
  ) async {
    final service = _FakeChatService(
      threads: [
        ChatThread(
          peerUserId: 'seller-2',
          peerUsername: 'seller2',
          latestActivityAt: DateTime(2026, 7, 6, 12),
          latestPreview: '今晚七点可以吗',
          unreadCount: 3,
          conversationCount: 4,
          mailCount: 2,
          realtimeCount: 2,
          pendingCount: 1,
          hasActiveRealtime: true,
          latestListingTitle: '二手显示器',
          peerPersona: _publishedPeerPersona,
        ),
      ],
    );

    await tester.pumpWidget(_buildPage(service));
    await tester.pumpAndSettle();

    expect(find.text('seller2'), findsOneWidget);
    expect(find.text('连接 2'), findsOneWidget);
    expect(find.text('留言 2'), findsOneWidget);
    expect(find.text('共 4 段'), findsOneWidget);
    expect(find.text('待回应 1'), findsOneWidget);
    expect(find.byType(SocialPersonaAvatar), findsOneWidget);
    expect(
      tester.getSize(find.byType(SocialPersonaAvatar)),
      const Size(48, 48),
    );
  });

  testWidgets('desktop thread selection opens a full-page route', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final service = _FakeChatService(
      threads: [
        ChatThread(
          peerUserId: 'seller-2',
          peerUsername: 'seller2',
          latestActivityAt: DateTime(2026, 7, 6, 12),
        ),
      ],
    );
    final router = GoRouter(
      initialLocation: '/conversations',
      routes: [
        GoRoute(
          path: '/conversations',
          builder: (context, state) => ConversationListPage(
            chatService: service,
            userService: _FakeUserService(),
          ),
        ),
        GoRoute(
          name: 'chat-thread',
          path: '/chat/threads/:peerUserId',
          builder: (context, state) =>
              const Scaffold(body: Center(child: Text('full-page-thread'))),
        ),
      ],
    );

    await tester.pumpWidget(
      MaterialApp.router(
        theme: AppTheme.light,
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        routerConfig: router,
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('seller2'));
    await tester.pumpAndSettle();

    expect(find.text('full-page-thread'), findsOneWidget);
    expect(find.byType(ConversationListPage), findsNothing);
  });

  testWidgets('single-contact inbox omits coaching copy at 200% text', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final service = _FakeChatService(
      threads: [
        ChatThread(
          peerUserId: 'seller-2',
          peerUsername: 'seller2',
          latestActivityAt: DateTime(2026, 7, 6, 12),
          latestPreview: '教材还在',
          conversationCount: 1,
          mailCount: 1,
        ),
      ],
    );

    await tester.pumpWidget(_buildPage(service, textScale: 2));
    await tester.pumpAndSettle();

    expect(find.text('接下来可以'), findsNothing);
    expect(find.text('找同学'), findsNothing);
    expect(find.text('发布出 / 收'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('space inbox omits coaching copy', (tester) async {
    final service = _FakeChatService(
      threads: [
        ChatThread(
          peerUserId: 'seller-2',
          peerUsername: 'seller2',
          latestActivityAt: DateTime(2026, 7, 6, 12),
          latestPreview: '教材还在',
          conversationCount: 1,
          mailCount: 1,
        ),
      ],
    )..seedSpace();

    await tester.pumpWidget(_buildPage(service));
    await tester.pumpAndSettle();

    expect(find.text('接下来可以'), findsNothing);
    expect(find.text('已存在群组'), findsOneWidget);
  });

  testWidgets(
    'conversation segment opens from its content without a heavy button',
    (tester) async {
      final thread = ChatThread(
        peerUserId: 'seller-2',
        peerUsername: 'seller2',
        latestActivityAt: DateTime(2026, 7, 6, 12),
        latestPreview: '我有一台 23.8 寸的',
        conversationCount: 1,
        mailCount: 1,
      );
      final service = _FakeChatService(
        threads: [thread],
        conversations: [
          Conversation(
            id: 'conversation-1',
            otherUserId: 'seller-2',
            otherUsername: 'seller2',
            mode: ConversationMode.mail,
            state: ConversationState.open,
            subject: '显示器',
            lastMessage: '我有一台 23.8 寸的',
          ),
        ],
      );
      final router = GoRouter(
        initialLocation: '/thread',
        routes: [
          GoRoute(
            path: '/thread',
            builder: (context, state) => ChatThreadPage(
              peerUserId: thread.peerUserId,
              initialThread: thread,
              chatService: service,
              userService: _FakeUserService(),
            ),
          ),
          GoRoute(
            name: 'user-chat',
            path: '/user-chat/:conversationId',
            builder: (context, state) => Scaffold(
              body: Text('opened ${state.pathParameters['conversationId']}'),
            ),
          ),
        ],
      );

      await tester.pumpWidget(
        MaterialApp.router(
          theme: AppTheme.light,
          locale: const Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          routerConfig: router,
        ),
      );
      await tester.pumpAndSettle();

      expect(find.widgetWithText(FilledButton, '打开这段沟通'), findsNothing);
      expect(
        tester.getTopLeft(find.text('我有一台 23.8 寸的').last).dy,
        lessThan(tester.getTopLeft(find.text('已发送')).dy),
      );
      await tester.tap(find.text('我有一台 23.8 寸的').last);
      await tester.pumpAndSettle();

      expect(find.text('opened conversation-1'), findsOneWidget);
    },
  );

  testWidgets('conversation segment exposes an open action to assistive tech', (
    tester,
  ) async {
    final thread = ChatThread(
      peerUserId: 'seller-2',
      peerUsername: 'seller2',
      latestActivityAt: DateTime(2026, 7, 6, 12),
      latestPreview: '教材还在',
      conversationCount: 1,
      mailCount: 1,
    );
    final service = _FakeChatService(
      threads: [thread],
      conversations: [
        Conversation(
          id: 'conversation-1',
          otherUserId: 'seller-2',
          otherUsername: 'seller2',
          mode: ConversationMode.mail,
          state: ConversationState.open,
          subject: '教材',
          lastMessage: '教材还在',
        ),
      ],
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: ChatThreadPage(
          peerUserId: thread.peerUserId,
          initialThread: thread,
          chatService: service,
          userService: _FakeUserService(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.bySemanticsLabel('打开这段沟通：seller2'), findsOneWidget);
  });

  testWidgets(
    'peer thread with no persona falls back to system recognizable avatar',
    (tester) async {
      final service = _FakeChatService(
        threads: [
          ChatThread(
            peerUserId: 'seller-3',
            peerUsername: 'seller3',
            latestActivityAt: DateTime(2026, 7, 6, 12),
            latestPreview: '教材还在',
            unreadCount: 0,
            conversationCount: 1,
            peerPersona: null,
          ),
        ],
      );

      await tester.pumpWidget(_buildPage(service));
      await tester.pumpAndSettle();

      expect(find.text('seller3'), findsOneWidget);
      // Should render system-drawn avatar in UserAvatar, not SocialPersonaAvatar
      expect(find.byType(SocialPersonaAvatar), findsNothing);
      expect(find.byType(UserAvatar), findsOneWidget);
      expect(tester.getSize(find.byType(UserAvatar)), const Size(48, 48));
    },
  );

  testWidgets('thread detail anchors both published roles before connection', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final thread = ChatThread(
      peerUserId: 'seller-2',
      peerUsername: 'seller2',
      latestActivityAt: DateTime.utc(2026, 8, 12, 10),
      latestPreview: '可以留言',
      peerPersona: _publishedPeerPersona,
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: ChatThreadPage(
          peerUserId: 'seller-2',
          initialThread: thread,
          chatService: _FakeChatService(
            threads: [thread],
            conversations: [
              Conversation(
                id: 'realtime-1',
                otherUserId: 'seller-2',
                otherUsername: 'seller2',
                mode: ConversationMode.realtime,
                state: ConversationState.open,
              ),
            ],
          ),
          userService: _FakeUserService(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final avatars = find.byType(SocialPersonaAvatar);
    expect(avatars, findsNWidgets(4));
    expect(tester.getSize(avatars.at(0)), const Size(48, 48));
    expect(tester.getSize(avatars.at(1)), const Size(48, 48));
    expect(tester.getSize(avatars.at(2)), const Size(120, 120));
    expect(tester.getSize(avatars.at(3)), const Size(120, 120));
    expect(find.byKey(const Key('relationship-space-poke')), findsOneWidget);
  });

  testWidgets('conversation inbox uses dark scaffold background', (
    tester,
  ) async {
    await tester.pumpWidget(
      _buildPage(_FakeChatService(), themeMode: ThemeMode.dark),
    );
    await tester.pumpAndSettle();

    final scaffold = tester.widget<Scaffold>(find.byType(Scaffold));
    expect(scaffold.backgroundColor, AppTheme.surfaceDark);
  });

  testWidgets('created group remains visible in the inbox', (tester) async {
    await tester.pumpWidget(_buildPage(_FakeChatService()));
    await tester.pumpAndSettle();
    final l = AppLocalizations.of(tester.element(find.byType(Scaffold)))!;

    await tester.tap(find.byTooltip(l.createAction));
    await tester.pumpAndSettle();
    await tester.tap(find.text(l.createGroup));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, '名称'), '浏览器亲测群组');
    await tester.tap(find.widgetWithText(FilledButton, l.createAction));
    await tester.pumpAndSettle();

    expect(find.text('浏览器亲测群组'), findsWidgets);
  });

  testWidgets('campus groups load as inbox cards without channel affordances', (
    tester,
  ) async {
    final service = _FakeChatService()
      ..seedSpace(name: '已存在群组', description: '社团教材交换');
    await tester.pumpWidget(_buildPage(service));
    await tester.pumpAndSettle();

    expect(find.text('已存在群组'), findsOneWidget);
    expect(find.text('校园群聊'), findsOneWidget);
    expect(find.text('社团教材交换'), findsOneWidget);
    expect(find.text('创建频道'), findsNothing);
    expect(find.text('群内成员均可发言与回复'), findsNothing);
    expect(find.text('仅创建者和管理员发布公告'), findsNothing);
  });

  testWidgets(
    'switching contact threads guards against stale thread and relationship space responses',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final threadA = ChatThread(
        peerUserId: 'peer-a',
        peerUsername: 'PeerA',
        latestActivityAt: DateTime.utc(2026, 8, 12, 10),
      );
      final threadB = ChatThread(
        peerUserId: 'peer-b',
        peerUsername: 'PeerB',
        latestActivityAt: DateTime.utc(2026, 8, 12, 11),
      );

      final service = _StaleControlledChatService();

      // Mount for peer-a
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light,
          locale: const Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: StatefulBuilder(
            builder: (context, setState) {
              return ChatThreadPage(
                peerUserId: 'peer-a',
                initialThread: null,
                chatService: service,
                userService: _FakeUserService(),
              );
            },
          ),
        ),
      );
      await tester.pump();

      // Re-mount for peer-b
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light,
          locale: const Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: StatefulBuilder(
            builder: (context, setState) {
              return ChatThreadPage(
                peerUserId: 'peer-b',
                initialThread: null,
                chatService: service,
                userService: _FakeUserService(),
              );
            },
          ),
        ),
      );
      await tester.pump();

      // Resolve stale peer-a requests
      service.threadCompleters['peer-a']?.complete(
        ChatThreadDetail(thread: threadA, conversations: const []),
      );
      service.spaceCompleters['peer-a']?.complete(
        RelationshipSpace(
          relationshipKey: 'space-a',
          events: [
            RelationshipSpaceEvent(
              id: 'event-a',
              sourceType: 'message',
              sourceId: '1',
              eventType: 'message.sent',
              conversationId: 'c1',
              actorId: 'peer-a',
              occurredAt: DateTime.utc(2026, 8, 12, 10),
            ),
          ],
          pins: const [],
          sharedObjects: const [],
        ),
      );
      await tester.pump();

      // Assert stale peer-a does NOT show up
      expect(find.text('PeerA'), findsNothing);

      // Now resolve peer-b requests
      service.threadCompleters['peer-b']?.complete(
        ChatThreadDetail(thread: threadB, conversations: const []),
      );
      service.spaceCompleters['peer-b']?.complete(
        RelationshipSpace(
          relationshipKey: 'space-b',
          events: [
            RelationshipSpaceEvent(
              id: 'event-b',
              sourceType: 'message',
              sourceId: '2',
              eventType: 'connection.started',
              conversationId: 'c2',
              actorId: 'peer-b',
              occurredAt: DateTime.utc(2026, 8, 12, 11),
            ),
          ],
          pins: const [],
          sharedObjects: const [],
        ),
      );
      await tester.pumpAndSettle();

      // Active peer-b shows up correctly
      expect(find.text('PeerB'), findsWidgets);
      expect(find.text('PeerA'), findsNothing);
      // The inbox keeps the relationship-space canvas compact and suppresses
      // its event rail; event details remain available after opening the chat.
      expect(find.text('开始了一次连接'), findsNothing);
    },
  );

  testWidgets('renders four collapsible location roots with online counts', (
    tester,
  ) async {
    final spaces = [
      CampusLocationSpace(
        id: 'qianhu-north',
        name: '前湖北院',
        locationKind: 'area',
        isOfficial: true,
        isMember: false,
        memberCount: 12,
        canCreateChildren: false,
        onlineCount: 7,
        children: [
          CampusLocationSpace(
            id: 'xian-su-yuan',
            name: '先骕园',
            parentSpaceId: 'qianhu-north',
            locationKind: 'facility',
            isOfficial: true,
            isMember: false,
            memberCount: 5,
            canCreateChildren: false,
            onlineCount: 3,
          ),
        ],
      ),
      const CampusLocationSpace(
        id: 'qianhu-south',
        name: '前湖南院',
        locationKind: 'area',
        isOfficial: true,
        isMember: false,
        memberCount: 0,
        canCreateChildren: false,
        onlineCount: 2,
      ),
      const CampusLocationSpace(
        id: 'qingshanhu-campus',
        name: '青山湖校区',
        locationKind: 'campus',
        isOfficial: true,
        isMember: false,
        memberCount: 0,
        canCreateChildren: false,
      ),
      const CampusLocationSpace(
        id: 'donghu-campus',
        name: '东湖校区',
        locationKind: 'campus',
        isOfficial: true,
        isMember: false,
        memberCount: 0,
        canCreateChildren: false,
        onlineCount: 1,
      ),
    ];

    await tester.pumpWidget(
      _buildPage(_FakeChatService(locationSpaces: spaces)),
    );
    await tester.pumpAndSettle();

    expect(find.text('南昌大学地点聊天室'), findsOneWidget);
    expect(find.text('前湖北院'), findsOneWidget);
    expect(find.text('前湖南院'), findsOneWidget);
    expect(find.text('青山湖校区'), findsOneWidget);
    expect(find.text('东湖校区'), findsOneWidget);
    expect(find.text('当前在线 7 人'), findsOneWidget);
    expect(find.text('7 位成员'), findsNothing);
    expect(find.text('加入'), findsNothing);
    expect(find.text('先骕园'), findsNothing);

    await tester.tap(find.text('前湖北院'));
    await tester.pumpAndSettle();

    expect(find.text('先骕园'), findsOneWidget);
    expect(find.text('当前在线 3 人'), findsOneWidget);
    expect(find.byTooltip('打开校园地图'), findsOneWidget);
  });

  testWidgets('one-shot location enters without a membership step', (
    tester,
  ) async {
    final leaf = CampusLocationSpace(
      id: 'xiuxian-square',
      name: '修贤广场',
      locationKind: 'landmark',
      isOfficial: true,
      isMember: false,
      memberCount: 8,
      canCreateChildren: true,
    );
    final service = _FakeChatService(
      locationSpaces: [leaf],
      locationRecommendation: leaf,
    );
    final router = GoRouter(
      initialLocation: '/conversations',
      routes: [
        GoRoute(
          path: '/conversations',
          builder: (context, state) => ConversationListPage(
            chatService: service,
            userService: _FakeUserService(),
            locationService: _FakeCampusLocationService(
              const CoarseCampusPosition(latitude: 28.662, longitude: 115.801),
            ),
          ),
        ),
        GoRoute(
          name: 'chat-space',
          path: '/chat/spaces/:spaceId',
          builder: (context, state) => Scaffold(
            body: Center(
              child: Text('opened-${state.pathParameters['spaceId']}'),
            ),
          ),
        ),
      ],
    );

    await tester.pumpWidget(
      MaterialApp.router(
        theme: AppTheme.light,
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        routerConfig: router,
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('location-use-current')));
    await tester.pumpAndSettle();

    expect(service.joinedLocationSpaceId, leaf.id);
    expect(find.text('opened-${leaf.id}'), findsOneWidget);
  });

  testWidgets('location room shows presence instead of member semantics', (
    tester,
  ) async {
    final service = _FakeChatService();
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: SpaceChatPage(
          spaceId: 'qianhu-north',
          initialSpace: const {
            'id': 'qianhu-north',
            'kind': 'group',
            'name': '前湖北院',
            'my_role': 'visitor',
            'member_count': 99,
            'online_count': 4,
            'is_location_space': true,
            'created_at': '2026-08-16T10:00:00Z',
            'updated_at': '2026-08-16T10:00:00Z',
          },
          chatService: service,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('当前在线 4 人'), findsOneWidget);
    expect(find.textContaining('99 位成员'), findsNothing);
    expect(find.textContaining('我的角色'), findsNothing);
    expect(find.text('地点聊天室'), findsOneWidget);
    expect(find.text('还没有话题'), findsOneWidget);
    expect(find.text('发起话题'), findsOneWidget);
    expect(service.locationPresenceCalls, greaterThanOrEqualTo(1));
  });

  testWidgets('group discussion requires a topic before replies', (
    tester,
  ) async {
    final service = _FakeChatService();
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: SpaceChatPage(
          spaceId: 'group-one',
          initialSpace: const {
            'id': 'group-one',
            'kind': 'group',
            'name': '学习搭子',
            'my_role': 'member',
            'member_count': 3,
            'created_at': '2026-08-16T10:00:00Z',
            'updated_at': '2026-08-16T10:00:00Z',
          },
          chatService: service,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('unified-message-composer')), findsNothing);
    await tester.tap(find.byKey(const Key('group-start-topic')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('group-topic-field')),
      '周三图书馆复习安排',
    );
    await tester.tap(find.byKey(const Key('group-topic-create')));
    await tester.pumpAndSettle();

    expect(find.text('周三图书馆复习安排'), findsOneWidget);
    expect(find.byKey(const Key('unified-message-composer')), findsOneWidget);
    await tester.enterText(
      find.byKey(const Key('composer-text-field')),
      '我可以带高数笔记',
    );
    await tester.tap(find.byKey(const Key('composer-send')));
    await tester.pumpAndSettle();

    expect(find.text('我可以带高数笔记'), findsOneWidget);
    expect(service.spaceMessages.first['reply_to_message_id'], 1);
  });
}

class _StaleControlledChatService extends ChatService {
  final Map<String, dynamic> threadCompleters = {};
  final Map<String, dynamic> spaceCompleters = {};

  @override
  Future<List<ChatThread>> getThreads({
    ConversationMode? mode,
    int limit = 50,
  }) async => const [];

  @override
  Future<ChatThreadDetail> getThread(
    String peerUserId, {
    ConversationMode? mode,
  }) {
    final completer = Completer<ChatThreadDetail>();
    threadCompleters[peerUserId] = completer;
    return completer.future;
  }

  @override
  Future<RelationshipSpace> getRelationshipSpace(
    String peerUserId, {
    String? cursor,
    int limit = 50,
  }) {
    final completer = Completer<RelationshipSpace>();
    spaceCompleters[peerUserId] = completer;
    return completer.future;
  }
}
