import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:goods4ncu_mobile/l10n/app_localizations.dart';
import 'package:goods4ncu_mobile/pages/create_listing_page.dart';
import 'package:goods4ncu_mobile/services/api_service.dart';
import 'package:goods4ncu_mobile/services/listing_service.dart';
import 'package:goods4ncu_mobile/theme/app_theme.dart';
import 'package:image_picker/image_picker.dart';

const _tinyPngBase64 =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/p9sAAAAASUVORK5CYII=';

class _FakeApiService extends ApiService {
  _FakeApiService({this.recognizedItem, this.recognizeError, this.createError});

  final RecognizedItem? recognizedItem;
  final Object? recognizeError;
  final Object? createError;
  int recognitionCalls = 0;
  final List<String?> submittedIdempotencyKeys = [];

  @override
  Future<RecognizedItem> recognizeItem(String imageBase64) async {
    recognitionCalls += 1;
    final error = recognizeError;
    if (error != null) throw error;

    return recognizedItem ??
        RecognizedItem(
          title: 'AI 识别标题',
          category: 'electronics',
          brand: 'Sony',
          conditionScore: 8,
          defects: const ['轻微磨损'],
          description: 'AI 识别出的补充描述',
        );
  }

  @override
  Future<String> createListing({
    required String title,
    required String category,
    required String brand,
    required int conditionScore,
    required double suggestedPriceCny,
    required List<String> defects,
    String? description,
    String direction = 'offer',
    String? idempotencyKey,
  }) async {
    submittedIdempotencyKeys.add(idempotencyKey);
    final error = createError;
    if (error != null) throw error;
    return 'listing-created';
  }
}

Widget _buildApp({
  Locale locale = const Locale('zh'),
  ThemeMode themeMode = ThemeMode.light,
  _FakeApiService? apiService,
  ImageBase64Picker? imageBase64Picker,
}) {
  final router = GoRouter(
    initialLocation: '/create',
    routes: [
      GoRoute(
        path: '/create',
        builder: (context, state) => CreateListingPage(
          apiService: apiService ?? _FakeApiService(),
          imageBase64Picker: imageBase64Picker,
        ),
      ),
      GoRoute(
        path: '/listing/:id',
        builder: (context, state) =>
            Text('listing ${state.pathParameters['id']}'),
      ),
    ],
  );

  return MaterialApp.router(
    theme: AppTheme.light,
    darkTheme: AppTheme.dark,
    themeMode: themeMode,
    locale: locale,
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    routerConfig: router,
  );
}

void main() {
  testWidgets('publish retries reuse a key until form content changes', (
    tester,
  ) async {
    final apiService = _FakeApiService(
      createError: Exception('simulated timeout'),
    );
    await tester.pumpWidget(_buildApp(apiService: apiService));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const ValueKey('create-title-field')),
      '二手高数教材',
    );
    await tester.enterText(
      find.byKey(const ValueKey('create-brand-field')),
      'NCU',
    );
    await tester.enterText(
      find.byKey(const ValueKey('create-price-field')),
      '35',
    );

    final submit = find.byKey(const ValueKey('create-submit-button'));
    await tester.tap(submit);
    await tester.pumpAndSettle();
    final firstKey = apiService.submittedIdempotencyKeys.single;
    expect(firstKey, isNotNull);

    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    await tester.tap(submit);
    await tester.pumpAndSettle();
    expect(apiService.submittedIdempotencyKeys, hasLength(2));
    expect(apiService.submittedIdempotencyKeys[1], firstKey);

    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('create-price-field')),
      '36',
    );
    await tester.tap(submit);
    await tester.pumpAndSettle();
    expect(apiService.submittedIdempotencyKeys, hasLength(3));
    expect(apiService.submittedIdempotencyKeys[2], isNot(firstKey));
  });

  testWidgets('mobile page shows a live missing-field summary', (tester) async {
    await tester.pumpWidget(_buildApp());
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('create-mobile-workspace')),
      findsOneWidget,
    );
    expect(find.text('还差 标题、品牌、价格'), findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey('create-title-field')),
      '二手高数教材',
    );
    await tester.enterText(
      find.byKey(const ValueKey('create-brand-field')),
      'NCU',
    );
    await tester.enterText(
      find.byKey(const ValueKey('create-price-field')),
      '35',
    );
    await tester.pump();

    expect(find.text('信息齐了，可以发布'), findsOneWidget);
  });

  testWidgets('wanted mode rewrites the create form semantics', (tester) async {
    await tester.pumpWidget(_buildApp());
    await tester.pumpAndSettle();

    await tester.tap(find.text('我要收'));
    await tester.pumpAndSettle();

    expect(find.text('描述你想收什么'), findsOneWidget);
    expect(find.text('预算上限（元） *'), findsOneWidget);

    await tester.drag(
      find.byKey(const ValueKey('create-mobile-workspace')),
      const Offset(0, -420),
    );
    await tester.pumpAndSettle();

    expect(find.text('最低成色'), findsOneWidget);
    expect(find.text('要求/备注'), findsOneWidget);
  });

  testWidgets('desktop page uses two-column workspace and English copy', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(_buildApp(locale: const Locale('en')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('create-desktop-workspace')),
      findsOneWidget,
    );
    expect(find.text('Let the assistant take a look first'), findsOneWidget);
    expect(find.text('Missing Title, Brand, Price'), findsOneWidget);
  });

  testWidgets(
    'dark mode renders the create workspace without light-only text',
    (tester) async {
      await tester.pumpWidget(_buildApp(themeMode: ThemeMode.dark));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('create-ai-capture-panel')),
        findsOneWidget,
      );
      expect(find.text('先让小昌看一眼'), findsOneWidget);
      expect(find.text('还差 标题、品牌、价格'), findsOneWidget);
    },
  );

  testWidgets(
    'AI recognition fills empty fields without replacing a typed title',
    (tester) async {
      final apiService = _FakeApiService(
        recognizedItem: RecognizedItem(
          title: 'AI 识别标题',
          category: 'electronics',
          brand: 'Sony',
          conditionScore: 8,
          defects: const ['轻微磨损'],
          description: 'AI 识别出的补充描述',
        ),
      );
      await tester.pumpWidget(
        _buildApp(
          apiService: apiService,
          imageBase64Picker: (ImageSource source) async => _tinyPngBase64,
        ),
      );
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const ValueKey('create-title-field')),
        '我自己写的标题',
      );
      await tester.tap(find.byKey(const ValueKey('create-gallery-button')));
      await tester.pumpAndSettle();

      expect(apiService.recognitionCalls, 1);
      expect(find.text('我自己写的标题'), findsOneWidget);
      expect(find.text('Sony'), findsOneWidget);
      expect(find.text('AI 识别完成'), findsOneWidget);

      await tester.drag(
        find.byKey(const ValueKey('create-mobile-workspace')),
        const Offset(0, -520),
      );
      await tester.pumpAndSettle();

      expect(find.text('轻微磨损'), findsOneWidget);
    },
  );

  testWidgets('AI recognition failure preserves input and offers retry', (
    tester,
  ) async {
    await tester.pumpWidget(
      _buildApp(
        apiService: _FakeApiService(recognizeError: StateError('LLM timeout')),
        imageBase64Picker: (ImageSource source) async => _tinyPngBase64,
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const ValueKey('create-title-field')),
      '不要被清空',
    );
    await tester.tap(find.byKey(const ValueKey('create-gallery-button')));
    await tester.pumpAndSettle();

    expect(find.text('不要被清空'), findsOneWidget);
    expect(find.text('需要重试'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
  });
}
