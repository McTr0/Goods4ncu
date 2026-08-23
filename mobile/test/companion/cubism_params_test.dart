import 'package:flutter_test/flutter_test.dart';
import 'package:goods4ncu_mobile/companion/cubism/cubism_body.dart';
import 'package:goods4ncu_mobile/companion/cubism/cubism_params.dart';

class _RecordingBridge implements CubismBridge {
  final Map<String, double> params = {};
  final List<(double, double)> focuses = [];
  var nods = 0;
  var shakes = 0;

  @override
  void setParam(String id, double value) => params[id] = value;

  @override
  void focus(double x, double y) => focuses.add((x, y));

  @override
  void nod() => nods++;

  @override
  void shake() => shakes++;
}

void main() {
  test('state choreography writes head/body from gaze', () {
    final bridge = _RecordingBridge();
    final params = paramsForState('thinking', gazeX: 0.5, gazeY: -0.2);

    expect(params[CubismParams.angleX], closeTo(15, 1e-9));
    expect(params[CubismParams.angleY], closeTo(6, 1e-9));
    expect(params[CubismParams.bodyZ], closeTo(5, 1e-9));
    expect(params[CubismParams.browLY], -0.5);
    expect(bridge.params.isEmpty, isTrue, reason: 'pure mapping untouched');
  });

  test('happy lifts smile and mouth form; sleeping closes eyes', () {
    final happy = paramsForState('happy', gazeX: 0, gazeY: 0);
    expect(happy[CubismParams.eyeSmile], 0.7);
    expect(happy[CubismParams.mouthForm], 0.6);

    final asleep = paramsForState('sleeping', gazeX: 0, gazeY: 0);
    expect(asleep[CubismParams.eyeLOpen], 0);
    expect(asleep[CubismParams.eyeROpen], 0);
  });

  test('gesture tags route to nod/shake on the bridge', () {
    final bridge = _RecordingBridge();

    gestureForTag(bridge, 'acknowledge');
    expect(bridge.nods, 1);

    gestureForTag(bridge, 'poke');
    expect(bridge.shakes, 1);

    // Procedural tags write nothing directly.
    gestureForTag(bridge, 'thinking');
    expect(bridge.nods, 1);
    expect(bridge.shakes, 1);
  });
}
