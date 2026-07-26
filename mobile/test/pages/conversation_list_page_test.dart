import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goods4ncu_mobile/l10n/app_localizations.dart';
import 'package:goods4ncu_mobile/models/models.dart';
import 'package:goods4ncu_mobile/pages/conversation_list_page.dart';
import 'package:goods4ncu_mobile/services/chat_service.dart';
import 'package:goods4ncu_mobile/services/user_service.dart';
import 'package:goods4ncu_mobile/theme/app_theme.dart';

class _FakeChatService extends ChatService {
  _FakeChatService({this.failConversations = false, List<ChatThread>? threads})
    : threads = threads ?? const [];

  final bool failConversations;
  final List<ChatThread> threads;
  final List<Map<String, dynamic>> spaces = [];

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
    return const [];
  }

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

class _FakeUserService extends UserService {}

Widget _buildPage(
  ChatService service, {
  Locale locale = const Locale('zh'),
  ThemeMode themeMode = ThemeMode.light,
}) {
  return MaterialApp(
    theme: AppTheme.light,
    darkTheme: AppTheme.dark,
    themeMode: themeMode,
    locale: locale,
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: ConversationListPage(
      chatService: service,
      userService: _FakeUserService(),
    ),
  );
}

void main() {
  testWidgets('assistant is pinned in all and hidden by realtime filter', (
    tester,
  ) async {
    await tester.pumpWidget(_buildPage(_FakeChatService()));
    await tester.pumpAndSettle();

    expect(find.text('小帮'), findsOneWidget);
    expect(find.text('上次我们聊到高数教材。'), findsOneWidget);

    await tester.tap(find.widgetWithText(ChoiceChip, '实时'));
    await tester.pumpAndSettle();

    expect(find.text('小帮'), findsNothing);
  });

  testWidgets('assistant remains available when direct inbox fails', (
    tester,
  ) async {
    await tester.pumpWidget(
      _buildPage(_FakeChatService(failConversations: true)),
    );
    await tester.pumpAndSettle();

    expect(find.text('小帮'), findsOneWidget);
    expect(find.text('消息暂时没有加载出来'), findsOneWidget);
  });

  testWidgets('conversation inbox localizes controls in English', (
    tester,
  ) async {
    await tester.pumpWidget(
      _buildPage(_FakeChatService(), locale: const Locale('en')),
    );
    await tester.pumpAndSettle();

    expect(find.text('Xiaobang'), findsOneWidget);
    expect(find.widgetWithText(ChoiceChip, 'Realtime'), findsOneWidget);
    expect(find.text('No conversations yet'), findsOneWidget);
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
        ),
      ],
    );

    await tester.pumpWidget(_buildPage(service));
    await tester.pumpAndSettle();

    expect(find.text('seller2'), findsOneWidget);
    expect(find.text('实时 2'), findsOneWidget);
    expect(find.text('留言 2'), findsOneWidget);
    expect(find.text('共 4 段'), findsOneWidget);
    expect(find.text('待回应 1'), findsOneWidget);
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

  testWidgets('campus spaces load as inbox cards', (tester) async {
    final service = _FakeChatService()
      ..seedSpace(name: '已存在群组', description: '社团教材交换');
    await tester.pumpWidget(_buildPage(service));
    await tester.pumpAndSettle();

    expect(find.text('已存在群组'), findsOneWidget);
    expect(find.text('校园群组与频道'), findsOneWidget);
    expect(find.text('社团教材交换'), findsOneWidget);
  });
}
