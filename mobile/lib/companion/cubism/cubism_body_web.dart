import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:ui_web' as ui_web;

import 'package:flutter/widgets.dart';

import '../character_renderer.dart';
import 'cubism_bridge_web.dart';
import 'cubism_renderer.dart';

const String _viewType = 'companion-live2d-stage';
const String _defaultModelUrl = '/assets/assets/live2d/doro/Doro.model3.json';

bool _factoryRegistered = false;

/// Registers (once) the platform-view factory that creates the PIXI host
/// div and boots the model into it. Without this registration Flutter web
/// throws "platform view is not registered" and blanks the layout.
void _ensureViewFactory(String modelUrl) {
  if (_factoryRegistered) return;
  ui_web.platformViewRegistry.registerViewFactory(_viewType, (int viewId) {
    final document = globalContext.getProperty<JSObject>('document'.toJS);
    final container =
        document.callMethod('createElement'.toJS, 'div'.toJS) as JSObject;
    container.setProperty('id'.toJS, '$_viewType-$viewId'.toJS);
    container.callMethod(
      'setAttribute'.toJS,
      'style'.toJS,
      'width:100%;height:100%;'.toJS,
    );
    scheduleMicrotask(() {
      final stage = WebCubismBridge.find();
      if (stage == null) return;
      final containerId = (container.getProperty('id'.toJS) as JSString).toDart;
      WebCubismBridge(stage).mount(containerId, modelUrl);
    });
    return container;
  });
  _factoryRegistered = true;
}

/// Web stage: an HtmlElementView hosting the PIXI canvas with the real
/// Cubism model (goal §72).
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
    if (!WebCubismBridge.isReady) return const SizedBox.shrink();
    _ensureViewFactory(modelUrl);
    return SizedBox(
      width: width,
      height: height,
      child: HtmlElementView(viewType: _viewType),
    );
  }
}

CharacterRenderer createCubismRenderer() =>
    CubismCharacterRenderer(bridge: WebCubismBridge(WebCubismBridge.find()!));

Widget? createCubismStage({double width = 300, double height = 360}) =>
    CubismStageWebView(width: width, height: height);
