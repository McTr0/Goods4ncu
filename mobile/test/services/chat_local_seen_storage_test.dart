import 'package:flutter_test/flutter_test.dart';
import 'package:goods4ncu_mobile/services/chat_local_seen_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('SharedPreferencesChatLocalSeenStorage', () {
    late SharedPreferencesChatLocalSeenStorage storage;

    setUp(() {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      storage = SharedPreferencesChatLocalSeenStorage();
    });

    test('stores a device-local marker per peer', () async {
      final seenAt = DateTime.utc(2026, 8, 11, 12, 30);

      await storage.mark('peer-a', seenAt);

      expect(await storage.read('peer-a'), seenAt);
      expect(await storage.read('peer-b'), isNull);
    });

    test('does not move a marker backwards', () async {
      final newer = DateTime.utc(2026, 8, 11, 12, 30);
      final older = DateTime.utc(2026, 8, 11, 12, 29);

      await storage.mark('peer-a', newer);
      await storage.mark('peer-a', older);

      expect(await storage.read('peer-a'), newer);
    });

    test('keeps markers isolated between peers', () async {
      await storage.mark('peer-a', DateTime.utc(2026, 8, 11, 12, 30));
      await storage.mark('peer-b', DateTime.utc(2026, 8, 11, 12, 31));

      expect(await storage.read('peer-a'), DateTime.utc(2026, 8, 11, 12, 30));
      expect(await storage.read('peer-b'), DateTime.utc(2026, 8, 11, 12, 31));
    });
  });
}
