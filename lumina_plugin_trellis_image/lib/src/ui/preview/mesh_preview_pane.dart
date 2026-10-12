import 'package:lumina_editor_api/lumina_editor_api.dart';
import 'package:lumina_plugin_trellis_image/src/shell/image_trellis_job.dart';
import 'package:lumina_plugin_trellis_image/src/ui/preview/mesh_preview_panel.dart';
import 'package:lumina_plugin_trellis_image/src/ui/preview/mesh_preview_viewport.dart';
import 'package:lumina_plugin_trellis_image/src/ui/preview/preview_style.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';

/// A generated mesh under review: the 3D viewport and, in a resizable side
/// panel, its statistics, Simplify and Save / Regenerate / Discard.
class MeshPreviewPane extends StatelessWidget {
  const MeshPreviewPane({
    super.key,
    required this.job,
    required this.style,
    this.host,
  });

  final ImageTrellisJob job;
  final PreviewStyle style;
  final LuminaEditorHostContext? host;

  @override
  Widget build(BuildContext context) {
    final preview = job.preview!;
    return ResizablePanel.horizontal(
      draggerBuilder: (_) => const HorizontalResizableDragger(),
      children: [
        ResizablePane.flex(
          minSize: 300,
          child: MeshPreviewViewport(
            preview: preview,
            style: style,
            host: host,
          ),
        ),
        ResizablePane(
          initialSize: 290,
          minSize: 220,
          child: MeshPreviewPanel(job: job, style: style),
        ),
      ],
    );
  }
}
