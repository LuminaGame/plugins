## Unreleased

- `dart run tool/pack_plugin.dart` packs the plugin for the Lumina Marketplace: `build/pack/lumina_plugin_pcg-<version>.zip` without build outputs, IDE folders, logs and secrets, checked against the marketplace's rules.
- Licensed under the MIT License (was all rights reserved); the manifest declares `"license": "MIT"` and `"changelog": "CHANGELOG.md"` for the Lumina Marketplace.
- The menu moved from Tools → PCG to **Plugins → PCG**, split into create / run / about sections.

## 0.1.0

- Initial release, generated from the Lumina plugin wizard's importer template and extended into the Procedural Content Generation example plugin.
- PCG Graph asset (`metadata.custom_type = pcg.graph`): Get Surface Data, Surface Sampler, Density Noise, Density Filter, Difference, Transform Points, Static Mesh Spawner; form-based graph editor opened from the Content Browser.
- PCG Volume actor (`PcgVolume` + `LuminaPcgComponent`): deterministic Generate / Cleanup producing ordinary `StaticMesh` actors, projected onto the level's Landscape (`LandscapeData.sampleHeight`) or the volume floor.
- Tools → PCG menu (New PCG Graph, Place PCG Volume, Generate All, Cleanup All, About), a `.pcggraph` importer and the `pcg.generate` console command.
- Requires `lumina_editor_api` with `EditorLevelAccess` / `LuminaEditorHostContext`.
