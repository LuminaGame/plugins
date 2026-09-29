import 'dart:math' as math;

import 'package:lumina_editor_api/lumina_editor_api.dart';

import '../model/pcg_graph.dart';
import '../model/pcg_point.dart';
import '../model/pcg_surface.dart';
import 'pcg_random.dart';

/// The box a PCG Volume covers, in stored space (cm, Z up): centre and full
/// extents (the actor's size × its scale).
class PcgVolumeBounds {
  final List<double> center;
  final List<double> size;

  const PcgVolumeBounds({required this.center, required this.size});

  double get minX => center[0] - size[0] / 2;
  double get maxX => center[0] + size[0] / 2;
  double get minY => center[1] - size[1] / 2;
  double get maxY => center[1] + size[1] / 2;
  double get minZ => center[2] - size[2] / 2;
  double get maxZ => center[2] + size[2] / 2;

  bool containsZ(double z) => z >= minZ - 1e-6 && z <= maxZ + 1e-6;
}

/// What a graph evaluation runs against: the volume, its seed, the surface
/// the level offers, and the hand-placed actors the Difference node avoids.
class PcgEvaluationContext {
  final PcgVolumeBounds bounds;
  final int seed;
  final PcgCompositeSurface surface;

  /// Existing actors the Difference node keeps clear of (never PCG output).
  final List<EditorActorSnapshot> obstacles;

  const PcgEvaluationContext({
    required this.bounds,
    required this.seed,
    required this.surface,
    this.obstacles = const [],
  });
}

/// The data on a graph edge.
class PcgData {
  final PcgSurface? surface;
  final List<PcgPoint> points;
  final List<PcgInstance> instances;

  const PcgData({this.surface, this.points = const [], this.instances = const []});

  PcgData copyWith({PcgSurface? surface, List<PcgPoint>? points, List<PcgInstance>? instances}) =>
      PcgData(surface: surface ?? this.surface, points: points ?? this.points, instances: instances ?? this.instances);

  /// The union of several inputs: one surface (the first), all points and
  /// all instances.
  static PcgData merge(Iterable<PcgData> inputs) {
    PcgSurface? surface;
    final points = <PcgPoint>[];
    final instances = <PcgInstance>[];
    for (final d in inputs) {
      surface ??= d.surface;
      points.addAll(d.points);
      instances.addAll(d.instances);
    }
    return PcgData(surface: surface, points: points, instances: instances);
  }
}

/// A finished evaluation: the instances every spawner produced, plus the
/// per-node point counts the editor reports.
class PcgEvaluationResult {
  final List<PcgInstance> instances;
  final Map<String, int> pointCountByNode;
  final List<String> warnings;

  const PcgEvaluationResult({required this.instances, required this.pointCountByNode, this.warnings = const []});
}

/// Evaluates a [PcgGraph] deterministically: same graph, seed, bounds and
/// level → same instances, in the same order.
class PcgEvaluator {
  const PcgEvaluator();

  PcgEvaluationResult evaluate(PcgGraph graph, PcgEvaluationContext context) {
    final outputs = <String, PcgData>{};
    final counts = <String, int>{};
    final warnings = <String>[];
    final instances = <PcgInstance>[];
    final order = graph.topologicalOrder();
    for (var index = 0; index < order.length; index++) {
      final node = order[index];
      final input = PcgData.merge(graph.inputsOf(node.id).map((id) => outputs[id] ?? const PcgData()));
      final output = _run(node, index, input, context, warnings);
      outputs[node.id] = output;
      counts[node.id] = output.points.length;
      if (node.type == PcgNodeType.staticMeshSpawner) instances.addAll(output.instances);
    }
    return PcgEvaluationResult(instances: instances, pointCountByNode: counts, warnings: warnings);
  }

  PcgData _run(PcgNode node, int index, PcgData input, PcgEvaluationContext ctx, List<String> warnings) {
    switch (node.type) {
      case PcgNodeType.getSurfaceData:
        return input.copyWith(surface: _selectSurface(node, ctx));
      case PcgNodeType.surfaceSampler:
        final surface = input.surface ?? _selectSurface(PcgNode(id: node.id, type: PcgNodeType.getSurfaceData), ctx);
        return input.copyWith(points: _sample(node, surface, ctx));
      case PcgNodeType.transformPoints:
        return input.copyWith(points: [for (final p in input.points) _transform(node, index, p)]);
      case PcgNodeType.densityNoise:
        final scale = math.max(1.0, node.number('noiseScale', 800.0));
        return input.copyWith(points: [
          for (final p in input.points)
            p.copyWith(density: PcgRandom.valueNoise(p.x / scale, p.y / scale, PcgRandom.hash([ctx.seed, index]))),
        ]);
      case PcgNodeType.densityFilter:
        final min = node.number('minDensity', 0.0);
        final max = node.number('maxDensity', 1.0);
        return input.copyWith(points: [for (final p in input.points) if (p.density >= min && p.density <= max) p]);
      case PcgNodeType.difference:
        final radius = node.number('radius', 300.0);
        final types = node.strings('actorTypes', const ['StaticMesh', 'Mesh', 'SkeletalMesh', 'Pawn', 'PlayerStart', 'Primitive']).toSet();
        final obstacles = [for (final a in ctx.obstacles) if (types.contains(a.type)) a];
        final r2 = radius * radius;
        return input.copyWith(points: [
          for (final p in input.points)
            if (!obstacles.any((a) => _distance2XY(a.location, p) < r2)) p,
        ]);
      case PcgNodeType.staticMeshSpawner:
        final meshes = node.meshes.where((m) => m.path.isNotEmpty && m.weight > 0).toList();
        if (meshes.isEmpty) {
          warnings.add('Static Mesh Spawner "${node.id}" has no meshes; nothing spawned.');
          return input.copyWith(instances: const []);
        }
        final total = meshes.fold(0.0, (s, m) => s + m.weight);
        return input.copyWith(instances: [
          for (final p in input.points)
            PcgInstance(
              meshPath: _pick(meshes, total, PcgRandom.unit(PcgRandom.hash([p.seed, index, 7]))).path,
              location: [p.x, p.y, p.z],
              rotation: List<double>.from(p.rotation),
              scale: List<double>.from(p.scale),
              seed: p.seed,
            ),
        ]);
    }
  }

