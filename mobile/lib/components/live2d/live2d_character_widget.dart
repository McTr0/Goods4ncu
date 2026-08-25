import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'live2d_effects.dart';
import 'live2d_controller.dart';

/// Interactive Live2D digital character viewport widget (Talking-Tom style).
class Live2DCharacterWidget extends StatefulWidget {
  const Live2DCharacterWidget({
    super.key,
    required this.controller,
    this.size = 280,
    this.modelAssetPath = 'assets/live2d/doro/icon.png',
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
  static const _mouseGazeResetDelay = Duration(milliseconds: 1600);
  static const _touchGazeResetDelay = Duration(milliseconds: 900);
  static const _mouseExitResetDelay = Duration(milliseconds: 350);

  late final AnimationController _animController;
  Offset _touchRipplePos = Offset.zero;
  bool _showRipple = false;
  Timer? _rippleTimer;
  final List<AmbientBubble> _ambientBubbles = [];
  Timer? _ambientTimer;
  Timer? _gazeResetTimer;

  @override
  void initState() {
    super.initState();
    _initAmbientBubbles();
    _startAmbientMotion();
    _animController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 4),
    )..repeat();
  }

  void _initAmbientBubbles() {
    final random = math.Random();
    for (var i = 0; i < 8; i++) {
      _ambientBubbles.add(
        AmbientBubble(
          x: random.nextDouble(),
          y: random.nextDouble(),
          size: 4 + random.nextDouble() * 12,
          speed: 0.0003 + random.nextDouble() * 0.0005,
          opacity: 0.08 + random.nextDouble() * 0.1,
          wobblePhase: random.nextDouble() * math.pi * 2,
        ),
      );
    }
  }

  void _startAmbientMotion() {
    double t = 0.0;
    _ambientTimer = Timer.periodic(const Duration(milliseconds: 50), (_) {
      if (!mounted) return;
      t += 0.05;
      setState(() {
        for (final b in _ambientBubbles) {
          b.y -= b.speed * 10;
          b.x += math.sin(t + b.wobblePhase) * 0.001;
          // Wrap around when reaching the top
          if (b.y < -0.05) {
            b.y = 1.05;
            b.x = math.Random().nextDouble();
          }
          if (b.x < -0.05) b.x = 1.05;
          if (b.x > 1.05) b.x = -0.05;
        }
      });
    });
  }

  @override
  void dispose() {
    _rippleTimer?.cancel();
    _ambientTimer?.cancel();
    _gazeResetTimer?.cancel();
    _animController.dispose();
    super.dispose();
  }

  void _onTapDown(TapDownDetails details, Size size) {
    setState(() {
      _touchRipplePos = details.localPosition;
      _showRipple = true;
    });

    widget.controller.handleTap(details.localPosition, size);
    _trackGaze(details.localPosition, size);
    _scheduleGazeReset(_touchGazeResetDelay);

    _rippleTimer?.cancel();
    _rippleTimer = Timer(const Duration(milliseconds: 300), () {
      if (mounted) {
        setState(() => _showRipple = false);
      }
    });
  }

  void _onDragStart(DragStartDetails details) {
    if (!widget.enableTouchTracking) return;
    widget.controller.startDrag(details.localPosition);
  }

  void _onDragUpdate(DragUpdateDetails details, Size size) {
    if (!widget.enableTouchTracking) return;
    widget.controller.updateDrag(details.localPosition);
    _trackGaze(details.localPosition, size);
    _gazeResetTimer?.cancel();
  }

  void _onDragEnd(DragEndDetails details) {
    if (!widget.enableTouchTracking) return;
    widget.controller.endDrag();
    _scheduleGazeReset(_touchGazeResetDelay);
  }

  void _trackGaze(Offset localPosition, Size size) {
    if (!widget.enableTouchTracking || size.width <= 0 || size.height <= 0) {
      return;
    }
    final normalizedX = ((localPosition.dx / size.width) * 2 - 1).clamp(
      -1.0,
      1.0,
    );
    final normalizedY = ((localPosition.dy / size.height) * 2 - 1).clamp(
      -1.0,
      1.0,
    );
    widget.controller.lookAt(normalizedX, normalizedY);
  }

