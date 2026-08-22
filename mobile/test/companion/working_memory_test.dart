import 'package:flutter_test/flutter_test.dart';
import 'package:goods4ncu_mobile/companion/environment.dart';
import 'package:goods4ncu_mobile/companion/working_memory.dart';

void main() {
  test('search sets the topic; post opens build recency', () {
    final memory = WorkingMemory();

    memory.observe(
      EnvironmentEvent(
        EnvironmentEventType.searchPerformed,
        payload: {'query': '二手显示器'},
      ),
    );
    memory.observe(
      EnvironmentEvent(
        EnvironmentEventType.postOpened,
        payload: {'postId': 'p1'},
      ),
    );
    memory.observe(
      EnvironmentEvent(
        EnvironmentEventType.postOpened,
        payload: {'listingId': 'l2'},
      ),
    );
    // Re-opening p1 moves it to the front.
    memory.observe(
      EnvironmentEvent(
        EnvironmentEventType.postOpened,
        payload: {'postId': 'p1'},
      ),
    );

    expect(memory.currentTopic, '二手显示器');
    expect(memory.recentPostIds, ['p1', 'l2']);
  });

  test('draft lifecycle clears pending state', () {
    final memory = WorkingMemory();

    memory.observe(
      EnvironmentEvent(
        EnvironmentEventType.draftShown,
        payload: {'draftText': '你好，请问周末方便面交吗？', 'postId': 'p9'},
      ),
    );
    expect(memory.pendingDraft, isNotNull);
    expect(memory.pendingDraftTarget, 'p9');

    memory.observe(EnvironmentEvent(EnvironmentEventType.draftConfirmed));
    expect(memory.pendingDraft, isNull);
  });

  test('prompt fragment carries topic, recency and draft flag only', () {
    final memory = WorkingMemory();
    expect(memory.toPromptFragment(), isEmpty);

    memory.observe(
      EnvironmentEvent(
        EnvironmentEventType.searchPerformed,
        payload: {'query': 'switch'},
      ),
    );
    memory.observe(
      EnvironmentEvent(
        EnvironmentEventType.postOpened,
        payload: {'postId': 'a'},
      ),
    );
    memory.observe(
      EnvironmentEvent(
        EnvironmentEventType.postOpened,
        payload: {'postId': 'b'},
      ),
    );
    memory.observe(
      EnvironmentEvent(
        EnvironmentEventType.draftShown,
        payload: {'draftText': 'x'},
      ),
    );

    final fragment = memory.toPromptFragment();
    expect(fragment['currentTopic'], 'switch');
    expect(fragment['recentPostIds'], ['b', 'a']);
    expect(fragment['hasPendingDraft'], isTrue);
  });
}
