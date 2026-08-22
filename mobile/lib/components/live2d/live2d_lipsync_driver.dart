import 'dart:async';
import 'dart:math' as math;
import 'live2d_controller.dart';

/// Drives the Live2D character mouth opening (Lip-Sync) in sync with text streaming or speech.
class Live2DLipSyncDriver {
  Live2DLipSyncDriver({required this.controller});

  final Live2DController controller;
  Timer? _decayTimer;
  double _targetOpen = 0.0;
  double _currentOpen = 0.0;
  Timer? _smoothingTimer;

  /// Feed a chunk of incoming text from the SSE chat stream.
  /// Generates a realistic mouth opening burst.
  void feedStreamingChunk(String chunk) {
    if (chunk.trim().isEmpty) return;

    // Calculate burst intensity based on characters
    _targetOpen = 0.5 + (0.5 * math.Random().nextDouble());
    _startSmoothing();

    _decayTimer?.cancel();
    _decayTimer = Timer(const Duration(milliseconds: 120), () {
      _targetOpen = 0.0;
      _startSmoothing();
    });
  }

  void _startSmoothing() {
    _smoothingTimer?.cancel();
    // Apply the first easing step synchronously so the mouth reacts to the
    // chunk immediately instead of waiting for a timer tick.
    _stepSmoothing();
    if ((_targetOpen - _currentOpen).abs() < 0.01) {
      _currentOpen = _targetOpen;
      controller.setMouthOpen(_currentOpen);
      return;
    }
    _smoothingTimer = Timer.periodic(const Duration(milliseconds: 16), (_) {
      if (_stepSmoothing()) {
        _smoothingTimer?.cancel();
        _smoothingTimer = null;
      }
    });
  }

  /// Advance one easing step; returns true when the target is reached.
  bool _stepSmoothing() {
    _currentOpen += (_targetOpen - _currentOpen) * 0.35;
    controller.setMouthOpen(_currentOpen);
    return (_targetOpen - _currentOpen).abs() < 0.01;
  }

  /// Mark the stream as finished, resetting the mouth back to closed.
  void onStreamComplete() {
    _decayTimer?.cancel();
    _smoothingTimer?.cancel();
    _smoothingTimer = null;
    _targetOpen = 0.0;
    _currentOpen = 0.0;
    controller.setMouthOpen(0.0);
  }

  void dispose() {
    _decayTimer?.cancel();
    _smoothingTimer?.cancel();
  }
}
