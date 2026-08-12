import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goods4ncu_mobile/components/social_persona_asset_panel.dart';
import 'package:goods4ncu_mobile/l10n/app_localizations.dart';
import 'package:goods4ncu_mobile/models/models.dart';

Widget _app(Widget child) {
  return MaterialApp(
    locale: const Locale('zh'),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(body: SingleChildScrollView(child: child)),
  );
}

SocialPersonaAsset _asset({
  required String id,
  required String status,
  String moderationStatus = 'approved',
  String? rejectReason,
}) {
  return SocialPersonaAsset(
    id: id,
    personaId: 'persona-1',
    assetType: 'illustration',
    declaredMimeType: 'image/png',
    declaredSizeBytes: 1024,
    uploadedSizeBytes: 1024,
    uploadedMimeType: 'image/png',
    storageVerifiedAt: DateTime.utc(2026, 8, 12),
    moderationStatus: moderationStatus,
    status: status,
    rejectReason: rejectReason,
  );
}

void main() {
  testWidgets('shows lifecycle facts and only offers use for approved assets', (
    tester,
  ) async {
    var selected = 0;
    var completed = 0;
    var revoked = 0;
    await tester.pumpWidget(
      _app(
        SocialPersonaAssetPanel(
          assets: [
            _asset(id: 'ready', status: 'active'),
            _asset(
              id: 'review',
              status: 'pending_review',
              moderationStatus: 'pending',
            ),
            _asset(
              id: 'rejected',
              status: 'rejected',
              moderationStatus: 'rejected',
              rejectReason: '图片内容不合规',
            ),
          ],
          onAdd: () {},
          onSelect: (_) => selected += 1,
          onComplete: (_) => completed += 1,
          onRevoke: (_) => revoked += 1,
        ),
      ),
    );
    await tester.pumpAndSettle();

    final l = AppLocalizations.of(tester.element(find.byType(Scaffold)))!;
    expect(find.text(l.socialPersonaAssetReady), findsOneWidget);
    expect(find.text(l.socialPersonaAssetPendingReview), findsOneWidget);
    expect(find.text(l.socialPersonaAssetRejected), findsOneWidget);
    expect(find.text('图片内容不合规'), findsOneWidget);
    expect(find.text(l.socialPersonaAssetUse), findsOneWidget);
    expect(find.text(l.socialPersonaAssetRetry), findsOneWidget);

    await tester.tap(find.text(l.socialPersonaAssetUse));
    await tester.pump();
    expect(selected, 1);

    await tester.tap(find.text(l.socialPersonaAssetRetry));
    await tester.pump();
    expect(completed, 1);

    await tester.tap(find.byTooltip(l.socialPersonaAssetRevoke).first);
    await tester.pump();
    expect(revoked, 1);
  });

  testWidgets('stays usable at a narrow 390 by 844 viewport', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(
      _app(
        SocialPersonaAssetPanel(
          assets: [_asset(id: 'ready', status: 'active')],
          onAdd: () {},
          onSelect: (_) {},
          onComplete: (_) {},
          onRevoke: (_) {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
  });
}
