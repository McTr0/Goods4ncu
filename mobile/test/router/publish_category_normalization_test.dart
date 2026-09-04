import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:goods4ncu_mobile/l10n/app_localizations.dart';
import 'package:goods4ncu_mobile/models/post.dart';
import 'package:goods4ncu_mobile/models/post_taxonomy.dart';
import 'package:goods4ncu_mobile/pages/create_post_page.dart';
import 'package:goods4ncu_mobile/router/app_router.dart';
import 'package:goods4ncu_mobile/router/publish_navigation.dart';
import 'package:goods4ncu_mobile/services/post_service.dart';
import 'package:goods4ncu_mobile/services/upload_service.dart';
import 'package:goods4ncu_mobile/theme/app_theme.dart';

class _FakePostService extends PostService {
  @override
  Future<CampusPost> createPost({
    required String title,
    required String body,
    required String category,
    List<String> tags = const [],
    String? coverImageUrl,
    String? spaceId,
    Map<String, dynamic>? marketplace,
    String? idempotencyKey,
  }) async {
    return CampusPost.fromJson({
      'id': 'p-test',
      'post_type': 'discussion',
      'title': title,
      'body': body,
      'reply_count': 0,
      'status': 'active',
      'is_locked': false,
    });
  }
}

class _FakeUploadService extends UploadService {}

void main() {
  group('Router Category Query Parameter Normalization', () {
    test('normalizes legacy and deleted categories to discussion', () {
      expect(normalizePublishCategory('event'), 'discussion');
      expect(normalizePublishCategory('help'), 'discussion');
      expect(normalizePublishCategory('lost'), 'discussion');
      expect(normalizePublishCategory('found'), 'discussion');
      expect(normalizePublishCategory('invalid_category'), 'discussion');
      expect(normalizePublishCategory(''), 'discussion');
      expect(normalizePublishCategory(null), 'discussion');
    });

    test('preserves valid authoritative post categories', () {
      for (final cat in kPostCategories) {
        expect(normalizePublishCategory(cat.key), cat.key);
      }
    });

    testWidgets(
      'navigating to /publish?category=event normalizes to discussion and omits event fields',
      (tester) async {
        final postService = _FakePostService();
        final uploadService = _FakeUploadService();

        final router = GoRouter(
          initialLocation: '/publish?category=event',
          routes: [
            GoRoute(
              path: PublishNavigation.hub,
              pageBuilder: (context, state) => NoTransitionPage(
                key: state.pageKey,
                child: CreatePostPage(
                  postService: postService,
                  uploadService: uploadService,
                  imagePicker: () async => null,
                  initialCategory: normalizePublishCategory(
                    state.uri.queryParameters['category'],
                  ),
                ),
              ),
            ),
          ],
        );

        await tester.pumpWidget(
          MaterialApp.router(
            theme: AppTheme.light,
            locale: const Locale('zh'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            routerConfig: router,
          ),
        );
        await tester.pumpAndSettle();

        // Verify event UI fields do not exist anywhere in the tree
        expect(find.text('活动信息'), findsNothing);
        expect(find.text('活动地点（选填）'), findsNothing);
        expect(
          find.byKey(const ValueKey('publish-event-starts-at')),
          findsNothing,
        );

        // Verify category was normalized to discussion
        expect(find.text('讨论'), findsOneWidget);
      },
    );

    testWidgets(
      'navigating to /publish?category=offer opens offer form with goods section',
      (tester) async {
        final postService = _FakePostService();
        final uploadService = _FakeUploadService();

        final router = GoRouter(
          initialLocation: '/publish?category=offer',
          routes: [
            GoRoute(
              path: PublishNavigation.hub,
              pageBuilder: (context, state) => NoTransitionPage(
                key: state.pageKey,
                child: CreatePostPage(
                  postService: postService,
                  uploadService: uploadService,
                  imagePicker: () async => null,
                  initialCategory: normalizePublishCategory(
                    state.uri.queryParameters['category'],
                  ),
                ),
              ),
            ),
          ],
        );

        await tester.pumpWidget(
          MaterialApp.router(
            theme: AppTheme.light,
            locale: const Locale('zh'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            routerConfig: router,
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('出'), findsOneWidget);
        expect(
          find.byKey(const ValueKey('publish-goods-category-field')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('publish-goods-brand-field')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('publish-goods-price-field')),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'CreatePostPage directly passed invalid initialCategory normalizes to discussion',
      (tester) async {
        final postService = _FakePostService();
        final uploadService = _FakeUploadService();

        await tester.pumpWidget(
          MaterialApp(
            theme: AppTheme.light,
            locale: const Locale('zh'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: CreatePostPage(
                postService: postService,
                uploadService: uploadService,
                imagePicker: () async => null,
                initialCategory: 'event',
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('活动信息'), findsNothing);
        expect(
          find.byKey(const ValueKey('publish-event-starts-at')),
          findsNothing,
        );
        expect(find.text('讨论'), findsOneWidget);
      },
    );
  });
}
