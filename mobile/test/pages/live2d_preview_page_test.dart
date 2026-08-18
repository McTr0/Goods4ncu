import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goods4ncu_mobile/components/live2d/live2d_character_widget.dart';
import 'package:goods4ncu_mobile/pages/live2d_preview_page.dart';
import 'package:goods4ncu_mobile/theme/app_theme.dart';

void main() {
  testWidgets('Live2DPreviewPage renders character widget and controls', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        home: const Live2DPreviewPage(),
      ),
    );

    expect(find.text('小昌 · 2D 互动数字人'), findsOneWidget);
    expect(find.byType(Live2DCharacterWidget), findsOneWidget);
    expect(find.text('摸摸头'), findsOneWidget);
    expect(find.text('模拟说话口型'), findsOneWidget);

    // Tap "摸摸头" button
    await tester.tap(find.text('摸摸头'));
    await tester.pump();

    // Verify speech bubble / reaction
    expect(find.textContaining('摸摸小脑袋'), findsOneWidget);
  });
}
