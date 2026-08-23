import 'dart:math' as math;
import 'dart:async';

import 'package:flutter/material.dart';

/// Particle types spawned by character interactions.
enum Live2DParticleType { heart, star, bubble, sparkle }

/// A single visual particle that floats upward and fades out.
class Live2DParticle {
  Live2DParticle({
    required this.type,
    required this.x,
    required this.y,
    required this.velocityX,
    required this.velocityY,
    required this.size,
    required this.life,
    required this.maxLife,
    required this.color,
    required this.rotation,
    required this.rotationSpeed,
  });

  final Live2DParticleType type;
  double x;
  double y;
  double velocityX;
  double velocityY;
  double size;
  double life;
  double maxLife;
  Color color;
  double rotation;
  double rotationSpeed;

  double get opacity => (life / maxLife).clamp(0.0, 1.0);
}

/// Manages spawning and updating visual particles for character interactions.
class Live2DParticleSystem extends ChangeNotifier {
  Live2DParticleSystem({this.maxParticles = 40});

  final int maxParticles;
  final List<Live2DParticle> particles = [];
  final math.Random _random = math.Random();
  Timer? _updateTimer;

  void start() {
    _updateTimer?.cancel();
    _updateTimer = Timer.periodic(const Duration(milliseconds: 16), (_) {
      _update();
    });
  }

  void _update() {
    if (particles.isEmpty) return;
    particles.removeWhere((p) => p.life <= 0);
    for (final p in particles) {
      p.x += p.velocityX;
      p.y += p.velocityY;
      p.velocityY += 0.02;
      p.rotation += p.rotationSpeed;
      p.life -= 0.016;
    }
    notifyListeners();
  }

  void spawnBurst({
    required Live2DParticleType type,
    required double x,
    required double y,
    int count = 5,
    Color? color,
  }) {
    for (var i = 0; i < count && particles.length < maxParticles; i++) {
      final angle = _random.nextDouble() * math.pi * 2;
      final speed = 0.5 + _random.nextDouble() * 1.5;
      particles.add(
        Live2DParticle(
          type: type,
          x: x + (_random.nextDouble() - 0.5) * 20,
          y: y + (_random.nextDouble() - 0.5) * 20,
          velocityX: math.cos(angle) * speed,
          velocityY: math.sin(angle) * speed - 1.0,
          size: 4 + _random.nextDouble() * 8,
          life: 1.0 + _random.nextDouble() * 0.5,
          maxLife: 1.0 + _random.nextDouble() * 0.5,
          color: color ?? _defaultColor(type),
          rotation: _random.nextDouble() * math.pi * 2,
          rotationSpeed: (_random.nextDouble() - 0.5) * 0.2,
        ),
      );
    }
    notifyListeners();
  }

  Color _defaultColor(Live2DParticleType type) {
    switch (type) {
      case Live2DParticleType.heart:
        return const Color(0xFFF9A8D4);
      case Live2DParticleType.star:
        return const Color(0xFFFDE68A);
      case Live2DParticleType.bubble:
        return const Color(0xFF93C5FD);
      case Live2DParticleType.sparkle:
        return const Color(0xFFFEF3C7);
    }
  }

  void clear() {
    particles.clear();
    notifyListeners();
  }

  @override
  void dispose() {
    _updateTimer?.cancel();
    super.dispose();
  }
}

/// Custom painter that renders all active particles on the canvas.
class Live2DParticlePainter extends CustomPainter {
  Live2DParticlePainter({required this.particles});

  final List<Live2DParticle> particles;

  @override
  void paint(Canvas canvas, Size size) {
    for (final p in particles) {
      final paint = Paint()
        ..color = p.color.withValues(alpha: p.opacity)
        ..style = PaintingStyle.fill;

      canvas.save();
      canvas.translate(p.x, p.y);
      canvas.rotate(p.rotation);

      switch (p.type) {
        case Live2DParticleType.heart:
          _drawHeart(canvas, paint, p.size);
        case Live2DParticleType.star:
          _drawStar(canvas, paint, p.size);
        case Live2DParticleType.bubble:
          canvas.drawCircle(Offset.zero, p.size * 0.5, paint);
          paint.style = PaintingStyle.stroke;
          paint.strokeWidth = 1.5;
          canvas.drawCircle(Offset.zero, p.size * 0.5, paint);
        case Live2DParticleType.sparkle:
          _drawSparkle(canvas, paint, p.size);
      }

      canvas.restore();
    }
  }

  void _drawHeart(Canvas canvas, Paint paint, double size) {
    final path = Path()
      ..moveTo(0, size * 0.3)
      ..cubicTo(-size * 0.5, -size * 0.3, 0, -size * 0.6, 0, -size * 0.15)
      ..cubicTo(0, -size * 0.6, size * 0.5, -size * 0.3, 0, size * 0.3)
      ..close();
    canvas.drawPath(path, paint);
  }

  void _drawStar(Canvas canvas, Paint paint, double size) {
    final path = Path();
    for (var i = 0; i < 5; i++) {
      final angle = -math.pi / 2 + i * 2 * math.pi / 5;
      final outerX = math.cos(angle) * size * 0.5;
      final outerY = math.sin(angle) * size * 0.5;
      if (i == 0) {
        path.moveTo(outerX, outerY);
      } else {
        path.lineTo(outerX, outerY);
      }
      final innerAngle = angle + math.pi / 5;
      path.lineTo(
        math.cos(innerAngle) * size * 0.2,
        math.sin(innerAngle) * size * 0.2,
      );
    }
    path.close();
    canvas.drawPath(path, paint);
  }

  void _drawSparkle(Canvas canvas, Paint paint, double size) {
    canvas.drawLine(
      Offset(-size * 0.5, 0),
      Offset(size * 0.5, 0),
      paint..strokeWidth = size * 0.15,
    );
    canvas.drawLine(
      Offset(0, -size * 0.5),
      Offset(0, size * 0.5),
      paint..strokeWidth = size * 0.15,
    );
  }

  @override
  bool shouldRepaint(covariant Live2DParticlePainter oldDelegate) => true;
}

/// A slow-moving ambient bubble that floats across the background.
class AmbientBubble {
  AmbientBubble({
    required this.x,
    required this.y,
    required this.size,
    required this.speed,
    required this.opacity,
    required this.wobblePhase,
  });

  double x;
  double y;
  double size;
  double speed;
  double opacity;
  double wobblePhase;
}

/// Custom painter that renders ambient background bubbles.
class AmbientBubblePainter extends CustomPainter {
  AmbientBubblePainter({required this.bubbles});

  final List<AmbientBubble> bubbles;

  @override
  void paint(Canvas canvas, Size size) {
    for (final b in bubbles) {
      final strokePaint = Paint()
        ..style = PaintingStyle.stroke
        ..color = const Color(0xFF0F766E).withValues(alpha: b.opacity)
        ..strokeWidth = 1.5;
      canvas.drawCircle(Offset(b.x, b.y), b.size, strokePaint);
      final fillPaint = Paint()
        ..style = PaintingStyle.fill
        ..color = const Color(0xFFE1F4EF).withValues(alpha: b.opacity * 0.3);
      canvas.drawCircle(
        Offset(b.x - b.size * 0.25, b.y - b.size * 0.25),
        b.size * 0.2,
        fillPaint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant AmbientBubblePainter oldDelegate) => true;
}
