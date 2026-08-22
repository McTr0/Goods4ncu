import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../companion/companion_config.dart';
import '../companion/runtime_host.dart';

/// Independent companion debug console (master goal §68).
///
/// Route: `/companion/debug`. Shows the live runtime snapshot and offers a
/// no-LLM interaction-loop harness to verify the state machine end-to-end.
class CompanionDebugConsole extends StatelessWidget {
  const CompanionDebugConsole({super.key});

  @override
  Widget build(BuildContext context) {
    if (!kCompanionEnabled) {
      return const Scaffold(body: Center(child: Text('Companion disabled')));
    }
    final host = context.watch<CompanionRuntimeHost>();
    final snap = host.snapshot();

    return Scaffold(
      key: const Key('companion-debug-console'),
      appBar: AppBar(
        title: const Text('Companion Debug'),
        actions: [
          IconButton(
            key: const Key('companion-open-timeline'),
            tooltip: 'Timeline',
            icon: const Icon(Icons.timeline),
            onPressed: () =>
                Navigator.pushNamed(context, '/companion/timeline'),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _section('STATE'),
          Wrap(
            spacing: 8,
            children: [
              _pill(snap.state.name, Colors.indigo),
              if (host.currentMotion != null)
                _pill('motion:${host.currentMotion}', Colors.deepPurple),
              _pill(
                'mouth ${snap.mouthOpen.toStringAsFixed(2)}',
                Colors.blueGrey,
              ),
            ],
          ),
          const SizedBox(height: 16),
          _section('EMOTION VECTOR'),
          ...snap.emotion.toMap().entries.map(
            (e) => Row(
              children: [
                SizedBox(
                  width: 120,
                  child: Text(e.key, style: const TextStyle(fontSize: 12)),
                ),
                Expanded(
                  child: LinearProgressIndicator(
                    value:
                        (e.value + (e.key == 'valence' ? 1 : 0)) /
                        (e.key == 'valence' ? 2 : 1),
                  ),
                ),
                SizedBox(
                  width: 48,
                  child: Text(
                    e.value.toStringAsFixed(2),
                    textAlign: TextAlign.right,
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          _section('ATTENTION'),
          Text(
            '${snap.attention.primary.name}'
            '${snap.attention.isLocked ? " 🔒" : ""}',
          ),
          const SizedBox(height: 16),
          _section('HARNESS (no LLM)'),
          FilledButton.icon(
            key: const Key('companion-run-loop'),
            icon: const Icon(Icons.play_arrow),
            label: const Text('Run LISTENING→THINKING→SPEAKING→IDLE loop'),
            onPressed: () => host.runInteractionLoop(),
          ),
        ],
      ),
    );
  }

  Widget _section(String title) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Text(
      title,
      style: const TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w800,
        letterSpacing: 1.1,
        color: Color(0xFF64748B),
      ),
    ),
  );

  Widget _pill(String text, Color color) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.12),
      borderRadius: BorderRadius.circular(999),
      border: Border.all(color: color.withValues(alpha: 0.4)),
    ),
    child: Text(
      text,
      style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: color),
    ),
  );
}
