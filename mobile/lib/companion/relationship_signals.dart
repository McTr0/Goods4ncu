/// Deterministic mapping from platform behaviour to relationship events
/// (master goal §14). Pure logic — the page owns the API calls.
class CompanionRelationshipSignals {
  int _roundsThisTurn = 0;
  bool _toolUsedThisTurn = false;
  DateTime? _lastLongConversationAt;

  static final RegExp _thanksPattern = RegExp(
    r'谢谢|感谢|thx|thanks',
    caseSensitive: false,
  );

  /// Call when a user turn begins (message dispatched).
  ///
  /// The plain-turn counter intentionally survives across turns: it measures
  /// session-long back-and-forth for `long_conversation`, and only re-arms
  /// after a credit plus its cooldown window.
  void onTurnStart() {
    _toolUsedThisTurn = false;
  }

  void onToolActivity() => _toolUsedThisTurn = true;

  /// Call after a turn completes. Returns at most one event name, in priority
  /// order: thanks > tool use > long conversation.
  String? eventForCompletedTurn(
    String userText, {
    DateTime Function()? now,
    Duration longConversationWindow = const Duration(minutes: 30),
  }) {
    final clock = now ?? DateTime.now;
    if (_thanksPattern.hasMatch(userText)) return 'user_thanks';
    if (_toolUsedThisTurn) return 'user_uses_agent_tool';

    _roundsThisTurn += 1;
    if (_roundsThisTurn >= 6) {
      final last = _lastLongConversationAt;
      if (last == null || clock().difference(last) > longConversationWindow) {
        _lastLongConversationAt = clock();
        return 'long_conversation';
      }
    }
    return null;
  }
}
