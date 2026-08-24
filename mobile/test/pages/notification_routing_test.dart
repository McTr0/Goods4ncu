import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:goods4ncu_mobile/l10n/app_localizations.dart';
import 'package:goods4ncu_mobile/models/models.dart';
import 'package:goods4ncu_mobile/pages/notifications_page.dart';
import 'package:goods4ncu_mobile/services/notification_filter_storage.dart';
import 'package:goods4ncu_mobile/services/notification_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Where tapping a notification takes you.
///
/// The two notices that matter most in a new community — somebody answered what
/// you were looking for, and a group formed around it — carried a conversation
/// or a space id that the tap handler did not know about, so tapping them did
/// nothing. A dead tap on the one notice that says a person engaged with you is
/// worse than not sending it: it reads as the place being broken at exactly the
/// moment it started working.

class _NoFilterStorage implements NotificationFilterStorage {
  @override
  Future<NotificationFilterPreference> readFilter() async =>
      NotificationFilterPreference.all;

  @override
  Future<void> writeFilter(NotificationFilterPreference filter) async {}
}

class _OneNotificationService extends NotificationService {
  _OneNotificationService(this.item);

  final AppNotification item;

  @override
  Future<NotificationsResponse> getNotifications({
    int limit = 20,
    int offset = 0,
    bool includeRead = true,
  }) async => NotificationsResponse(
    items: [item],
    total: 1,
    unreadCount: item.isRead ? 0 : 1,
    limit: limit,
    offset: offset,
  );

  @override
  Future<bool> markNotificationRead(String id) async => true;
}

AppNotification _notification({
  String? conversationId,
  String? spaceId,
  String? listingId,
}) => AppNotification(
  id: 'n1',
  eventType: 'conversation_created',
  title: '有人回应了你想找的东西',
  body: '想收个二手显示器',
  relatedConversationId: conversationId,
  relatedSpaceId: spaceId,
  relatedListingId: listingId,
  isRead: false,
  createdAt: DateTime.now().toIso8601String(),
);

Future<void> _pumpWith(WidgetTester tester, AppNotification item) async {
  SharedPreferences.setMockInitialValues({});
  final router = GoRouter(
    routes: [
      GoRoute(
        path: '/',
        builder: (context, state) => NotificationsPage(
          notificationService: _OneNotificationService(item),
          filterStorage: _NoFilterStorage(),
        ),
      ),
      GoRoute(
        path: '/dm/:id',
        builder: (context, state) =>
            Text('conversation ${state.pathParameters['id']}'),
      ),
      GoRoute(
        path: '/spaces/:id',
        builder: (context, state) =>
            Text('space ${state.pathParameters['id']}'),
      ),
      GoRoute(
        path: '/listing/:id',
        builder: (context, state) =>
            Text('listing ${state.pathParameters['id']}'),
      ),
    ],
  );
  await tester.pumpWidget(
    MaterialApp.router(
      locale: const Locale('zh'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      routerConfig: router,
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('someone answering you opens the conversation', (tester) async {
    await _pumpWith(tester, _notification(conversationId: 'conv-7'));

    expect(find.text('有人回应了你想找的东西'), findsOneWidget);
    await tester.tap(find.text('有人回应了你想找的东西'));
    await tester.pumpAndSettle();
    expect(find.text('conversation conv-7'), findsOneWidget);
  });

  testWidgets('a formed space opens the space', (tester) async {
    await _pumpWith(tester, _notification(spaceId: 'space-3'));

    await tester.tap(find.text('有人回应了你想找的东西'));
    await tester.pumpAndSettle();
    expect(find.text('space space-3'), findsOneWidget);
  });

  testWidgets('a listing notice still opens the listing', (tester) async {
    // The destinations that already worked must keep working.
    await _pumpWith(tester, _notification(listingId: 'listing-9'));

    await tester.tap(find.text('有人回应了你想找的东西'));
    await tester.pumpAndSettle();
    expect(find.text('listing listing-9'), findsOneWidget);
  });

  testWidgets('a conversation wins over a listing when both are present', (
    tester,
  ) async {
    // A notice about somebody replying carries the listing for context, but the
    // thing to open is the reply.
    await _pumpWith(
      tester,
      _notification(conversationId: 'conv-7', listingId: 'listing-9'),
    );

    await tester.tap(find.text('有人回应了你想找的东西'));
    await tester.pumpAndSettle();
    expect(find.text('conversation conv-7'), findsOneWidget);
  });
}
