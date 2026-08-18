import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'live2d_controller.dart';

/// Interactive Live2D digital character viewport widget (Talking-Tom style).
class Live2DCharacterWidget extends StatefulWidget {
  const Live2DCharacterWidget({
    super.key,
    required this.controller,
    this.size = 280,
    this.modelAssetPath = 'assets/live2d/doro/Doro.2048/texture_00.png',
    this.showSpeechBubble = true,
    this.enableTouchTracking = true,
  });

  final Live2DController controller;
  final double size;
  final String modelAssetPath;
  final bool showSpeechBubble;
  final bool enableTouchTracking;

  @override
  State<Live2DCharacterWidget> createState() => _Live2DCharacterWidgetState();
}

class _Live2DCharacterWidgetState extends State<Live2DCharacterWidget>
    with SingleTickerProviderStateMixin {
  late final AnimationController _animController;
  Offset _touchRipplePos = Offset.zero;
  bool _showRipple = false;

  @override
  void initState() {
    super.initState();
    _animController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 4),
    )..repeat();
  }

  @override
  void dispose() {
    _animController.dispose();
    super.dispose();
  }

  void _onTapDown(TapDownDetails details, Size size) {
    setState(() {
      _touchRipplePos = details.localPosition;
      _showRipple = true;
    });

    widget.controller.handleTap(details.localPosition, size);

    Future.delayed(const Duration(milliseconds: 300), () {
      if (mounted) {
        setState(() => _showRipple = false);
      }
    });
  }

  void _onPanUpdate(DragUpdateDetails details, Size size) {
    if (!widget.enableTouchTracking || size.width == 0 || size.height == 0) return;
    final normalizedX = ((details.localPosition.dx / size.width) - 0.5) * 2.0;
    final normalizedY = ((details.localPosition.dy / size.height) - 0.5) * 2.0;
    widget.controller.lookAt(normalizedX, normalizedY);
  }

  void _onPanEnd(DragEndDetails details) {
    if (!widget.enableTouchTracking) return;
    widget.controller.resetGaze();
  }

  @override
  Widget build(BuildContext context) {
    final effectiveSize = Size.square(widget.size);

    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, child) {
        final speech = widget.controller.speechBubble;

        return SizedBox(
          width: effectiveSize.width,
          height: effectiveSize.height + (widget.showSpeechBubble ? 60 : 0),
          child: Stack(
            clipBehavior: Clip.none,
            alignment: Alignment.bottomCenter,
            children: [
              // 1. Interactive Character Mesh Viewport
              Positioned(
                bottom: 0,
                child: GestureDetector(
                  onTapDown: (details) => _onTapDown(details, effectiveSize),
                  onPanUpdate: (details) => _onPanUpdate(details, effectiveSize),
                  onPanEnd: _onPanEnd,
                  child: AnimatedBuilder(
                    animation: _animController,
                    builder: (context, _) {
                      return CustomPaint(
                        size: effectiveSize,
                        painter: _Live2DCanvasPainter(
                          controller: widget.controller,
                          animValue: _animController.value,
                          modelAssetPath: widget.modelAssetPath,
                        ),
                        child: SizedBox(
                          width: effectiveSize.width,
                          height: effectiveSize.height,
                          child: _showRipple
                              ? _buildTouchRipple()
                              : const SizedBox.shrink(),
                        ),
                      );
                    },
                  ),
                ),
              ),

              // 2. Dynamic Speech Bubble Overlay (Talking Tom Dialogue)
              if (widget.showSpeechBubble && speech != null && speech.isNotEmpty)
                Positioned(
                  top: 0,
                  child: _buildSpeechBubble(speech),
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildSpeechBubble(String text) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0.0, end: 1.0),
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOutBack,
      builder: (context, val, child) {
        return Transform.scale(
          scale: val,
          alignment: Alignment.bottomCenter,
          child: Container(
            constraints: BoxConstraints(maxWidth: widget.size * 1.1),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.96),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: const Color(0xFF0F766E).withValues(alpha: 0.3),
                width: 1.5,
              ),
              boxShadow: [
                BoxShadow(
                  color: const Color(0xFF0F766E).withValues(alpha: 0.12),
                  blurRadius: 10,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: Text(
              text,
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: Color(0xFF134E4A),
                height: 1.3,
              ),
              textAlign: TextAlign.center,
            ),
          ),
        );
      },
    );
  }

  Widget _buildTouchRipple() {
    return CustomPaint(
      painter: _TouchRipplePainter(pos: _touchRipplePos),
    );
  }
}

