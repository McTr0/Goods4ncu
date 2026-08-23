import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:goods4ncu_mobile/components/contact_conversation_sheet.dart';
import 'package:goods4ncu_mobile/l10n/app_localizations.dart';
import 'package:goods4ncu_mobile/models/models.dart';
import 'package:goods4ncu_mobile/services/chat_service.dart';

class _FakeChatService extends ChatService {
  ConversationMode? createdMode;
  String? createdSubject;
  String? createdContent;

  @override
  Future<Conversation> createConversation({
    required String recipientId,
    required ConversationMode mode,
    required String content,
    String? listingId,
    String? subject,
    MailExpectation? mailExpectation,
    String? clientRequestId,
  }) async {
    createdMode = mode;
    createdSubject = subject;
    createdContent = content;
    return Conversation(
      id: 'conversation-created',
      otherUserId: recipientId,
      otherUsername: '同学甲',
      mode: mode,
      state: mode == ConversationMode.mail
          ? ConversationState.open
          : ConversationState.synSent,
      subject: subject,
      lastMessage: content,
    );
  }
}

MaterialApp _app(GoRouter router) {
  return MaterialApp.router(
    locale: const Locale('zh'),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    routerConfig: router,
  );
}

void main() {
  testWidgets('contact page opens directly in the requested mode', (
    tester,
  ) async {
    final service = _FakeChatService();
    Conversation? result;
    final router = GoRouter(
      initialLocation: '/',
      routes: [
        GoRoute(
          path: '/',
          builder: (context, state) => Scaffold(
            body: FilledButton(
              onPressed: () async {
                result = await openContactConversationPage(
                  context: context,
                  chatService: service,
                  recipientId: 'peer-one',
                  mode: ConversationMode.mail,
                  recipientName: '同学甲',
                );
              },
              child: const Text('再联系'),
            ),
          ),
        ),
        GoRoute(
          path: '/contact/:recipientId',
          builder: (context, state) => ContactConversationPage(
            chatService: service,
            recipientId: state.pathParameters['recipientId']!,
            initialMode: ConversationMode.parse(
              state.uri.queryParameters['mode'],
            ),
            recipientName: state.uri.queryParameters['recipientName'],
          ),
        ),
      ],
    );

    await tester.pumpWidget(_app(router));
    await tester.tap(find.text('再联系'));
    await tester.pumpAndSettle();

    // The mail composer shows immediately — no intermediate mode picker.
    expect(find.byType(ContactConversationPage), findsOneWidget);
    expect(find.byType(Dialog), findsNothing);
    expect(find.byType(BottomSheet), findsNothing);
    expect(find.text('写封留言'), findsOneWidget);
    expect(find.byKey(const ValueKey('mail-subject-field')), findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey('mail-subject-field')),
      '借书安排',
    );
    await tester.enterText(
      find.byKey(const ValueKey('conversation-opening-field')),
      '周五可以在图书馆见面吗？',
    );
    await tester.tap(find.byKey(const ValueKey('submit-contact-conversation')));
    await tester.pumpAndSettle();

    expect(find.text('再联系'), findsOneWidget);
    expect(result?.id, 'conversation-created');
    expect(service.createdMode, ConversationMode.mail);
    expect(service.createdSubject, '借书安排');
    expect(service.createdContent, '周五可以在图书馆见面吗？');
  });

  testWidgets('realtime mode skips the subject field', (tester) async {
    final service = _FakeChatService();

    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: ContactConversationPage(
          chatService: service,
          recipientId: 'peer-one',
          initialMode: ConversationMode.realtime,
          recipientName: '同学甲',
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('mail-subject-field')), findsNothing);
    expect(
      find.byKey(const ValueKey('conversation-opening-field')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('contact page stays phone friendly and web width constrained', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final service = _FakeChatService();

    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: ContactConversationPage(
          chatService: service,
          recipientId: 'peer-one',
          initialMode: ConversationMode.mail,
          recipientName: '同学甲',
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      tester.getSize(find.byKey(const ValueKey('contact-page-content'))).width,
      lessThanOrEqualTo(720),
    );
    expect(tester.takeException(), isNull);
  });
}
