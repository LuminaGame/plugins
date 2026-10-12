import 'package:lumina_plugin_trellis_image/src/shell/image_trellis_job.dart';
import 'package:lumina_plugin_trellis_image/src/shell/mesh_preview.dart';
import 'package:lumina_plugin_trellis_image/src/ui/preview/preview_style.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';

/// The review side of a generated mesh: its statistics, Simplify (a ratio
/// or a triangle target, Apply / Revert, before → after) and the decision:
/// Save to Project (name + project folder), Regenerate, Discard.
class MeshPreviewPanel extends StatefulWidget {
  const MeshPreviewPanel({super.key, required this.job, required this.style});

  final ImageTrellisJob job;
  final PreviewStyle style;

  /// Where meshes are saved when the folder field is left as it is.
  static const String defaultFolder = 'contents/meshes/trellis';

  @override
  State<MeshPreviewPanel> createState() => _MeshPreviewPanelState();
}

class _MeshPreviewPanelState extends State<MeshPreviewPanel> {
  double _percent = 25;
  final _triangles = TextEditingController();
  late final _name = TextEditingController(
    text: 'SM_Trellis_${DateTime.now().millisecondsSinceEpoch ~/ 1000}',
  );
  final _folder = TextEditingController(text: MeshPreviewPanel.defaultFolder);
  String? _inputError;

  @override
  void dispose() {
    _triangles.dispose();
    _name.dispose();
    _folder.dispose();
    super.dispose();
  }

  Future<void> _apply() async {
    final text = _triangles.text.trim();
    if (text.isNotEmpty) {
      final n = int.tryParse(text);
      if (n == null || n < 1) {
        setState(
          () =>
              _inputError = 'Target triangles must be a positive whole number.',
        );
        return;
      }
      setState(() => _inputError = null);
      await widget.job.simplify(triangles: n);
      return;
    }
    setState(() => _inputError = null);
    await widget.job.simplify(ratio: _percent / 100);
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _inputError = 'Enter an asset name.');
      return;
    }
    setState(() => _inputError = null);
    await widget.job.save(
      name: name,
      folder: _folder.text.trim().isEmpty
          ? MeshPreviewPanel.defaultFolder
          : _folder.text.trim(),
    );
  }

  Widget _field(
    String label,
    TextEditingController c,
    Key key, {
    bool enabled = true,
    String? placeholder,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(label, style: TextStyle(fontSize: 10, color: widget.style.muted)),
        const Gap(3),
        TextField(
          key: key,
          controller: c,
          enabled: enabled,
          placeholder: placeholder == null ? null : Text(placeholder),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final job = widget.job;
    final p = job.preview!;
    final s = widget.style;
    final idle = !job.working && !job.busy;
    final saved = p.savedAssetPath;
    final shown = p.shownStats;
    final simplified = p.simplified;
    return Container(
      color: s.sidebar,
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            s.section([
              s.header('Mesh'),
              s.row(
                'Triangles',
                '${shown.triangles}',
                key: const Key('trellis_preview_triangles'),
              ),
              s.row('Vertices', '${shown.vertices}'),
              s.row('Size (cm)', shown.sizeLabel),
              s.row('File size', MeshStats.bytes(shown.fileBytes)),
              s.row('Vertex colours', shown.hasVertexColors ? 'yes' : 'no'),
              s.row(
                'Not in the project until saved',
                saved == null ? 'temp' : 'saved',
              ),
            ]),
            s.section([
              s.header('Simplify'),
              Text(
                'Keep ${_percent.round()}% of the triangles',
                style: TextStyle(fontSize: 10, color: s.muted),
              ),
              const Gap(6),
              Slider(
                key: const Key('trellis_simplify_ratio'),
                value: SliderValue.single(_percent),
                min: 1,
                max: 99,
                divisions: 98,
                onChanged: idle
                    ? (v) => setState(() => _percent = v.value)
                    : null,
              ),
              const Gap(6),
              Row(
                children: [
                  for (final v in const [50, 25, 10]) ...[
                    Expanded(
                      child: OutlineButton(
                        key: ValueKey('trellis_simplify_preset_$v'),
                        size: ButtonSize.small,
                        onPressed: idle
                            ? () => setState(() => _percent = v.toDouble())
                            : null,
                        child: Text(
                          '$v%',
                          style: const TextStyle(fontSize: 10),
                        ),
                      ),
                    ),
                    if (v != 10) const Gap(4),
                  ],
                ],
              ),
              const Gap(8),
              _field(
                'Or a triangle target (overrides the ratio)',
                _triangles,
                const Key('trellis_simplify_triangles'),
                enabled: idle,
                placeholder: 'e.g. 100000',
              ),
              Row(
                children: [
                  Expanded(
                    child: PrimaryButton(
                      key: const Key('trellis_simplify_apply'),
                      size: ButtonSize.small,
                      onPressed: idle && saved == null ? _apply : null,
                      child: const Text('Apply'),
                    ),
                  ),
                  const Gap(6),
                  Expanded(
                    child: OutlineButton(
                      key: const Key('trellis_simplify_revert'),
                      size: ButtonSize.small,
                      onPressed: idle && simplified != null && saved == null
                          ? job.revert
                          : null,
                      child: const Text('Revert'),
                    ),
                  ),
                ],
              ),
              if (simplified != null) ...[
                const Gap(8),
                Text(
                  '${simplified.before.triangles} → ${simplified.after.triangles} triangles '
                  '(${(simplified.after.triangles * 100 / simplified.before.triangles).toStringAsFixed(1)}%, '
                  '${(simplified.durationMs / 1000).toStringAsFixed(1)} s)',
                  key: const Key('trellis_simplify_result'),
                  style: TextStyle(fontSize: 10, color: s.foreground),
                ),
              ],
            ]),
            s.section([
              s.header('Save'),
              _field(
                'Asset name',
                _name,
                const Key('trellis_save_name'),
                enabled: idle && saved == null,
              ),
              _field(
                'Project folder',
                _folder,
                const Key('trellis_save_folder'),
                enabled: idle && saved == null,
              ),
              PrimaryButton(
                key: const Key('trellis_save'),
                onPressed: idle && saved == null ? _save : null,
                leading: const Icon(LucideIcons.save, size: 14),
                child: Text(saved == null ? 'Save to Project' : 'Saved'),
              ),
              if (saved != null) ...[
                const Gap(6),
                SelectableText(
                  'Saved asset: $saved',
                  style: TextStyle(fontSize: 10, color: s.foreground),
                ),
              ],
              const Gap(8),
              Row(
                children: [
                  Expanded(
                    child: OutlineButton(
                      key: const Key('trellis_regenerate'),
                      onPressed: idle && job.lastDraftId != null
                          ? job.regenerate
                          : null,
                      leading: const Icon(LucideIcons.refreshCw, size: 14),
                      child: const Text('Regenerate'),
                    ),
                  ),
                  const Gap(6),
                  Expanded(
                    child: DestructiveButton(
                      key: const Key('trellis_discard'),
                      onPressed: idle ? job.discard : null,
                      leading: const Icon(LucideIcons.trash2, size: 14),
                      child: Text(saved == null ? 'Discard' : 'Close'),
                    ),
                  ),
                ],
              ),
            ]),
            if (_inputError != null)
              Text(
                _inputError!,
                style: TextStyle(fontSize: 10, color: s.destructive),
              ),
          ],
        ),
      ),
    );
  }
}
