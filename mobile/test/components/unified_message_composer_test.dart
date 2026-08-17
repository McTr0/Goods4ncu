import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goods4ncu_mobile/components/unified_message_composer.dart';
import 'package:goods4ncu_mobile/l10n/app_localizations.dart';
import 'package:goods4ncu_mobile/services/speech_dictation.dart';

class _FakeSpeechDictation implements SpeechDictation {
  _FakeSpeechDictation({this.isSupported = true});

  @override
  final bool isSupported;
  void Function(SpeechDictationResult result)? onResult;
  void Function(String code)? onError;
  SpeechDictationEnded? onEnded;
  String? locale;
  bool stopped = false;
  bool disposed = false;

  @override
  Future<void> start({
    required String locale,
    required void Function(SpeechDictationResult result) onResult,
    required void Function(String code) onError,
    required SpeechDictationEnded onEnded,
  }) async {
    this.locale = locale;
    this.onResult = onResult;
    this.onError = onError;
    this.onEnded = onEnded;
  }

  @override
  Future<void> stop() async {
    stopped = true;
    onEnded?.call();
  }

  @override
  void dispose() => disposed = true;

  void emit(String text, {required bool isFinal}) {
    onResult?.call(SpeechDictationResult(text: text, isFinal: isFinal));
  }
}

Widget _testApp(Widget child) {
  return MaterialApp(
    locale: const Locale('zh'),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(
      body: Align(alignment: Alignment.bottomCenter, child: child),
    ),
  );
}

void main() {
  testWidgets('expands only the contextual tools supplied by its host', (
    tester,
  ) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    var selected = '';

    await tester.pumpWidget(
      _testApp(
        UnifiedMessageComposer(
          controller: controller,
          hintText: '输入消息',
          onSend: () {},
          expandedActions: [
            MessageComposerAction(
              id: 'poll',
              icon: Icons.poll_outlined,
              label: '投票',
              onPressed: () => selected = 'poll',
            ),
          ],
        ),
      ),
    );

    expect(find.text('投票'), findsNothing);
    await tester.tap(find.byKey(const Key('composer-tools-toggle')));
    await tester.pumpAndSettle();
    expect(find.text('投票'), findsOneWidget);

    await tester.tap(find.byKey(const Key('composer-tool-poll')));
    await tester.pumpAndSettle();
    expect(selected, 'poll');
    expect(find.text('投票'), findsNothing);
  });

  testWidgets('disables send and host actions during an async send', (
    tester,
  ) async {
    final controller = TextEditingController(text: 'hello');
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      _testApp(
        UnifiedMessageComposer(
          controller: controller,
          hintText: '输入消息',
          isSending: true,
          onSend: () {},
          primaryActions: [
            MessageComposerAction(
              id: 'image',
              icon: Icons.image_outlined,
              label: '图片',
              onPressed: () {},
            ),
          ],
        ),
      ),
    );

    expect(
      tester
          .widget<IconButton>(find.byKey(const Key('composer-send')))
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<IconButton>(find.byKey(const Key('composer-action-image')))
          .onPressed,
      isNull,
    );
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });

  testWidgets('dictation writes interim and final text without sending audio', (
    tester,
  ) async {
    final controller = TextEditingController(text: '已有');
    final dictation = _FakeSpeechDictation();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      _testApp(
        UnifiedMessageComposer(
          controller: controller,
          hintText: '输入消息',
          dictation: dictation,
          onSend: () {},
        ),
      ),
    );

    await tester.tap(find.byKey(const Key('composer-dictation')));
    await tester.pump();
    expect(dictation.locale, 'zh');
    expect(find.textContaining('正在听写'), findsOneWidget);

    dictation.emit('测试', isFinal: false);
    await tester.pump();
    expect(controller.text, '已有测试');

    dictation.emit('测试', isFinal: true);
    dictation.emit('输入', isFinal: false);
    await tester.pump();
    expect(controller.text, '已有测试输入');

    await tester.tap(find.byKey(const Key('composer-dictation-stop')));
    await tester.pump();
    expect(dictation.stopped, isTrue);
    expect(controller.text, '已有测试输入');
  });

  testWidgets('explains when browser dictation is unsupported', (tester) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      _testApp(
        UnifiedMessageComposer(
          controller: controller,
          hintText: '输入消息',
          dictation: _FakeSpeechDictation(isSupported: false),
          onSend: () {},
        ),
      ),
    );

    await tester.tap(find.byKey(const Key('composer-dictation')));
    await tester.pump();

    expect(find.text('当前设备不支持语音转文字'), findsOneWidget);
  });
}
