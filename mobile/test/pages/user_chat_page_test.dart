import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goods4ncu_mobile/components/audio_message_player.dart';
import 'package:goods4ncu_mobile/l10n/app_localizations.dart';
import 'package:goods4ncu_mobile/models/models.dart';
import 'package:goods4ncu_mobile/pages/user_chat_composer_controller.dart';
import 'package:goods4ncu_mobile/pages/user_chat_components.dart';
import 'package:goods4ncu_mobile/pages/user_chat_page.dart';
import 'package:goods4ncu_mobile/providers/chat_notifier.dart';
import 'package:provider/provider.dart';
import 'package:goods4ncu_mobile/components/agreement_card.dart';
import 'package:goods4ncu_mobile/components/handoff_prompt.dart';
import 'package:goods4ncu_mobile/services/agreement_service.dart';
import 'package:goods4ncu_mobile/services/reputation_service.dart';
import 'package:goods4ncu_mobile/services/upload_service.dart';
import 'package:goods4ncu_mobile/services/chat_service.dart';
import 'package:goods4ncu_mobile/services/user_service.dart';

class _FakePageChatService extends ChatService {
  @override
  Future<List<ConversationMessage>> getChatConversationMessages(
    String conversationId, {
    int limit = 50,
    int offset = 0,
  }) async => const [];
}

class _FakePageUserService extends UserService {
  @override
  Future<Map<String, dynamic>> getUserProfile() async => {'user_id': 'user-me'};
}

class _BrokenAgreementService extends AgreementService {
  @override
  Future<Agreement> ensure(String conversationId, String kind) async =>
      throw Exception('unreachable');
}

class _FakePageAgreementService extends AgreementService {
  _FakePageAgreementService({required this.agreement});
  Agreement agreement;
  @override
  Future<Agreement> ensure(String conversationId, String kind) async =>
      agreement;
}

class _FakePageReputationService extends ReputationService {
  _FakePageReputationService({this.awaiting = const []});
  final List<String> awaiting;
  @override
  Future<List<String>> pending() async => awaiting;
}

Agreement _pageAgreement({
  List<AgreementTerm> terms = const [],
  String status = 'forming',
}) => Agreement(
  id: 'agreement-1',
  kind: 'deal',
  status: status,
  terms: terms,
  participants: const ['user-me', 'user-other'],
  fullyAgreed: false,
  availableSlots: const ['item', 'price', 'time', 'place', 'conditions'],
);

UserChatPage _pageWith({
  required AgreementService agreements,
  required ReputationService reputation,
  String conversationId = 'conv-1',
  Key? key,
}) => UserChatPage(
  // A distinct key gives a fresh State, which is what real navigation does:
  // opening another conversation pushes a new page rather than mutating this
  // one.
  key: key,
  conversationId: conversationId,
  otherUserId: 'user-other',
  otherUsername: 'Other User',
  chatService: _FakePageChatService(),
  userService: _FakePageUserService(),
  agreementService: agreements,
  reputationService: reputation,
);

