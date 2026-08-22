import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goods4ncu_mobile/components/agent_debug_panel.dart';
import 'package:goods4ncu_mobile/components/live2d/xiaochang_brain.dart';

void main() {
  testWidgets('renders page context and character state', (tester) async {
    final brain = XiaochangBrain();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AgentDebugPanel(
            brain: brain,
            pageContext: const {
              'page': 'post_detail',
              'listingId': 'listing-7',
              'postId': '42',
            },
            toolCalls: const ['12:00:00.000 search_inventory'],
            uiActions: const ['SHOW_POSTS postIds=[1, 2]'],
            pendingConfirmations: 2,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('AGENT DEBUG'), findsOneWidget);
    expect(find.text('post_detail'), findsOneWidget);
    expect(find.text('listing-7'), findsOneWidget);
    expect(find.text('42'), findsOneWidget);
    expect(find.text('12:00:00.000 search_inventory'), findsOneWidget);
    expect(find.text('SHOW_POSTS postIds=[1, 2]'), findsOneWidget);
    expect(find.text('2'), findsOneWidget);
    brain.dispose();
  });

  testWidgets('reflects live tool state from the brain', (tester) async {
    final brain = XiaochangBrain();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AgentDebugPanel(
            brain: brain,
            pageContext: const {'page': 'chat'},
            toolCalls: const [],
            uiActions: const [],
            pendingConfirmations: 0,
            currentTool: 'search_inventory',
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('THINKING'), findsNothing);
    brain.onToolStarted('search_inventory');
    await tester.pumpAndSettle();

    expect(find.text('THINKING'), findsOneWidget);
    expect(find.text('curious'), findsOneWidget);
    expect(find.text('tool_using_search_inventory'), findsOneWidget);
    expect(find.text('search_inventory'), findsOneWidget);
    await tester.pump();
    brain.dispose();
  });

  testWidgets('shows latency values when provided', (tester) async {
    final brain = XiaochangBrain();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AgentDebugPanel(
            brain: brain,
            pageContext: const {'page': 'chat'},
            toolCalls: const [],
            uiActions: const [],
            pendingConfirmations: 0,
            firstTokenLatency: const Duration(milliseconds: 240),
            lastTurnLatency: const Duration(milliseconds: 1830),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('240 ms'), findsOneWidget);
    expect(find.text('1830 ms'), findsOneWidget);
    brain.dispose();
  });
}
