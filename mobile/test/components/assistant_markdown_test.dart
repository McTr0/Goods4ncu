import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goods4ncu_mobile/components/assistant_markdown.dart';

void main() {
  test('sanitizer escapes html outside fenced code', () {
    const source =
        '<img src="https://tracker.test/a.png">\n'
        '```html\n<div>kept as code</div>\n```';

    final sanitized = sanitizeAssistantMarkdown(source);

    expect(sanitized, contains('&lt;img'));
    expect(sanitized, contains('<div>kept as code</div>'));
  });

  testWidgets('renders markdown formatting without loading markdown images', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: AssistantMarkdown(
            data:
                '# 建议\n\n- **先确认预算**\n- 再比较成色\n\n'
                '![远程图片](https://tracker.test/a.png)',
          ),
        ),
      ),
    );
    await tester.pump();

    final renderedText = tester
        .widgetList<RichText>(find.byType(RichText))
        .map((widget) => widget.text.toPlainText())
        .join('\n');
    expect(renderedText, contains('建议'));
    expect(renderedText, contains('先确认预算'));
    expect(renderedText, isNot(contains('**')));
    expect(renderedText, contains('[图片：远程图片]'));
    expect(find.byType(Image), findsNothing);
  });
}
