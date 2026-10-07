[English](README.md)

# Procedural Content Generation (lumina_plugin_pcg)

PCG Graph asset'leri ve PCG Volume actor'leri ekleyen bir Lumina Studio plugin'i: graph, bir yüzeyin nasıl örnekleneceğini ve hangi static mesh'lerin yerleştirileceğini tanımlar; level'daki volume da graph'ı çalıştırıp bu mesh'leri bir landscape'in ya da volume tabanının üzerine dağıtır.

Aynı zamanda Lumina Studio plugin API'sinin referans örneğidir: yalnızca `lumina_editor_api` ve `lumina` paketlerine bağımlıdır; menu'ler, kendi editor'ü olan bir asset type, bir details customization, bir importer ve bir console command kullanır. Plugin wizard'ının importer template'inden başlatılıp genişletildi.

## Lumina Studio'ya ne ekler

| Extension point | Katkı |
|---|---|
| Menu | **Plugins → PCG**: New PCG Graph, Place PCG Volume, Generate All, Cleanup All, About |
| Asset type | **PCG Graph**: `metadata.custom_type = pcg.graph` olan bir `.lmas`; çift tıklayınca graph editor'ü bir sub-editor tab'ında açılır |
| Details customization | `PcgVolume` actor'lerinde bir **PCG** bölümü: graph, seed (randomize ile), boyut, instance sayısı, **Generate**, **Cleanup**, **Edit Graph** |
| Importer | `.pcggraph` (JSON olarak bir graph) → `.lmas` |
| Console command | `pcg.generate [volumeId]` |

### Graph

PCG Graph, node'lardan oluşan bir DAG'dir; veri (surface → points → instances) edge'ler boyunca akar.

| Node | Parametreler |
|---|---|
| Get Surface Data | `surface`: `auto` (noktayı kapsayan bir landscape varsa o, yoksa volume tabanı), `landscape`, `floor` |
| Surface Sampler | `cellSize` (cm), `looseness` 0–1, `maxSlopeDegrees` |
| Density Noise | `noiseScale` (cm) |
| Density Filter | `minDensity`, `maxDensity` |
| Difference | `radius` (cm), `actorTypes` (uzak durulacak, elle yerleştirilmiş actor'ler) |
| Transform Points | `rotationMin/Max` (derece, XYZ), `scaleMin/Max`, `uniformScale`, `offsetMin/Max` (cm) |
| Static Mesh Spawner | `meshes`: `[{path, weight}]` |

Editor form tabanlıdır: node'lar evaluation sırasıyla listelenir; ekleme, silme, taşıma ve parametre düzenleme yapılır, node'lar bir zincir olarak yeniden bağlanır. Kaydedilen graph (`nodes` + `edges`) gerçek bir DAG'dir.

### Volume

**Place PCG Volume**, `LuminaPcgComponent` (`graphPath`, `seed`, `sizeX/Y/Z`, `instanceCount`) taşıyan bir `PcgVolume` actor'ü ekler (scale öncesi 2000 × 2000 × 500 cm). **Generate**, graph'ı seed'e göre deterministik olarak hesaplar ve her instance'ı volume'un altına parent'lanmış, `LuminaPcgGeneratedComponent` ile işaretlenmiş sıradan bir `StaticMesh` actor'ü olarak yerleştirir. Yeniden generate etmek bunları değiştirir; **Cleanup** kaldırır. Instance'lar yüksekliklerini, volume'un örtüştüğü yerde level'ın Landscape actor'ünden (`LandscapeData.sampleHeight`), yoksa volume tabanından alır.

Instance'lar sıradan actor'ler olduğu için viewport, Play-In-Editor, Dart code generation ve paketlenmiş oyun PCG'ye özel hiçbir şeye ihtiyaç duymaz.

## Kurulum

Plugin'i Lumina Studio içinden Lumina Marketplace'ten alın ya da bu klasörü editor'ün taradığı plugin root'larından birine koyun: engine'in `plugins/` klasörü, `<project>/plugins/` ya da kullanıcıya özel `~/.local/share/lumina/plugins/`. Development için checkout'unuzu link'leyin:

```bash
mkdir -p ~/.local/share/lumina/plugins
ln -s "$PWD/lumina_plugin_pcg" ~/.local/share/lumina/plugins/lumina_plugin_pcg   # plugins checkout'unun içinden
```

Sonra:

1. Lumina Studio'yu açın ve **Plugins → Plugin Manager…** menüsüne gidin.
2. **Procedural Content Generation**'ı bulun ve enable edin.
3. Editor'ü yeniden başlatın. Bu bir code plugin'i olduğu için editor plugin registrar'ını yeniden üretir ve `LuminaPluginPcgPlugin` register edilmiş halde yeniden build olur.

## Denemek

1. Birkaç mesh import edin: `.glb` dosyalarını Content Browser'a sürükleyin (örneğin [test-assets](https://github.com/LuminaGame/test-assets) repo'sundan `test-assets/Props/Barrels/*.glb`).
2. **Plugins → PCG → New PCG Graph**, spawner'ında `contents/meshes/` altındaki tüm mesh'lerle `contents/pcg/PCG_Graph_1.lmas` dosyasını oluşturur ve editor'ü açar. Cell size, noise ve filter ayarlarını yapıp **Save** deyin.
3. **Plugins → PCG → Place PCG Volume**, bulunan ilk graph'ı kullanan bir volume'u origin'e yerleştirir. Viewport'ta taşıyıp ölçekleyin.
4. Volume'u seçin, Details → **PCG** → **Generate**. Seed'i değiştirip yeniden generate edin; **Cleanup** her şeyi kaldırır. **Plugins → PCG → Generate All** level'daki tüm volume'ları yeniden generate eder.

## Graph'ı koddan kullanmak

Model ve evaluator saf Dart'tır, editor olmadan da çalışır:

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
final json = graph.toJsonString(); // .pcggraph formatı
```

## Marketplace için paketlemek

```bash
dart run tool/pack_plugin.dart          # -> build/pack/lumina_plugin_pcg-<version>.zip
```

Build output'larını, IDE klasörlerini, log'ları ve secret'ları dışarıda bırakır; manifest'i, version'ı, lisansı ve dosya tiplerini marketplace kurallarına göre kontrol eder. `--dry-run`, `--out <dir>`, `--verbose` ve `--skip-disallowed` seçenekleri [repo README'sinde](../README.tr.md#pluginimarketplace-için-paketlemek) anlatılıyor. Zip'i marketplace'te **Publish → Plugin** altından yükleyin.

## Test'ler

```bash
flutter test
```

Sampler determinism'i, filter'lar, difference, spawner ağırlıkları, seed tekrarlanabilirliği, gerçek bir `LandscapeData` heightmap'ine projeksiyon, `test-assets/` içindeki gerçek barrel modelleriyle gerçek bir level dosyası üzerinde volume servisi, pack script'i ve Details bölümü ile graph editor'ü için widget test'leri.

`test/architecture/process_part_reach_test.dart` plugin'in bir süreç bölümü olmadığını doğrular: editörün kendi sürecinde çalışır (`process_class` ve `"isolation": "process"` yok). İzole bir plugin aynı dosyada süreç bölümünün hangi paketleri import edebileceğini listeler (`create-plugin` skill'ine bakın).

## Lisans

MIT (bkz. [LICENSE](LICENSE)). Kendi plugin'leriniz için template olarak kullanabilirsiniz.
