import 'package:lumina_editor_api/lumina_editor_api.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';
import 'package:lumina_plugin_trellis_image/src/shell/image_client.dart';
import 'package:lumina_plugin_trellis_image/src/ui/image_workspace.dart';

class TrellisImagePlugin extends LuminaEditorPlugin {
  @override
  String get pluginName => 'lumina_plugin_trellis_image';
  ImageClient? _client;
  @override
  void register(LuminaEditorContext context) {
    final client = _client = ImageClient(
      context.processChannel(pluginName),
      trellis: context.processChannel('trellis_plugin'),
    );
    final host = context is LuminaEditorHostContext ? context : null;
    final theme = context is EditorThemeHost
        ? (context as EditorThemeHost).theme
        : null;
    context.registerTab(
      EditorTabDescriptor(
        id: 'trellis_image.editor',
        title: 'Trellis Image Studio',
        icon: LucideIcons.image,
        contentDroppable: false,
        contentBrowserOpened: false,
        builder: (_) =>
            ImageWorkspace(client: client, host: host, editorTheme: theme),
      ),
    );
    context.registerMenuItem(
      'Plugins/Trellis Image/Text or Reference to 3D…',
      EditorCommand(
        id: 'trellis_image.open',
        label: 'Text or Reference to 3D…',
        icon: LucideIcons.image,
        canExecute: () => true,
        execute: (_) => context.openTab(
          'trellis_image.editor',
          title: 'Trellis Image Studio',
        ),
      ),
    );
  }

  @override
  void unregister(LuminaEditorContext context) {
    _client?.dispose();
    _client = null;
  }
}
