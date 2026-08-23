import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goods4ncu_mobile/components/live2d/live2d_character_widget.dart';
import 'package:goods4ncu_mobile/components/live2d/live2d_controller.dart';

Widget _testApp(Live2DController controller) {
  return MaterialApp(
    home: Scaffold(
      body: Center(
        child: Live2DCharacterWidget(
          controller: controller,
          size: 200,
          showSpeechBubble: false,
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('mouse gaze returns to center after the pointer stops', (
    tester,
  ) async {
    final controller = Live2DController();
    await tester.pumpWidget(_testApp(controller));

    final target = find.byType(Live2DCharacterWidget);
    final center = tester.getCenter(target);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: center);
    await mouse.moveTo(center + const Offset(70, -50));
    await tester.pump();

    expect(controller.lookAtX, greaterThan(0));
    expect(controller.lookAtY, lessThan(0));

    await tester.pump(const Duration(milliseconds: 1601));
    expect(controller.lookAtX, 0);
    expect(controller.lookAtY, 0);
    await mouse.removePointer();
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });

  testWidgets('touch gaze returns to center shortly after release', (
    tester,
  ) async {
    final controller = Live2DController();
    await tester.pumpWidget(_testApp(controller));

    final target = find.byType(Live2DCharacterWidget);
    final center = tester.getCenter(target);
    await tester.tapAt(center + const Offset(60, 30));
    await tester.pump();

    expect(controller.lookAtX, greaterThan(0));
    expect(controller.lookAtY, greaterThan(0));

    await tester.pump(const Duration(milliseconds: 901));
    expect(controller.lookAtX, 0);
    expect(controller.lookAtY, 0);
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });
}
