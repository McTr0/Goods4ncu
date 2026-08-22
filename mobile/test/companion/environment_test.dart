import 'package:flutter_test/flutter_test.dart';
import 'package:goods4ncu_mobile/companion/environment.dart';

void main() {
  test('post open/close updates focus and only open is meaningful', () {
    final tracker = EnvironmentTracker(state: EnvironmentState());
    tracker.events.listen((_) {});
    final captured = <EnvironmentEvent>[];
    final hooked = EnvironmentTracker(
      state: EnvironmentState(),
      onMeaningfulEvent: captured.add,
    );

    hooked.trackPostOpened(postId: 'p-1', listingId: 'l-1');
    expect(hooked.state.selectedPostId, 'p-1');
    expect(hooked.state.selectedListingId, 'l-1');
    expect(captured.map((e) => e.type), [EnvironmentEventType.postOpened]);

    hooked.track(EnvironmentEvent(EnvironmentEventType.postClosed));
    expect(hooked.state.selectedPostId, isNull);
    expect(
      captured,
      hasLength(1),
      reason: 'closing is recorded but not forwarded',
    );
  });

  test('scroll ticks are folded into a counter, never events', () {
    final tracker = EnvironmentTracker(state: EnvironmentState());
    var forwarded = 0;
    tracker.events.listen((_) {});

    final hooked = EnvironmentTracker(
      state: EnvironmentState(),
      onMeaningfulEvent: (_) => forwarded++,
    );

    for (var i = 0; i < 50; i++) {
      hooked.trackScroll();
    }

    expect(hooked.state.scrollTicks, 50);
    expect(forwarded, 0);
    expect(hooked.state.recentEvents, isEmpty);
  });

  test('search query is stored and surfaced in the prompt fragment', () {
    final tracker = EnvironmentTracker(state: EnvironmentState());
    tracker.trackPageChanged('post_detail');
    tracker.trackSearch('显示器');

    expect(tracker.state.page, 'post_detail');
    expect(tracker.state.searchQuery, '显示器');

    final fragment = tracker.state.toPromptFragment();
    expect(fragment['page'], 'post_detail');
    expect(fragment['searchQuery'], '显示器');
  });

  test('recent events ring keeps newest first within capacity', () {
    final state = EnvironmentState(maxEvents: 3);
    for (var i = 0; i < 5; i++) {
      state.record(
        EnvironmentEvent(
          EnvironmentEventType.searchPerformed,
          payload: {'query': 'q$i'},
        ),
      );
    }
    expect(state.recentEvents.length, 3);
    expect(state.recentEvents.first.payload['query'], 'q4');
    expect(state.takeRecentForLLM(2).length, 2);
  });
}
