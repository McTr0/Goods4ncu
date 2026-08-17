import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goods4ncu_mobile/components/relationship_space_preview.dart';
import 'package:goods4ncu_mobile/components/social_persona_card.dart';
import 'package:goods4ncu_mobile/l10n/app_localizations.dart';
import 'package:goods4ncu_mobile/models/models.dart';
import 'package:goods4ncu_mobile/theme/app_theme.dart';

Widget _host(Widget child, {Locale locale = const Locale('zh')}) {
  return MaterialApp(
    theme: AppTheme.light,
    locale: locale,
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(body: SingleChildScrollView(child: child)),
  );
}

void main() {
  testWidgets('stage places peer top-left and self bottom-right', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const Scaffold(
          body: SizedBox(
            width: 390,
            height: 700,
            child: RelationshipSpacePreview(
              otherName: 'Alice',
              stageMode: true,
              stageContent: Center(child: Text('空间内消息')),
            ),
          ),
        ),
      ),
    );

    expect(find.byKey(const Key('relationship-space-stage')), findsOneWidget);
    expect(find.text('空间内消息'), findsOneWidget);
    final peer = tester.getRect(find.text('Alice'));
    final self = tester.getRect(find.text('我'));
    expect(peer.left, lessThan(self.left));
    expect(peer.top, lessThan(self.top));
  });

  testWidgets(
    'shows a shared space with verifiable event and without presence claims',
    (tester) async {
      final now = DateTime.utc(2026, 8, 13, 10, 0);
      await tester.pumpWidget(
        _host(
          RelationshipSpacePreview(
            otherName: 'Alice',
            events: [
              RelationshipSpaceEvent(
                id: '1',
                sourceType: 'message',
                sourceId: '101',
                eventType: 'message.sent',
                conversationId: 'c1',
                actorId: 'user1',
                occurredAt: now,
              ),
            ],
          ),
        ),
      );

      expect(
        find.byKey(const Key('relationship-space-preview')),
        findsOneWidget,
      );
      expect(find.text('共同空间'), findsOneWidget);
      expect(find.text('可以留言'), findsOneWidget);
      expect(find.text('发送了留言'), findsOneWidget);
      expect(find.text('Alice'), findsOneWidget);
      expect(find.text('我'), findsWidgets);
      expect(find.text('在线'), findsNothing);
      expect(find.text('已读'), findsNothing);
      expect(find.text('正在输入'), findsNothing);
    },
  );

  testWidgets('shows actionable empty state guidance when no events exist', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(const RelationshipSpacePreview(otherName: 'Alice')),
    );

    expect(find.text('长按一条留言固定，或分享商品与文件，它们会留在这里'), findsOneWidget);
    expect(find.text('在线'), findsNothing);
    expect(find.text('正在输入'), findsNothing);
    expect(find.text('已读'), findsNothing);
  });

  testWidgets('connected state is explicit and localized', (tester) async {
    await tester.pumpWidget(
      _host(
        const RelationshipSpacePreview(otherName: 'Alice', isConnected: true),
        locale: const Locale('en'),
      ),
    );

    expect(find.text('Shared space'), findsOneWidget);
    expect(find.text('Connected'), findsOneWidget);
    expect(find.text('Leave a message'), findsNothing);
  });

  testWidgets('poke is an explicit local-only interaction', (tester) async {
    await tester.pumpWidget(
      _host(const RelationshipSpacePreview(otherName: 'Alice')),
    );

    final poke = find.byKey(const Key('relationship-space-poke'));
    expect(poke, findsOneWidget);
    await tester.tap(poke);
    await tester.pump();

    expect(find.text('你拍了拍 Alice'), findsOneWidget);
    expect(find.text('对方已收到'), findsNothing);
    expect(find.text('对方已回应'), findsNothing);
  });

  testWidgets(
    'shows deterministic memory rail counts with natural copy in collapsed and expanded modes',
    (tester) async {
      final now = DateTime.utc(2026, 8, 13, 10, 0);
      await tester.pumpWidget(
        _host(
          RelationshipSpacePreview(
            otherName: 'Alice',
            pinCount: 2,
            sharedObjectCount: 1,
            hasRecentConnection: true,
            recentConnection: RelationshipSpaceConnection(
              conversationId: 'c1',
              startedAt: now.subtract(const Duration(hours: 1)),
              endedAt: now.subtract(const Duration(minutes: 10)),
            ),
          ),
        ),
      );

      // Collapsed mode: shows explicit "上次连接" instead of vague "时间轨迹"
      expect(find.text('已固定留言'), findsOneWidget);
      expect(find.text('2 条已固定'), findsOneWidget);
      expect(find.text('1 项共享内容'), findsOneWidget);
      expect(find.text('上次连接'), findsOneWidget);
      expect(find.text('最近记录'), findsOneWidget);
      expect(find.text('时间轨迹'), findsNothing);

      // Expand
      final toggle = find.byKey(const Key('relationship-space-expand-toggle'));
      await tester.tap(toggle);
      await tester.pumpAndSettle();

      // Expanded mode: shows detailed recovery point with timestamp
      expect(find.textContaining('上次连接记录'), findsOneWidget);
    },
  );

  testWidgets('localizes last connection chip in English', (tester) async {
    await tester.pumpWidget(
      _host(
        const RelationshipSpacePreview(
          otherName: 'Alice',
          hasRecentConnection: true,
        ),
        locale: const Locale('en'),
      ),
    );

    expect(find.text('Last connection'), findsOneWidget);
    expect(find.text('Timeline'), findsNothing);
  });

  testWidgets(
    'does not leave recent records blank when memory exists without events',
    (tester) async {
      await tester.pumpWidget(
        _host(const RelationshipSpacePreview(otherName: 'Alice', pinCount: 1)),
      );

      expect(find.text('最近记录'), findsOneWidget);
      expect(find.text('这里暂时没有可回看的时间记录'), findsOneWidget);
    },
  );

  testWidgets(
    'expand/collapse button has at least 48x48 minimum touch target',
    (tester) async {
      await tester.pumpWidget(
        _host(const RelationshipSpacePreview(otherName: 'Alice')),
      );

      final toggle = find.byKey(const Key('relationship-space-expand-toggle'));
      final size = tester.getSize(toggle);
      expect(size.width, greaterThanOrEqualTo(48.0));
      expect(size.height, greaterThanOrEqualTo(48.0));
    },
  );

  testWidgets('local expand and collapse shows top 3 verifiable events', (
    tester,
  ) async {
    final now = DateTime.utc(2026, 8, 13, 10, 0);
    final events = [
      RelationshipSpaceEvent(
        id: '1',
        sourceType: 'message',
        sourceId: '101',
        eventType: 'message.sent',
        conversationId: 'c1',
        actorId: 'user1',
        occurredAt: now,
      ),
      RelationshipSpaceEvent(
        id: '2',
        sourceType: 'conversation_event',
        sourceId: '102',
        eventType: 'connection.started',
        conversationId: 'c1',
        actorId: 'user1',
        occurredAt: now.subtract(const Duration(minutes: 10)),
      ),
      RelationshipSpaceEvent(
        id: '3',
        sourceType: 'conversation_event',
        sourceId: '103',
        eventType: 'shared_object.changed',
        conversationId: 'c1',
        actorId: 'user2',
        occurredAt: now.subtract(const Duration(minutes: 20)),
      ),
      RelationshipSpaceEvent(
        id: '4',
        sourceType: 'message',
        sourceId: '104',
        eventType: 'message.sent',
        conversationId: 'c1',
        actorId: 'user1',
        occurredAt: now.subtract(const Duration(minutes: 30)),
      ),
    ];

    await tester.pumpWidget(
      _host(
        RelationshipSpacePreview(
          otherName: 'Alice',
          events: events,
          pinCount: 3,
          recentConnection: RelationshipSpaceConnection(
            conversationId: 'c1',
            startedAt: now.subtract(const Duration(hours: 1)),
            endedAt: now.subtract(const Duration(minutes: 10)),
          ),
        ),
      ),
    );

    // In collapsed mode: shows latest event
    expect(find.text('发送了留言'), findsOneWidget);
    expect(find.text('3 条已固定'), findsOneWidget);
    expect(find.text('开始了一次连接'), findsNothing);

    // Tap expand toggle
    final toggle = find.byKey(const Key('relationship-space-expand-toggle'));
    expect(toggle, findsOneWidget);
    await tester.tap(toggle);
    await tester.pumpAndSettle();

    // In expanded mode: shows up to top 3 events
    expect(find.text('发送了留言'), findsOneWidget);
    expect(find.text('开始了一次连接'), findsOneWidget);
    expect(find.text('共享内容有变化'), findsOneWidget);
    expect(find.textContaining('上次连接记录'), findsOneWidget);

    // Collapse again
    await tester.tap(toggle);
    await tester.pumpAndSettle();

    expect(find.text('开始了一次连接'), findsNothing);
  });

  testWidgets('merges opening and creation records with the sent message', (
    tester,
  ) async {
    final now = DateTime.utc(2026, 8, 13, 10, 0);
    await tester.pumpWidget(
      _host(
        RelationshipSpacePreview(
          otherName: 'Alice',
          events: [
            RelationshipSpaceEvent(
              id: 'created',
              sourceType: 'conversation',
              sourceId: 'c1',
              eventType: 'conversation.created',
              conversationId: 'c1',
              actorId: 'user1',
              occurredAt: now,
            ),
            RelationshipSpaceEvent(
              id: 'opening',
              sourceType: 'message',
              sourceId: 'm1',
              eventType: 'message.opening',
              conversationId: 'c1',
              actorId: 'user1',
              occurredAt: now,
            ),
            RelationshipSpaceEvent(
              id: 'sent',
              sourceType: 'message',
              sourceId: 'm1',
              eventType: 'message.sent',
              conversationId: 'c1',
              actorId: 'user1',
              occurredAt: now,
            ),
          ],
        ),
      ),
    );

    expect(find.text('发送了留言'), findsOneWidget);
    expect(find.text('发送了首条留言'), findsNothing);
    expect(find.text('发起了沟通'), findsNothing);
  });

  testWidgets('only merges technical records inside the same conversation', (
    tester,
  ) async {
    final now = DateTime.utc(2026, 8, 13, 10, 0);
    await tester.pumpWidget(
      _host(
        RelationshipSpacePreview(
          otherName: 'Alice',
          initiallyExpanded: true,
          events: [
            RelationshipSpaceEvent(
              id: 'created-1',
              sourceType: 'conversation',
              sourceId: 'c1',
              eventType: 'conversation.created',
              conversationId: 'c1',
              actorId: 'user1',
              occurredAt: now,
            ),
            RelationshipSpaceEvent(
              id: 'sent-1',
              sourceType: 'message',
              sourceId: 'm1',
              eventType: 'message.sent',
              conversationId: 'c1',
              actorId: 'user1',
              occurredAt: now,
            ),
            RelationshipSpaceEvent(
              id: 'created-2',
              sourceType: 'conversation',
              sourceId: 'c2',
              eventType: 'conversation.created',
              conversationId: 'c2',
              actorId: 'user1',
              occurredAt: now.subtract(const Duration(days: 1)),
            ),
          ],
        ),
      ),
    );

    expect(find.text('发送了留言'), findsOneWidget);
    expect(find.text('发起了沟通'), findsOneWidget);
  });

  testWidgets(
    'formats unknown and known event types neutrally without leaking raw names',
    (tester) async {
      final now = DateTime.utc(2026, 8, 13, 12, 0);
      final events = [
        RelationshipSpaceEvent(
          id: '1',
          sourceType: 'custom',
          sourceId: '1',
          eventType: 'arbitrary_internal_telemetry_type_xyz',
          conversationId: 'c1',
          actorId: 'user1',
          occurredAt: now,
        ),
      ];

      await tester.pumpWidget(
        _host(RelationshipSpacePreview(otherName: 'Bob', events: events)),
      );

      expect(find.text('留下了新记录'), findsOneWidget);
      expect(find.text('arbitrary_internal_telemetry_type_xyz'), findsNothing);
    },
  );

  testWidgets('uses static role tokens for both sides of a full space', (
    tester,
  ) async {
    const persona = SocialPersona(
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
    );
    await tester.pumpWidget(
      _host(
        const RelationshipSpacePreview(
          otherName: 'Alice',
          otherPersona: persona,
          selfPersona: persona,
        ),
      ),
    );

    final avatars = find.byType(SocialPersonaAvatar);
    expect(avatars, findsNWidgets(2));
    expect(tester.getSize(avatars.at(0)), const Size(120, 120));
    expect(tester.getSize(avatars.at(1)), const Size(120, 120));
    expect(find.text('在线'), findsNothing);
    expect(find.text('已读'), findsNothing);
    expect(find.text('正在输入'), findsNothing);
  });

  testWidgets('connected space withdraws role tokens from the conversation', (
    tester,
  ) async {
    const persona = SocialPersona(
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
    );
    await tester.pumpWidget(
      _host(
        const RelationshipSpacePreview(
          otherName: 'Alice',
          otherPersona: persona,
          selfPersona: persona,
          isConnected: true,
        ),
      ),
    );

    expect(find.byType(SocialPersonaAvatar), findsNWidgets(2));
    expect(find.text('已连接'), findsOneWidget);
  });

  testWidgets(
    'full role space fits a 390x844 viewport at 200% text without overflow',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final now = DateTime.utc(2026, 8, 13, 10, 0);
      const persona = SocialPersona(
        representationMode: 'role_character',
        styleVersion: 'v1',
        appearance: SocialPersonaAppearance(
          palette: 'plum',
          silhouette: 'round',
          accessory: 'leaf',
          outfit: 'campus',
        ),
        selfDescriptions: ['slow_to_warm', 'meetup_friendly'],
        contactPosture: 'leave_message',
        status: 'published',
      );
      await tester.pumpWidget(
        _host(
          MediaQuery(
            data: const MediaQueryData(
              textScaler: TextScaler.linear(2),
              disableAnimations: true,
            ),
            child: RelationshipSpacePreview(
              otherName: 'Alice',
              otherPersona: persona,
              selfPersona: persona,
              events: [
                RelationshipSpaceEvent(
                  id: '1',
                  sourceType: 'message',
                  sourceId: '101',
                  eventType: 'message.sent',
                  conversationId: 'c1',
                  actorId: 'user1',
                  occurredAt: now,
                ),
              ],
              hasRecentConnection: true,
              pinCount: 2,
              sharedObjectCount: 1,
            ),
          ),
        ),
      );

      expect(
        find.byKey(const Key('relationship-space-preview')),
        findsOneWidget,
      );
      expect(find.text('发送了留言'), findsOneWidget);
      expect(find.byType(SocialPersonaAvatar), findsNWidgets(2));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'shows shared object references without loading their resources',
    (tester) async {
      await tester.pumpWidget(
        _host(
          RelationshipSpacePreview(
            otherName: 'Alice',
            sharedObjects: [
              RelationshipSpaceSharedObject(
                key: 'listing:listing-1',
                kind: 'listing',
                refId: 'listing-1',
                snapshot: const {'title': '数据库教材'},
                sourceMessageId: 7,
                conversationId: 'conv-1',
                actorId: 'user-1',
                createdAt: DateTime.utc(2026, 1, 1),
              ),
              RelationshipSpaceSharedObject(
                key: 'link:link-1',
                kind: 'link',
                refId: 'link-1',
                snapshot: const {'label': '交接地点'},
                sourceMessageId: 8,
                conversationId: 'conv-1',
                actorId: 'user-2',
                createdAt: DateTime.utc(2026, 1, 2),
              ),
            ],
          ),
        ),
      );

      expect(find.text('共享内容'), findsOneWidget);
      expect(find.textContaining('商品 · 数据库教材'), findsOneWidget);
      expect(find.textContaining('链接 · 交接地点'), findsOneWidget);
      expect(find.textContaining('从原处分享，只在这里查看'), findsOneWidget);
      expect(find.byType(Image), findsNothing);
    },
  );
}
