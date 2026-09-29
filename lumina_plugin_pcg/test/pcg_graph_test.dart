import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lumina/data/models/lumina_asset.dart';
import 'package:lumina_editor_api/lumina_editor_api.dart';
import 'package:lumina_plugin_pcg/lumina_plugin_pcg.dart';

void main() {
  late Directory temp;
  setUp(() => temp = Directory.systemTemp.createTempSync('pcg_graph_'));
  tearDown(() => temp.deleteSync(recursive: true));

  test('the starter graph is the seven-node chain in evaluation order', () {
    final g = PcgGraph.starter(name: 'G', meshes: const [PcgMeshEntry(path: 'contents/meshes/a.glb')]);
    expect(g.topologicalOrder().map((n) => n.type).toList(), [
      PcgNodeType.getSurfaceData,
      PcgNodeType.surfaceSampler,
      PcgNodeType.densityNoise,
      PcgNodeType.densityFilter,
      PcgNodeType.difference,
      PcgNodeType.transformPoints,
      PcgNodeType.staticMeshSpawner,
    ]);
    expect(g.edges, hasLength(6));
    expect(g.nodeById('spawner')!.meshes.single.path, 'contents/meshes/a.glb');
    expect(g.inputsOf('sampler'), ['surface']);
  });

  test('JSON round-trips every node, parameter and edge', () {
    final g = PcgGraph.starter(name: 'Round', meshes: const [PcgMeshEntry(path: 'm.glb', weight: 2.5)]);
    g.nodeById('sampler')!.params['cellSize'] = 123.0;
    g.nodeById('transform')!.params['rotationMax'] = [0.0, 0.0, 90.0];
    final back = PcgGraph.fromJsonString(g.toJsonString());
    expect(back.name, 'Round');
    expect(back.nodes.length, g.nodes.length);
    expect(back.edges, g.edges);
    expect(back.nodeById('sampler')!.number('cellSize', 0), 123.0);
    expect(back.nodeById('transform')!.vector3('rotationMax', const [0, 0, 0]), [0.0, 0.0, 90.0]);
    expect(back.nodeById('spawner')!.meshes.single.weight, 2.5);
    expect(() => PcgGraph.fromJson({'version': 99, 'name': 'x'}), throwsFormatException);
    expect(() => PcgNodeType.parse('bogus'), throwsFormatException);
  });

  test('a cycle is refused, fresh ids do not collide, relinkAsChain follows list order', () {
    final g = PcgGraph(name: 'C', nodes: [
      PcgNode(id: 'a', type: PcgNodeType.surfaceSampler),
      PcgNode(id: 'b', type: PcgNodeType.densityFilter),
    ], edges: const [PcgEdge('a', 'b'), PcgEdge('b', 'a')]);
    expect(g.topologicalOrder, throwsStateError);
    g.relinkAsChain();
    expect(g.edges, const [PcgEdge('a', 'b')]);
    expect(g.topologicalOrder().map((n) => n.id), ['a', 'b']);
    expect(g.freshNodeId(PcgNodeType.surfaceSampler), 'surfaceSampler');
    g.nodes.add(PcgNode(id: 'surfaceSampler', type: PcgNodeType.surfaceSampler));
    expect(g.freshNodeId(PcgNodeType.surfaceSampler), 'surfaceSampler_2');
    expect(g.freshNodeId(PcgNodeType.staticMeshSpawner), 'spawner');
  });

  test('.lmas round-trip: custom_type marks the asset, scan finds it, a foreign .lmas is ignored', () async {
    final g = PcgGraph.starter(name: 'Scatter');
    final path = '${temp.path}/contents/pcg/Scatter.lmas';
    await PcgGraphAsset.save(g, path);
    final asset = LuminaAsset.fromBytes(File(path).readAsBytesSync());
    expect(asset.type, AssetType.unknown);
    expect(asset.metadata[kCustomAssetTypeKey], PcgGraphAsset.customTypeId);
    expect(PcgGraphAsset.isGraph(asset), isTrue);
    expect(PcgGraphAsset.load(path)!.nodes.length, 7);
    // A mesh asset next to it is not a graph.
    File('${temp.path}/contents/meshes/M.lmas')
      ..createSync(recursive: true)
      ..writeAsBytesSync(const LuminaAsset(assetId: 'm', name: 'M', type: AssetType.filamesh).toProtoBufferBytes());
    expect(PcgGraphAsset.load('${temp.path}/contents/meshes/M.lmas'), isNull);
    expect(PcgGraphAsset.load('${temp.path}/nope.lmas'), isNull);
    expect(PcgGraphAsset.scan(temp.path), ['contents/pcg/Scatter.lmas']);
    expect(PcgGraphAsset.absolute(temp.path, 'contents/pcg/Scatter.lmas'), path);
    expect(PcgGraphAsset.relative(temp.path, path), 'contents/pcg/Scatter.lmas');
  });

  // Windows directory listings join below the project
  // with '\', and graph references must stay '/'-separated on every host.
  test('relative() gives /-separated paths for Windows-shaped input', () {
    expect(PcgGraphAsset.relative('C:/p', r'C:/p/contents\pcg\G.lmas'), 'contents/pcg/G.lmas');
    expect(PcgGraphAsset.relative(r'C:\p', r'C:\p\contents\meshes\Barrel.glb'), 'contents/meshes/Barrel.glb');
    expect(PcgGraphAsset.relative('/home/u/p', '/home/u/p/contents/pcg/G.lmas'), 'contents/pcg/G.lmas');
  });
}
