import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_core/lumina_core.dart';
import 'package:lumina_editor_api/lumina_editor_api.dart';
import 'package:lumina_plugin_pcg/lumina_plugin_pcg.dart';

const _meshA = 'contents/meshes/fuel_barrel_red.glb';
const _meshB = 'contents/meshes/dented_barrel.glb';

PcgEvaluationContext _floorContext({
  int seed = 7,
  List<double> center = const [0.0, 0.0, 0.0],
  List<double> size = const [2000.0, 2000.0, 500.0],
  List<EditorActorSnapshot> obstacles = const [],
  List<PcgLandscapeSurface> landscapes = const [],
}) {
  final bounds = PcgVolumeBounds(center: center, size: size);
  return PcgEvaluationContext(
    bounds: bounds,
    seed: seed,
    surface: PcgCompositeSurface(landscapes: landscapes, floor: PcgFloorSurface(bounds.minZ)),
    obstacles: obstacles,
  );
}

PcgGraph _chain(List<PcgNode> nodes) {
  final g = PcgGraph(name: 'T', nodes: nodes);
  g.relinkAsChain();
  return g;
}

PcgNode _sampler({double cell = 200.0, double looseness = 0.5, double maxSlope = 45.0}) =>
    PcgNode(id: 'sampler', type: PcgNodeType.surfaceSampler, params: {'cellSize': cell, 'looseness': looseness, 'maxSlopeDegrees': maxSlope});

PcgNode _spawner([List<PcgMeshEntry> meshes = const [PcgMeshEntry(path: _meshA)]]) =>
    PcgNode(id: 'spawner', type: PcgNodeType.staticMeshSpawner, params: {'meshes': meshes.map((m) => m.toJson()).toList()});

