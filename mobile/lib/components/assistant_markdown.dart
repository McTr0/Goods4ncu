import 'package:flutter/material.dart';
import 'package:markdown_widget/markdown_widget.dart';

String sanitizeAssistantMarkdown(String source) {
  var inCodeFence = false;
  return source
      .split('\n')
      .map((line) {
        if (line.trimLeft().startsWith('```')) {
          inCodeFence = !inCodeFence;
          return line;
        }
        if (inCodeFence) return line;
        return line.replaceAll('<', '&lt;').replaceAll('>', '&gt;');
      })
      .join('\n');
}

class AssistantMarkdown extends StatelessWidget {
  const AssistantMarkdown({super.key, required this.data});

  final String data;

  @override
  Widget build(BuildContext context) {
    const textColor = Color(0xFF24312F);
    const mutedColor = Color(0xFF526663);
    const primary = Color(0xFF0F766E);

    return MarkdownBlock(
      data: sanitizeAssistantMarkdown(data),
      selectable: true,
      generator: MarkdownGenerator(
        linesMargin: const EdgeInsets.symmetric(vertical: 3),
      ),
      config: MarkdownConfig(
        configs: [
          const PConfig(
            textStyle: TextStyle(color: textColor, fontSize: 16, height: 1.45),
          ),
          const H1Config(
            style: TextStyle(
              color: textColor,
              fontSize: 22,
              height: 1.3,
              fontWeight: FontWeight.w800,
            ),
          ),
          const H2Config(
            style: TextStyle(
              color: textColor,
              fontSize: 20,
              height: 1.3,
              fontWeight: FontWeight.w800,
            ),
          ),
          const H3Config(
            style: TextStyle(
              color: textColor,
              fontSize: 18,
              height: 1.35,
              fontWeight: FontWeight.w800,
            ),
          ),
          const H4Config(
            style: TextStyle(
              color: textColor,
              fontSize: 17,
              fontWeight: FontWeight.w700,
            ),
          ),
          const H5Config(
            style: TextStyle(
              color: textColor,
              fontSize: 16,
              fontWeight: FontWeight.w700,
            ),
          ),
          const H6Config(
            style: TextStyle(
              color: mutedColor,
              fontSize: 15,
              fontWeight: FontWeight.w700,
            ),
          ),
          const CodeConfig(
            style: TextStyle(
              color: Color(0xFF9A3412),
              backgroundColor: Color(0xFFFFE8D7),
              fontFamily: 'monospace',
            ),
          ),
          const PreConfig(
            padding: EdgeInsets.all(12),
            margin: EdgeInsets.symmetric(vertical: 6),
            decoration: BoxDecoration(
              color: Color(0xFF172321),
              borderRadius: BorderRadius.all(Radius.circular(10)),
            ),
            textStyle: TextStyle(
              color: Color(0xFFE5F3F0),
              fontSize: 13,
              height: 1.45,
              fontFamily: 'monospace',
            ),
            styleNotMatched: TextStyle(color: Color(0xFFE5F3F0)),
          ),
          const BlockquoteConfig(
            sideColor: primary,
            textColor: mutedColor,
            sideWith: 3,
            padding: EdgeInsets.fromLTRB(12, 2, 0, 2),
            margin: EdgeInsets.symmetric(vertical: 6),
          ),
          const LinkConfig(
            style: TextStyle(
              color: primary,
              decoration: TextDecoration.underline,
              decorationColor: primary,
            ),
            onTap: _ignoreExternalLink,
          ),
          ImgConfig(builder: _buildBlockedImage),
        ],
      ),
    );
  }

  static void _ignoreExternalLink(String _) {}

  static Widget _buildBlockedImage(String _, Map<String, String> attributes) {
    final alt = attributes['alt']?.trim();
    return Text(
      alt == null || alt.isEmpty ? '[图片链接]' : '[图片：$alt]',
      style: const TextStyle(
        color: Color(0xFF64748B),
        fontStyle: FontStyle.italic,
      ),
    );
  }
}
