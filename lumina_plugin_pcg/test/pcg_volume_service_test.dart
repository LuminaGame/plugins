import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_editor_api/lumina_editor_api.dart';
import 'package:lumina_plugin_pcg/lumina_plugin_pcg.dart';

import 'test_support.dart';

void main() {
  late Directory project;
  late FileLevel level;
  late PcgVolumeService service;
  late List<String> barrels;

  setUp(() async {
    project = Directory.systemTemp.createTempSync('pcg_service_');
    barrels = copyBarrels(project);
    level = FileLevel(project);
    service = PcgVolumeService(level);
    final graph = PcgGraph.starter(name: 'Barrels', meshes: [for (final b in barrels) PcgMeshEntry(path: b)]);
    // Deterministic, dense enough to count: 400 cm cells, keep half by noise.
    graph.nodeById('sampler')!.params['cellSize'] = 400.0;
    graph.nodeById('filter')!.params['minDensity'] = 0.0;
    await PcgGraphAsset.save(graph, '${project.path}/contents/pcg/Barrels.lmas');
  });
  tearDown(() => project.deleteSync(recursive: true));

  test('placeVolume adds a PcgVolume actor with its component, selected', () async {
    final id = await service.placeVolume(location: [100.0, 200.0, 0.0], graphPath: 'contents/pcg/Barrels.lmas', seed: 4);
    final v = level.actors.single;
    expect(v.id, id);
    expect(v.type, PcgTypes.volumeActor);
    final s = PcgVolumeSettings.of(v)!;
    expect(s.graphPath, 'contents/pcg/Barrels.lmas');
    expect(s.seed, 4);
    expect(s.sizeX, 2000.0);
    expect(level.selected, [id]);
    expect(level.transactions.first, 'Place PCG Volume');
  });

  test('generate spawns real barrel StaticMesh actors under the volume; the level file on disk carries them', () async {
    final id = await service.placeVolume(location: [0.0, 0.0, 0.0], graphPath: 'contents/pcg/Barrels.lmas', seed: 4);
    final report = await service.generate(id);
    expect(report.ok, isTrue, reason: report.error);
    expect(report.spawned, greaterThan(0));
    expect(report.spawned, lessThanOrEqualTo(25));
    final generated = service.generatedBy(id);
    expect(generated, hasLength(report.spawned));
    for (final a in generated) {
      expect(a.type, 'StaticMesh');
      expect(a.parentId, id);
      expect(File(a.meshAssetPath!).existsSync(), isTrue, reason: 'instances reference the copied .glb on disk');
      expect(barrels.map((b) => '${project.path}/$b'), contains(a.meshAssetPath));
      expect(a.componentOfType('LuminaMeshComponent'), isNotNull);
      expect(PcgVolumeSettings.isGenerated(a, volumeId: id), isTrue);
      expect(a.location[2], closeTo(-250.0, 1e-9), reason: 'no landscape: on the volume floor');
    }
    expect(PcgVolumeSettings.of(level.actors.firstWhere((a) => a.id == id))!.instanceCount, report.spawned);
    expect(level.logs.last, contains('Generated ${report.spawned} instances'));

    await level.saveLevel();
    final json = jsonDecode(File('${project.path}/contents/levels/L_Main.lmas').readAsStringSync()) as Map;
    final actors = (json['metadata'] as Map)['actors'] as List;
    expect(actors, hasLength(1 + report.spawned));
    final onDisk = actors.where((a) => (a as Map)['type'] == 'StaticMesh').toList();
    expect(onDisk, hasLength(report.spawned));
    expect((onDisk.first as Map)['parentId'], id);
    expect(((onDisk.first as Map)['meshAssetPath'] as String), endsWith('.glb'));
  });

  test('re-generate with the same seed replaces the instances with identical ones; a new seed moves them', () async {
    final id = await service.placeVolume(location: [0.0, 0.0, 0.0], graphPath: 'contents/pcg/Barrels.lmas', seed: 4);
    final first = await service.generate(id);
    final firstLocations = service.generatedBy(id).map((a) => a.location.join(',')).toList();
    final second = await service.generate(id);
    expect(second.removed, first.spawned);
    expect(second.spawned, first.spawned);
    expect(service.generatedBy(id).map((a) => a.location.join(',')).toList(), firstLocations);
    expect(level.actors.where((a) => a.type == 'StaticMesh'), hasLength(first.spawned), reason: 'never accumulates');

    level.setComponentProperty(id, PcgTypes.component, PcgTypes.propSeed, 99);
    await service.generate(id);
    expect(service.generatedBy(id).map((a) => a.location.join(',')).toList(), isNot(firstLocations));
  });

  test('cleanup removes every generated instance and nothing else; generateAll / cleanupAll cover all volumes', () async {
    final hand = await level.addActors(const [
      EditorActorSpec(name: 'Barrel_Hand', type: 'StaticMesh', location: [0.0, 0.0, 0.0]),
    ]);
    final a = await service.placeVolume(location: [0.0, 0.0, 0.0], graphPath: 'contents/pcg/Barrels.lmas', seed: 1);
    final b = await service.placeVolume(location: [5000.0, 0.0, 0.0], graphPath: 'contents/pcg/Barrels.lmas', seed: 2);
    final reports = await service.generateAll();
    expect(reports, hasLength(2));
    expect(reports.every((r) => r.ok && r.spawned > 0), isTrue);
    expect(service.generatedBy(a), isNotEmpty);
    expect(service.generatedBy(b), isNotEmpty);
    final cleanup = service.cleanup(a);
    expect(cleanup.removed, reports[0].spawned);
    expect(service.generatedBy(a), isEmpty);
    expect(service.generatedBy(b), hasLength(reports[1].spawned));
    expect(level.actors.any((x) => x.id == hand.single), isTrue, reason: 'hand-placed actors survive');
    service.cleanupAll();
    expect(level.actors.where((x) => x.type == 'StaticMesh').map((x) => x.id), [hand.single]);
    expect(level.actors.where((x) => x.type == PcgTypes.volumeActor), hasLength(2));
  });

  test('a volume without a graph, with a missing graph, or a non-volume id reports an error and changes nothing', () async {
    final id = await service.placeVolume(location: [0.0, 0.0, 0.0]);
    expect((await service.generate(id)).error, contains('no PCG Graph'));
    level.setComponentProperty(id, PcgTypes.component, PcgTypes.propGraph, 'contents/pcg/Missing.lmas');
    expect((await service.generate(id)).error, contains('not found'));
    expect((await service.generate('nope')).error, contains('not a PCG Volume'));
    expect(service.cleanup('nope').ok, isFalse);
    expect(level.actors, hasLength(1));
  });

  test('the Difference node keeps generated barrels away from a hand-placed actor', () async {
    final hand = await level.addActors(const [EditorActorSpec(name: 'Crate', type: 'StaticMesh', location: [0.0, 0.0, 0.0])]);
    final id = await service.placeVolume(location: [0.0, 0.0, 0.0], graphPath: 'contents/pcg/Barrels.lmas', seed: 3);
    await service.generate(id);
    for (final a in service.generatedBy(id)) {
      final d = (a.location[0] * a.location[0] + a.location[1] * a.location[1]);
      expect(d, greaterThanOrEqualTo(300.0 * 300.0), reason: 'starter graph: 300 cm difference radius around ${hand.single}');
    }
  });
}