class _TouchRipplePainter extends CustomPainter {
  final Offset pos;
  _TouchRipplePainter({required this.pos});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = const Color(0xFF0F766E).withValues(alpha: 0.3)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5;

    canvas.drawCircle(pos, 18, paint);
  }

  @override
  bool shouldRepaint(covariant _TouchRipplePainter oldDelegate) => true;
}

/// Custom painter that renders Live2D parameter transforms (breathing, LookAt gaze, mouth opening).
class _Live2DCanvasPainter extends CustomPainter {
  final Live2DController controller;
  final double animValue;
  final String modelAssetPath;

  _Live2DCanvasPainter({
    required this.controller,
    required this.animValue,
    required this.modelAssetPath,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);

    // 1. Calculate physical parameter physics
    // Breathing oscillation (Y axis bounce)
    final breathCycle = math.sin(animValue * 2 * math.pi);
    final breathOffsetY = breathCycle * (size.height * 0.015);
    final breathScaleY = 1.0 + (breathCycle * 0.012);

    // Motion modifiers (squash & stretch on tap)
    double motionScaleX = 1.0;
    double motionScaleY = 1.0;
    double headAngle = 0.0;

    if (controller.activeMotion == 'tap_head') {
      motionScaleX = 1.04;
      motionScaleY = 0.95;
      headAngle = math.sin(animValue * 8 * math.pi) * 0.06;
    } else if (controller.activeMotion == 'poke_belly') {
      motionScaleX = 0.94;
      motionScaleY = 1.05;
      headAngle = -0.04;
    }

    // LookAt gaze tracking
    final lookX = controller.lookAtX * (size.width * 0.04);
    final lookY = controller.lookAtY * (size.height * 0.03);

    // 2. Draw Soft Ambient Shadow & Glow
    final shadowPaint = Paint()
      ..color = const Color(0xFF0F766E).withValues(alpha: 0.12)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 12);
    canvas.drawOval(
      Rect.fromCenter(
        center: Offset(center.dx, size.height * 0.92),
        width: size.width * 0.65 * motionScaleX,
        height: size.height * 0.14,
      ),
      shadowPaint,
    );

    // 3. Render Transformed Character Body & Head
    canvas.save();
    canvas.translate(center.dx + lookX, center.dy + breathOffsetY + lookY);
    canvas.rotate(headAngle);
    canvas.scale(motionScaleX, motionScaleY * breathScaleY);

    // Main Doro character body background
    final bodyPaint = Paint()
      ..color = const Color(0xFFE6F4EA)
      ..style = PaintingStyle.fill;
    final bodyRect = RRect.fromRectAndRadius(
      Rect.fromCenter(center: Offset.zero, width: size.width * 0.78, height: size.height * 0.78),
      Radius.circular(size.width * 0.36),
    );
    canvas.drawRRect(bodyRect, bodyPaint);

    final borderPaint = Paint()
      ..color = const Color(0xFF0F766E).withValues(alpha: 0.35)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.0;
    canvas.drawRRect(bodyRect, borderPaint);

    // 4. Render Cute Doro Ears (Physical Bouncing)
    final earBlink = math.sin(animValue * 4 * math.pi) * 0.05;
    _drawEar(canvas, size, isLeft: true, earBlink: earBlink);
    _drawEar(canvas, size, isLeft: false, earBlink: earBlink);

    // 5. Render Expressive Eyes with Gaze Tracking
    _drawEyes(canvas, size, lookX, lookY);

    // 6. Render Dynamic Lip-Sync Mouth
    _drawMouth(canvas, size, controller.mouthOpen);

    // 7. Render Blushing Cheeks
    _drawCheeks(canvas, size);