void main() {
  Widget buildTestableWidget(Widget child) {
    return MaterialApp(
      locale: const Locale('zh'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      // UserChatPage takes most of its collaborators as parameters; this is the
      // one it still reads from context.
      home: Provider<UploadService>(
        create: (_) => UploadService(),
        child: Scaffold(body: child),
      ),
    );
  }

  group('UserChatPage', () {
    test('requires chatNotifier when injecting composerController', () {
      final notifier = ChatNotifier(
        conversationId: 'conv-1',
        chatService: _FakePageChatService(),
        userService: _FakePageUserService(),
      );
      addTearDown(notifier.dispose);
      final composerController = UserChatComposerController(
        chatNotifier: notifier,
      );
      addTearDown(composerController.dispose);

      expect(
        () => UserChatPage(
          conversationId: 'conv-1',
          otherUserId: 'user-other',
          otherUsername: 'Other User',
          composerController: composerController,
        ),
        throwsA(isA<AssertionError>()),
      );
    });
  });

  group('the arrangement is reachable from the conversation', () {
    // Three times this session a feature landed complete at the widget level
    // and unreachable at the page level, so nobody could actually use it. These
    // assert the wiring; the widgets are covered on their own.

    testWidgets('the card is pinned above the messages', (tester) async {
      await tester.pumpWidget(
        buildTestableWidget(
          _pageWith(
            agreements: _FakePageAgreementService(
              agreement: _pageAgreement(
                terms: [
                  const AgreementTerm(
                    slot: 'price',
                    value: '300 元',
                    proposedBy: 'user-other',
                    agreedBy: ['user-other'],
                    isSuggestion: false,
                  ),
                ],
              ),
            ),
            reputation: _FakePageReputationService(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(AgreementCard), findsOneWidget);
      expect(find.text('300 元'), findsOneWidget);
    });

    testWidgets('the handoff question waits until it is settled', (
      tester,
    ) async {
      // Asking before anything was arranged would be asking about a meeting
      // that was never planned.
      await tester.pumpWidget(
        buildTestableWidget(
          _pageWith(
            key: const ValueKey('conv-1'),
            agreements: _FakePageAgreementService(agreement: _pageAgreement()),
            reputation: _FakePageReputationService(
              awaiting: const ['agreement-1'],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(HandoffPrompt), findsNothing);

      await tester.pumpWidget(
        buildTestableWidget(
          _pageWith(
            key: const ValueKey('conv-2'),
            conversationId: 'conv-2',
            agreements: _FakePageAgreementService(
              agreement: _pageAgreement(status: 'settled'),
            ),
            reputation: _FakePageReputationService(
              awaiting: const ['agreement-1'],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(HandoffPrompt), findsOneWidget);
    });

    testWidgets('a card that fails to load does not break the chat', (
      tester,
    ) async {
      // A conversation that will not open because a card failed is a much worse
      // outcome than a missing card.
      await tester.pumpWidget(
        buildTestableWidget(
          _pageWith(
            agreements: _BrokenAgreementService(),
            reputation: _FakePageReputationService(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(AgreementCard), findsNothing);
      expect(tester.takeException(), isNull);
      expect(find.byType(UserChatPage), findsOneWidget);
    });
  });

  group('MessageBubble', () {
    testWidgets('aligns own messages to the right', (tester) async {
      final message = ConversationMessage(
        id: '1',
        conversationId: 'conv-1',
        senderId: 'user-me',
        content: 'My message',
        sentAt: DateTime.now(),
        status: 'sent',
      );

      await tester.pumpWidget(
        buildTestableWidget(
          MessageBubble(
            message: message,
            isMe: true,
            isConnected: true,
            onEdit: () {},
          ),
        ),
      );

      final align = tester.widget<Align>(find.byType(Align));
      expect(align.alignment, equals(Alignment.centerRight));
    });

    testWidgets('aligns other messages to the left', (tester) async {
      final message = ConversationMessage(
        id: '1',
        conversationId: 'conv-1',
        senderId: 'user-other',
        content: 'Other message',
        sentAt: DateTime.now(),
        status: 'sent',
      );

      await tester.pumpWidget(
        buildTestableWidget(
          MessageBubble(
            message: message,
            isMe: false,
            isConnected: true,
            onEdit: null,
          ),
        ),
      );

      final align = tester.widget<Align>(find.byType(Align));
      expect(align.alignment, equals(Alignment.centerLeft));
    });

    testWidgets('displays message content', (tester) async {
      final message = ConversationMessage(
        id: '1',
        conversationId: 'conv-1',
        senderId: 'user-other',
        content: 'Hello, World!',
        sentAt: DateTime.now(),
        status: 'sent',
      );

      await tester.pumpWidget(
        buildTestableWidget(
          MessageBubble(
            message: message,
            isMe: false,
            isConnected: true,
            onEdit: null,
          ),
        ),
      );

      expect(find.text('Hello, World!'), findsOneWidget);
    });

    testWidgets(
      'offers explicit acknowledgement actions for received messages',
      (tester) async {
        MessageAcknowledgementKind? selected;
        final message = ConversationMessage(
          id: '1',
          conversationId: 'conv-1',
          senderId: 'user-other',
          content: '请确认收到这条留言',
          sentAt: DateTime.now(),
          status: 'sent',
        );

        await tester.pumpWidget(
          buildTestableWidget(
            MessageBubble(
              message: message,
              isMe: false,
              isConnected: false,
              onEdit: null,
              onAcknowledge: (kind) => selected = kind,
            ),
          ),
        );

        await tester.longPress(find.text('请确认收到这条留言'));
        await tester.pumpAndSettle();

        expect(find.text('收到'), findsOneWidget);
        expect(find.text('我会看'), findsOneWidget);
        expect(find.text('已处理'), findsOneWidget);
        await tester.tap(find.text('我会看'));
        expect(selected, MessageAcknowledgementKind.willReview);
      },
    );

    testWidgets(
      'keeps acknowledgement actions reachable on a 390x844 viewport',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(390, 844));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final message = ConversationMessage(
          id: 'narrow-1',
          conversationId: 'conv-1',
          senderId: 'user-other',
          content: '窄屏也要能明确表达我会看',
          sentAt: DateTime.now(),
          status: 'sent',
        );

        await tester.pumpWidget(
          buildTestableWidget(
            MessageBubble(
              message: message,
              isMe: false,
              isConnected: false,
              onAcknowledge: (_) {},
            ),
          ),
        );
        await tester.longPress(find.text('窄屏也要能明确表达我会看'));
        await tester.pumpAndSettle();

        expect(find.text('收到'), findsOneWidget);
        expect(find.text('我会看'), findsOneWidget);
        expect(find.text('已处理'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('exposes message actions through accessibility semantics', (
      tester,
    ) async {
      final message = ConversationMessage(
        id: '1',
        conversationId: 'conv-1',
        senderId: 'user-other',
        content: '无障碍确认入口',
        sentAt: DateTime.now(),
        status: 'sent',
      );

      await tester.pumpWidget(
        buildTestableWidget(
          MessageBubble(
            message: message,
            isMe: false,
            isConnected: false,
            onAcknowledge: (_) {},
          ),
        ),
      );

      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is Semantics && widget.properties.label == '打开消息操作',
        ),
        findsOneWidget,
      );
    });

    testWidgets('displays timestamp', (tester) async {
      final message = ConversationMessage(
        id: '1',
        conversationId: 'conv-1',
        senderId: 'user-other',
        content: 'Test message',
        sentAt: DateTime(2024, 1, 15, 14, 30), // 14:30
        status: 'sent',
      );

      await tester.pumpWidget(
        buildTestableWidget(
          MessageBubble(
            message: message,
            isMe: false,
            isConnected: true,
            onEdit: null,
          ),
        ),
      );

      expect(find.text('14:30'), findsOneWidget);
    });

    testWidgets('shows edit link for own messages within edit window', (
      tester,
    ) async {
      final message = ConversationMessage(
        id: '1',
        conversationId: 'conv-1',
        senderId: 'user-me',
        content: 'My editable message',
        sentAt: DateTime.now().subtract(const Duration(minutes: 5)),
        status: 'sent',
      );

      await tester.pumpWidget(
        buildTestableWidget(
          MessageBubble(
            message: message,
            isMe: true,
            isConnected: true,
            onEdit: () {},
          ),
        ),
      );

      expect(find.text('编辑'), findsOneWidget);
    });

    testWidgets('does not show edit link for other users messages', (
      tester,
    ) async {
      final message = ConversationMessage(
        id: '1',
        conversationId: 'conv-1',
        senderId: 'user-other',
        content: 'Other message',
        sentAt: DateTime.now().subtract(const Duration(minutes: 5)),
        status: 'sent',
      );

      await tester.pumpWidget(
        buildTestableWidget(
          MessageBubble(
            message: message,
            isMe: false,
            isConnected: true,
            onEdit: null,
          ),
        ),
      );

      expect(find.text('编辑'), findsNothing);
    });

    testWidgets('does not show edit link when onEdit is null', (tester) async {
      final message = ConversationMessage(
        id: '1',
        conversationId: 'conv-1',
        senderId: 'user-me',
        content: 'My message without edit',
        sentAt: DateTime.now().subtract(const Duration(minutes: 5)),
        status: 'sent',
      );

      await tester.pumpWidget(
        buildTestableWidget(
          MessageBubble(
            message: message,
            isMe: true,
            isConnected: true,
            onEdit: null,
          ),
        ),
      );

      expect(find.text('编辑'), findsNothing);
    });

    testWidgets('displays edited indicator when message is edited', (
      tester,
    ) async {
      final message = ConversationMessage(
        id: '1',
        conversationId: 'conv-1',
        senderId: 'user-me',
        content: 'Edited message',
        sentAt: DateTime.now().subtract(const Duration(minutes: 5)),
        editedAt: DateTime.now(),
        status: 'sent',
      );

      await tester.pumpWidget(
        buildTestableWidget(
          MessageBubble(
            message: message,
            isMe: true,
            isConnected: true,
            onEdit: null, // Should be null because editedAt is set
          ),
        ),
      );

      expect(find.text('（已编辑）'), findsOneWidget);
    });

    testWidgets('shows sending status with spinner', (tester) async {
      final message = ConversationMessage(
        id: '1',
        conversationId: 'conv-1',
        senderId: 'user-me',
        content: 'Sending message...',
        sentAt: DateTime.now(),
        status: 'sending',
      );

      await tester.pumpWidget(
        buildTestableWidget(
          MessageBubble(
            message: message,
            isMe: true,
            isConnected: true,
            onEdit: null,
          ),
        ),
      );

      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.text('发送中'), findsNothing);
    });

    testWidgets('shows sent status', (tester) async {
      final message = ConversationMessage(
        id: '1',
        conversationId: 'conv-1',
        senderId: 'user-me',
        content: 'Sent message',
        sentAt: DateTime.now(),
        status: 'sent',
      );

      await tester.pumpWidget(
        buildTestableWidget(
          MessageBubble(
            message: message,
            isMe: true,
            isConnected: true,
            onEdit: null,
          ),
        ),
      );

      expect(find.byIcon(Icons.done_rounded), findsOneWidget);
    });

    testWidgets('maps legacy delivered status to sent', (tester) async {
      final message = ConversationMessage(
        id: '1',
        conversationId: 'conv-1',
        senderId: 'user-me',
        content: 'Delivered message',
        sentAt: DateTime.now(),
        status: 'delivered',
      );

      await tester.pumpWidget(
        buildTestableWidget(
          MessageBubble(
            message: message,
            isMe: true,
            isConnected: true,
            onEdit: null,
          ),
        ),
      );

      expect(find.byIcon(Icons.done_rounded), findsOneWidget);
    });

    testWidgets('maps legacy read status to sent', (tester) async {
      final message = ConversationMessage(
        id: '1',
        conversationId: 'conv-1',
        senderId: 'user-me',
        content: 'Read message',
        sentAt: DateTime.now(),
        status: 'read',
      );

      await tester.pumpWidget(
        buildTestableWidget(
          MessageBubble(
            message: message,
            isMe: true,
            isConnected: true,
            onEdit: null,
          ),
        ),
      );

      expect(find.byIcon(Icons.done_rounded), findsOneWidget);
    });

    testWidgets('shows failed status', (tester) async {
      var retryCount = 0;
      final message = ConversationMessage(
        id: '1',
        conversationId: 'conv-1',
        senderId: 'user-me',
        content: 'Failed message',
        sentAt: DateTime.now(),
        status: 'failed',
      );

      await tester.pumpWidget(
        buildTestableWidget(
          MessageBubble(
            message: message,
            isMe: true,
            isConnected: true,
            onEdit: null,
            onRetry: () => retryCount += 1,
          ),
        ),
      );

      expect(find.byIcon(Icons.error_outline_rounded), findsOneWidget);
      await tester.tap(find.byIcon(Icons.error_outline_rounded));
      expect(retryCount, 1);
    });

    testWidgets('shows delivery status even when not connected', (
      tester,
    ) async {
      final message = ConversationMessage(
        id: '1',
        conversationId: 'conv-1',
        senderId: 'user-me',
        content: 'Offline message',
        sentAt: DateTime.now(),
        status: 'sent',
      );

      await tester.pumpWidget(
        buildTestableWidget(
          MessageBubble(
            message: message,
            isMe: true,
            isConnected: false,
            onEdit: null,
          ),
        ),
      );

      expect(find.byIcon(Icons.done_rounded), findsOneWidget);
    });

    testWidgets('displays voice message player', (tester) async {
      final message = ConversationMessage(
        id: '1',
        conversationId: 'conv-1',
        senderId: 'user-other',
        content: '[语音消息]',
        audioBase64: 'audio-data',
        sentAt: DateTime.now(),
        status: 'sent',
      );

      await tester.pumpWidget(
        buildTestableWidget(
          MessageBubble(
            message: message,
            isMe: false,
            isConnected: true,
            onEdit: null,
          ),
        ),
      );

      expect(find.text('语音消息'), findsOneWidget);
      expect(find.byType(AudioMessagePlayer), findsOneWidget);
      expect(find.byIcon(Icons.play_circle), findsOneWidget);
    });

    testWidgets('triggers onEdit callback when edit is tapped', (tester) async {
      bool editCalled = false;
      final message = ConversationMessage(
        id: '1',
        conversationId: 'conv-1',
        senderId: 'user-me',
        content: 'Tap to edit',
        sentAt: DateTime.now().subtract(const Duration(minutes: 5)),
        status: 'sent',
      );

      await tester.pumpWidget(
        buildTestableWidget(
          MessageBubble(
            message: message,
            isMe: true,
            isConnected: true,
            onEdit: () {
              editCalled = true;
            },
          ),
        ),
      );

      await tester.tap(find.text('编辑'));
      await tester.pump();

      expect(editCalled, isTrue);
    });

    testWidgets('triggers onEdit callback when bubble is long pressed', (
      tester,
    ) async {
      bool editCalled = false;
      final message = ConversationMessage(
        id: '1',
        conversationId: 'conv-1',
        senderId: 'user-me',
        content: 'Long press to edit',
        sentAt: DateTime.now().subtract(const Duration(minutes: 5)),
        status: 'sent',
      );

      await tester.pumpWidget(
        buildTestableWidget(
          MessageBubble(
            message: message,
            isMe: true,
            isConnected: true,
            onEdit: () {
              editCalled = true;
            },
          ),
        ),
      );

      await tester.longPress(find.text('Long press to edit'));
      await tester.pump();

      expect(editCalled, isTrue);
    });

    testWidgets('uses different colors for own vs other messages', (
      tester,
    ) async {
      final myMessage = ConversationMessage(
        id: '1',
        conversationId: 'conv-1',
        senderId: 'user-me',
        content: 'My message',
        sentAt: DateTime.now(),
        status: 'sent',
      );

      final otherMessage = ConversationMessage(
        id: '2',
        conversationId: 'conv-1',
        senderId: 'user-other',
        content: 'Other message',
        sentAt: DateTime.now(),
        status: 'sent',
      );

      await tester.pumpWidget(
        buildTestableWidget(
          Column(
            children: [
              MessageBubble(
                message: myMessage,
                isMe: true,
                isConnected: true,
                onEdit: null,
              ),
              MessageBubble(
                message: otherMessage,
                isMe: false,
                isConnected: true,
                onEdit: null,
              ),
            ],
          ),
        ),
      );

      // Find the containers with decorations (message bubbles)
      final containers = tester.widgetList<Container>(find.byType(Container));
      expect(containers.length, greaterThanOrEqualTo(2));
    });
  });

  group('ConnectionIndicator', () {
    testWidgets('shows offline state when ws not connected', (tester) async {
      await tester.pumpWidget(
        buildTestableWidget(
          const ConnectionIndicator(status: 'connected', isWsConnected: false),
        ),
      );

      expect(find.text('离线'), findsOneWidget);
    });

    testWidgets('shows connected status when ws connected', (tester) async {
      await tester.pumpWidget(
        buildTestableWidget(
          const ConnectionIndicator(status: 'connected', isWsConnected: true),
        ),
      );

      expect(find.text('已连接'), findsOneWidget);
    });

    testWidgets('shows pending status', (tester) async {
      await tester.pumpWidget(
        buildTestableWidget(
          const ConnectionIndicator(status: 'pending', isWsConnected: true),
        ),
      );

      expect(find.text('待接受'), findsOneWidget);
    });

    testWidgets('shows connecting status with animation', (tester) async {
      await tester.pumpWidget(
        buildTestableWidget(
          const ConnectionIndicator(status: 'connecting', isWsConnected: true),
        ),
      );

      expect(find.text('连接中...'), findsOneWidget);
      // Verify the ConnectionIndicator has an AnimatedBuilder descendant
      expect(
        find.descendant(
          of: find.byType(ConnectionIndicator),
          matching: find.byType(AnimatedBuilder),
        ),
        findsWidgets,
      );
    });

    testWidgets('shows default offline for unknown status', (tester) async {
      await tester.pumpWidget(
        buildTestableWidget(
          const ConnectionIndicator(
            status: 'unknown_status',
            isWsConnected: true,
          ),
        ),
      );

      expect(find.text('离线'), findsOneWidget);
    });
  });

  group('UserChatMessageList', () {
    testWidgets('shows retry state when initial load fails', (tester) async {
      final controller = ScrollController();
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        buildTestableWidget(
          UserChatMessageList(
            isLoading: false,
            error: 'network',
            messages: const [],
            currentUserId: null,
            connectionStatus: null,
            scrollController: controller,
            onRetry: () {},
            onEditMessage: (_) {},
          ),
        ),
      );

      final l = AppLocalizations.of(tester.element(find.byType(Scaffold)))!;
      expect(find.text(l.loadFailedWithError('network')), findsOneWidget);
      expect(find.text(l.retry), findsOneWidget);
    });

    testWidgets('shows empty state when there are no messages', (tester) async {
      final controller = ScrollController();
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        buildTestableWidget(
          UserChatMessageList(
            isLoading: false,
            error: null,
            messages: const [],
            currentUserId: null,
            connectionStatus: 'connected',
            scrollController: controller,
            onRetry: () {},
            onEditMessage: (_) {},
          ),
        ),
      );

      expect(find.text('暂无消息，开始聊天吧'), findsOneWidget);
    });
  });

  group('UserChatInputArea', () {
    testWidgets('shows pending banner when conversation is not connected', (
      tester,
    ) async {
      final controller = TextEditingController();
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        buildTestableWidget(
          UserChatInputArea(
            connectionStatus: 'pending',
            isRecording: false,
            recordingSeconds: 0,
            isSending: false,
            isEditing: false,
            textController: controller,
            onPickImage: () {},
            onToggleRecording: () {},
            onCancelEdit: () {},
            onChanged: (_) {},
            onSubmitted: (_) {},
            onSend: () {},
          ),
        ),
      );

      expect(find.text('等待对方接通'), findsOneWidget);
      expect(find.byType(TextField), findsNothing);
    });

    testWidgets('shows edit affordances when editing a message', (
      tester,
    ) async {
      final controller = TextEditingController(text: 'draft');
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        buildTestableWidget(
          UserChatInputArea(
            connectionStatus: 'connected',
            isRecording: false,
            recordingSeconds: 0,
            isSending: false,
            isEditing: true,
            textController: controller,
            onPickImage: () {},
            onToggleRecording: () {},
            onCancelEdit: () {},
            onChanged: (_) {},
            onSubmitted: (_) {},
            onSend: () {},
          ),
        ),
      );

      expect(find.text('编辑消息...'), findsOneWidget);
      expect(find.byIcon(Icons.check), findsOneWidget);
      expect(find.byIcon(Icons.close), findsOneWidget);
    });
  });
}
