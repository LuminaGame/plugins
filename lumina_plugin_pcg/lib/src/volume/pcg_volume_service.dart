import 'package:lumina_editor_api/lumina_editor_api.dart';

import 'package:lumina_plugin_pcg/src/eval/pcg_evaluator.dart';
import 'package:lumina_plugin_pcg/src/model/pcg_graph.dart';
import 'package:lumina_plugin_pcg/src/model/pcg_graph_asset.dart';
import 'package:lumina_plugin_pcg/src/model/pcg_surface.dart';
import 'package:lumina_plugin_pcg/src/volume/pcg_volume.dart';

/// What one Generate did.
class PcgGenerateReport {
  final String volumeId;
  final int removed;
  final int spawned;
  final String surface;
  final List<String> warnings;
  final String? error;

  const PcgGenerateReport({
    required this.volumeId,
    this.removed = 0,
    this.spawned = 0,
    this.surface = '',
    this.warnings = const [],
    this.error,
  });

  bool get ok => error == null;
}

/// Generate / Cleanup over the open level: the editor-side half of a PCG
/// Volume.
///
/// Every instance is an ordinary `StaticMesh` actor parented under the
/// volume and tagged with [PcgTypes.generatedTag], so the viewport, PIE,
/// code generation and the packaged game need nothing PCG-specific.
class PcgVolumeService {
  final EditorLevelAccess level;
  final PcgEvaluator evaluator;

  PcgVolumeService(this.level, {this.evaluator = const PcgEvaluator()});

  static const String logSource = 'PCG';

  /// Every PCG Volume in the level.
  List<EditorActorSnapshot> get volumes => [for (final a in level.actors) if (a.type == PcgTypes.volumeActor) a];

  /// The instances [volumeId] generated.
  List<EditorActorSnapshot> generatedBy(String volumeId) =>
      [for (final a in level.actors) if (PcgVolumeSettings.isGenerated(a, volumeId: volumeId)) a];

  /// Places a new PCG Volume at [location] and returns its id.
  Future<String> placeVolume({
    required List<double> location,
    String graphPath = '',
    int seed = 1,
    String? name,
  }) async {
    final count = volumes.length + 1;
    final ids = await level.addActors(
      [PcgVolumeSettings.spec(name: name ?? 'PCGVolume_$count', location: location, graphPath: graphPath, seed: seed)],
      label: 'Place PCG Volume',
    );
    level.selectActors(ids);
    level.log('Placed PCG Volume ${name ?? 'PCGVolume_$count'} at ${location.map((v) => v.toStringAsFixed(0)).join(', ')} cm',
        source: logSource);
    return ids.first;
  }

  /// The surface the volume samples: every Landscape actor's heightmap, then
  /// the volume floor.
  PcgCompositeSurface surfaceFor(EditorActorSnapshot volume, PcgVolumeBounds bounds) {
    final landscapes = <PcgLandscapeSurface>[];
    for (final a in level.actors) {
      final s = PcgLandscapeSurface.fromActor(a);
      if (s != null) landscapes.add(s);
    }
    return PcgCompositeSurface(landscapes: landscapes, floor: PcgFloorSurface(bounds.minZ));
  }

  PcgVolumeBounds boundsOf(EditorActorSnapshot volume, PcgVolumeSettings settings) {
    double s(int i) => volume.scale.length > i ? volume.scale[i] : 1.0;
    return PcgVolumeBounds(
      center: List<double>.from(volume.location),
      size: [settings.sizeX * s(0), settings.sizeY * s(1), settings.sizeZ * s(2)],
    );
  }

  /// Evaluates the volume's graph without touching the level.
  PcgEvaluationResult? preview(EditorActorSnapshot volume, {PcgGraph? graph}) {
    final settings = PcgVolumeSettings.of(volume);
    if (settings == null) return null;
    final g = graph ?? PcgGraphAsset.load(PcgGraphAsset.absolute(level.projectDirPath, settings.graphPath));
    if (g == null) return null;
    final bounds = boundsOf(volume, settings);
    return evaluator.evaluate(g, _context(volume, settings, bounds));
  }

  PcgEvaluationContext _context(EditorActorSnapshot volume, PcgVolumeSettings settings, PcgVolumeBounds bounds) {
    final obstacles = [
      for (final a in level.actors)
        if (a.id != volume.id && a.type != PcgTypes.volumeActor && !PcgVolumeSettings.isGenerated(a)) a,
    ];
    return PcgEvaluationContext(bounds: bounds, seed: settings.seed, surface: surfaceFor(volume, bounds), obstacles: obstacles);
  }

