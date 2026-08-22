import 'package:flutter/material.dart';

import 'live2d/xiaochang_brain.dart';

/// Developer overlay required by the agent polish phase.
///
/// Enabled by opening the assistant page with `?agentDebug=true`. Shows the
/// live page context, character state machine values, recent tool calls,
/// recent UI actions, pending confirmations, and turn latency so agent +
/// Live2D behaviour can be inspected without attaching a debugger.
class AgentDebugPanel extends StatelessWidget {
  const AgentDebugPanel({
    super.key,
    required this.brain,
    required this.pageContext,
    required this.toolCalls,
    required this.uiActions,
    required this.pendingConfirmations,
    this.currentTool,
    this.firstTokenLatency,
    this.lastTurnLatency,
  });

  final XiaochangBrain brain;
  final Map<String, dynamic> pageContext;
  final List<String> toolCalls;
  final List<String> uiActions;
  final int pendingConfirmations;
  final String? currentTool;
  final Duration? firstTokenLatency;
  final Duration? lastTurnLatency;

  static const Color _bg = Color(0xF0101614);
  static const Color _text = Color(0xFFD7E2DC);
  static const Color _muted = Color(0xFF8FA39B);
  static const Color _accent = Color(0xFF6EE7C8);

  String get _attentionLabel => switch (brain.attention) {
    XiaochangAttention.user => 'IDLE',
    XiaochangAttention.input => 'LISTENING',
    XiaochangAttention.thinking => 'THINKING',
    XiaochangAttention.speaking => 'SPEAKING',
    XiaochangAttention.away => 'AWAY',
  };

  String get _moodLabel => switch (brain.mood) {
    XiaochangMood.neutral => 'neutral',
    XiaochangMood.curious => 'curious',
    XiaochangMood.happy => 'happy',
    XiaochangMood.concerned => 'concerned',
    XiaochangMood.sleepy => 'sleepy',
    XiaochangMood.playful => 'playful',
  };

  String get _taskLabel => switch (brain.task) {
    XiaochangTask.conversation => 'conversation',
    XiaochangTask.findItem => 'find_item',
    XiaochangTask.inspectItem => 'inspect_item',
    XiaochangTask.negotiate => 'negotiate',
    XiaochangTask.messageSeller => 'message_seller',
    XiaochangTask.getHelp => 'get_help',
  };

  String _formatLatency(Duration? value) {
    if (value == null) return '—';
    return '${value.inMilliseconds} ms';
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: brain,
      builder: (context, _) {
        final intent = brain.currentIntent;
        return Container(
          width: 264,
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
          decoration: BoxDecoration(
            color: _bg,
            borderRadius: BorderRadius.circular(10),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.35),
                blurRadius: 18,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'AGENT DEBUG',
                  style: TextStyle(
                    color: _accent,
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1.2,
                  ),
                ),
                const SizedBox(height: 8),
                _sectionTitle('PAGE CONTEXT'),
                _kv('page', pageContext['page']?.toString() ?? 'chat'),
                if (pageContext['listingId'] != null)
                  _kv('listingId', pageContext['listingId'].toString()),
                if (pageContext['postId'] != null)
                  _kv('postId', pageContext['postId'].toString()),
                const SizedBox(height: 8),
                _sectionTitle('CHARACTER STATE'),
                _kv('state', _attentionLabel),
                _kv('emotion', _moodLabel),
                _kv('task', _taskLabel),
                _kv(
                  'gaze',
                  '(${brain.gazeTargetX.toStringAsFixed(2)}, '
                      '${brain.gazeTargetY.toStringAsFixed(2)})',
                ),
                _kv('intent', intent?.action ?? '—'),
                if (intent != null) _kv('reason', intent.reason),
                _kv('currentTool', currentTool ?? '—'),
                const SizedBox(height: 8),
                _sectionTitle('TOOL CALLS (${toolCalls.length})'),
                if (toolCalls.isEmpty)
                  _empty('none yet')
                else ...[
                  for (final call in toolCalls.take(6)) _bullet(call),
                ],
                const SizedBox(height: 8),
                _sectionTitle('UI ACTIONS (${uiActions.length})'),
                if (uiActions.isEmpty)
                  _empty('none yet')
                else ...[
                  for (final action in uiActions.take(6)) _bullet(action),
                ],
                const SizedBox(height: 8),
                _sectionTitle('CONFIRMATION / LATENCY'),
                _kv('pendingConfirm', '$pendingConfirmations'),
                _kv('firstToken', _formatLatency(firstTokenLatency)),
                _kv('lastTurn', _formatLatency(lastTurnLatency)),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _sectionTitle(String title) => Padding(
    padding: const EdgeInsets.only(bottom: 4),
    child: Text(
      title,
      style: const TextStyle(
        color: _muted,
        fontSize: 9.5,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.8,
      ),
    ),
  );

  Widget _kv(String key, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 1),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 92,
          child: Text(key, style: const TextStyle(color: _muted, fontSize: 10)),
        ),
        Expanded(
          child: Text(
            value,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: _text, fontSize: 10),
          ),
        ),
      ],
    ),
  );

  Widget _bullet(String text) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 1),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.only(top: 3),
          child: Icon(Icons.circle, size: 4, color: _accent),
        ),
        const SizedBox(width: 5),
        Expanded(
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: _text, fontSize: 10),
          ),
        ),
      ],
    ),
  );

  Widget _empty(String text) =>
      Text(text, style: const TextStyle(color: _muted, fontSize: 10));
}
