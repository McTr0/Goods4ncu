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
    home: Scaffold(body: child),
  );
}

void main() {
  testWidgets('shows a shared space without presence claims', (tester) async {
    await tester.pumpWidget(
      _host(
        const RelationshipSpacePreview(otherName: 'Alice', latestEvent: '图书馆见'),
      ),
    );

    expect(find.byKey(const Key('relationship-space-preview')), findsOneWidget);
    expect(find.text('共同空间'), findsOneWidget);
    expect(find.text('可以留言'), findsOneWidget);
    expect(find.text('图书馆见'), findsOneWidget);
    expect(find.text('Alice'), findsOneWidget);
    expect(find.text('我'), findsWidgets);
    expect(find.text('在线'), findsNothing);
    expect(find.text('已读'), findsNothing);
    expect(find.text('正在输入'), findsNothing);
  });

  testWidgets('connected state is explicit and localized', (tester) async {
    await tester.pumpWidget(
      _host(
        const RelationshipSpacePreview(otherName: 'Alice', isConnected: true),
        locale: Locale('en'),
      ),
    );

    expect(find.text('Shared space'), findsOneWidget);
    expect(find.text('Connected'), findsOneWidget);
    expect(find.text('Leave a message'), findsNothing);
  });

  testWidgets('shows deterministic memory rail counts', (tester) async {
    await tester.pumpWidget(
      _host(
        const RelationshipSpacePreview(
          otherName: 'Alice',
          pinCount: 2,
          sharedObjectCount: 1,
          hasRecentConnection: true,
        ),
      ),
    );

    expect(find.text('2 个 Pin'), findsOneWidget);
    expect(find.text('1 个共享对象'), findsOneWidget);
    expect(find.text('时间轨迹'), findsWidgets);
  });

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
    expect(tester.getSize(avatars.at(0)), const Size(160, 160));
    expect(tester.getSize(avatars.at(1)), const Size(160, 160));
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

    // Once the users explicitly connect, the role presentation leaves the
    // stage. The relationship state remains visible without implying that a
    // platform character is participating in the conversation.
    expect(find.byType(SocialPersonaAvatar), findsNothing);
    expect(find.text('已连接'), findsOneWidget);
  });

  testWidgets('full role space fits a 390x844 viewport at 200% text', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
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
          child: const RelationshipSpacePreview(
            otherName: 'Alice',
            otherPersona: persona,
            selfPersona: persona,
            latestEvent: '图书馆见',
          ),
        ),
      ),
    );

    expect(find.byKey(const Key('relationship-space-preview')), findsOneWidget);
    expect(find.text('图书馆见'), findsOneWidget);
    expect(find.byType(SocialPersonaAvatar), findsNWidgets(2));
    expect(tester.takeException(), isNull);
  });

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

      expect(find.text('共享对象'), findsOneWidget);
      expect(find.textContaining('商品 · 数据库教材'), findsOneWidget);
      expect(find.textContaining('链接 · 交接地点'), findsOneWidget);
      expect(find.textContaining('只读引用'), findsOneWidget);
      expect(find.byType(Image), findsNothing);
    },
  );
}
