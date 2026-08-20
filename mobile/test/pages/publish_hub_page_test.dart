import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:goods4ncu_mobile/l10n/app_localizations.dart';
import 'package:goods4ncu_mobile/pages/create_listing_page.dart';
import 'package:goods4ncu_mobile/pages/create_post_page.dart';
import 'package:goods4ncu_mobile/pages/publish_hub_page.dart';
import 'package:goods4ncu_mobile/router/publish_navigation.dart';
import 'package:goods4ncu_mobile/services/api_service.dart';
import 'package:goods4ncu_mobile/services/post_service.dart';
import 'package:goods4ncu_mobile/services/upload_service.dart';
import 'package:goods4ncu_mobile/theme/app_theme.dart';

MaterialApp _localizedApp({required Widget home}) {
  return MaterialApp(
    theme: AppTheme.light,
    locale: const Locale('zh'),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: home,
  );
}

void main() {
  setUpAll(() {
    GoRouter.optionURLReflectsImperativeAPIs = true;
  });

  group('legacy publish routes', () {
    test('old post and listing routes redirect to canonical destinations', () {
      expect(
        PublishNavigation.redirectLegacy(Uri.parse('/create/post')),
        PublishNavigation.discussion,
      );
      expect(
        PublishNavigation.redirectLegacy(Uri.parse('/create/listing')),
        '/publish/listing?direction=offer',
      );
      expect(
        PublishNavigation.redirectLegacy(
          Uri.parse('/create/listing?direction=wanted'),
        ),
        '/publish/listing?direction=wanted',
      );
    });

    test('old generic create route keeps explicit marketplace intent', () {
      expect(
        PublishNavigation.redirectLegacy(Uri.parse('/create')),
        PublishNavigation.hub,
      );
      expect(
        PublishNavigation.redirectLegacy(Uri.parse('/create?kind=offer')),
        '/publish/listing?direction=offer',
      );
      expect(
        PublishNavigation.redirectLegacy(Uri.parse('/create?kind=wanted')),
        '/publish/listing?direction=wanted',
      );
    });
  });

  testWidgets('publish hub exposes all creation types and returns on back', (
    tester,
  ) async {
    final router = GoRouter(
      initialLocation: PublishNavigation.hub,
      routes: [
        GoRoute(
          path: PublishNavigation.hub,
          builder: (context, state) => const PublishHubPage(),
        ),
        GoRoute(
          path: PublishNavigation.discussion,
          builder: (context, state) => const Scaffold(body: Text('discussion')),
        ),
        GoRoute(
          path: PublishNavigation.listingPath,
          builder: (context, state) => CreateListingPage(
            apiService: ApiService(),
            initialDirection: state.uri.queryParameters['direction'] == 'wanted'
                ? 'wanted'
                : 'offer',
            showBackButton: true,
          ),
        ),
      ],
    );
    addTearDown(router.dispose);

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

    expect(find.byKey(const ValueKey('publish-choice-discussion')), findsOne);
    expect(find.byKey(const ValueKey('publish-choice-offer')), findsOne);
    expect(find.byKey(const ValueKey('publish-choice-wanted')), findsOne);

    await tester.tap(find.byKey(const ValueKey('publish-choice-discussion')));
    await tester.pumpAndSettle();
    expect(find.text('discussion'), findsOneWidget);
    expect(
      router.routeInformationProvider.value.uri.path,
      PublishNavigation.discussion,
    );

    router.pop();
    await tester.pumpAndSettle();
    expect(find.byType(PublishHubPage), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('publish-choice-offer')));
    await tester.pumpAndSettle();
    expect(find.byType(CreateListingPage), findsOneWidget);
    expect(find.byType(BackButton), findsOneWidget);

    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    await tester.ensureVisible(
      find.byKey(const ValueKey('publish-choice-wanted')),
    );
    await tester.tap(find.byKey(const ValueKey('publish-choice-wanted')));
    await tester.pumpAndSettle();
    expect(find.byType(CreateListingPage), findsOneWidget);
    expect(find.byType(BackButton), findsOneWidget);
  });

  testWidgets('discussion composer renders one primary publish action', (
    tester,
  ) async {
    await tester.pumpWidget(
      _localizedApp(
        home: CreatePostPage(
          postService: PostService(),
          uploadService: UploadService(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final publishAction = find.byKey(const ValueKey('post-publish-action'));
    expect(publishAction, findsOneWidget);
    expect(
      find.descendant(of: find.byType(AppBar), matching: publishAction),
      findsNothing,
    );
    expect(
      find.descendant(of: find.byType(Form), matching: publishAction),
      findsOneWidget,
    );
  });
}
