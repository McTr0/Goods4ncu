import 'package:flutter_test/flutter_test.dart';
import 'package:goods4ncu_mobile/services/notification_filter_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeNotificationFilterPreferenceStore
    implements NotificationFilterPreferenceStore {
  _FakeNotificationFilterPreferenceStore({
    this.readValue,
    this.writeResult = true,
    this.throwOnWrite = false,
  });

  final String? readValue;
  final bool writeResult;
  final bool throwOnWrite;
  int readCalls = 0;
  int writeCalls = 0;
  String? lastWriteKey;
  String? lastWriteValue;

  @override
  Future<String?> readString(String key) async {
    readCalls += 1;
    return readValue;
  }

  @override
  Future<bool> writeString(String key, String value) async {
    writeCalls += 1;
    lastWriteKey = key;
    lastWriteValue = value;
    if (throwOnWrite) {
      throw Exception('store write failed');
    }
    return writeResult;
  }
}

void main() {
  group('SharedPrefsNotificationFilterStorage', () {
    late SharedPrefsNotificationFilterStorage storage;

    setUp(() {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      storage = SharedPrefsNotificationFilterStorage();
    });

    test('defaults to all when no persisted value exists', () async {
      final filter = await storage.readFilter();

      expect(filter, NotificationFilterPreference.all);
    });

    test('maps unread persisted value to unread preference', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'notifications_filter': 'unread',
      });

      final filter = await storage.readFilter();

      expect(filter, NotificationFilterPreference.unread);
    });

    test('falls back to all for unknown persisted value', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'notifications_filter': 'unexpected-value',
      });

      final filter = await storage.readFilter();

      expect(filter, NotificationFilterPreference.all);
    });

    test('writes unread preference to shared preferences', () async {
      await storage.writeFilter(NotificationFilterPreference.unread);
      final prefs = await SharedPreferences.getInstance();

      expect(prefs.getString('notifications_filter'), 'unread');
    });

    test('writes all preference to shared preferences', () async {
      await storage.writeFilter(NotificationFilterPreference.all);
      final prefs = await SharedPreferences.getInstance();

      expect(prefs.getString('notifications_filter'), 'all');
    });

    test('reads via injected store and maps unread value', () async {
      final fakeStore = _FakeNotificationFilterPreferenceStore(
        readValue: 'unread',
      );
      final storageWithFakeStore = SharedPrefsNotificationFilterStorage(
        store: fakeStore,
      );

      final filter = await storageWithFakeStore.readFilter();

      expect(filter, NotificationFilterPreference.unread);
      expect(fakeStore.readCalls, 1);
    });

    test('throws when persistence write returns false', () async {
      final fakeStore = _FakeNotificationFilterPreferenceStore(
        writeResult: false,
      );
      final storageWithFailingStore = SharedPrefsNotificationFilterStorage(
        store: fakeStore,
      );

      await expectLater(
        () => storageWithFailingStore.writeFilter(
          NotificationFilterPreference.unread,
        ),
        throwsA(
          isA<Exception>().having(
            (e) => e.toString(),
            'message',
            contains('failed to persist notifications filter preference'),
          ),
        ),
      );

      expect(fakeStore.writeCalls, 1);
      expect(fakeStore.lastWriteKey, 'notifications_filter');
      expect(fakeStore.lastWriteValue, 'unread');
    });

    test('propagates injected store write exceptions', () async {
      final fakeStore = _FakeNotificationFilterPreferenceStore(
        throwOnWrite: true,
      );
      final storageWithFailingStore = SharedPrefsNotificationFilterStorage(
        store: fakeStore,
      );

      await expectLater(
        () => storageWithFailingStore.writeFilter(
          NotificationFilterPreference.unread,
        ),
        throwsA(
          isA<Exception>().having(
            (e) => e.toString(),
            'message',
            contains('store write failed'),
          ),
        ),
      );

      expect(fakeStore.writeCalls, 1);
      expect(fakeStore.lastWriteKey, 'notifications_filter');
      expect(fakeStore.lastWriteValue, 'unread');
    });
  });
}
