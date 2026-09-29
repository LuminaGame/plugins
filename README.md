[Türkçe](README.tr.md)

# Lumina plugins

Plugins for Lumina Studio, the editor of the [Lumina](https://github.com/LuminaGame/lumina) game engine. They are built on the editor's plugin API, `lumina_editor_api`, and are MIT-licensed so they can serve as templates and examples for your own plugins.

| Plugin | What it adds |
|---|---|
| [`lumina_plugin_pcg`](lumina_plugin_pcg/) | Procedural Content Generation: PCG Graph assets and PCG Volume actors that scatter static meshes over a landscape or a volume floor. The reference example of the plugin API. |
| [`lumina_plugin_miniai`](lumina_plugin_miniai/) | MiniAI: an AI assistant panel that chats with a local model (llama-server + MiniCPM5, downloaded on demand) or any OpenAI-compatible endpoint, and works on the project through the editor's MCP tools. |

## How a Lumina plugin is put together

A plugin is a Flutter package with a `<name>.lmplugin` manifest next to its `pubspec.yaml`:

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

The registration class extends `LuminaEditorPlugin` and, in `register(LuminaEditorContext context)`, contributes menu items, panels, toolbar buttons, asset types, importers, details customizations, console commands and project settings sections.

Lumina Studio scans three plugin roots: the engine's `plugins/` folder, `<project>/plugins/`, and the per-user folder `~/.local/share/lumina/plugins/` (`LUMINA_USER_PLUGIN_DIR` overrides it), which is also where the Lumina Marketplace installs plugins. To install a plugin, get it from the [marketplace](https://github.com/LuminaGame/marketplace) inside Lumina Studio, or copy or link its folder into one of those roots, then enable it in **Plugins → Plugin Manager…**. New plugins start from **Plugins → New Plugin…**, a wizard with templates. Code plugins take effect after the editor restarts and rebuilds with the plugin registered.

## Requirements

- Flutter SDK with Dart `^3.12.0`.
- [melos](https://melos.invertase.dev/) 7 (a dev dependency; `dart pub global activate melos`, or `dart run melos`).
- The plugins depend on `lumina` and `lumina_editor_api` from the [lumina](https://github.com/LuminaGame/lumina) repository, which pull in the native engine packages. Building or testing them therefore needs the same native setup as the engine: a prebuilt Google Filament v1.77.0 and, for `flutter_riglogic`, a built OpenRigLogic library (see the [tools](https://github.com/LuminaGame/tools) repository).

## Setup

Check out the Lumina repositories side by side:

```
<dir>/
  lumina/        https://github.com/LuminaGame/lumina
  tools/         https://github.com/LuminaGame/tools
  plugins/       this repository
  filament/      patched Filament v1.77.0 with its prebuilt out/ folders
  test-assets/   https://github.com/LuminaGame/test-assets (optional, Git LFS)
```

```bash
git clone https://github.com/LuminaGame/plugins.git
cd plugins
ln -s ../filament filament            # Windows: mklink /J filament ..\filament
ln -s ../test-assets test-assets      # optional; Windows: mklink /J test-assets ..\test-assets
dart pub get
```

`filament/` and `test-assets/` are gitignored links. The repository is a Dart pub workspace (`workspace:` in the root pubspec, `resolution: workspace` in each plugin).

The plugins take `lumina` and `lumina_editor_api` as git dependencies:

```yaml
dependencies:
  lumina_editor_api:
    git:
      url: https://github.com/LuminaGame/lumina.git
      path: lumina_editor_api
```

To build against your local checkouts instead, create a gitignored `pubspec_overrides.yaml` at the repository root (pub workspaces read overrides from the root only):

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

The root pubspec's `hooks: user_defines:` tell the engine packages' native-assets hooks where Filament (`filament_dir: filament`), the bundled libc++ (`libcxx_dir`, Linux) and the OpenRigLogic library (`riglogic_lib_dir: ../tools/flutter_riglogic/third_party/openriglogic/lib`) are, assuming this sibling layout.

## Development

```bash
melos run analyze        # flutter analyze in every plugin
melos run format         # dart format
melos run format:check   # fail on unformatted sources
melos run test           # flutter test in every plugin, one at a time
melos run pack           # pack every plugin for the marketplace
```

## Packing a plugin for the marketplace

```bash
cd lumina_plugin_pcg
dart run tool/pack_plugin.dart          # -> build/pack/lumina_plugin_pcg-<version>.zip
```

The script writes the plugin under a single `<name>/` folder and leaves out build outputs (`build/`, `.dart_tool/`), IDE and VCS folders, logs, partial downloads, `pubspec_overrides.yaml`, secrets (`.env*`, `credentials*.json`) and everything the `.gitignore` / `.pubignore` files ignore. It refuses (exit code 2, every problem named) a manifest the marketplace would refuse, a version that differs from `pubspec.yaml`, a declared license without a `LICENSE` file, and files outside the marketplace's allow-list.

| Option | Effect |
|---|---|
| `--out <dir>` | write the zip to `<dir>` instead of `build/pack/` |
| `--dry-run` | list what would go in and what is left out; write nothing |
| `--verbose` | list every packed file |
| `--skip-disallowed` | leave refused files out with a warning instead of failing |

`dart tool/pack_plugin.dart` does the same without pub's resolution and build hooks, so it is faster. Upload the zip on the marketplace under **Publish → Plugin**.

## License

MIT (see [LICENSE](LICENSE)); each plugin carries its own `LICENSE`. Use them as a starting point for your own plugins. The engine packages they depend on are licensed separately in their own repositories.