void main() {
  const evaluator = PcgEvaluator();

  test('Surface Sampler: a 2000 cm volume at 200 cm cells yields a 10×10 grid on the floor, inside the bounds', () {
    final g = _chain([PcgNode(id: 'surface', type: PcgNodeType.getSurfaceData), _sampler(looseness: 0.0), _spawner()]);
    final ctx = _floorContext(center: [500.0, -300.0, 100.0]);
    final r = evaluator.evaluate(g, ctx);
    expect(r.pointCountByNode['sampler'], 100);
    expect(r.instances, hasLength(100));
    for (final i in r.instances) {
      expect(i.location[0], inInclusiveRange(ctx.bounds.minX, ctx.bounds.maxX));
      expect(i.location[1], inInclusiveRange(ctx.bounds.minY, ctx.bounds.maxY));
      expect(i.location[2], closeTo(100.0 - 250.0, 1e-9), reason: 'points sit on the volume floor');
      expect(i.meshPath, _meshA);
    }
    // looseness 0: an exact, centred grid.
    final xs = r.instances.map((i) => i.location[0]).toSet().toList()..sort();
    expect(xs.first, closeTo(500.0 - 900.0, 1e-9));
    expect(xs.last, closeTo(500.0 + 900.0, 1e-9));
    expect(xs, hasLength(10));
  });

  test('seed reproducibility: same seed → identical instances in order; another seed → different jitter', () {
    final g = _chain([_sampler(), PcgNode(id: 'transform', type: PcgNodeType.transformPoints), _spawner()]);
    final a = evaluator.evaluate(g, _floorContext(seed: 11)).instances;
    final b = evaluator.evaluate(g, _floorContext(seed: 11)).instances;
    final c = evaluator.evaluate(g, _floorContext(seed: 12)).instances;
    expect(a.length, b.length);
    for (var i = 0; i < a.length; i++) {
      expect(a[i].location, b[i].location);
      expect(a[i].rotation, b[i].rotation);
      expect(a[i].scale, b[i].scale);
      expect(a[i].seed, b[i].seed);
    }
    expect(c.length, a.length);
    expect(c.map((i) => i.location).toList(), isNot(a.map((i) => i.location).toList()));
  });

  test('looseness jitters within half a cell; Transform Points honours its ranges', () {
    final g = _chain([
      _sampler(looseness: 1.0),
      PcgNode(id: 'transform', type: PcgNodeType.transformPoints, params: {
        'rotationMin': [0.0, 0.0, 10.0],
        'rotationMax': [0.0, 0.0, 20.0],
        'scaleMin': 0.5,
        'scaleMax': 0.6,
        'uniformScale': true,
        'offsetMin': [0.0, 0.0, -5.0],
        'offsetMax': [0.0, 0.0, 5.0],
      }),
      _spawner(),
    ]);
    final loose = evaluator.evaluate(g, _floorContext(seed: 3)).instances;
    final tight = evaluator.evaluate(_chain([_sampler(looseness: 0.0), _spawner()]), _floorContext(seed: 3)).instances;
    expect(loose, hasLength(tight.length));
    var moved = 0;
    for (var i = 0; i < loose.length; i++) {
      final dx = (loose[i].location[0] - tight[i].location[0]).abs();
      final dy = (loose[i].location[1] - tight[i].location[1]).abs();
      expect(dx, lessThanOrEqualTo(100.0 + 1e-9));
      expect(dy, lessThanOrEqualTo(100.0 + 1e-9));
      if (dx > 1e-6 || dy > 1e-6) moved++;
      expect(loose[i].rotation[2], inInclusiveRange(10.0, 20.0));
      expect(loose[i].rotation[0], 0.0);
      expect(loose[i].scale[0], inInclusiveRange(0.5, 0.6));
      expect(loose[i].scale[0], loose[i].scale[1], reason: 'uniform scale');
      expect(loose[i].location[2] - tight[i].location[2], inInclusiveRange(-5.0, 5.0));
    }
    expect(moved, greaterThan(loose.length ~/ 2));
    final nonUniform = evaluator
        .evaluate(
          _chain([
            _sampler(),
            PcgNode(id: 't', type: PcgNodeType.transformPoints, params: {'scaleMin': 0.5, 'scaleMax': 2.0, 'uniformScale': false}),
            _spawner(),
          ]),
          _floorContext(),
        )
        .instances;
    expect(nonUniform.any((i) => i.scale[0] != i.scale[1]), isTrue);
  });

  test('Density Noise writes [0, 1] densities and Density Filter keeps only the band', () {
    final g = _chain([
      _sampler(cell: 100.0),
      PcgNode(id: 'noise', type: PcgNodeType.densityNoise, params: {'noiseScale': 600.0}),
      PcgNode(id: 'filter', type: PcgNodeType.densityFilter, params: {'minDensity': 0.5, 'maxDensity': 1.0}),
      _spawner(),
    ]);
    final r = evaluator.evaluate(g, _floorContext(seed: 5));
    final before = r.pointCountByNode['noise']!;
    final after = r.pointCountByNode['filter']!;
    expect(before, 400);
    expect(after, greaterThan(50));
    expect(after, lessThan(before), reason: 'a 0.5 threshold on smooth noise drops a real share');
    // The same seed → the same survivors.
    expect(evaluator.evaluate(g, _floorContext(seed: 5)).instances.length, after);
    final all = evaluator.evaluate(
      _chain([_sampler(cell: 100.0), PcgNode(id: 'n', type: PcgNodeType.densityNoise), PcgNode(id: 'f', type: PcgNodeType.densityFilter, params: {'minDensity': 0.0, 'maxDensity': 1.0}), _spawner()]),
      _floorContext(seed: 5),
    );
    expect(all.instances, hasLength(400), reason: 'noise is always inside [0, 1]');
  });

  test('Difference drops points within the radius of hand-placed actors of the listed types only', () {
    const barrel = EditorActorSnapshot(id: 'b', name: 'Barrel', type: 'StaticMesh', location: [0.0, 0.0, 0.0], rotation: [0, 0, 0], scale: [1, 1, 1]);
    const light = EditorActorSnapshot(id: 'l', name: 'Sun', type: 'DirectionalLight', location: [500.0, 500.0, 0.0], rotation: [0, 0, 0], scale: [1, 1, 1]);
    final g = _chain([
      _sampler(looseness: 0.0),
      PcgNode(id: 'difference', type: PcgNodeType.difference, params: {'radius': 350.0, 'actorTypes': ['StaticMesh']}),
      _spawner(),
    ]);
    final r = evaluator.evaluate(g, _floorContext(obstacles: const [barrel, light]));
    expect(r.pointCountByNode['sampler'], 100);
    expect(r.pointCountByNode['difference'], lessThan(100));
    for (final i in r.instances) {
      final d = math.sqrt(i.location[0] * i.location[0] + i.location[1] * i.location[1]);
      expect(d, greaterThanOrEqualTo(350.0), reason: 'nothing spawns within 350 cm of the barrel');
    }
    final near = r.instances.where((i) => (i.location[0] - 500).abs() < 350 && (i.location[1] - 500).abs() < 350);
    expect(near, isNotEmpty, reason: 'a DirectionalLight is not in actorTypes, so it excludes nothing');
  });

  test('Static Mesh Spawner picks by weight, deterministically, and never a zero-weight mesh', () {
    final g = _chain([
      _sampler(cell: 50.0),
      _spawner(const [PcgMeshEntry(path: _meshA, weight: 3.0), PcgMeshEntry(path: _meshB, weight: 1.0), PcgMeshEntry(path: 'contents/meshes/never.glb', weight: 0.0)]),
    ]);
    final r = evaluator.evaluate(g, _floorContext(seed: 21));
    expect(r.instances, hasLength(1600));
    final a = r.instances.where((i) => i.meshPath == _meshA).length;
    final b = r.instances.where((i) => i.meshPath == _meshB).length;
    expect(a + b, 1600);
    expect(a / 1600, closeTo(0.75, 0.05));
    expect(r.instances.map((i) => i.meshPath).toList(), evaluator.evaluate(g, _floorContext(seed: 21)).instances.map((i) => i.meshPath).toList());
    final empty = evaluator.evaluate(_chain([_sampler(), _spawner(const [])]), _floorContext());
    expect(empty.instances, isEmpty);
    expect(empty.warnings.single, contains('no meshes'));
  });

  test('landscape projection: points land on the sampled terrain height and slopes above the limit are rejected', () {
    // A 256 m terrain with a ridge: heights 20 m + a gaussian along the
    // diagonal, exactly like lumina_ui's landscape placement test.
    final data = LandscapeData.flat(gridResolution: 129, worldSize: 256.0, maxHeight: 100.0);
    final half = 64.0;
    for (var r = 0; r < 129; r++) {
      for (var c = 0; c < 129; c++) {
        final u = (c - half) / half;
        final v = (r - half) / half;
        data.setHeight(c, r, 20.0 + math.exp(-((u - v) * (u - v)) * 6.0) * 45.0);
      }
    }
    // Landscape actor at (1000, -2000, 300) cm, scaled 2× in Z.
    const actor = EditorActorSnapshot(id: 'L', name: 'Terrain', type: 'Landscape', location: [1000.0, -2000.0, 300.0], rotation: [0, 0, 0], scale: [1.0, 1.0, 2.0]);
    final landscape = PcgLandscapeSurface(actor: actor, data: data);

    // Height mapping at the terrain centre and off-centre.
    expect(landscape.contains(1000.0, -2000.0), isTrue);
    expect(landscape.contains(1000.0 + 12801.0, -2000.0), isFalse, reason: '128 m half-size in cm');
    final hCentre = data.sampleHeight(0.0, 0.0);
    expect(landscape.heightAt(1000.0, -2000.0), closeTo(300.0 + hCentre * 100.0 * 2.0, 1e-6));
    // Stored +Y is terrain −Z (Z-up → Y-up: (x, y, z) → (x, z, −y)).
    final hOff = data.sampleHeight(30.0, -40.0);
    expect(landscape.heightAt(1000.0 + 3000.0, -2000.0 + 4000.0), closeTo(300.0 + hOff * 100.0 * 2.0, 1e-6));

    // A volume tall enough to contain the terrain heights (20–65 m ×2).
    final ctx = _floorContext(
      seed: 9,
      center: [1000.0, -2000.0, 300.0 + 8000.0],
      size: [6000.0, 6000.0, 20000.0],
      landscapes: [landscape],
    );
    final all = evaluator.evaluate(_chain([_sampler(cell: 300.0, looseness: 0.3, maxSlope: 90.0), _spawner()]), ctx);
    expect(all.instances, hasLength(400));
    for (final i in all.instances) {
      expect(i.location[2], closeTo(landscape.heightAt(i.location[0], i.location[1])!, 1e-6), reason: 'projected onto the heightmap');
      expect(i.location[2], greaterThan(300.0 + 20.0 * 100.0 * 2.0 - 1.0));
    }
    final flatOnly = evaluator.evaluate(_chain([_sampler(cell: 300.0, looseness: 0.3, maxSlope: 20.0), _spawner()]), ctx);
    expect(flatOnly.instances.length, lessThan(all.instances.length), reason: 'the ridge flanks exceed 20°');
    expect(flatOnly.instances, isNotEmpty);
    for (final i in flatOnly.instances) {
      expect(landscape.slopeAt(i.location[0], i.location[1]), lessThanOrEqualTo(20.0));
    }

    // Outside the terrain footprint the composite surface falls back to the
    // volume floor; a volume whose floor is below the terrain range but whose
    // top is too low drops the terrain points.
    final beyond = _floorContext(seed: 9, center: [40000.0, 0.0, 0.0], size: [2000.0, 2000.0, 500.0], landscapes: [landscape]);
    final floorPts = evaluator.evaluate(_chain([_sampler(looseness: 0.0), _spawner()]), beyond);
    expect(floorPts.instances, hasLength(100));
    expect(floorPts.instances.every((i) => i.location[2] == -250.0), isTrue);
    final tooLow = _floorContext(seed: 9, center: [1000.0, -2000.0, 0.0], size: [6000.0, 6000.0, 500.0], landscapes: [landscape]);
    expect(evaluator.evaluate(_chain([_sampler(), _spawner()]), tooLow).instances, isEmpty, reason: 'terrain heights (4000+ cm) lie above a 500 cm volume at z=0');
    // An explicit `floor` surface ignores the landscape.
    final floorNode = _chain([PcgNode(id: 's', type: PcgNodeType.getSurfaceData, params: {'surface': 'floor'}), _sampler(looseness: 0.0), _spawner()]);
    expect(evaluator.evaluate(floorNode, tooLow).instances, hasLength(900), reason: '6000 cm at the default 200 cm cells: a 30 × 30 grid on the floor');
    expect(PcgLandscapeSurface.fromActor(actor), isNull, reason: 'no asset path → no surface');
  });
}
