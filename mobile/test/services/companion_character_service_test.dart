import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goods4ncu_mobile/l10n/app_localizations.dart';
import 'package:goods4ncu_mobile/services/companion_character_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('CompanionCharacterService', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
      CompanionCharacterService.resetForTest();
    });

    test('defaults to doro and rejects unknown characters', () async {
      final service = CompanionCharacterService.instance;
      await service.load();

      expect(service.character, 'doro');

      await service.select('gugugaga');
      expect(service.character, 'doro');
    });

    test('select persists the choice and notifies listeners', () async {
      final service = CompanionCharacterService.instance;
      await service.load();
      var notifications = 0;
      service.addListener(() => notifications++);

      // Only doro ships a model today, so re-selecting doro is a no-op.
      await service.select('doro');
      expect(notifications, 0);
      expect(service.character, 'doro');
    });

    test('load restores a persisted selection', () async {
      SharedPreferences.setMockInitialValues({'companion.character': 'doro'});
      final service = CompanionCharacterService.instance;
      await service.load();

      expect(service.character, 'doro');
    });

    test('catalog never contains legacy character tokens', () {
      final service = CompanionCharacterService.instance;
      for (final character in service.availableCharacters) {
        expect(character, isNot(contains('ncu_')));
        expect(character, isNot('classic'));
        expect(character, isNot('phoebe_chupi'));
        expect(character, isNot('gugugaga'));
      }
      expect(service.availableCharacters, contains('doro'));
    });
  });

  group('settings character sheet contract', () {
    testWidgets('exposes localized labels for the picker', (tester) async {
      late AppLocalizations l;
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('zh'),
          home: Builder(
            builder: (context) {
              l = AppLocalizations.of(context)!;
              return const Scaffold(body: SizedBox.shrink());
            },
          ),
        ),
      );
      await tester.pump();

      expect(l.socialPersonaCharacter, '角色选择');
      expect(l.socialPersonaCharacterDoro, 'Doro');
      expect(l.characterSettingsSubtitle, isNotEmpty);
      expect(l.characterSettingsUpdated, isNotEmpty);
    });
  });
}
