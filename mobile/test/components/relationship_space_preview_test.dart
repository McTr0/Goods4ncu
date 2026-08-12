import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goods4ncu_mobile/components/relationship_space_preview.dart';
import 'package:goods4ncu_mobile/l10n/app_localizations.dart';
import 'package:goods4ncu_mobile/theme/app_theme.dart';

Widget _host(Widget child, {Locale locale = const Locale('zh')}) {
  return MaterialApp(
    theme: AppTheme.light,
    locale: locale,
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(body: child),
  );
}

void main() {
  testWidgets('shows a shared space without presence claims', (tester) async {
    await tester.pumpWidget(
      _host(
        const RelationshipSpacePreview(otherName: 'Alice', latestEvent: '图书馆见'),
      ),
    );

    expect(find.byKey(const Key('relationship-space-preview')), findsOneWidget);
    expect(find.text('共同空间'), findsOneWidget);
    expect(find.text('可以留言'), findsOneWidget);
    expect(find.text('图书馆见'), findsOneWidget);
    expect(find.text('Alice'), findsOneWidget);
    expect(find.text('我'), findsWidgets);
    expect(find.text('在线'), findsNothing);
    expect(find.text('已读'), findsNothing);
    expect(find.text('正在输入'), findsNothing);
  });

  testWidgets('connected state is explicit and localized', (tester) async {
    await tester.pumpWidget(
      _host(
        const RelationshipSpacePreview(otherName: 'Alice', isConnected: true),
        locale: Locale('en'),
      ),
    );

    expect(find.text('Shared space'), findsOneWidget);
    expect(find.text('Connected'), findsOneWidget);
    expect(find.text('Leave a message'), findsNothing);
  });
}