  /// Re-generates [volumeId]: removes what it generated before, evaluates its
  /// graph and places the instances. Deterministic for a given seed.
  Future<PcgGenerateReport> generate(String volumeId) async {
    final volume = _volume(volumeId);
    if (volume == null) return PcgGenerateReport(volumeId: volumeId, error: 'Actor $volumeId is not a PCG Volume');
    final settings = PcgVolumeSettings.of(volume)!;
    if (settings.graphPath.isEmpty) {
      return PcgGenerateReport(volumeId: volumeId, error: '${volume.name} has no PCG Graph; pick one in Details');
    }
    final graphFile = PcgGraphAsset.absolute(level.projectDirPath, settings.graphPath);
    final graph = PcgGraphAsset.load(graphFile);
    if (graph == null) {
      return PcgGenerateReport(volumeId: volumeId, error: 'PCG Graph not found or unreadable: ${settings.graphPath}');
    }

    final bounds = boundsOf(volume, settings);
    final context = _context(volume, settings, bounds);
    final PcgEvaluationResult result;
    try {
      result = evaluator.evaluate(graph, context);
    } on StateError catch (e) {
      return PcgGenerateReport(volumeId: volumeId, error: e.message);
    }
    for (final w in result.warnings) {
      level.log(w, level: 'warning', source: logSource);
    }

    final stale = generatedBy(volumeId).map((a) => a.id).toList();
    if (stale.isNotEmpty) level.removeActors(stale, label: 'PCG Cleanup ${volume.name}');

    final specs = <EditorActorSpec>[];
    for (var i = 0; i < result.instances.length; i++) {
      final inst = result.instances[i];
      final meshName = inst.meshPath.split('/').last.split('.').first;
      specs.add(EditorActorSpec(
        id: '${volume.id}_pcg_$i',
        name: '${meshName}_${i + 1}',
        type: 'StaticMesh',
        parentId: volume.id,
        location: inst.location,
        rotation: inst.rotation,
        scale: inst.scale,
        meshAssetPath: PcgGraphAsset.absolute(level.projectDirPath, inst.meshPath),
        components: [
          const EditorComponentSpec(type: 'LuminaMeshComponent', name: 'Mesh Component'),
          EditorComponentSpec(
            type: PcgTypes.generatedTag,
            name: 'PCG Generated',
            properties: {PcgTypes.propSourceVolume: volume.id, PcgTypes.propSeed: inst.seed},
          ),
        ],
      ));
    }
    if (specs.isNotEmpty) await level.addActors(specs, label: 'PCG Generate ${volume.name}');
    level.setComponentProperty(volume.id, PcgTypes.component, PcgTypes.propInstanceCount, specs.length, label: 'PCG instance count');
    final surface = context.surface.describe;
    level.log(
      'Generated ${specs.length} instances for ${volume.name} (seed ${settings.seed}, ${graph.nodes.length} nodes, on $surface; removed $stale.length stale)'
          .replaceAll('\$stale.length', '${stale.length}'),
      level: 'success',
      source: logSource,
    );
    return PcgGenerateReport(volumeId: volumeId, removed: stale.length, spawned: specs.length, surface: surface, warnings: result.warnings);
  }

  /// Removes everything [volumeId] generated.
  PcgGenerateReport cleanup(String volumeId) {
    final volume = _volume(volumeId);
    if (volume == null) return PcgGenerateReport(volumeId: volumeId, error: 'Actor $volumeId is not a PCG Volume');
    final stale = generatedBy(volumeId).map((a) => a.id).toList();
    if (stale.isNotEmpty) level.removeActors(stale, label: 'PCG Cleanup ${volume.name}');
    level.setComponentProperty(volume.id, PcgTypes.component, PcgTypes.propInstanceCount, 0, label: 'PCG instance count');
    level.log('Cleaned up ${stale.length} instances of ${volume.name}', source: logSource);
    return PcgGenerateReport(volumeId: volumeId, removed: stale.length);
  }

  /// Generate on every volume (Tools → PCG → Generate All).
  Future<List<PcgGenerateReport>> generateAll() async {
    final reports = <PcgGenerateReport>[];
    for (final v in volumes) {
      final r = await generate(v.id);
      if (!r.ok) level.log(r.error!, level: 'warning', source: logSource);
      reports.add(r);
    }
    if (reports.isEmpty) level.log('No PCG Volumes in the level', level: 'warning', source: logSource);
    return reports;
  }

  /// Cleanup on every volume.
  List<PcgGenerateReport> cleanupAll() => [for (final v in volumes) cleanup(v.id)];

  EditorActorSnapshot? _volume(String id) {
    for (final a in level.actors) {
      if (a.id == id && a.type == PcgTypes.volumeActor) return a;
    }
    return null;
  }
}
