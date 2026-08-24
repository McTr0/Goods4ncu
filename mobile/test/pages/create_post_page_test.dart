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

  @override
  Future<String> uploadPostImageBytes(
    List<int> imageBytes, {
    String extension = 'jpg',
    String contentType = 'image/jpeg',
  }) async {
    uploadedExtension = extension;
    uploadedContentType = contentType;
    return 'https://cdn.test/post-cover.jpg';
  }
}

class _FakePostService extends PostService {
  String? coverImageUrl;

  @override
  Future<CampusPost> createPost({
    required String title,
    required String body,
    required String category,
    List<String> tags = const [],
    String? coverImageUrl,
    String? listingId,
    String? spaceId,
    Map<String, dynamic> errandMetadata = const {},
  }) async {
    this.coverImageUrl = coverImageUrl;
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

void main() {
  testWidgets('selects and uploads a discussion cover image', (tester) async {
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
    expect(find.text('created'), findsOneWidget);
  });
}
