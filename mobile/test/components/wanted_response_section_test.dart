import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goods4ncu_mobile/components/wanted_response_section.dart';
import 'package:goods4ncu_mobile/l10n/app_localizations.dart';
import 'package:goods4ncu_mobile/models/models.dart';
import 'package:goods4ncu_mobile/theme/app_theme.dart';

WantedResponse _response({
  String id = 'response-1',
  String status = 'pending',
  String wantedStatus = 'active',
  String offerStatus = 'active',
  String? message = '上下册都在，可以看看',
}) {
  return WantedResponse(
    id: id,
    wantedListingId: 'wanted-1',
    wantedTitle: '想收高数教材',
    wantedStatus: wantedStatus,
    offerListingId: 'offer-1',
    offerTitle: '高数教材第七版',
    offerStatus: offerStatus,
    responderId: 'seller-1',
    requesterId: 'buyer-1',
    message: message,
    status: status,
  );
}

Widget _app(Widget child, {double textScale = 1}) {
  return MaterialApp(
    theme: AppTheme.light,
    locale: const Locale('zh'),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Builder(
      builder: (context) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(textScale)),
        child: Scaffold(
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: child,
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets(
    'received pending response shows context and dispatches owner actions',
    (tester) async {
      WantedResponse? opened;
      WantedResponse? accepted;
      WantedResponse? dismissed;
      WantedResponse? withdrawn;
      final response = _response();

      await tester.pumpWidget(
        _app(
          WantedResponseSection(
            role: WantedResponseRole.requester,
            responses: [response],
            onOpenOffer: (value) => opened = value,
            onAccept: (value) => accepted = value,
            onDismiss: (value) => dismissed = value,
            onWithdraw: (value) => withdrawn = value,
          ),
        ),
      );
      await tester.pump();

      expect(find.text('收到的推荐'), findsOneWidget);
      expect(find.text('商品：高数教材第七版 · 进行中'), findsOneWidget);
      expect(find.text('需求：想收高数教材 · 进行中'), findsOneWidget);
      expect(find.text('等待处理'), findsOneWidget);
      expect(find.text('推荐留言'), findsOneWidget);
      expect(find.text('上下册都在，可以看看'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('wanted-response-withdraw-response-1')),
        findsNothing,
      );

      await tester.tap(
        find.byKey(const ValueKey('wanted-response-open-offer-response-1')),
      );
      await tester.tap(
        find.byKey(const ValueKey('wanted-response-accept-response-1')),
      );
      await tester.tap(
        find.byKey(const ValueKey('wanted-response-dismiss-response-1')),
      );

      expect(opened, same(response));
      expect(accepted, same(response));
      expect(dismissed, same(response));
      expect(withdrawn, isNull);
    },
  );

  testWidgets(
    'sent pending response exposes withdraw and honors row busy state',
    (tester) async {
      WantedResponse? withdrawn;
      final response = _response();

      await tester.pumpWidget(
        _app(
          WantedResponseSection(
            role: WantedResponseRole.responder,
            responses: [response],
            busyResponseIds: const {'response-1'},
            onWithdraw: (value) => withdrawn = value,
          ),
        ),
      );
      await tester.pump();

      expect(find.text('我发出的推荐'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('wanted-response-accept-response-1')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('wanted-response-dismiss-response-1')),
        findsNothing,
      );
      final withdrawButton = tester.widget<OutlinedButton>(
        find.byKey(const ValueKey('wanted-response-withdraw-response-1')),
      );
      expect(withdrawButton.onPressed, isNull);
      expect(
        find.byKey(const ValueKey('wanted-response-row-busy-response-1')),
        findsOneWidget,
      );
      expect(withdrawn, isNull);
    },
  );

  testWidgets('resolved response is localized and has no pending actions', (
    tester,
  ) async {
    final response = _response(
      status: 'accepted',
      wantedStatus: 'fulfilled',
      offerStatus: 'sold',
      message: null,
    );

    await tester.pumpWidget(
      _app(
        WantedResponseSection(
          role: WantedResponseRole.requester,
          responses: [response],
          onAccept: (_) {},
          onDismiss: (_) {},
          onOpenOffer: (_) {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('已接受'), findsOneWidget);
    expect(find.text('商品：高数教材第七版 · 已售'), findsOneWidget);
    expect(find.text('需求：想收高数教材 · 已完成'), findsOneWidget);
    expect(find.text('推荐留言'), findsNothing);
    expect(
      find.byKey(const ValueKey('wanted-response-accept-response-1')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('wanted-response-dismiss-response-1')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('wanted-response-open-offer-response-1')),
      findsOneWidget,
    );
  });

  testWidgets('deleted offer history does not expose a broken detail link', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        WantedResponseSection(
          role: WantedResponseRole.requester,
          responses: [_response(status: 'accepted', offerStatus: 'deleted')],
          onOpenOffer: (_) {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('商品：高数教材第七版 · 已下架'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('wanted-response-open-offer-response-1')),
      findsNothing,
    );
  });

  testWidgets('loading, error, retry, and empty states are explicit', (
    tester,
  ) async {
    var retries = 0;
    await tester.pumpWidget(
      _app(
        WantedResponseSection(
          role: WantedResponseRole.requester,
          responses: const [],
          errorMessage: '',
          onRetry: () => retries++,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('推荐暂时没有加载出来，请重试。'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('wanted-response-retry')));
    expect(retries, 1);

    await tester.pumpWidget(
      _app(
        const WantedResponseSection(
          role: WantedResponseRole.responder,
          responses: [],
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('你还没有为这条需求推荐商品。'), findsOneWidget);

    await tester.pumpWidget(
      _app(
        const WantedResponseSection(
          role: WantedResponseRole.requester,
          responses: [],
          isLoading: true,
        ),
      ),
    );
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });

  testWidgets('actions wrap without overflow at 200 percent text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      _app(
        WantedResponseSection(
          role: WantedResponseRole.requester,
          responses: [_response()],
          onOpenOffer: (_) {},
          onAccept: (_) {},
          onDismiss: (_) {},
        ),
        textScale: 2,
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(
      find.byKey(const ValueKey('wanted-response-accept-response-1')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('wanted-response-dismiss-response-1')),
      findsOneWidget,
    );
  });
}
