import 'dart:math' as math;

import 'package:lumina_editor_api/lumina_editor_api.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';

import '../model/pcg_graph_asset.dart';
import '../volume/pcg_volume.dart';
import '../volume/pcg_volume_service.dart';
import 'pcg_fields.dart';

/// The `PCG` section of the Details panel for a selected PCG Volume:
/// graph, seed, size, instance count, Generate / Cleanup / Edit Graph.
///
/// Built through [DetailsCustomization]: every edit goes back through
/// [DetailsTarget.setProperty] as `LuminaPcgComponent.<property>` so the
/// host records it as an undoable transaction.
class PcgVolumeDetails extends StatefulWidget {
  final DetailsTarget target;
  final EditorLevelAccess level;
  final PcgVolumeService service;

  const PcgVolumeDetails({super.key, required this.target, required this.level, required this.service});

  @override
  State<PcgVolumeDetails> createState() => _PcgVolumeDetailsState();
}

class _PcgVolumeDetailsState extends State<PcgVolumeDetails> {
  bool _busy = false;
  String? _status;

  EditorActorSnapshot get _actor => widget.target.target as EditorActorSnapshot;
  PcgVolumeSettings get _settings => PcgVolumeSettings.of(_actor) ?? const PcgVolumeSettings();

  void _set(String property, Object? value) => widget.target.setProperty('${PcgTypes.component}.$property', value);

  Future<void> _generate() async {
    setState(() => _busy = true);
    final report = await widget.service.generate(_actor.id);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _status = report.ok ? 'Generated ${report.spawned} instances on ${report.surface}' : report.error;
    });
  }

  void _cleanup() {
    final report = widget.service.cleanup(_actor.id);
    setState(() => _status = 'Removed ${report.removed} instances');
  }

  @override
  Widget build(BuildContext context) {
    final settings = _settings;
    final graphs = PcgGraphAsset.scan(widget.level.projectDirPath);
    final graphValue = settings.graphPath.isEmpty || !graphs.contains(settings.graphPath) ? null : settings.graphPath;
    final generated = widget.service.generatedBy(_actor.id).length;
    return Container(
      padding: const EdgeInsets.all(8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PcgFieldRow(
            label: 'PCG Graph',
            child: graphs.isEmpty
                ? const Text('No PCG Graph in contents/ (Tools → PCG → New PCG Graph)', style: TextStyle(fontSize: 10))
                : Select<String>(
                    key: const Key('pcg_graph_select'),
                    value: graphValue,
                    placeholder: const Text('Pick a graph', style: TextStyle(fontSize: 10)),
                    onChanged: (v) {
                      if (v != null) _set(PcgTypes.propGraph, v);
                    },
                    itemBuilder: (context, v) => Text(v.split('/').last, style: const TextStyle(fontSize: 10)),
                    popup: SelectPopup(
                      items: SelectItemList(
                        children: [for (final g in graphs) SelectItemButton(value: g, child: Text(g, style: const TextStyle(fontSize: 10)))],
                      ),
                    ).call,
                  ),
          ),
          PcgFieldRow(
            label: 'Seed',
            child: Row(
              children: [
                Expanded(
                  child: PcgNumberField(
                    fieldKey: const Key('pcg_seed_field'),
                    value: settings.seed.toDouble(),
                    fractionDigits: 0,
                    onCommit: (v) => _set(PcgTypes.propSeed, v.round()),
                  ),
                ),
                const SizedBox(width: 4),
                OutlineButton(
                  key: const Key('pcg_randomize_seed'),
                  size: ButtonSize.small,
                  onPressed: () => _set(PcgTypes.propSeed, math.Random().nextInt(1 << 30)),
                  child: const Icon(LucideIcons.dices, size: 12),
                ),
              ],
            ),
          ),
          PcgFieldRow(
            label: 'Size (cm)',
            child: PcgVector3Field(
              value: [settings.sizeX, settings.sizeY, settings.sizeZ],
              onCommit: (v) {
                if (v[0] != settings.sizeX) _set(PcgTypes.propSizeX, v[0]);
                if (v[1] != settings.sizeY) _set(PcgTypes.propSizeY, v[1]);
                if (v[2] != settings.sizeZ) _set(PcgTypes.propSizeZ, v[2]);
              },
            ),
          ),
          PcgFieldRow(
            label: 'Instances',
            child: Text('$generated', key: const Key('pcg_instance_count'), style: const TextStyle(fontSize: 10)),
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              PrimaryButton(
                key: const Key('pcg_generate_button'),
                size: ButtonSize.small,
                onPressed: _busy ? null : _generate,
                child: Row(mainAxisSize: MainAxisSize.min, children: const [Icon(LucideIcons.sprout, size: 12), SizedBox(width: 4), Text('Generate')]),
              ),
              const SizedBox(width: 6),
              OutlineButton(
                key: const Key('pcg_cleanup_button'),
                size: ButtonSize.small,
                onPressed: _busy || generated == 0 ? null : _cleanup,
                child: const Text('Cleanup'),
              ),
              const SizedBox(width: 6),
              GhostButton(
                key: const Key('pcg_edit_graph_button'),
                size: ButtonSize.small,
                onPressed: settings.graphPath.isEmpty ? null : () => widget.level.openAssetEditor(settings.graphPath),
                child: const Text('Edit Graph'),
              ),
            ],
          ),
          if (_status != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(_status!, key: const Key('pcg_status'), style: const TextStyle(fontSize: 10)).muted(),
            ),
        ],
      ),
    );
  }
}
