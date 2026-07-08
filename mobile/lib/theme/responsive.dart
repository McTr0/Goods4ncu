import 'package:flutter/material.dart';

abstract final class AppBreakpoints {
  static const double desktop = 1024;
  static const double wideDesktop = 1280;
}

class ResponsiveContent extends StatelessWidget {
  final Widget child;
  final double maxWidth;
  final AlignmentGeometry alignment;

  const ResponsiveContent({
    super.key,
    required this.child,
    this.maxWidth = 1440,
    this.alignment = Alignment.topCenter,
  });

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: alignment,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: child,
      ),
    );
  }
}
