import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goods4ncu_mobile/l10n/app_localizations.dart';
import 'package:goods4ncu_mobile/models/models.dart';
import 'package:goods4ncu_mobile/pages/chat_page.dart';
import 'package:goods4ncu_mobile/services/api_service.dart';
import 'package:goods4ncu_mobile/services/chat_service.dart';
import 'package:goods4ncu_mobile/services/sse_service.dart';
import 'package:goods4ncu_mobile/services/upload_service.dart';

class _FakeApiService extends ApiService {
  _FakeApiService({this.undoable = const [], this.undoResult});

  List<UndoableAction> undoable;
  final UndoResult? undoResult;
  final List<String> undone = [];

  @override
  Future<Map<String, dynamic>> getUserProfile() async => {'user_id': 'user-1'};

  @override
  Future<List<HitlRequest>> getNegotiations() async => const [];

  @override
  Future<List<AgentPlan>> getAgentPlans() async => const [];

  @override
  Future<List<UndoableAction>> getUndoableActions() async => undoable;

  @override
  Future<UndoResult> undoAction(String id) async {
    undone.add(id);
    undoable = undoable.where((a) => a.id != id).toList();
    return undoResult ??
        UndoResult(undone: true, conflict: false, message: '已撤销发布');
  }
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

  testWidgets('a reversible write offers an undo affordance with a countdown', (
    tester,
  ) async {
    // The whole trade behind executing low-risk writes immediately is that the
    // user can still take them back. If this affordance is missing the backend
    // undo window buys nothing.
    final api = _FakeApiService(
      undoable: [
        UndoableAction(
          id: 'action-1',
          actionKind: 'listing.create',
          summary: '发布商品《宿舍小台灯》，价格 ¥30.00',
          undoDeadline: DateTime.now().toUtc().add(const Duration(minutes: 5)),
        ),
      ],
    );

    await tester.pumpWidget(
      _buildTestApp(
        ChatPage(
          apiService: api,
          chatService: _FakeChatService(),
          sseService: SseService(),
          uploadService: _FakeUploadService(),
          embedded: true,
        ),
      ),
    );
    await tester.pumpAndSettle();

    final l = AppLocalizations.of(tester.element(find.byType(Scaffold)))!;
    expect(find.text(l.undoDoneHeader), findsOneWidget);
    expect(find.text('发布商品《宿舍小台灯》，价格 ¥30.00'), findsOneWidget);
    // A countdown, so the window is visible rather than a surprise.
    expect(find.textContaining('剩'), findsOneWidget);

    await tester.tap(find.text(l.undoAction));
    await tester.pumpAndSettle();

    expect(api.undone, ['action-1']);
    // The affordance goes away with the action it belonged to.
    expect(find.text(l.undoDoneHeader), findsNothing);
  });

  testWidgets('a refused undo shows the server explanation, not an error', (
    tester,
  ) async {
    // A conflict means the world moved on — the item sold — and reverting
    // would have overwritten that. The user needs to read what happened, so
    // this must not surface as a generic failure.
    final api = _FakeApiService(
      undoable: [
        UndoableAction(
          id: 'action-2',
          actionKind: 'listing.create',
          summary: '发布商品《宿舍小台灯》',
          undoDeadline: DateTime.now().toUtc().add(const Duration(minutes: 5)),
        ),
      ],
      undoResult: UndoResult(
        undone: false,
        conflict: true,
        message: '这条发布已经有了新的变化，撤销可能覆盖新的改动，因此没有执行。',
      ),
    );

    await tester.pumpWidget(
      _buildTestApp(
        ChatPage(
          apiService: api,
          chatService: _FakeChatService(),
          sseService: SseService(),
          uploadService: _FakeUploadService(),
          embedded: true,
        ),
      ),
    );
    await tester.pumpAndSettle();

    final l = AppLocalizations.of(tester.element(find.byType(Scaffold)))!;
    await tester.tap(find.text(l.undoAction));
    await tester.pump();

    expect(find.textContaining('撤销可能覆盖新的改动'), findsOneWidget);
  });

  testWidgets('an already-expired action is not offered', (tester) async {
    // Showing a dead button invites a tap that can only fail.
    final api = _FakeApiService(
      undoable: [
        UndoableAction(
          id: 'action-3',
          actionKind: 'listing.create',
          summary: '过期的发布',
          undoDeadline: DateTime.now().toUtc().subtract(
            const Duration(seconds: 1),
          ),
        ),
      ],
    );

    await tester.pumpWidget(
      _buildTestApp(
        ChatPage(
          apiService: api,
          chatService: _FakeChatService(),
          sseService: SseService(),
          uploadService: _FakeUploadService(),
          embedded: true,
        ),
      ),
    );
    await tester.pumpAndSettle();

    final l = AppLocalizations.of(tester.element(find.byType(Scaffold)))!;
    expect(find.text(l.undoDoneHeader), findsNothing);
    expect(find.text('过期的发布'), findsNothing);
  });
}