    canvas.restore();
  }

  void _drawEar(Canvas canvas, Size size, {required bool isLeft, required double earBlink}) {
    final earPaint = Paint()
      ..color = const Color(0xFF0F766E)
      ..style = PaintingStyle.fill;
    final innerEarPaint = Paint()
      ..color = const Color(0xFFFFD1DC)
      ..style = PaintingStyle.fill;

    final dir = isLeft ? -1.0 : 1.0;
    canvas.save();
    canvas.translate(dir * (size.width * 0.28), -size.height * 0.35);
    canvas.rotate(dir * (0.3 + earBlink));

    final earPath = Path()
      ..moveTo(0, 0)
      ..lineTo(dir * size.width * 0.12, -size.height * 0.18)
      ..lineTo(dir * size.width * 0.22, 0)
      ..close();

    canvas.drawPath(earPath, earPaint);

    // Inner pink ear
    final innerEarPath = Path()
      ..moveTo(0, 0)
      ..lineTo(dir * size.width * 0.08, -size.height * 0.12)
      ..lineTo(dir * size.width * 0.16, 0)
      ..close();
    canvas.drawPath(innerEarPath, innerEarPaint);

    canvas.restore();
  }

  void _drawEyes(Canvas canvas, Size size, double lookX, double lookY) {
    final isBlinking = (animValue * 10).floor() % 10 == 0; // Periodic blink
    final eyeRadius = size.width * 0.065;
    final eyeSpacing = size.width * 0.20;

    final eyePaint = Paint()..color = const Color(0xFF1E293B);
    final pupilPaint = Paint()..color = Colors.white;

    for (final isLeft in [true, false]) {
      final eyeX = (isLeft ? -1.0 : 1.0) * eyeSpacing;
      final eyeY = -size.height * 0.05;

      if (isBlinking || controller.expression == Live2DExpression.shy) {
        // Closed / Happy Curved Eyes (^_^)
        final curvePaint = Paint()
          ..color = const Color(0xFF1E293B)
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round
          ..strokeWidth = 3.5;

        final path = Path()
          ..moveTo(eyeX - eyeRadius, eyeY)
          ..quadraticBezierTo(eyeX, eyeY - eyeRadius * 0.8, eyeX + eyeRadius, eyeY);
        canvas.drawPath(path, curvePaint);
      } else {
        // Open Eye Outer
        canvas.drawCircle(Offset(eyeX, eyeY), eyeRadius, eyePaint);

        // Pupil / Highlight tracking gaze
        final pupilX = eyeX + (lookX * 0.4) + (isLeft ? 2.0 : -2.0);
        final pupilY = eyeY + (lookY * 0.4) - 2.0;
        canvas.drawCircle(Offset(pupilX, pupilY), eyeRadius * 0.35, pupilPaint);
      }
    }
  }

  void _drawMouth(Canvas canvas, Size size, double mouthOpen) {
    final mouthY = size.height * 0.12;

    if (mouthOpen > 0.1) {
      // Dynamic Open Lip-Sync Mouth :D
      final openHeight = size.height * 0.08 * mouthOpen;
      final mouthWidth = size.width * 0.14;

      final mouthPaint = Paint()
        ..color = const Color(0xFF991B1B)
        ..style = PaintingStyle.fill;
      final tonguePaint = Paint()
        ..color = const Color(0xFFF43F5E)
        ..style = PaintingStyle.fill;

      final mouthRect = RRect.fromRectAndRadius(
        Rect.fromCenter(center: Offset(0, mouthY), width: mouthWidth, height: openHeight),
        Radius.circular(mouthWidth * 0.4),
      );
      canvas.drawRRect(mouthRect, mouthPaint);

      // Tongue inside
      if (mouthOpen > 0.3) {
        canvas.drawCircle(
          Offset(0, mouthY + openHeight * 0.25),
          mouthWidth * 0.25,
          tonguePaint,
        );
      }
    } else {
      // Gentle Smile (w)
      final smilePaint = Paint()
        ..color = const Color(0xFF1E293B)
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeWidth = 2.5;

      final path = Path()
        ..moveTo(-size.width * 0.06, mouthY)
        ..quadraticBezierTo(-size.width * 0.03, mouthY + 5, 0, mouthY)
        ..quadraticBezierTo(size.width * 0.03, mouthY + 5, size.width * 0.06, mouthY);

      canvas.drawPath(path, smilePaint);
    }
  }

  void _drawCheeks(Canvas canvas, Size size) {
    final blushPaint = Paint()
      ..color = const Color(0xFFFB7185).withValues(alpha: 0.45)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6);

    canvas.drawCircle(Offset(-size.width * 0.28, size.height * 0.06), size.width * 0.05, blushPaint);
    canvas.drawCircle(Offset(size.width * 0.28, size.height * 0.06), size.width * 0.05, blushPaint);
  }

  @override
  bool shouldRepaint(covariant _Live2DCanvasPainter oldDelegate) => true;
}
