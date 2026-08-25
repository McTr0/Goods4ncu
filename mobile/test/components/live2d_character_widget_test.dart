import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goods4ncu_mobile/components/live2d/live2d_character_widget.dart';
import 'package:goods4ncu_mobile/components/live2d/live2d_controller.dart';
import 'package:goods4ncu_mobile/theme/app_theme.dart';

Widget _testApp(
  Live2DController controller, {
  bool showSpeechBubble = false,
  ThemeMode themeMode = ThemeMode.light,
}) {
  return MaterialApp(
    theme: AppTheme.light,
    darkTheme: AppTheme.dark,
    themeMode: themeMode,
    home: Scaffold(
      body: Center(
        child: Live2DCharacterWidget(
          controller: controller,
          size: 200,
          showSpeechBubble: showSpeechBubble,
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('speech bubble uses dark theme surface and text colors', (
    tester,
  ) async {
    final controller = Live2DController()..showSpeechBubble('暗色气泡');
    await tester.pumpWidget(
      _testApp(controller, showSpeechBubble: true, themeMode: ThemeMode.dark),
    );
    await tester.pump();

    final context = tester.element(
      find.byKey(const Key('live2d-speech-bubble')),
    );
    final scheme = Theme.of(context).colorScheme;
    final bubble = tester.widget<Container>(
      find.byKey(const Key('live2d-speech-bubble')),
    );
    final decoration = bubble.decoration! as BoxDecoration;
    final text = tester.widget<Text>(find.text('暗色气泡'));

    expect(
      decoration.color,
      scheme.surfaceContainerHigh.withValues(alpha: 0.96),
    );
    expect(text.style?.color, scheme.onSurface);

    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });

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
