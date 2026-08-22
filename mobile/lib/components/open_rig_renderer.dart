import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Repository-owned, editor-independent 2D mesh rig.
///
/// The runtime consumes a transparent texture plus a small JSON manifest. It
/// deliberately has no presence, message or network dependencies: callers
/// provide only a semantic motion key and normalized progress.
class OpenRigCharacter extends StatelessWidget {
  const OpenRigCharacter({
    super.key,
    required this.characterId,
    required this.size,
    required this.motionKey,
    required this.progress,
    required this.fallback,
  });

  final String characterId;
  final double size;
  final String motionKey;
  final double progress;
  final Widget fallback;

  @override
  Widget build(BuildContext context) {
    final cached = OpenRigAssetCache.getSync(characterId);
    if (cached != null) {
      return RepaintBoundary(
        child: CustomPaint(
          key: ValueKey('persona_open_rig_$characterId'),
          size: Size.square(size),
          painter: OpenRigPainter(
            asset: cached,
            motionKey: motionKey,
            progress: progress.clamp(0.0, 1.0),
          ),
        ),
      );
    }
    final future = OpenRigAssetCache.load(characterId);
    if (future == null) return fallback;
    return FutureBuilder<OpenRigAsset>(
      future: future,
      builder: (context, snapshot) {
        final asset = snapshot.data;
        if (asset == null) {
          return snapshot.hasError
              ? fallback
              : SizedBox.square(dimension: size);
        }
        return RepaintBoundary(
          child: CustomPaint(
            key: ValueKey('persona_open_rig_$characterId'),
            size: Size.square(size),
            painter: OpenRigPainter(
              asset: asset,
              motionKey: motionKey,
              progress: progress.clamp(0.0, 1.0),
            ),
          ),
        );
      },
    );
  }
}

class OpenRigAssetCache {
  OpenRigAssetCache._();

  static const manifests = <String, String>{
    'doro': 'assets/avatars/v2/open_rig/doro/rig.json',
    'gugugaga': 'assets/avatars/v2/open_rig/gugugaga/rig.json',
    'phoebe_chupi': 'assets/avatars/v2/open_rig/phoebe_chupi/rig.json',
  };
  static final Map<String, Future<OpenRigAsset>> _cache = {};
  static final Map<String, OpenRigAsset> _assets = {};

  static OpenRigAsset? getSync(String characterId) => _assets[characterId];

  static Future<OpenRigAsset>? load(String characterId) {
    final manifest = manifests[characterId];
    if (manifest == null) return null;
    return _cache.putIfAbsent(characterId, () => _load(characterId, manifest));
  }

  static Future<OpenRigAsset> _load(
    String characterId,
    String manifestAsset,
  ) async {
    final raw = jsonDecode(await rootBundle.loadString(manifestAsset));
    if (raw is! Map<String, dynamic>) {
      throw const FormatException('Open rig manifest must be an object');
    }
    final definition = OpenRigDefinition.fromJson(raw);
    final textureData = await rootBundle.load(definition.textureAsset);
    final codec = await ui.instantiateImageCodec(
      textureData.buffer.asUint8List(
        textureData.offsetInBytes,
        textureData.lengthInBytes,
      ),
      targetWidth: 512,
      targetHeight: 512,
    );
    final frame = await codec.getNextFrame();
    codec.dispose();
    final asset = OpenRigAsset(definition: definition, image: frame.image);
    _assets[characterId] = asset;
    return asset;
  }
}

class OpenRigAsset {
  const OpenRigAsset({required this.definition, required this.image});

  final OpenRigDefinition definition;
  final ui.Image image;
}

class OpenRigDefinition {
  const OpenRigDefinition({
    required this.version,
    required this.id,
    required this.textureAsset,
    required this.columns,
    required this.rows,
    required this.bones,
    required this.motions,
  });

  final int version;
  final String id;
  final String textureAsset;
  final int columns;
  final int rows;
  final List<OpenRigBone> bones;
  final Map<String, OpenRigMotion> motions;

