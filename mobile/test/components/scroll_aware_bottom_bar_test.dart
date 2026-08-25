import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goods4ncu_mobile/components/scroll_aware_bottom_bar.dart';

Widget _host(
  ScrollAwareBottomBarController controller, {
  ScrollController? scrollController,
}) {
  return MaterialApp(
    home: Scaffold(
      body: NotificationListener<ScrollMetricsNotification>(
        onNotification: controller.handleScrollMetricsNotification,
        child: Listener(
          onPointerSignal: controller.handlePointerSignal,
          child: NotificationListener<ScrollNotification>(
            onNotification: controller.handleScrollNotification,
            child: ListView.builder(
              controller: scrollController,
              itemCount: 40,
              itemBuilder: (_, index) =>
                  SizedBox(height: 64, child: Text('Item $index')),
            ),
          ),
        ),
      ),
      bottomNavigationBar: ScrollAwareBottomBar(
        controller: controller,
        child: const SizedBox(height: 72, child: Text('Navigation')),
      ),
    ),
  );
}

void main() {
  testWidgets('hides on downward drag and returns on upward drag', (
    tester,
  ) async {
    final controller = ScrollAwareBottomBarController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(_host(controller));

    expect(controller.visible, isTrue);
    expect(tester.getSize(find.text('Navigation')).height, 72);

    await tester.drag(find.byType(ListView), const Offset(0, -160));
    await tester.pumpAndSettle();

    expect(controller.visible, isFalse);
    expect(tester.getSize(find.byType(ScrollAwareBottomBar)).height, 0);

    await tester.drag(find.byType(ListView), const Offset(0, 80));
    await tester.pumpAndSettle();

    expect(controller.visible, isTrue);
    expect(tester.getSize(find.byType(ScrollAwareBottomBar)).height, 72);
  });

  testWidgets('programmatic scrolling does not hide navigation', (
    tester,
  ) async {
    final controller = ScrollAwareBottomBarController();
    final scrollController = ScrollController();
    addTearDown(controller.dispose);
    addTearDown(scrollController.dispose);

    await tester.pumpWidget(
      _host(controller, scrollController: scrollController),
    );

    final animation = scrollController.animateTo(
      500,
      duration: const Duration(milliseconds: 100),
      curve: Curves.linear,
    );
    await tester.pumpAndSettle();
    await animation;

    expect(controller.visible, isTrue);
  });

  testWidgets('mouse wheel hides navigation on a scrollable page', (
    tester,
  ) async {
    final controller = ScrollAwareBottomBarController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(_host(controller));
    final center = tester.getCenter(find.byType(ListView));

    await tester.sendEventToBinding(
      PointerScrollEvent(position: center, scrollDelta: const Offset(0, 200)),
    );
    await tester.pump();
    await tester.sendEventToBinding(
      PointerScrollEvent(position: center, scrollDelta: const Offset(0, 200)),
    );
    await tester.pumpAndSettle();

    expect(controller.visible, isFalse);
  });
}
