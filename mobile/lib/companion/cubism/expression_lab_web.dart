import 'cubism_bridge_web.dart';

/// Thin wrapper over the window.__live2dStage singleton.
class ExpressionLab {
  static WebCubismBridge? _bridge() {
    final raw = WebCubismBridge.find();
    return raw == null ? null : WebCubismBridge(raw);
  }

  static bool enabled() {
    final bridge = _bridge();
    return bridge != null && bridge.runtimeSupported();
  }

  static List<String> names() => _bridge()?.expressionNames() ?? const [];

  static void setExpression(String name) =>
      _bridge()?.setExpressionByName(name);

  static void reset() => _bridge()?.resetExpression();

  static void idle() => _bridge()?.startIdleMotion();
}
