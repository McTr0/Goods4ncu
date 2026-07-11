import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:good4ncu_mobile/l10n/app_localizations.dart';
import 'package:good4ncu_mobile/models/models.dart';
import 'package:good4ncu_mobile/pages/chat_page.dart';
import 'package:good4ncu_mobile/services/api_service.dart';
import 'package:good4ncu_mobile/services/chat_service.dart';
import 'package:good4ncu_mobile/services/sse_service.dart';
import 'package:good4ncu_mobile/services/upload_service.dart';

class _FakeApiService extends ApiService {
  @override
  Future<Map<String, dynamic>> getUserProfile() async => {'user_id': 'user-1'};

  @override
  Future<List<HitlRequest>> getNegotiations() async => const [];
}

class _FakeChatService extends ChatService {
  @override
  Future<AssistantConversationHistory> getAssistantHistory({
    int limit = 50,
    int offset = 0,
  }) async {
    return AssistantConversationHistory(
      messages: [
        ChatMessage(
          sender: 'bot',
          content: '欢迎回来',
          timestamp: DateTime(2026, 7, 9, 10),
        ),
      ],
      total: 1,
    );
  }
}

class _FakeUploadService extends UploadService {}

Widget _buildTestApp(Widget child) {
  return MaterialApp(
    locale: const Locale('zh'),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(body: child),
  );
}

void main() {
  testWidgets('assistant page exposes an exit action', (tester) async {
    var exited = false;

    await tester.pumpWidget(
      _buildTestApp(
        ChatPage(
          apiService: _FakeApiService(),
          chatService: _FakeChatService(),
          sseService: SseService(),
          uploadService: _FakeUploadService(),
          embedded: true,
          onExit: () => exited = true,
        ),
      ),
    );
    await tester.pumpAndSettle();

    final l = AppLocalizations.of(tester.element(find.byType(Scaffold)))!;
    await tester.tap(find.byTooltip(l.closeConversationAction));
    await tester.pump();

    expect(exited, isTrue);
  });
}