  void _scheduleGazeReset(Duration delay) {
    _gazeResetTimer?.cancel();
    _gazeResetTimer = Timer(delay, widget.controller.resetGaze);
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
              // Ambient background bubbles
              Positioned.fill(
                child: IgnorePointer(
                  child: CustomPaint(
                    painter: AmbientBubblePainter(bubbles: _ambientBubbles),
                  ),
                ),
              ),
              // 1. Interactive Doro Live2D Character Viewport
              Positioned(
                bottom: 0,
                child: GestureDetector(
                  onTapDown: (details) => _onTapDown(details, effectiveSize),
                  onPanStart: _onDragStart,
                  onPanUpdate: (details) =>
                      _onDragUpdate(details, effectiveSize),
                  onPanEnd: _onDragEnd,
                  child: AnimatedBuilder(
                    animation: _animController,
                    builder: (context, _) {
                      final t = _animController.value * 2 * math.pi;
                      final breathOffsetY =
                          math.sin(t) * 3.0 + math.sin(t * 2.7) * 1.2;
                      final breathScaleY = 1.0 + math.sin(t) * 0.02;

                      // Physical motion variables
                      double motionScaleX = 1.0;
                      double motionScaleY = 1.0;
                      double bodyAngle =
                          widget.controller.lookAtX * 0.035 +
                          widget.controller.idleSway;
                      double headAngle =
                          widget.controller.lookAtX * 0.08 +
                          widget.controller.idleSway * 0.5;

                      final motion = widget.controller.activeMotion;
                      if (motion == 'lift') {
                        motionScaleX = 0.98;
                        motionScaleY = 1.04;
                        bodyAngle += 0.025;
                      } else if (motion == 'spring_back') {
                        final progress = 1 - _animController.value * 4 % 1;
                        bodyAngle += math.sin(progress * math.pi) * 0.06;
                        motionScaleY = 1 + math.sin(progress * math.pi) * 0.04;
                      } else if (motion == 'scan_inventory' ||
                          motion == 'look_at_results' ||
                          motion == 'present_results' ||
                          motion == 'focus_post') {
                        bodyAngle += 0.05;
                        headAngle += 0.05;
                      } else if (motion == 'careful_review' ||
                          motion == 'confirm_understanding' ||
                          motion == 'apologize' ||
                          motion == 'no_results') {
                        bodyAngle -= 0.035;
                        motionScaleY = 0.98;
                      } else if (motion == 'poke_belly') {
                        motionScaleX = 1.14;
                        motionScaleY = 0.86;
                      } else if (motion == 'tap_head') {
                        headAngle += 0.08;
                        motionScaleX = 0.95;
                        motionScaleY = 1.05;
                      } else if (motion == 'lean_forward' ||
                          motion == 'think') {
                        motionScaleX = 1.03;
                        motionScaleY = 0.98;
                      }

                      final lookX =
                          widget.controller.lookAtX * (widget.size * 0.05);
                      final lookY =
                          widget.controller.lookAtY * (widget.size * 0.03);
                      final dragOffset = widget.controller.isDragging
                          ? widget.controller.dragOffset
                          : Offset.zero;

                      return Transform.translate(
                        offset: Offset(
                          lookX + dragOffset.dx,
                          breathOffsetY + lookY + dragOffset.dy,
                        ),
                        child: Transform.rotate(
                          angle: bodyAngle,
                          child: Transform.scale(
                            scaleX: motionScaleX,
                            scaleY: motionScaleY * breathScaleY,
                            child: Transform.translate(
                              offset: Offset(-lookX * 0.35, -lookY * 0.25),
                              child: Transform.rotate(
                                angle: headAngle - bodyAngle,
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
                                            borderRadius: BorderRadius.circular(
                                              100,
                                            ),
                                            boxShadow: [
                                              BoxShadow(
                                                color: const Color(
                                                  0xFF0F766E,
                                                ).withValues(alpha: 0.18),
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
                                        borderRadius: BorderRadius.circular(
                                          widget.size * 0.28,
                                        ),
                                        child: RepaintBoundary(
                                          child: Image.asset(
                                            widget.modelAssetPath,
                                            width: effectiveSize.width * 0.96,
                                            height: effectiveSize.height * 0.96,
                                            fit: BoxFit.contain,
                                            errorBuilder:
                                                (
                                                  context,
                                                  error,
                                                  stackTrace,
                                                ) => Image.asset(
                                                  'assets/characters/xiaochang.png',
                                                  width:
                                                      effectiveSize.width *
                                                      0.92,
                                                  height:
                                                      effectiveSize.height *
                                                      0.92,
                                                  fit: BoxFit.contain,
                                                ),
                                          ),
                                        ),
                                      ),

                                      // Lip-Sync Dynamic Mouth Overlay during SSE streaming speech
                                      if (widget.controller.mouthOpen > 0.05)
                                        Positioned(
                                          bottom: effectiveSize.height * 0.28,
                                          child: _buildDynamicMouth(
                                            widget.controller.mouthOpen,
                                          ),
                                        ),

                                      // Blink overlay
                                      if (widget.controller.isBlinking)
                                        Positioned(
                                          top: effectiveSize.height * 0.18,
                                          left: effectiveSize.width * 0.22,
                                          right: effectiveSize.width * 0.22,
                                          child: IgnorePointer(
                                            child: Container(
                                              height:
                                                  effectiveSize.height * 0.04,
                                              decoration: BoxDecoration(
                                                color: const Color(
                                                  0xFF134E4A,
                                                ).withValues(alpha: 0.0),
                                                borderRadius:
                                                    BorderRadius.circular(100),
                                              ),
                                            ),
                                          ),
                                        ),

                                      // Shy / Happy Blushing Emotion Overlay
                                      if (widget.controller.expression ==
                                              Live2DExpression.shy ||
                                          widget.controller.expression ==
                                              Live2DExpression.happy)
                                        Positioned.fill(
                                          child: _buildBlushOverlay(
                                            effectiveSize,
                                          ),
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
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
              if (widget.enableTouchTracking)
                Positioned(
                  bottom: 0,
                  width: effectiveSize.width,
                  height: effectiveSize.height,
                  child: MouseRegion(
                    opaque: false,
                    hitTestBehavior: HitTestBehavior.translucent,
                    onHover: (event) {
                      _trackGaze(event.localPosition, effectiveSize);
                      _scheduleGazeReset(_mouseGazeResetDelay);
                    },
                    onExit: (_) => _scheduleGazeReset(_mouseExitResetDelay),
                    child: const SizedBox.expand(),
                  ),
                ),

              // Particle effects overlay
              Positioned.fill(
                child: IgnorePointer(
                  child: ListenableBuilder(
                    listenable: widget.controller.particleSystem,
                    builder: (context, _) {
                      return CustomPaint(
                        painter: Live2DParticlePainter(
                          particles: widget.controller.particleSystem.particles,
                        ),
                      );
                    },
                  ),
                ),
              ),

              // 2. Dynamic Speech Bubble Overlay (Talking Tom Dialogue)
              if (widget.showSpeechBubble &&
                  speech != null &&
                  speech.isNotEmpty)
                Positioned(top: 0, child: _buildSpeechBubble(speech)),
            ],
          ),
        );
      },
    );
  }

  Widget _buildDynamicMouth(double mouthOpen) {
    final height = 4.0 + 14.0 * mouthOpen;
    final width = 12.0 + 8.0 * mouthOpen;

    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: const Color(0xFFB91C1C).withValues(alpha: 0.85),
        borderRadius: BorderRadius.circular(height * 0.6),
        border: Border.all(
          color: const Color(0xFF134E4A).withValues(alpha: 0.7),
          width: 1.2,
        ),
      ),
      child: Center(
        child: Container(
          width: width * 0.55,
          height: height * 0.35,
          decoration: BoxDecoration(
            color: const Color(0xFFFCA5A5).withValues(alpha: 0.9),
            borderRadius: BorderRadius.circular(height * 0.3),
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
                color: const Color(0xFFF9A8D4).withValues(alpha: 0.45),
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
                color: const Color(0xFFF9A8D4).withValues(alpha: 0.45),
                borderRadius: BorderRadius.circular(100),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSpeechBubble(String text) {
    final scheme = Theme.of(context).colorScheme;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0.0, end: 1.0),
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOutBack,
      builder: (context, val, child) {
        return Transform.scale(
          scale: val,
          alignment: Alignment.bottomCenter,
          child: Container(
            key: const Key('live2d-speech-bubble'),
            constraints: BoxConstraints(
              maxWidth: math.max(widget.size * 1.15, 260),
              maxHeight: 160,
            ),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHigh.withValues(alpha: 0.96),
              borderRadius: BorderRadius.circular(18),
              border: Border.all(
                color: scheme.primary.withValues(alpha: 0.42),
                width: 1.5,
              ),
              boxShadow: [
                BoxShadow(
                  color: scheme.shadow.withValues(alpha: 0.24),
                  blurRadius: 14,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: SingleChildScrollView(
              physics: const BouncingScrollPhysics(),
              child: Text(
                text,
                style: TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w600,
                  color: scheme.onSurface,
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
    return CustomPaint(painter: _TouchRipplePainter(pos: _touchRipplePos));
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
