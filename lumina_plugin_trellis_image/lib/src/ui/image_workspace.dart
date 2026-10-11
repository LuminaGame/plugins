import 'dart:io';
import 'package:lumina_editor_api/lumina_editor_api.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';
import '../models/image_config.dart';
import '../shell/image_client.dart';

class ImageWorkspace extends StatefulWidget {
  const ImageWorkspace({
    super.key,
    required this.client,
    this.host,
    this.editorTheme,
  });
  final ImageClient client;
  final LuminaEditorHostContext? host;
  final EditorThemeAccess? editorTheme;
  @override
  State<ImageWorkspace> createState() => _ImageWorkspaceState();
}

class _ImageWorkspaceState extends State<ImageWorkspace> {
  final _prompt = TextEditingController();
  final _root = TextEditingController(text: ImageConfig.defaultRoot);
  final _binary = TextEditingController();
  final _gpu = TextEditingController(text: '0');
  final _steps = TextEditingController(text: '20');
  final _seed = TextEditingController(text: '42');
  final _size = TextEditingController(text: '1024');
  String? _reference;
  bool _configured = false;
  @override
  void initState() {
    super.initState();
    widget.client.addListener(_changed);
    widget.editorTheme?.addListener(_changed);
    widget.client.call('image.state');
  }

  void _changed() {
    if (!mounted) return;
    final config = widget.client.state['config'];
    if (!_configured && config is Map) {
      _root.text = config['root'] as String? ?? _root.text;
      _binary.text = config['binary'] as String? ?? '';
      _gpu.text = config['gpu'] as String? ?? '0';
      _configured = true;
    }
    // The installer resolves the executable while all fields are disabled.
    if (config is Map && _binary.text.isEmpty && config['binary'] is String) {
      _binary.text = config['binary'] as String;
    }
    setState(() {});
  }

  @override
  void dispose() {
    widget.client.removeListener(_changed);
    widget.editorTheme?.removeListener(_changed);
    for (final controller in [
      _prompt,
      _root,
      _binary,
      _gpu,
      _steps,
      _seed,
      _size,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _configure() => widget.client.call('image.configure', {
    'root': _root.text.trim(),
    'binary': _binary.text.trim(),
    'gpu': _gpu.text.trim(),
  });
  Future<void> _generate() async {
    await _configure();
    if (widget.client.error != null || !mounted) return;
    final steps = int.tryParse(_steps.text),
        seed = int.tryParse(_seed.text),
        size = int.tryParse(_size.text);
    if (steps == null || seed == null || size == null) {
      widget.client.callError = 'Steps, seed and image size must be integers.';
      setState(() {});
      return;
    }
    await widget.client.call('image.generate', {
      'prompt': _prompt.text,
      'reference': _reference,
      'steps': steps,
      'seed': seed,
      'width': size,
      'height': size,
    });
  }

  Widget _field(String label, TextEditingController controller) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(label, style: const TextStyle(fontSize: 10)),
        const Gap(4),
        TextField(
          key: ValueKey(label),
          controller: controller,
          enabled: !widget.client.busy,
        ),
      ],
    ),
  );
  Color _color(String token, Color fallback) =>
      widget.editorTheme?.color(token) ?? fallback;
  @override
  Widget build(BuildContext context) {
    final client = widget.client;
    final colors = Theme.of(context).colorScheme;
    return ResizablePanel.horizontal(
      draggerBuilder: (_) => const HorizontalResizableDragger(),
      children: [
        ResizablePane(
          initialSize: 320,
          minSize: 200,
          child: Container(
            color: _color('rail', colors.card),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Qwen Image 2.1 · Q4_K_M',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: _color('foreground', colors.foreground),
                    ),
                  ),
                  const Gap(12),
                  _field('Describe the image or the reference edit', _prompt),
                  if (widget.host != null) ...[
                    const Text(
                      'Reference texture (optional)',
                      style: TextStyle(fontSize: 10),
                    ),
                    const Gap(4),
                    IgnorePointer(
                      ignoring: client.busy,
                      child: EditorAssetPicker(
                        hostContext: widget.host!,
                        selectedPath: _reference,
                        typeFilter: const {AssetType.texture},
                        allowClear: true,
                        placeholder: 'Choose reference texture…',
                        onSelected: (value) =>
                            setState(() => _reference = value),
                      ),
                    ),
                    const Gap(12),
                  ],
                  _field('Steps', _steps),
                  _field('Seed', _seed),
                  _field('Square image size (256–2048)', _size),
                  PrimaryButton(
                    key: const Key('qwen_generate'),
                    onPressed: client.busy ? null : _generate,
                    child: const Text('Generate image'),
                  ),
                  const Gap(16),
                  _field('Model/runtime folder', _root),
                  _field('sd-cli executable', _binary),
                  _field('Vulkan GPU index', _gpu),
                  SecondaryButton(
                    onPressed: client.busy
                        ? null
                        : () async {
                            await _configure();
                            if (client.error == null) {
                              await client.call('image.install');
                            }
                          },
                    child: const Text('Install runtime & models'),
                  ),
                  const Gap(8),
                  SecondaryButton(
                    onPressed: client.canCancel ? client.cancel : null,
                    child: const Text('Cancel current job'),
                  ),
                ],
              ),
            ),
          ),
        ),
        ResizablePane.flex(
          minSize: 300,
          child: Container(
            color: _color('card', colors.card),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(
                  padding: const EdgeInsets.all(12),
                  color: _color('cardHeader', colors.card),
                  child: Text(
                    client.status,
                    style: const TextStyle(fontSize: 11),
                  ),
                ),
                if (client.error != null)
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: SelectableText(
                      client.error!,
                      style: TextStyle(color: colors.destructive),
                    ),
                  ),
                Expanded(
                  child: client.draft == null
                      ? const Center(
                          child: Text('Generate an image to review it here.'),
                        )
                      : Padding(
                          padding: const EdgeInsets.all(12),
                          child: Image.file(
                            File(client.draft!),
                            key: ValueKey(client.draftId),
                            fit: BoxFit.contain,
                            errorBuilder: (_, error, _) =>
                                Center(child: Text('Preview failed: $error')),
                          ),
                        ),
                ),
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: PrimaryButton(
                    key: const Key('qwen_approve_3d'),
                    onPressed: client.busy || client.draftId == null
                        ? null
                        : client.approve3d,
                    child: const Text('Approve this image & generate 3D'),
                  ),
                ),
                if (client.state['result'] is Map)
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: SelectableText(
                      'Saved asset: ${(client.state['result'] as Map)['asset_path']}',
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
