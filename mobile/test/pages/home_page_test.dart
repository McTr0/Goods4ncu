import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:goods4ncu_mobile/l10n/app_localizations.dart';
import 'package:goods4ncu_mobile/models/models.dart';
import 'package:goods4ncu_mobile/pages/home_page.dart';
import 'package:goods4ncu_mobile/services/recommendation_service.dart';
import 'package:goods4ncu_mobile/theme/app_theme.dart';
import 'package:provider/provider.dart';

/// A campus where nobody has posted yet — day one, and the state every real
/// launch starts in.
class _EmptyRecommendationService extends RecommendationService {
  @override
  Future<List<Listing>> getRecommendationFeed({
    int limit = 20,
    int offset = 0,
    String direction = 'all',
  }) async => const [];
}

class _FakeRecommendationService extends RecommendationService {
  @override
  Future<List<Listing>> getRecommendationFeed({
    int limit = 20,
    int offset = 0,
    String direction = 'all',
  }) async {
    return [
      Listing(
        id: 'listing-1',
        title: '程序设计教材',
        category: 'books',
        brand: 'NCU',
        conditionScore: 8,
        suggestedPriceCny: 35,
        status: 'active',
      ),
    ];
  }
}

Widget _buildApp({
  Locale locale = const Locale('zh'),
  ThemeMode themeMode = ThemeMode.light,
  RecommendationService? recommendations,
}) {
  final router = GoRouter(
    routes: [
      GoRoute(path: '/', builder: (context, state) => const HomePage()),
      GoRoute(
        path: '/chat',
        builder: (context, state) =>
            Text('chat prompt: ${state.uri.queryParameters['prompt'] ?? ''}'),
      ),
      GoRoute(
        path: '/listing/:id',
        builder: (context, state) =>
            Text('listing ${state.pathParameters['id'] ?? ''}'),
      ),
      GoRoute(
        path: '/create',
        builder: (context, state) => const Text('say something'),
      ),
    ],
  );

  return Provider<RecommendationService>.value(
    value: recommendations ?? _FakeRecommendationService(),
    child: MaterialApp.router(
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      themeMode: themeMode,
      locale: locale,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      routerConfig: router,
    ),
  );
}

void main() {
  testWidgets('day one invites the first voice instead of announcing emptiness', (
    tester,
  ) async {
    // The most important screen a cold-start community has, and it used to say
    // "暂无商品" — announcing the place is empty, offering nothing to do, and
    // framing the product as a shop out of stock. The first thirty students
    // decide from this screen whether to come back.
    await tester.pumpWidget(
      _buildApp(recommendations: _EmptyRecommendationService()),
    );
    await tester.pumpAndSettle();
    final l = AppLocalizations.of(tester.element(find.byType(HomePage)))!;

    expect(find.text(l.homeColdStartTitle), findsOneWidget);
    expect(find.text(l.noProducts), findsNothing);
    // And an actual way to speak: telling someone the first voice matters, then
    // giving them nowhere to speak, says nothing at all.
    expect(find.text(l.homeColdStartAction), findsOneWidget);
  });

  testWidgets('the invitation leads somewhere', (tester) async {
    await tester.pumpWidget(
      _buildApp(recommendations: _EmptyRecommendationService()),
    );
    await tester.pumpAndSettle();
    final l = AppLocalizations.of(tester.element(find.byType(HomePage)))!;

    // Below the fold on a test-sized screen.
    await tester.ensureVisible(find.text(l.homeColdStartAction));
    await tester.pumpAndSettle();
    await tester.tap(find.text(l.homeColdStartAction));
    await tester.pumpAndSettle();
    expect(find.text('say something'), findsOneWidget);
  });

  testWidgets('home page keeps the customer entry simple', (tester) async {
    await tester.pumpWidget(_buildApp());
    await tester.pumpAndSettle();

    expect(find.text('今天想淘点什么？'), findsOneWidget);
    expect(find.text('试试这样开始'), findsOneWidget);
    expect(find.text('推荐怎么来'), findsNothing);
    expect(find.textContaining('相关度'), findsNothing);
    expect(find.textContaining('新鲜度'), findsNothing);
    expect(find.textContaining('轻量排序'), findsNothing);

    await tester.enterText(
      find.byKey(const ValueKey('home-agent-prompt')),
      '帮我找一本高数教材',
    );
    await tester.testTextInput.receiveAction(TextInputAction.send);
    await tester.pumpAndSettle();

    expect(find.textContaining('chat prompt: 帮我找一本高数教材'), findsOneWidget);
  });

  testWidgets('home page shows a simple marketplace feed', (tester) async {
    await tester.pumpWidget(_buildApp());
    await tester.pumpAndSettle();

    await tester.drag(find.byType(CustomScrollView), const Offset(0, -700));
    await tester.pumpAndSettle();

    expect(find.text('最近上新'), findsOneWidget);
    expect(find.text('看看同学们正在出什么闲置。'), findsOneWidget);
    expect(find.text('全部'), findsOneWidget);
    expect(find.text('出'), findsWidgets);
    expect(find.text('收'), findsOneWidget);
    expect(find.text('可解释排序'), findsNothing);
    expect(find.text('程序设计教材'), findsOneWidget);
  });

  testWidgets('home page localizes the entry in English', (tester) async {
    await tester.pumpWidget(_buildApp(locale: const Locale('en')));
    await tester.pumpAndSettle();

    expect(find.text('What are you looking for today?'), findsOneWidget);
    expect(find.text('Try starting with'), findsOneWidget);
    expect(find.text('今天想淘点什么？'), findsNothing);

    await tester.enterText(
      find.byKey(const ValueKey('home-agent-prompt')),
      'help me find a laptop',
    );
    await tester.testTextInput.receiveAction(TextInputAction.send);
    await tester.pumpAndSettle();

    expect(
      find.textContaining('chat prompt: help me find a laptop'),
      findsOneWidget,
    );
  });

  testWidgets('home page uses the dark surface gradient in dark mode', (
    tester,
  ) async {
    await tester.pumpWidget(_buildApp(themeMode: ThemeMode.dark));
    await tester.pumpAndSettle();

    final decoratedBox = tester
        .widgetList<DecoratedBox>(find.byType(DecoratedBox))
        .firstWhere((box) {
          final decoration = box.decoration;
          return decoration is BoxDecoration &&
              decoration.gradient is LinearGradient;
        });
    final gradient =
        (decoratedBox.decoration as BoxDecoration).gradient! as LinearGradient;

    expect(gradient.colors.first, AppTheme.surfaceDark);
  });
}