  factory OpenRigDefinition.fromJson(Map<String, dynamic> json) {
    final grid = (json['grid'] as List<dynamic>? ?? const [10, 10])
        .map((value) => (value as num).toInt())
        .toList(growable: false);
    if (grid.length != 2 || grid.any((value) => value < 2 || value > 24)) {
      throw const FormatException(
        'Open rig grid must contain two values 2..24',
      );
    }
    final bones = (json['bones'] as List<dynamic>? ?? const [])
        .map((value) => OpenRigBone.fromJson(value as Map<String, dynamic>))
        .toList(growable: false);
    if (bones.isEmpty ||
        bones.map((bone) => bone.id).toSet().length != bones.length) {
      throw const FormatException(
        'Open rig bones must be non-empty and unique',
      );
    }
    final rawMotions =
        json['motions'] as Map<String, dynamic>? ?? const <String, dynamic>{};
    return OpenRigDefinition(
      version: (json['version'] as num?)?.toInt() ?? 1,
      id: json['id']?.toString() ?? '',
      textureAsset: json['texture']?.toString() ?? '',
      columns: grid.first,
      rows: grid.last,
      bones: bones,
      motions: {
        for (final entry in rawMotions.entries)
          entry.key: OpenRigMotion.fromJson(
            entry.value as Map<String, dynamic>,
          ),
      },
    );
  }

  OpenRigMotion? motionFor(String key) => motions[key] ?? motions['idle'];
}

class OpenRigBone {
  const OpenRigBone({
    required this.id,
    required this.pivot,
    required this.radius,
    required this.strength,
  });

  final String id;
  final Offset pivot;
  final double radius;
  final double strength;

  factory OpenRigBone.fromJson(Map<String, dynamic> json) {
    final pivot = (json['pivot'] as List<dynamic>? ?? const [0.5, 0.5])
        .map((value) => (value as num).toDouble())
        .toList(growable: false);
    if (pivot.length != 2) {
      throw const FormatException('Open rig pivot must contain x and y');
    }
    return OpenRigBone(
      id: json['id']?.toString() ?? '',
      pivot: Offset(pivot.first, pivot.last),
      radius: (json['radius'] as num?)?.toDouble() ?? 0.5,
      strength: (json['strength'] as num?)?.toDouble() ?? 1.0,
    );
  }

  double influence(Offset normalizedPoint) {
    if (radius <= 0) return 0;
    final distance = (normalizedPoint - pivot).distance;
    final normalized = (1 - distance / radius).clamp(0.0, 1.0);
    return normalized * normalized * strength;
  }
}

class OpenRigMotion {
  const OpenRigMotion({required this.loop, required this.tracks});

  final bool loop;
  final Map<String, List<OpenRigKeyframe>> tracks;

  factory OpenRigMotion.fromJson(Map<String, dynamic> json) {
    final rawTracks =
        json['tracks'] as Map<String, dynamic>? ?? const <String, dynamic>{};
    final tracks = <String, List<OpenRigKeyframe>>{};
    for (final entry in rawTracks.entries) {
      final keyframes =
          (entry.value as List<dynamic>)
              .map(
                (value) =>
                    OpenRigKeyframe.fromJson(value as Map<String, dynamic>),
              )
              .toList()
            ..sort((a, b) => a.time.compareTo(b.time));
      if (keyframes.isNotEmpty) tracks[entry.key] = keyframes;
    }
    return OpenRigMotion(loop: json['loop'] == true, tracks: tracks);
  }

  OpenRigTransform transformFor(String boneId, double progress) {
    final keyframes = tracks[boneId];
    if (keyframes == null || keyframes.isEmpty) {
      return OpenRigTransform.identity;
    }
    final p = loop ? progress % 1.0 : progress.clamp(0.0, 1.0);
    if (p <= keyframes.first.time) return keyframes.first.transform;
    if (p >= keyframes.last.time) return keyframes.last.transform;
    for (var index = 0; index < keyframes.length - 1; index += 1) {
      final from = keyframes[index];
      final to = keyframes[index + 1];
      if (p <= to.time) {
        final span = math.max(0.0001, to.time - from.time);
        final linear = ((p - from.time) / span).clamp(0.0, 1.0);
        final eased = linear * linear * (3 - 2 * linear);
        return OpenRigTransform.lerp(from.transform, to.transform, eased);
      }
    }
    return keyframes.last.transform;
  }
}

class OpenRigKeyframe {
  const OpenRigKeyframe({required this.time, required this.transform});

  final double time;
  final OpenRigTransform transform;

  factory OpenRigKeyframe.fromJson(Map<String, dynamic> json) {
    return OpenRigKeyframe(
      time: ((json['t'] as num?)?.toDouble() ?? 0).clamp(0.0, 1.0),
      transform: OpenRigTransform(
        translateX: (json['tx'] as num?)?.toDouble() ?? 0,
        translateY: (json['ty'] as num?)?.toDouble() ?? 0,
        rotation: (json['r'] as num?)?.toDouble() ?? 0,
        scaleX: (json['sx'] as num?)?.toDouble() ?? 1,
        scaleY: (json['sy'] as num?)?.toDouble() ?? 1,
      ),
    );
  }
}

