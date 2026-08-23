import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'cubism_params.dart';

/// Web implementation backed by window.__live2dStage (web/live2d_stage.js).
class WebCubismBridge implements CubismBridge {
  WebCubismBridge(this._stage);

  final JSObject _stage;

  static JSObject? find() {
    final stage = globalContext.getProperty<JSAny?>('__live2dStage'.toJS);
    if (stage == null || !stage.isA<JSObject>()) return null;
    return stage as JSObject;
  }

  static bool get isReady => find() != null;

  /// Mirrors the stage's own supported() check (runtime libs present).
  bool runtimeSupported() =>
      (_stage.callMethod('supported'.toJS) as JSBoolean).toDart;

  /// True when a mount/model load failed after the stage was created.
  bool hasLoadFailed() =>
      (_stage.callMethod('hasLoadFailed'.toJS) as JSBoolean).toDart;

  /// Mount by element id (legacy convenience).
  bool mount(String containerId, String modelUrl) =>
      (_stage.callMethod('mount'.toJS, containerId.toJS, modelUrl.toJS)
              as JSBoolean)
          .toDart;

  /// Mount by passing the container ELEMENT directly (goal §8 of the
  /// debugging session): no DOM lookup timing race.
  bool mountElement(JSObject el, String modelUrl) =>
      (_stage.callMethod('mountElement'.toJS, el, modelUrl.toJS) as JSBoolean)
          .toDart;

  void disposeStage() => _stage.callMethod('dispose'.toJS);

  @override
  void setParam(String id, double value) {
    _stage.callMethod('setParam'.toJS, id.toJS, value.toJS);
  }

  @override
  void focus(double x, double y) {
    _stage.callMethod('focus'.toJS, x.toJS, y.toJS);
  }

  @override
  void nod() => _stage.callMethod('nod'.toJS);

  @override
  void shake() => _stage.callMethod('shake'.toJS);
}
