import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goods4ncu_mobile/components/live2d/live2d_controller.dart';
import 'package:goods4ncu_mobile/components/live2d/live2d_lipsync_driver.dart';

void main() {
  group('Live2DController Tests', () {
    test('initial state is idle and zero gaze', () {
      final controller = Live2DController();
      expect(controller.lookAtX, 0.0);
      expect(controller.lookAtY, 0.0);
      expect(controller.mouthOpen, 0.0);
      expect(controller.expression, Live2DExpression.idle);
      expect(controller.hitCount, 0);
      expect(controller.lastHitZone, Live2DHitZone.none);
      controller.dispose();
    });

    test('lookAt clamps coordinates within [-1.0, 1.0]', () {
      final controller = Live2DController();
      controller.lookAt(1.5, -2.0);
      expect(controller.lookAtX, 1.0);
      expect(controller.lookAtY, -1.0);

      controller.resetGaze();
      expect(controller.lookAtX, 0.0);
      expect(controller.lookAtY, 0.0);
      controller.dispose();
    });

    test('setMouthOpen clamps between 0.0 and 1.0', () {
      final controller = Live2DController();
      controller.setMouthOpen(0.85);
      expect(controller.mouthOpen, 0.85);

      controller.setMouthOpen(1.5);
      expect(controller.mouthOpen, 1.0);

      controller.setMouthOpen(-0.5);
      expect(controller.mouthOpen, 0.0);
      controller.dispose();
    });

    test('handleTap correctly classifies head vs belly hit zones', () {
      final controller = Live2DController();
      const size = Size(200, 200);

      // Tap Top (Head zone)
      final hitHead = controller.handleTap(const Offset(100, 40), size);
      expect(hitHead, Live2DHitZone.head);
      expect(controller.lastHitZone, Live2DHitZone.head);
      expect(controller.hitCount, 1);
      expect(controller.speechBubble, isNotNull);

      // Tap Bottom (Belly zone)
      final hitBelly = controller.handleTap(const Offset(100, 150), size);
      expect(hitBelly, Live2DHitZone.belly);
      expect(controller.lastHitZone, Live2DHitZone.belly);
      expect(controller.hitCount, 2);
      expect(controller.speechBubble, isNotNull);

      controller.dispose();
    });

    test('Live2DLipSyncDriver drives mouth opening on streaming chunks', () {
      final controller = Live2DController();
      final driver = Live2DLipSyncDriver(controller: controller);

      driver.feedStreamingChunk('你好！');
      expect(controller.mouthOpen, greaterThan(0.0));

      driver.onStreamComplete();
      expect(controller.mouthOpen, 0.0);

      driver.dispose();
      controller.dispose();
    });
  });
}
