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
              // 1. Interactive Doro Live2D Character Viewport
              Positioned(
                bottom: 0,
                child: GestureDetector(
                  onTapDown: (details) => _onTapDown(details, effectiveSize),
                  onPanUpdate: (details) => _onPanUpdate(details, effectiveSize),
                  onPanEnd: _onPanEnd,
                  child: AnimatedBuilder(
                    animation: _animController,
                    builder: (context, _) {
                      final t = _animController.value * 2 * math.pi;
                      final breathOffsetY = math.sin(t) * 4.0;
                      final breathScaleY = 1.0 + math.sin(t) * 0.015;

                      // Physical motion variables
                      double motionScaleX = 1.0;
                      double motionScaleY = 1.0;
                      double headAngle = widget.controller.lookAtX * 0.08;

                      if (widget.controller.activeMotion == 'poke_belly') {
                        motionScaleX = 1.14;
                        motionScaleY = 0.86;
                      } else if (widget.controller.activeMotion == 'tap_head') {
                        headAngle += 0.08;
                        motionScaleX = 0.95;
                        motionScaleY = 1.05;
                      }

                      final lookX = widget.controller.lookAtX * (widget.size * 0.05);
                      final lookY = widget.controller.lookAtY * (widget.size * 0.03);

                      return Transform.translate(
                        offset: Offset(lookX, breathOffsetY + lookY),
                        child: Transform.rotate(
                          angle: headAngle,
                          child: Transform.scale(
                            scaleX: motionScaleX,
                            scaleY: motionScaleY * breathScaleY,
                            child: SizedBox(
                              width: effectiveSize.width,
                              height: effectiveSize.height,
                              child: Stack(
                                alignment: Alignment.center,
                                children: [
                                  // Soft Ambient Shadow below Doro
                                  Positioned(
                                    bottom: 6,
                                    child: Container(
                                      width: effectiveSize.width * 0.72,
                                      height: 18,
                                      decoration: BoxDecoration(
                                        borderRadius: BorderRadius.circular(100),
                                        boxShadow: [
                                          BoxShadow(
                                            color: const Color(0xFF0F766E).withValues(alpha: 0.18),
                                            blurRadius: 18,
                                            spreadRadius: 2,
                                            offset: const Offset(0, 6),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),

                                  // Doro Live2D Character Image Asset
                                  ClipRRect(
                                    borderRadius: BorderRadius.circular(widget.size * 0.35),
                                    child: Image.asset(
                                      'assets/live2d/doro/icon.png',
                                      width: effectiveSize.width * 0.92,
                                      height: effectiveSize.height * 0.92,
                                      fit: BoxFit.contain,
                                      errorBuilder: (context, error, stackTrace) => Image.asset(
                                        'assets/characters/xiaochang.png',
                                        width: effectiveSize.width * 0.92,
                                        height: effectiveSize.height * 0.92,
                                        fit: BoxFit.contain,
                                      ),
                                    ),
                                  ),

                                  // Lip-Sync Dynamic Mouth Overlay during SSE streaming speech
                                  if (widget.controller.mouthOpen > 0.05)
                                    Positioned(
                                      bottom: effectiveSize.height * 0.28,
                                      child: _buildDynamicMouth(widget.controller.mouthOpen),
                                    ),

                                  // Shy / Happy Blushing Emotion Overlay
                                  if (widget.controller.expression == Live2DExpression.shy ||
                                      widget.controller.expression == Live2DExpression.happy)
                                    Positioned.fill(
                                      child: _buildBlushOverlay(effectiveSize),
                                    ),

                                  // Touch ripple effect
                                  if (_showRipple)
                                    Positioned.fill(
                                      child: _buildTouchRipple(),
                                    ),
                                ],
                              ),
                            ),
                          ),
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

  Widget _buildDynamicMouth(double mouthOpen) {
    final height = 5.0 + 16.0 * mouthOpen;
    final width = 14.0 + 10.0 * mouthOpen;

    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: const Color(0xFF991B1B),
        borderRadius: BorderRadius.circular(height * 0.5),
        border: Border.all(color: const Color(0xFF134E4A), width: 1.5),
      ),
      child: Center(
        child: Container(
          width: width * 0.6,
          height: height * 0.45,
          decoration: BoxDecoration(
            color: const Color(0xFFFB923C),
            borderRadius: BorderRadius.circular(8),
          ),
        ),
      ),
    );
  }

  Widget _buildBlushOverlay(Size size) {
    return IgnorePointer(
      child: Stack(
        children: [
          Positioned(
            left: size.width * 0.16,
            bottom: size.height * 0.32,
            child: Container(
              width: size.width * 0.14,
              height: size.height * 0.07,
              decoration: BoxDecoration(
                color: const Color(0xFFF97316).withValues(alpha: 0.35),
                borderRadius: BorderRadius.circular(100),
              ),
            ),
          ),
          Positioned(
            right: size.width * 0.16,
            bottom: size.height * 0.32,
            child: Container(
              width: size.width * 0.14,
              height: size.height * 0.07,
              decoration: BoxDecoration(
                color: const Color(0xFFF97316).withValues(alpha: 0.35),
                borderRadius: BorderRadius.circular(100),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSpeechBubble(String text) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0.0, end: 1.0),
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOutBack,
      builder: (context, val, child) {
        return Transform.scale(
          scale: val,
          alignment: Alignment.bottomCenter,
          child: Container(
            constraints: BoxConstraints(
              maxWidth: math.max(widget.size * 1.15, 260),
              maxHeight: 160,
            ),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.96),
              borderRadius: BorderRadius.circular(18),
              border: Border.all(
                color: const Color(0xFF0F766E).withValues(alpha: 0.35),
                width: 1.5,
              ),
              boxShadow: [
                BoxShadow(
                  color: const Color(0xFF0F766E).withValues(alpha: 0.15),
                  blurRadius: 14,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: SingleChildScrollView(
              physics: const BouncingScrollPhysics(),
              child: Text(
                text,
                style: const TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF134E4A),
                  height: 1.35,
                ),
                textAlign: TextAlign.center,
              ),
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
