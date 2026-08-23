import 'package:flutter/widgets.dart';

import '../character_renderer.dart';

/// Non-web fallback: Cubism body unavailable (graceful degradation §74).
class CubismStageFallback extends StatelessWidget {
  const CubismStageFallback({super.key});

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

CharacterRenderer? createCubismRenderer() => null;

Widget? createCubismStage({double width = 300, double height = 360}) => null;
