import 'package:flutter_test/flutter_test.dart';
import 'package:goods4ncu_mobile/companion/cubism/cubism_params.dart';

class _RecordingBridge implements CubismBridge {
  final List<String> expressions = [];
  var resets = 0;
  var idleStarts = 0;
  final Map<String, double> params = {};
  var nods = 0;

  @override
  void setParam(String id, double value) => params[id] = value;

  @override
  void focus(double x, double y) {}

  @override
  void nod() => nods++;

  @override
  void shake() {}

  @override
  void setExpressionByName(String name) => expressions.add(name);

  @override
  void resetExpression() => resets++;

  @override
  void startIdleMotion() => idleStarts++;
}

void main() {
  test('catalog ships every native Doro expression', () {
    expect(
      kDoroExpressions,
      containsAll([
        'Exp1', 'Exp8', 'TongueOut', 'Highlight OFF', 'Running OFF',
      ]),
    );
    expect(kDoroExpressions.length, 11);
  });

  test('semantic gestures still map to procedural fallbacks', () {
    final bridge = _RecordingBridge();
    gestureForTag(bridge, 'acknowledge');
    expect(bridge.nods, 1);
  });

  test('native expression calls flow through the bridge', () {
    final bridge = _RecordingBridge();
    bridge.setExpressionByName('TongueOut');
    bridge.resetExpression();
    bridge.startIdleMotion();
    expect(bridge.expressions, ['TongueOut']);
    expect(bridge.resets, 1);
    expect(bridge.idleStarts, 1);
  });
}
