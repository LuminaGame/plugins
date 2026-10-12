import 'package:lumina_editor_api/lumina_editor_api.dart';
import 'package:lumina_plugin_trellis_image/src/shell/mesh_preview.dart';
import 'package:lumina_plugin_trellis_image/src/ui/preview/preview_style.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';

/// The generated mesh in the editor's 3D viewport (the UMG Viewport behind
/// `build3DViewport`): orbit (left drag), pan (right / middle drag), zoom
/// (wheel), and the Lit / Unlit / Wireframe view modes. Vertex colours show
/// as the mesh carries them.
class MeshPreviewViewport extends StatefulWidget {
  const MeshPreviewViewport({
    super.key,
    required this.preview,
    required this.style,
    this.host,
  });

  final MeshPreview preview;
  final PreviewStyle style;

  /// The editor; null in tests without one (a summary stands in).
  final LuminaEditorHostContext? host;

  @override
  State<MeshPreviewViewport> createState() => _MeshPreviewViewportState();
}

class _MeshPreviewViewportState extends State<MeshPreviewViewport> {
  static const _modes = [
    ('lit', 'Lit', LucideIcons.sun),
    ('unlit', 'Unlit', LucideIcons.sunDim),
    ('wireframe', 'Wireframe', LucideIcons.grid3x3),
  ];
  String _mode = 'lit';

  @override
  Widget build(BuildContext context) {
    final s = widget.style;
    final stats = widget.preview.shownStats;
    final host = widget.host;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          height: 30,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          color: s.cardHeader,
          child: Row(
            children: [
              for (final (id, label, icon) in _modes) ...[
                _ModeButton(
                  key: ValueKey('trellis_preview_mode_$id'),
                  label: label,
                  icon: icon,
                  selected: _mode == id,
                  style: s,
                  onPressed: () => setState(() => _mode = id),
                ),
                const Gap(4),
              ],
              const Spacer(),
              Text(
                '${MeshStats.count(stats.triangles)} triangles · ${MeshStats.count(stats.vertices)} vertices',
                style: TextStyle(fontSize: 10, color: s.muted),
              ),
            ],
          ),
        ),
        Expanded(
          child: host == null
              ? Container(
                  key: const Key('trellis_preview_no_viewport'),
                  color: s.background,
                  alignment: Alignment.center,
                  child: Text(
                    '3D preview: ${widget.preview.shownPath}',
                    style: TextStyle(fontSize: 11, color: s.muted),
                  ),
                )
              : KeyedSubtree(
                  key: const Key('trellis_preview_viewport'),
                  child: host.build3DViewport(
                    context,
                    Plugin3DViewportOptions(
                      title: widget.preview.simplified == null
                          ? 'Generated mesh'
                          : 'Simplified mesh',
                      meshPath: widget.preview.shownPath,
                      viewMode: _mode,
                      showGizmo: false,
                    ),
                  ),
                ),
        ),
      ],
    );
  }
}

class _ModeButton extends StatelessWidget {
  const _ModeButton({
    super.key,
    required this.label,
    required this.icon,
    required this.selected,
    required this.style,
    required this.onPressed,
  });

  final String label;
  final IconData icon;
  final bool selected;
  final PreviewStyle style;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final child = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 12),
        const Gap(4),
        Text(label, style: const TextStyle(fontSize: 10)),
      ],
    );
    return SizedBox(
      height: 22,
      child: selected
          ? PrimaryButton(
              size: ButtonSize.small,
              density: ButtonDensity.compact,
              onPressed: onPressed,
              child: child,
            )
          : GhostButton(
              size: ButtonSize.small,
              density: ButtonDensity.compact,
              onPressed: onPressed,
              child: child,
            ),
    );
  }
}
