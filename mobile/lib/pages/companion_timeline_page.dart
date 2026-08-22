import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../companion/companion_config.dart';
import '../companion/runtime_host.dart';

/// Event timeline debugger (master goal §69): a rolling, timestamped view of
/// every companion runtime event, for analysing perceived latency.
class CompanionTimelinePage extends StatelessWidget {
  const CompanionTimelinePage({super.key});

  @override
  Widget build(BuildContext context) {
    if (!kCompanionEnabled) {
      return const Scaffold(body: Center(child: Text('Companion disabled')));
    }
    final host = context.watch<CompanionRuntimeHost>();
    final events = host.timeline.events.reversed.toList();

    return Scaffold(
      key: const Key('companion-timeline'),
      appBar: AppBar(
        title: const Text('Companion Timeline'),
        actions: [
          IconButton(
            tooltip: 'Clear',
            icon: const Icon(Icons.delete_sweep_outlined),
            onPressed: () => host.timeline.clear(),
          ),
        ],
      ),
      body: events.isEmpty
          ? const Center(child: Text('No events yet'))
          : ListView.separated(
              itemCount: events.length,
              separatorBuilder: (context, index) => const Divider(height: 1),
              itemBuilder: (context, index) {
                final e = events[index];
                final t = e.timestamp;
                String two(int v) => v.toString().padLeft(2, '0');
                final clock =
                    '${two(t.hour)}:${two(t.minute)}:${two(t.second)}.'
                    '${t.millisecond.toString().padLeft(3, '0')}';
                final data = e.data.isEmpty
                    ? ''
                    : ' ${e.data.entries.map((x) => '${x.key}=${x.value}').join(' ')}';
                return ListTile(
                  dense: true,
                  visualDensity: VisualDensity.compact,
                  leading: Text(
                    clock,
                    style: const TextStyle(
                      fontFeatures: [],
                      fontSize: 12,
                      color: Color(0xFF64748B),
                    ),
                  ),
                  title: Text(
                    e.type.name,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  subtitle: data.isEmpty
                      ? null
                      : Text(
                          data,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 11),
                        ),
                );
              },
            ),
    );
  }
}