  PcgSurface _selectSurface(PcgNode node, PcgEvaluationContext ctx) {
    switch (node.text('surface', 'auto')) {
      case 'floor':
        return PcgFloorSurface(ctx.bounds.minZ);
      case 'landscape':
        return PcgCompositeSurface(landscapes: ctx.surface.landscapes, floor: null);
      default:
        return ctx.surface;
    }
  }

  List<PcgPoint> _sample(PcgNode node, PcgSurface surface, PcgEvaluationContext ctx) {
    final cell = math.max(1.0, node.number('cellSize', 200.0));
    final looseness = node.number('looseness', 0.5).clamp(0.0, 1.0);
    final maxSlope = node.number('maxSlopeDegrees', 45.0);
    final b = ctx.bounds;
    final cols = math.max(1, (b.size[0] / cell).floor());
    final rows = math.max(1, (b.size[1] / cell).floor());
    // Centre the grid in the footprint so a volume of any size is sampled
    // symmetrically.
    final originX = b.center[0] - (cols - 1) * cell / 2;
    final originY = b.center[1] - (rows - 1) * cell / 2;
    final points = <PcgPoint>[];
    for (var iy = 0; iy < rows; iy++) {
      for (var ix = 0; ix < cols; ix++) {
        final seed = PcgRandom.hash([ctx.seed, ix, iy]);
        final jx = (PcgRandom.unit(PcgRandom.hash([seed, 1])) - 0.5) * cell * looseness;
        final jy = (PcgRandom.unit(PcgRandom.hash([seed, 2])) - 0.5) * cell * looseness;
        final x = originX + ix * cell + jx;
        final y = originY + iy * cell + jy;
        if (x < b.minX || x > b.maxX || y < b.minY || y > b.maxY) continue;
        final z = surface.heightAt(x, y);
        if (z == null || !b.containsZ(z)) continue;
        final slope = surface.slopeAt(x, y);
        if (slope > maxSlope) continue;
        points.add(PcgPoint(x: x, y: y, z: z, seed: seed, slopeDegrees: slope));
      }
    }
    return points;
  }

  PcgPoint _transform(PcgNode node, int index, PcgPoint p) {
    final rotMin = node.vector3('rotationMin', const [0.0, 0.0, 0.0]);
    final rotMax = node.vector3('rotationMax', const [0.0, 0.0, 360.0]);
    final scaleMin = node.number('scaleMin', 0.8);
    final scaleMax = node.number('scaleMax', 1.2);
    final uniform = node.flag('uniformScale', true);
    final offMin = node.vector3('offsetMin', const [0.0, 0.0, 0.0]);
    final offMax = node.vector3('offsetMax', const [0.0, 0.0, 0.0]);
    double r(int salt, double min, double max) => PcgRandom.range(PcgRandom.hash([p.seed, index, salt]), min, max);
    final rotation = [for (var i = 0; i < 3; i++) p.rotation[i] + r(10 + i, rotMin[i], rotMax[i])];
    final List<double> scale;
    if (uniform) {
      final s = r(20, scaleMin, scaleMax);
      scale = [for (var i = 0; i < 3; i++) p.scale[i] * s];
    } else {
      scale = [for (var i = 0; i < 3; i++) p.scale[i] * r(20 + i, scaleMin, scaleMax)];
    }
    return p.copyWith(
      x: p.x + r(30, offMin[0], offMax[0]),
      y: p.y + r(31, offMin[1], offMax[1]),
      z: p.z + r(32, offMin[2], offMax[2]),
      rotation: rotation,
      scale: scale,
    );
  }

  static double _distance2XY(List<double> a, PcgPoint p) {
    if (a.length < 2) return double.infinity;
    final dx = a[0] - p.x;
    final dy = a[1] - p.y;
    return dx * dx + dy * dy;
  }

  static PcgMeshEntry _pick(List<PcgMeshEntry> meshes, double total, double u) {
    var t = u * total;
    for (final m in meshes) {
      t -= m.weight;
      if (t < 0) return m;
    }
    return meshes.last;
  }
}
