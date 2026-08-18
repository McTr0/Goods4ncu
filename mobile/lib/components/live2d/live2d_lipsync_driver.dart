import 'dart:async';
import 'dart:math' as math;
import 'live2d_controller.dart';

/// Drives the Live2D character mouth opening (Lip-Sync) in sync with text streaming or speech.
class Live2DLipSyncDriver {
  Live2DLipSyncDriver({required this.controller});

  final Live2DController controller;
  Timer? _decayTimer;
  DateTime _lastTokenTime = DateTime.now();

  /// Feed a chunk of incoming text from the SSE chat stream.
  /// Generates a realistic mouth opening burst.
  void feedStreamingChunk(String chunk) {
    if (chunk.trim().isEmpty) return;

    _lastTokenTime = DateTime.now();
    // Calculate burst intensity based on characters
    final intensity = (0.5 + (0.5 * math.Random().nextDouble())).clamp(0.2, 1.0);
    controller.setMouthOpen(intensity);

    _decayTimer?.cancel();
    _decayTimer = Timer(const Duration(milliseconds: 140), () {
      final elapsed = DateTime.now().difference(_lastTokenTime).inMilliseconds;
      if (elapsed >= 120) {
        controller.setMouthOpen(0.0);
      }
    });
  }

  /// Mark the stream as finished, resetting the mouth back to closed.
  void onStreamComplete() {
    _decayTimer?.cancel();
    controller.setMouthOpen(0.0);
  }

  void dispose() {
    _decayTimer?.cancel();
  }
}
