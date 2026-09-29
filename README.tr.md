[English](README.md)

# Lumina plugins

[Lumina](https://github.com/LuminaGame/lumina) game engine'inin editor'ü Lumina Studio için plugin'ler. Editor'ün plugin API'si `lumina_editor_api` üzerine kuruludurlar ve MIT lisanslıdırlar; kendi plugin'leriniz için template ve örnek olarak kullanabilirsiniz.

| Plugin | Ne ekler |
|---|---|
| [`lumina_plugin_pcg`](lumina_plugin_pcg/) | Procedural Content Generation: static mesh'leri bir landscape'in ya da volume tabanının üzerine dağıtan PCG Graph asset'leri ve PCG Volume actor'leri. Plugin API'sinin referans örneği. |
| [`lumina_plugin_miniai`](lumina_plugin_miniai/) | MiniAI: local bir modelle (gerektiğinde indirilen llama-server + MiniCPM5) ya da herhangi bir OpenAI-compatible endpoint ile sohbet eden ve editor'ün MCP tool'ları üzerinden proje üzerinde çalışan bir AI asistan paneli. |

## Bir Lumina plugin'i nasıl kurulur

Plugin, `pubspec.yaml`'ının yanında `<name>.lmplugin` manifest'i olan bir Flutter paketidir:

```json
{
  "name": "lumina_plugin_pcg",
  "friendly_name": "Procedural Content Generation",
  "version": "0.1.0",
  "category": "Procedural",
  "license": "MIT",
  "changelog": "CHANGELOG.md",
  "engine_version": ">=0.0.1 <1.0.0",
  "modules": [
    {
      "name": "lumina_plugin_pcg",
      "type": "editor",
      "entry_library": "lib/lumina_plugin_pcg.dart",
      "registration_class": "LuminaPluginPcgPlugin"
    }
  ]
}
```

Registration class'ı `LuminaEditorPlugin`'i extend eder ve `register(LuminaEditorContext context)` içinde menu item'ları, panel'ler, toolbar butonları, asset type'ları, importer'lar, details customization'lar, console command'ları ve project settings bölümleri ekler.

Lumina Studio üç plugin root'unu tarar: engine'in `plugins/` klasörü, `<project>/plugins/` ve kullanıcıya özel `~/.local/share/lumina/plugins/` (`LUMINA_USER_PLUGIN_DIR` ile değiştirilebilir); Lumina Marketplace de plugin'leri bu klasöre kurar. Bir plugin'i kurmak için onu Lumina Studio içinden [marketplace](https://github.com/LuminaGame/marketplace)'ten alın ya da klasörünü bu root'lardan birine kopyalayın veya link'leyin, sonra **Plugins → Plugin Manager…** içinde enable edin. Yeni plugin'ler, template'ler sunan bir wizard olan **Plugins → New Plugin…** ile başlar. Kod içeren plugin'ler, editor yeniden başlayıp plugin register edilmiş halde yeniden build olduktan sonra devreye girer.

## Gereksinimler

- Dart `^3.12.0` içeren Flutter SDK.
- [melos](https://melos.invertase.dev/) 7 (dev dependency; `dart pub global activate melos` ya da `dart run melos`).
- Plugin'ler [lumina](https://github.com/LuminaGame/lumina) repo'sundaki `lumina` ve `lumina_editor_api` paketlerine bağımlıdır; bunlar da native engine paketlerini getirir. Bu yüzden build ve test için engine ile aynı native kurulum gerekir: prebuilt Google Filament v1.77.0 ve `flutter_riglogic` için build edilmiş bir OpenRigLogic kütüphanesi (bkz. [tools](https://github.com/LuminaGame/tools) repo'su).

## Kurulum

Lumina repo'larını yan yana checkout edin:

```
<dir>/
  lumina/        https://github.com/LuminaGame/lumina
  tools/         https://github.com/LuminaGame/tools
  plugins/       bu repo
  filament/      prebuilt out/ klasörleriyle patch'li Filament v1.77.0
  test-assets/   https://github.com/LuminaGame/test-assets (opsiyonel, Git LFS)
```

```bash
git clone https://github.com/LuminaGame/plugins.git
cd plugins
ln -s ../filament filament            # Windows: mklink /J filament ..\filament
ln -s ../test-assets test-assets      # opsiyonel; Windows: mklink /J test-assets ..\test-assets
dart pub get
```

`filament/` ve `test-assets/` gitignore'daki link'lerdir. Repo bir Dart pub workspace'idir (root pubspec'te `workspace:`, her plugin'de `resolution: workspace`).

Plugin'ler `lumina` ve `lumina_editor_api` paketlerini git dependency olarak alır:

```yaml
dependencies:
  lumina_editor_api:
    git:
      url: https://github.com/LuminaGame/lumina.git
      path: lumina_editor_api
```

Bunun yerine local checkout'larınıza karşı build etmek için repo root'unda gitignore'lu bir `pubspec_overrides.yaml` oluşturun (pub workspace'ler override'ları yalnızca root'tan okur):

```yaml
dependency_overrides:
  lumina:
    path: ../lumina/lumina
  lumina_editor_api:
    path: ../lumina/lumina_editor_api
  flutter_filament:
    path: ../lumina/flutter_filament
  flutter_assimp:
    path: ../tools/flutter_assimp
  flutter_riglogic:
    path: ../tools/flutter_riglogic
  flutter_gstreamer:
    path: ../tools/flutter_gstreamer
```

Root pubspec'teki `hooks: user_defines:` bölümü, bu yan yana düzeni varsayarak engine paketlerinin native assets hook'larına Filament'in (`filament_dir: filament`), bundled libc++'ın (`libcxx_dir`, Linux) ve OpenRigLogic kütüphanesinin (`riglogic_lib_dir: ../tools/flutter_riglogic/third_party/openriglogic/lib`) yerini söyler.

## Development

```bash
melos run analyze        # her plugin'de flutter analyze
melos run format         # dart format
melos run format:check   # format'lanmamış kaynak varsa fail eder
melos run test           # her plugin'de sırayla flutter test
melos run pack           # tüm plugin'leri marketplace için paketler
```

## Plugin'i marketplace için paketlemek

```bash
cd lumina_plugin_pcg
dart run tool/pack_plugin.dart          # -> build/pack/lumina_plugin_pcg-<version>.zip
```

Script plugin'i tek bir `<name>/` klasörü altına yazar; build output'larını (`build/`, `.dart_tool/`), IDE ve VCS klasörlerini, log'ları, yarım kalmış download'ları, `pubspec_overrides.yaml`'ı, secret'ları (`.env*`, `credentials*.json`) ve `.gitignore` / `.pubignore` dosyalarının ignore ettiği her şeyi dışarıda bırakır. Marketplace'in reddedeceği bir manifest'i, `pubspec.yaml`'dan farklı bir version'ı, `LICENSE` dosyası olmayan bir lisans beyanını ve marketplace allow-list'i dışındaki dosyaları reddeder (exit code 2, her sorun adıyla listelenir).

| Seçenek | Etkisi |
|---|---|
| `--out <dir>` | zip'i `build/pack/` yerine `<dir>` altına yazar |
| `--dry-run` | neyin gireceğini ve neyin dışarıda kalacağını listeler; hiçbir şey yazmaz |
| `--verbose` | paketlenen her dosyayı listeler |
| `--skip-disallowed` | fail etmek yerine reddedilen dosyaları bir uyarıyla dışarıda bırakır |

`dart tool/pack_plugin.dart` aynı işi pub'ın resolution ve build hook'ları olmadan, daha hızlı yapar. Zip'i marketplace'te **Publish → Plugin** altından yükleyin.

## Lisans

MIT (bkz. [LICENSE](LICENSE)); her plugin'in kendi `LICENSE` dosyası vardır. Kendi plugin'lerinize başlangıç noktası olarak kullanabilirsiniz. Bağımlı oldukları engine paketleri kendi repo'larında ayrıca lisanslanır.
