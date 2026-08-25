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
    final scheme = Theme.of(context).colorScheme;
    final textColor = scheme.onSurface;
    final mutedColor = scheme.onSurfaceVariant;
    final primary = scheme.primary;

    return MarkdownBlock(
      data: sanitizeAssistantMarkdown(data),
      selectable: true,
      generator: MarkdownGenerator(
        linesMargin: const EdgeInsets.symmetric(vertical: 3),
      ),
      config: MarkdownConfig(
        configs: [
          PConfig(
            textStyle: TextStyle(color: textColor, fontSize: 16, height: 1.45),
          ),
          H1Config(
            style: TextStyle(
              color: textColor,
              fontSize: 22,
              height: 1.3,
              fontWeight: FontWeight.w800,
            ),
          ),
          H2Config(
            style: TextStyle(
              color: textColor,
              fontSize: 20,
              height: 1.3,
              fontWeight: FontWeight.w800,
            ),
          ),
          H3Config(
            style: TextStyle(
              color: textColor,
              fontSize: 18,
              height: 1.35,
              fontWeight: FontWeight.w800,
            ),
          ),
          H4Config(
            style: TextStyle(
              color: textColor,
              fontSize: 17,
              fontWeight: FontWeight.w700,
            ),
          ),
          H5Config(
            style: TextStyle(
              color: textColor,
              fontSize: 16,
              fontWeight: FontWeight.w700,
            ),
          ),
          H6Config(
            style: TextStyle(
              color: mutedColor,
              fontSize: 15,
              fontWeight: FontWeight.w700,
            ),
          ),
          CodeConfig(
            style: TextStyle(
              color: scheme.onTertiaryContainer,
              backgroundColor: scheme.tertiaryContainer,
              fontFamily: 'monospace',
            ),
          ),
          PreConfig(
            padding: const EdgeInsets.all(12),
            margin: const EdgeInsets.symmetric(vertical: 6),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest,
              borderRadius: const BorderRadius.all(Radius.circular(10)),
            ),
            textStyle: TextStyle(
              color: scheme.onSurface,
              fontSize: 13,
              height: 1.45,
              fontFamily: 'monospace',
            ),
            styleNotMatched: TextStyle(color: scheme.onSurface),
          ),
          BlockquoteConfig(
            sideColor: primary,
            textColor: mutedColor,
            sideWith: 3,
            padding: const EdgeInsets.fromLTRB(12, 2, 0, 2),
            margin: const EdgeInsets.symmetric(vertical: 6),
          ),
          LinkConfig(
            style: TextStyle(
              color: primary,
              decoration: TextDecoration.underline,
              decorationColor: primary,
            ),
            onTap: _ignoreExternalLink,
          ),
          ImgConfig(
            builder: (url, attributes) =>
                _buildBlockedImage(url, attributes, mutedColor),
          ),
        ],
      ),
    );
  }

  static void _ignoreExternalLink(String _) {}

  static Widget _buildBlockedImage(
    String _,
    Map<String, String> attributes,
    Color color,
  ) {
    final alt = attributes['alt']?.trim();
    return Text(
      alt == null || alt.isEmpty ? '[图片链接]' : '[图片：$alt]',
      style: TextStyle(color: color, fontStyle: FontStyle.italic),
    );
  }
}
