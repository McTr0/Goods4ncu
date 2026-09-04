import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:goods4ncu_mobile/l10n/app_localizations.dart';
import 'package:goods4ncu_mobile/models/post.dart';
import 'package:goods4ncu_mobile/pages/create_post_page.dart';
import 'package:goods4ncu_mobile/services/post_service.dart';
import 'package:goods4ncu_mobile/services/upload_service.dart';
import 'package:goods4ncu_mobile/theme/app_theme.dart';

class _FakeUploadService extends UploadService {
  String? uploadedExtension;
  String? uploadedContentType;
  int uploadCalls = 0;

  @override
  Future<String> uploadPostImageBytes(
    List<int> imageBytes, {
    String extension = 'jpg',
    String contentType = 'image/jpeg',
  }) async {
    uploadCalls++;
    uploadedExtension = extension;
    uploadedContentType = contentType;
    return 'https://cdn.test/post-cover.jpg';
  }
}

class _FakePostService extends PostService {
  String? coverImageUrl;
  String? lastIdempotencyKey;
  int createCalls = 0;
  bool shouldFail = false;

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
    createCalls++;
    this.coverImageUrl = coverImageUrl;
    lastIdempotencyKey = idempotencyKey;
    if (shouldFail) {
      throw Exception('Simulated network timeout');
    }
    return CampusPost.fromJson({
      'id': 'post-created',
      'post_type': 'discussion',
      'title': title,
      'body': body,
      'cover_image_url': coverImageUrl,
      'author': {'id': 'u-1', 'username': 'mira'},
      'reply_count': 0,
      'status': 'active',
      'is_locked': false,
    });
  }
}

Widget _app({
  required PostService postService,
  required UploadService uploadService,
  required PostImagePicker imagePicker,
}) {
  final router = GoRouter(
    initialLocation: '/create',
    routes: [
      GoRoute(
        path: '/create',
        builder: (_, _) => CreatePostPage(
          postService: postService,
          uploadService: uploadService,
          imagePicker: imagePicker,
        ),
      ),
      GoRoute(path: '/posts/:id', builder: (_, _) => const Text('created')),
    ],
  );
  return MaterialApp.router(
    theme: AppTheme.light,
    locale: const Locale('en'),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    routerConfig: router,
  );
}

final _k1x1Png = Uint8List.fromList(const [
  137,
  80,
  78,
  71,
  13,
  10,
  26,
  10,
  0,
  0,
  0,
  13,
  73,
  72,
  68,
  82,
  0,
  0,
  0,
  1,
  0,
  0,
  0,
  1,
  8,
  6,
  0,
  0,
  0,
  31,
  21,
  196,
  137,
  0,
  0,
  0,
  13,
  73,
  68,
  65,
  84,
  120,
  156,
  99,
  248,
  207,
  192,
  240,
  31,
  0,
  5,
  0,
  1,
  255,
  137,
  153,
  61,
  29,
  0,
  0,
  0,
  0,
  73,
  69,
  78,
  68,
  174,
  66,
  96,
  130,
]);

