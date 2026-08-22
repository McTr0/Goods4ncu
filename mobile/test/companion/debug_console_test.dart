import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goods4ncu_mobile/companion/companion_events.dart';
import 'package:goods4ncu_mobile/companion/runtime_host.dart';
import 'package:goods4ncu_mobile/pages/companion_debug_console.dart';
import 'package:goods4ncu_mobile/pages/companion_timeline_page.dart';
import 'package:provider/provider.dart';

Widget _wrap(Widget child, {CompanionRuntimeHost? host}) {
  final runtimeHost = host ?? CompanionRuntimeHost();
  return ChangeNotifierProvider<CompanionRuntimeHost>.value(
    value: runtimeHost,
    child: MaterialApp(
      routes: {'/companion/timeline': (_) => const CompanionTimelinePage()},
      home: child,
    ),
  );
}

void main() {
  testWidgets('console shows live state and harness drives the full loop', (
    tester,
  ) async {
    final host = CompanionRuntimeHost();

    await tester.pumpWidget(_wrap(const CompanionDebugConsole(), host: host));

    expect(find.text('idle'), findsOneWidget);

    // Fake-async timers only advance when we pump explicit durations.
    await tester.tap(find.byKey(const Key('companion-run-loop')));
    await tester.pump(); // LISTENING
    expect(host.machine.state.name, 'listening');

    await tester.pump(const Duration(milliseconds: 300)); // THINKING
    expect(host.machine.state.name, 'thinking');

    await tester.pump(const Duration(milliseconds: 400)); // SPEAKING + gesture
    expect(host.machine.state.name, 'speaking');

    await tester.pump(const Duration(milliseconds: 600)); // TTS end -> IDLE
    expect(host.machine.state.name, 'idle');
    // The demo spoke: TTS events were announced on the bus.
    expect(
      host.timeline.events.map((e) => e.type),
      containsAll([CompanionEventType.ttsStart, CompanionEventType.ttsEnd]),
    );
    // And the mock body received the speech gesture.
    expect(host.mock!.motionLog.map((m) => m.$1), contains('acknowledge'));

    host.dispose();
  });

  testWidgets('debug console links to the timeline page', (tester) async {
    final host = CompanionRuntimeHost();
    host.bus.emit(CompanionEventType.agentThinking, {'probe': true});

    await tester.pumpWidget(_wrap(const CompanionDebugConsole(), host: host));
    await tester.tap(find.byKey(const Key('companion-open-timeline')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('companion-timeline')), findsOneWidget);
    expect(find.text('agentThinking'), findsOneWidget);

    host.dispose();
  });
}
