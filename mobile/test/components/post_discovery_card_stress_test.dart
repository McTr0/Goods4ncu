import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:goods4ncu_mobile/components/post_discovery_card.dart';
import 'package:goods4ncu_mobile/l10n/app_localizations.dart';
import 'package:goods4ncu_mobile/models/post.dart';
import 'package:goods4ncu_mobile/theme/app_theme.dart';

CampusPost _postWithManyTags() {
  final tags = <String>[
    'urgent',
    'qianhuNorth',
    'question',
    'share',
    'help',
    'negotiable',
    'pickupOnly',
    'topPrice',
  ];
  return CampusPost.fromJson({
    'id': 'stress-1',
    'category': 'wanted',
    'title': '收往年期末真题 高数大物英语都要',
    'body': '价格好商量，急要，前湖北院自提也可以包邮，长期有效。',
    'tags': tags,
    'author': {'id': 'u1', 'username': '测试用户很长很长很长'},
    'reply_count': 3,
    'fertilizer_count': 9,
    'status': 'active',
    'created_at': '2026-08-20T10:00:00Z',
  });
}

Widget _app(Widget child) {
  return MaterialApp(
    theme: AppTheme.light,
    locale: const Locale('zh'),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(body: SingleChildScrollView(child: child)),
  );
}

void main() {
  testWidgets('discovery card survives many long tags without overflow', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      _app(PostDiscoveryCard(post: _postWithManyTags(), onTap: () {})),
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
    // First tag becomes the emoji+text pill on the cover.
    expect(find.text('⏰ 急'), findsOneWidget);
    // Remaining tags stay localized in the body, capped at two.
    expect(find.text('📍 前湖北院'), findsOneWidget);
    expect(find.text('❓ 提问'), findsOneWidget);
  });

  testWidgets('imageless goods posts render text-first without an empty slot', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final post = CampusPost.fromJson({
      'id': 'errand-1',
      'category': 'offer',
      'title': '每天下午代取快递 北门菜鸟驿站',
      'body': '课少时间多，5 元一件送到宿舍楼下。',
      'tags': ['help', 'qianhuNorth'],
      'author': {'id': 'u2', 'username': 'runner'},
      'reply_count': 2,
      'status': 'active',
    });

    await tester.pumpWidget(_app(PostDiscoveryCard(post: post, onTap: () {})));
    await tester.pump();

    // No reserved image slot for goods posts without photos.
    expect(find.byKey(const ValueKey('post-cover-errand-1')), findsNothing);
    expect(tester.takeException(), isNull);
    // Header pills still identify category and first tag.
    expect(find.text('商品出'), findsOneWidget);
    expect(find.text('📍 前湖北院'), findsOneWidget);
  });
}
