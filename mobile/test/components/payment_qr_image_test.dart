import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goods4ncu_mobile/components/payment_qr_image.dart';
import 'package:goods4ncu_mobile/l10n/app_localizations.dart';

Widget _buildTestApp(Widget child) {
  return MaterialApp(
    locale: const Locale('zh'),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(body: child),
  );
}

void main() {
  testWidgets('shows a fallback when the QR image cannot be decoded', (
    tester,
  ) async {
    await tester.pumpWidget(
      _buildTestApp(
        const PaymentQrImage(
          url: 'http://127.0.0.1:1/not-an-image.jpg',
          label: '微信收款码',
          width: 112,
          height: 112,
        ),
      ),
    );

    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.broken_image_outlined), findsOneWidget);
    expect(find.text('加载失败: 微信收款码'), findsOneWidget);
  });
}
