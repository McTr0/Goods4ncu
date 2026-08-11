import 'package:shared_preferences/shared_preferences.dart';

/// Device-local last-seen marker for direct-message threads.
///
/// It is intentionally not synchronized with the server. Two devices may
/// therefore show different "new message" badges without exposing an
/// attention/read fact to the other participant.
abstract class ChatLocalSeenStorage {
  Future<DateTime?> read(String peerUserId);

  Future<void> mark(String peerUserId, DateTime seenAt);
}

class SharedPreferencesChatLocalSeenStorage implements ChatLocalSeenStorage {
  static const _keyPrefix = 'chat_locally_seen:';

  @override
  Future<DateTime?> read(String peerUserId) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('$_keyPrefix$peerUserId');
    return raw == null ? null : DateTime.tryParse(raw);
  }

  @override
  Future<void> mark(String peerUserId, DateTime seenAt) async {
    final prefs = await SharedPreferences.getInstance();
    final current = await read(peerUserId);
    if (current != null && !seenAt.isAfter(current)) return;
    await prefs.setString(
      '$_keyPrefix$peerUserId',
      seenAt.toUtc().toIso8601String(),
    );
  }
}
