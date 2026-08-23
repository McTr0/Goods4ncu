import 'package:flutter/widgets.dart';

import '../character_renderer.dart';
import 'cubism_bridge_web.dart';
import 'cubism_renderer.dart';

const String _containerId = 'live2d-stage-container';

/// Flutter web serves declared assets under `/assets/<repo-path>`, and the
/// repo path itself starts with `assets/`, hence the doubled prefix.
const String _defaultModelUrl = '/assets/assets/live2d/doro/Doro.model3.json';

/// Web stage: an HtmlElementView hosting the PIXI canvas; mounting happens
/// when the platform view is created (goal §72 — real Cubism body on web).
class CubismStageWebView extends StatelessWidget {
  const CubismStageWebView({
    super.key,
    this.width = 300,
    this.height = 360,
    this.modelUrl = _defaultModelUrl,
  });

  final double width;
  final double height;
  final String modelUrl;

  @override
  Widget build(BuildContext context) {
    final stage = WebCubismBridge.find();
    if (stage == null) return const SizedBox.shrink();
    return SizedBox(
      width: width,
      height: height,
      child: HtmlElementView(
        viewType: _containerId,
        onPlatformViewCreated: (_) {
          WebCubismBridge(stage).mount(_containerId, modelUrl);
        },
      ),
    );
  }
}

CharacterRenderer createCubismRenderer() =>
    CubismCharacterRenderer(bridge: WebCubismBridge(WebCubismBridge.find()!));

Widget? createCubismStage({double width = 300, double height = 360}) =>
    CubismStageWebView(width: width, height: height);
