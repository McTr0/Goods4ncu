import 'dart:math';

/// Exponential gaze approach — eyes/head glide, never teleport (§42).
class GazeSmoother {
  GazeSmoother({this.approachPerSecond = 6.0, double x = 0, double y = 0})
    : _x = x,
      _y = y;

  final double approachPerSecond;
  double _x;
  double _y;

  double get x => _x;
  double get y => _y;

  double _targetX = 0;
  double _targetY = 0;

  void setTarget(double x, double y) {
    _targetX = x.clamp(-1.0, 1.0);
    _targetY = y.clamp(-1.0, 1.0);
  }

  /// Advance one frame; returns the smoothed value. Call per tick.
  void tick(Duration elapsed) {
    final seconds = elapsed.inMicroseconds / Duration.microsecondsPerSecond;
    if (seconds <= 0) return;
    final factor = (1 - exp(-approachPerSecond * seconds)).clamp(0.0, 1.0);
    _x += (_targetX - _x) * factor;
    _y += (_targetY - _y) * factor;
    // Snap when close enough so we don't emit forever.
    if ((_targetX - _x).abs() < 0.005) _x = _targetX;
    if ((_targetY - _y).abs() < 0.005) _y = _targetY;
  }

  bool get settled => _x == _targetX && _y == _targetY;
}

/// Idle behaviour tiers (§32–35): micro / short / long.
enum IdleTier { none, micro, shortIdle, longIdle }

/// Decides which idle tier applies given how long nothing happened.
IdleTier idleTierFor(Duration sinceInteraction) {
  if (sinceInteraction < const Duration(seconds: 30)) return IdleTier.micro;
  if (sinceInteraction < const Duration(seconds: 120)) {
    return IdleTier.shortIdle;
  }
  return IdleTier.longIdle;
}