void main() {
  testWidgets('selects and uploads a discussion cover image', (tester) async {
    final postService = _FakePostService();
    final uploadService = _FakeUploadService();
    final image = PickedPostImage(
      bytes: _k1x1Png,
      extension: 'png',
      contentType: 'image/png',
    );

    await tester.pumpWidget(
      _app(
        postService: postService,
        uploadService: uploadService,
        imagePicker: () async => image,
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('post-pick-cover-action')));
    await tester.pump();
    expect(find.byKey(const ValueKey('post-cover-preview')), findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey('post-title-field')),
      'Campus market',
    );
    await tester.enterText(
      find.byKey(const ValueKey('post-body-field')),
      'A useful campus update.',
    );
    await tester.ensureVisible(
      find.byKey(const ValueKey('post-publish-action')),
    );
    await tester.tap(find.byKey(const ValueKey('post-publish-action')));
    await tester.pumpAndSettle();

    expect(uploadService.uploadedExtension, 'png');
    expect(uploadService.uploadedContentType, 'image/png');
    expect(postService.coverImageUrl, 'https://cdn.test/post-cover.jpg');
    expect(postService.lastIdempotencyKey, isNotNull);
    expect(find.text('created'), findsOneWidget);
  });

  testWidgets('does not upload image when form validation fails', (
    tester,
  ) async {
    final postService = _FakePostService();
    final uploadService = _FakeUploadService();
    final image = PickedPostImage(
      bytes: Uint8List.fromList(const [
        137,
        80,
        78,
        71,
        13,
        10,
        26,
        10,
        0,
        0,
        0,
        13,
        73,
        72,
        68,
        82,
        0,
        0,
        0,
        1,
        0,
        0,
        0,
        1,
        8,
        6,
        0,
        0,
        0,
        31,
        21,
        196,
        137,
        0,
        0,
        0,
        13,
        73,
        68,
        65,
        84,
        120,
        156,
        99,
        248,
        207,
        192,
        240,
        31,
        0,
        5,
        0,
        1,
        255,
        137,
        153,
        61,
        29,
        0,
        0,
        0,
        0,
        0,
        73,
        69,
        78,
        68,
        174,
        66,
        96,
        130,
      ]),
      extension: 'png',
      contentType: 'image/png',
    );

    await tester.pumpWidget(
      _app(
        postService: postService,
        uploadService: uploadService,
        imagePicker: () async => image,
      ),
    );
    await tester.pumpAndSettle();

    // Pick image but leave title and body empty
    await tester.tap(find.byKey(const ValueKey('post-pick-cover-action')));
    await tester.pump();
    expect(find.byKey(const ValueKey('post-cover-preview')), findsOneWidget);

    // Tap publish without valid fields
    await tester.ensureVisible(
      find.byKey(const ValueKey('post-publish-action')),
    );
    await tester.tap(find.byKey(const ValueKey('post-publish-action')));
    await tester.pumpAndSettle();

    // Pure validation must prevent upload from ever running!
    expect(uploadService.uploadedContentType, isNull);
    expect(postService.createCalls, 0);
  });

  testWidgets(
    'reuses same idempotency key across retry attempts until success',
    (tester) async {
      final postService = _FakePostService();
      final uploadService = _FakeUploadService();

      await tester.pumpWidget(
        _app(
          postService: postService,
          uploadService: uploadService,
          imagePicker: () async => null,
        ),
      );
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const ValueKey('post-title-field')),
        'Retryable post',
      );
      await tester.enterText(
        find.byKey(const ValueKey('post-body-field')),
        'Post body text.',
      );

      // First attempt fails
      postService.shouldFail = true;
      await tester.ensureVisible(
        find.byKey(const ValueKey('post-publish-action')),
      );
      await tester.tap(find.byKey(const ValueKey('post-publish-action')));
      await tester.pumpAndSettle();

      expect(postService.createCalls, 1);
      final firstKey = postService.lastIdempotencyKey;
      expect(firstKey, isNotNull);
      expect(find.text('created'), findsNothing);

      // Dismiss the error snackbar so button is un-obscured
      ScaffoldMessenger.of(
        tester.element(find.byType(CreatePostPage)),
      ).hideCurrentSnackBar();
      await tester.pumpAndSettle();

      // Retry without modifying form -> must reuse same idempotency key
      postService.shouldFail = false;
      await tester.tap(find.byKey(const ValueKey('post-publish-action')));
      await tester.pumpAndSettle();

      expect(postService.createCalls, 2);
      expect(postService.lastIdempotencyKey, firstKey);
      expect(find.text('created'), findsOneWidget);
    },
  );

  testWidgets('validates required brand when publishing an offer listing', (
    tester,
  ) async {
    final postService = _FakePostService();
    final uploadService = _FakeUploadService();

    final router = GoRouter(
      initialLocation: '/create',
      routes: [
        GoRoute(
          path: '/create',
          builder: (_, _) => CreatePostPage(
            postService: postService,
            uploadService: uploadService,
            imagePicker: () async => null,
            initialCategory: 'offer',
          ),
        ),
        GoRoute(path: '/posts/:id', builder: (_, _) => const Text('created')),
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

    // Verify brand label indicates required for offer
    expect(find.text('品牌 / 来源（必填）'), findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey('post-title-field')),
      '出售自行车',
    );
    await tester.enterText(
      find.byKey(const ValueKey('post-body-field')),
      '九成新山地车。',
    );
    await tester.enterText(
      find.byKey(const ValueKey('publish-goods-price-field')),
      '200',
    );

    // Leave brand empty and submit -> validation fails
    await tester.ensureVisible(
      find.byKey(const ValueKey('post-publish-action')),
    );
    await tester.tap(find.byKey(const ValueKey('post-publish-action')));
    await tester.pumpAndSettle();

    expect(find.text('请填写品牌或来源'), findsOneWidget);
    expect(find.text('created'), findsNothing);
  });

  testWidgets('does not re-upload image on retry with unchanged form', (
    tester,
  ) async {
    final postService = _FakePostService();
    final uploadService = _FakeUploadService();
    final image = PickedPostImage(
      bytes: _k1x1Png,
      extension: 'png',
      contentType: 'image/png',
    );

    await tester.pumpWidget(
      _app(
        postService: postService,
        uploadService: uploadService,
        imagePicker: () async => image,
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const ValueKey('post-title-field')),
      'Post with image',
    );
    await tester.enterText(
      find.byKey(const ValueKey('post-body-field')),
      'Body text',
    );

    // Pick image
    await tester.tap(find.byKey(const ValueKey('post-pick-cover-action')));
    await tester.pump();
    expect(find.byKey(const ValueKey('post-cover-preview')), findsOneWidget);

    // First submit attempt fails at post creation
    postService.shouldFail = true;
    await tester.ensureVisible(
      find.byKey(const ValueKey('post-publish-action')),
    );
    await tester.tap(find.byKey(const ValueKey('post-publish-action')));
    await tester.pumpAndSettle();

    expect(uploadService.uploadCalls, 1);
    expect(postService.createCalls, 1);
    final firstKey = postService.lastIdempotencyKey;
    final firstCoverUrl = postService.coverImageUrl;
    expect(firstKey, isNotNull);
    expect(firstCoverUrl, 'https://cdn.test/post-cover.jpg');

    // Dismiss error snackbar
    ScaffoldMessenger.of(
      tester.element(find.byType(CreatePostPage)),
    ).hideCurrentSnackBar();
    await tester.pumpAndSettle();

    // Retry without modifying form -> upload service must NOT be called again
    postService.shouldFail = false;
    await tester.tap(find.byKey(const ValueKey('post-publish-action')));
    await tester.pumpAndSettle();

    expect(
      uploadService.uploadCalls,
      1,
      reason: 'Image should not be re-uploaded on retry',
    );
    expect(postService.createCalls, 2);
    expect(postService.lastIdempotencyKey, firstKey);
    expect(postService.coverImageUrl, firstCoverUrl);
    expect(find.text('created'), findsOneWidget);
  });
}
