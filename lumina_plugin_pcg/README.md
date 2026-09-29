[Türkçe](README.tr.md)

# Procedural Content Generation (lumina_plugin_pcg)

A Lumina Studio plugin that adds PCG Graph assets and PCG Volume actors: a graph describes how to sample a surface and which static meshes to place, and a volume in the level runs the graph to scatter those meshes over a landscape or the volume's floor.

It is also the reference example of the Lumina Studio plugin API: it depends on `lumina_editor_api` and `lumina` only, and uses menus, an asset type with its own editor, a details customization, an importer and a console command. Started from the plugin wizard's importer template and extended.

## What it adds to Lumina Studio

| Extension point | Contribution |
|---|---|
| Menu | **Plugins → PCG**: New PCG Graph, Place PCG Volume, Generate All, Cleanup All, About |
| Asset type | **PCG Graph**: an `.lmas` with `metadata.custom_type = pcg.graph`; double-clicking it opens the graph editor in a sub-editor tab |
| Details customization | a **PCG** section on `PcgVolume` actors: graph, seed (with randomize), size, instance count, **Generate**, **Cleanup**, **Edit Graph** |
| Importer | `.pcggraph` (a graph as JSON) → `.lmas` |
| Console command | `pcg.generate [volumeId]` |

### The graph

A PCG Graph is a DAG of nodes; data (surface → points → instances) flows along its edges.

| Node | Parameters |
|---|---|
| Get Surface Data | `surface`: `auto` (the landscape where one covers the point, else the volume floor), `landscape`, `floor` |
| Surface Sampler | `cellSize` (cm), `looseness` 0–1, `maxSlopeDegrees` |
| Density Noise | `noiseScale` (cm) |
| Density Filter | `minDensity`, `maxDensity` |
| Difference | `radius` (cm), `actorTypes` (hand-placed actors to keep clear of) |
| Transform Points | `rotationMin/Max` (degrees XYZ), `scaleMin/Max`, `uniformScale`, `offsetMin/Max` (cm) |
| Static Mesh Spawner | `meshes`: `[{path, weight}]` |

The editor is form-based: the nodes in evaluation order, with add, remove, move and parameter editing, re-linked as a chain. The saved graph (`nodes` + `edges`) is a real DAG.

### The volume

**Place PCG Volume** adds a `PcgVolume` actor (2000 × 2000 × 500 cm before scale) with a `LuminaPcgComponent` (`graphPath`, `seed`, `sizeX/Y/Z`, `instanceCount`). **Generate** evaluates the graph deterministically for the seed and places every instance as an ordinary `StaticMesh` actor, parented under the volume and tagged with a `LuminaPcgGeneratedComponent`. Generating again replaces them; **Cleanup** removes them. Instances take their height from the level's Landscape actor where the volume overlaps one (`LandscapeData.sampleHeight`), else from the volume floor.

Because the instances are plain actors, the viewport, Play-In-Editor, Dart code generation and the packaged game need nothing PCG-specific.

## Installing

Get the plugin from the Lumina Marketplace inside Lumina Studio, or put this folder into one of the plugin roots the editor scans: the engine's `plugins/`, `<project>/plugins/`, or the per-user `~/.local/share/lumina/plugins/`. For development, link your checkout:

```bash
mkdir -p ~/.local/share/lumina/plugins
ln -s "$PWD/lumina_plugin_pcg" ~/.local/share/lumina/plugins/lumina_plugin_pcg   # from the plugins checkout
```

Then:

1. Open Lumina Studio and go to **Plugins → Plugin Manager…**.
2. Find **Procedural Content Generation** and enable it.
3. Restart the editor. This is a code plugin, so the editor regenerates its plugin registrar and rebuilds with `LuminaPluginPcgPlugin` registered.

## Trying it

1. Import a few meshes: drag `.glb` files into the Content Browser (for example `test-assets/Props/Barrels/*.glb` from the [test-assets](https://github.com/LuminaGame/test-assets) repository).
2. **Plugins → PCG → New PCG Graph** creates `contents/pcg/PCG_Graph_1.lmas` with every mesh under `contents/meshes/` in its spawner and opens the editor. Adjust the cell size, noise and filter, then **Save**.
3. **Plugins → PCG → Place PCG Volume** places a volume at the origin using the first graph found. Move and scale it in the viewport.
4. Select the volume, then Details → **PCG** → **Generate**. Change the seed and generate again; **Cleanup** removes everything. **Plugins → PCG → Generate All** regenerates every volume in the level.

## Using the graph from code

The model and the evaluator are plain Dart and can run without the editor:

```dart
import 'package:lumina_plugin_pcg/lumina_plugin_pcg.dart';

final graph = PcgGraph.starter(
  name: 'Barrels',
  meshes: const [
    PcgMeshEntry(path: 'contents/meshes/fuel_barrel_red.glb', weight: 2),
    PcgMeshEntry(path: 'contents/meshes/dented_barrel.glb'),
  ],
);

final bounds = PcgVolumeBounds(center: const [0, 0, 0], size: const [2000, 2000, 500]);
final result = const PcgEvaluator().evaluate(
  graph,
  PcgEvaluationContext(
    bounds: bounds,
    seed: 7,
    surface: PcgCompositeSurface(landscapes: const [], floor: PcgFloorSurface(bounds.minZ)),
  ),
);

for (final instance in result.instances) {
  print('${instance.meshPath} at ${instance.location}');
}
final json = graph.toJsonString(); // the .pcggraph format
```

## Packing for the marketplace

```bash
dart run tool/pack_plugin.dart          # -> build/pack/lumina_plugin_pcg-<version>.zip
```

It leaves out build outputs, IDE folders, logs and secrets, and checks the manifest, version, license and file types against the marketplace's rules. `--dry-run`, `--out <dir>`, `--verbose` and `--skip-disallowed` are described in the [repository README](../README.md#packing-a-plugin-for-the-marketplace). Upload the zip under **Publish → Plugin** on the marketplace.

## Tests

```bash
flutter test
```

Sampler determinism, filters, difference, spawner weights, seed reproducibility, landscape projection against a real `LandscapeData` heightmap, the volume service over a real level file with real barrel models from `test-assets/`, the pack script, and widget tests for the Details section and the graph editor.

## License

MIT (see [LICENSE](LICENSE)). Use it as a template for your own plugins.