class OpenRigTransform {
  const OpenRigTransform({
    required this.translateX,
    required this.translateY,
    required this.rotation,
    required this.scaleX,
    required this.scaleY,
  });

  static const identity = OpenRigTransform(
    translateX: 0,
    translateY: 0,
    rotation: 0,
    scaleX: 1,
    scaleY: 1,
  );

  final double translateX;
  final double translateY;
  final double rotation;
  final double scaleX;
  final double scaleY;

  static OpenRigTransform lerp(
    OpenRigTransform from,
    OpenRigTransform to,
    double t,
  ) {
    return OpenRigTransform(
      translateX: _lerp(from.translateX, to.translateX, t),
      translateY: _lerp(from.translateY, to.translateY, t),
      rotation: _lerp(from.rotation, to.rotation, t),
      scaleX: _lerp(from.scaleX, to.scaleX, t),
      scaleY: _lerp(from.scaleY, to.scaleY, t),
    );
  }

  static double _lerp(double from, double to, double t) =>
      from + (to - from) * t;
}

class OpenRigPainter extends CustomPainter {
  const OpenRigPainter({
    required this.asset,
    required this.motionKey,
    required this.progress,
  });

  final OpenRigAsset asset;
  final String motionKey;
  final double progress;

  @override
  void paint(Canvas canvas, Size size) {
    final definition = asset.definition;
    final motion = definition.motionFor(motionKey);
    final columns = definition.columns;
    final rows = definition.rows;
    final vertexCount = (columns + 1) * (rows + 1);
    final positions = Float32List(vertexCount * 2);
    final textureCoordinates = Float32List(vertexCount * 2);
    var vertex = 0;
    for (var row = 0; row <= rows; row += 1) {
      final y = row / rows;
      for (var column = 0; column <= columns; column += 1) {
        final x = column / columns;
        final normalized = Offset(x, y);
        final original = Offset(x * size.width, y * size.height);
        var deformed = original;
        if (motion != null) {
          for (final bone in definition.bones) {
            final weight = bone.influence(normalized).clamp(0.0, 1.0);
            if (weight <= 0) continue;
            final transform = motion.transformFor(bone.id, progress);
            final pivot = Offset(
              bone.pivot.dx * size.width,
              bone.pivot.dy * size.height,
            );
            final relative = original - pivot;
            final scaled = Offset(
              relative.dx * transform.scaleX,
              relative.dy * transform.scaleY,
            );
            final cosine = math.cos(transform.rotation);
            final sine = math.sin(transform.rotation);
            final rotated = Offset(
              scaled.dx * cosine - scaled.dy * sine,
              scaled.dx * sine + scaled.dy * cosine,
            );
            final transformed =
                pivot +
                rotated +
                Offset(
                  transform.translateX * size.width,
                  transform.translateY * size.height,
                );
            deformed += (transformed - original) * weight;
          }
        }
        positions[vertex * 2] = deformed.dx;
        positions[vertex * 2 + 1] = deformed.dy;
        textureCoordinates[vertex * 2] = x * asset.image.width;
        textureCoordinates[vertex * 2 + 1] = y * asset.image.height;
        vertex += 1;
      }
    }

    final indices = Uint16List(columns * rows * 6);
    var index = 0;
    for (var row = 0; row < rows; row += 1) {
      for (var column = 0; column < columns; column += 1) {
        final topLeft = row * (columns + 1) + column;
        final topRight = topLeft + 1;
        final bottomLeft = topLeft + columns + 1;
        final bottomRight = bottomLeft + 1;
        indices[index++] = topLeft;
        indices[index++] = bottomLeft;
        indices[index++] = topRight;
        indices[index++] = topRight;
        indices[index++] = bottomLeft;
        indices[index++] = bottomRight;
      }
    }

    final vertices = ui.Vertices.raw(
      ui.VertexMode.triangles,
      positions,
      textureCoordinates: textureCoordinates,
      indices: indices,
    );
    final matrix = Float64List(16)
      ..[0] = 1
      ..[5] = 1
      ..[10] = 1
      ..[15] = 1;
    final paint = Paint()
      ..isAntiAlias = true
      ..filterQuality = FilterQuality.medium
      ..shader = ui.ImageShader(
        asset.image,
        TileMode.clamp,
        TileMode.clamp,
        matrix,
      );
    canvas.drawVertices(vertices, BlendMode.srcOver, paint);
  }

  @override
  bool shouldRepaint(OpenRigPainter oldDelegate) =>
      oldDelegate.asset.image != asset.image ||
      oldDelegate.motionKey != motionKey ||
      oldDelegate.progress != progress;
}
