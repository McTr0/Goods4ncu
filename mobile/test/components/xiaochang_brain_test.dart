import 'package:flutter_test/flutter_test.dart';
import 'package:goods4ncu_mobile/components/live2d/xiaochang_brain.dart';

void main() {
  group('XiaochangBrain page context', () {
    test('starts in assistant-home conversation mode', () {
      final brain = XiaochangBrain();
      brain.dispose();

      expect(brain.page, 'chat');
      expect(brain.task, XiaochangTask.conversation);
      expect(brain.lastReason, 'Waiting for the user');
    });

    test('uses inspection mode for listing context', () {
      final brain = XiaochangBrain();

      brain.onPageChanged('post_detail', listingId: 'listing-7');

      expect(brain.page, 'post_detail');
      expect(brain.task, XiaochangTask.inspectItem);
      expect(brain.lastReason, 'The user is inspecting a specific item');
      expect(brain.gazeTargetX, 0.45);
      brain.dispose();
    });

    test('distinguishes discussion context from listings', () {
      final brain = XiaochangBrain();

      brain.onPageChanged('post_detail');

      expect(brain.page, 'post_detail');
      expect(brain.task, XiaochangTask.inspectItem);
      expect(brain.currentIntent?.action, 'focus_post');
      expect(brain.lastReason, 'The user is inspecting a specific discussion');
      brain.dispose();
    });
  });
}
