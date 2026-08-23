import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:ui_web' as ui_web;

import 'package:flutter/widgets.dart';

import '../character_renderer.dart';
import 'cubism_bridge_web.dart';
import 'cubism_renderer.dart';

const String _viewType = 'companion-live2d-stage';

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
    // The stage script may race Flutter's async bootstrap; poll instead of
    // bailing silently, and surface a visible failure if it never arrives.
    Future<void>.delayed(Duration.zero, () async {
      JSObject? stage;
      for (var i = 0; i < 40; i++) {
        stage = WebCubismBridge.find();
        if (stage != null) break;
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      if (stage == null) {
        container.setProperty(
          'innerHTML'.toJS,
          'Live2D runtime did not load (window.__live2dStage missing)'.toJS,
        );
        return;
      }
      // Pass the ELEMENT directly and retry until accepted — no DOM lookup
      // race, no silent false. Final failure writes a visible diagnostic.
      final bridge = WebCubismBridge(stage);
      for (var attempt = 0; attempt < 50; attempt++) {
        if (bridge.mountElement(container, modelUrl)) return;
        if (bridge.hasLoadFailed()) return;
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      container.setProperty(
        'innerHTML'.toJS,
        'Live2D mount failed after retries — see console'.toJS,
      );
    });
    return container;
  });
  _factoryRegistered = true;
}

/// Web stage: an HtmlElementView hosting the PIXI canvas with the real
/// Cubism model. If the runtime or the model fails to load, [fallback]
/// replaces the slot so the user never sees a blank box (goal §74).
class CubismStageWebView extends StatefulWidget {
  const CubismStageWebView({
    super.key,
    required this.fallback,
    required this.modelUrl,
    this.width = 300,
    this.height = 360,
  });

  final WidgetBuilder fallback;
  final double width;
  final double height;
  final String modelUrl;

  @override
  State<CubismStageWebView> createState() => _CubismStageWebViewState();
}

class _CubismStageWebViewState extends State<CubismStageWebView> {
  static const _pollInterval = Duration(milliseconds: 300);
  static const _maxPolls = 12; // ~3.6 s

  Timer? _pollTimer;
  int _polls = 0;
  bool? _runtimeSupported; // null = not yet probed

  @override
  void initState() {
    super.initState();
    _probe();
  }

  Future<void> _probe() async {
    for (var i = 0; i < 20; i++) {
      final stage = WebCubismBridge.find();
      if (stage != null) {
        final bridge = WebCubismBridge(stage);
        // Runtime scripts may still be initializing; give them a beat.
        await Future<void>.delayed(const Duration(milliseconds: 150));
        if (!mounted) return;
        setState(() => _runtimeSupported = bridge.runtimeSupported());
        if (_runtimeSupported == true) _startFailureWatch(bridge);
        return;
      }
      await Future<void>.delayed(_pollInterval);
      if (!mounted) return;
    }
    if (mounted) setState(() => _runtimeSupported = false);
  }

  /// Watches for async load failure and swaps to the fallback body.
  void _startFailureWatch(WebCubismBridge bridge) {
    _pollTimer = Timer.periodic(_pollInterval, (timer) {
      _polls++;
      final failed = bridge.hasLoadFailed();
      if (failed && mounted) {
        timer.cancel();
        setState(() => _runtimeSupported = false);
      } else if (_polls >= _maxPolls) {
        timer.cancel();
      }
    });
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Unsupported / failed → legacy sprite body takes the slot.
    if (_runtimeSupported == false) return widget.fallback(context);
    if (_runtimeSupported == null) {
      // Still probing: keep layout stable with an empty box of same size.
      return SizedBox(width: widget.width, height: widget.height);
    }
    _ensureViewFactory(widget.modelUrl);
    return SizedBox(
      width: widget.width,
      height: widget.height,
      child: HtmlElementView(viewType: _viewType),
    );
  }
}

/// Whether the Cubism4 runtime is actually usable right now (goal §74).
/// Null-safe: any missing piece degrades to false.
bool cubismRuntimeSupported() {
  try {
    final stage = WebCubismBridge.find();
    if (stage == null) return false;
    return WebCubismBridge(stage).runtimeSupported();
  } catch (_) {
    return false;
  }
}

CharacterRenderer createCubismRenderer() =>
    CubismCharacterRenderer(bridge: WebCubismBridge(WebCubismBridge.find()!));

Widget? createCubismStage({
  required WidgetBuilder fallback,
  required String modelUrl,
  double width = 300,
  double height = 360,
}) {
  _ensureViewFactory(modelUrl);
  return CubismStageWebView(
    fallback: fallback,
    modelUrl: modelUrl,
    width: width,
    height: height,
  );
}
