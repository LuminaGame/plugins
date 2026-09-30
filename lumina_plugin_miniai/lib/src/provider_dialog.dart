import 'package:shadcn_flutter/shadcn_flutter.dart';

import 'claude_code_section.dart';
import 'llm/openai_compat_provider.dart';
import 'local_model_section.dart';
import 'miniai_controller.dart';
import 'settings/provider_settings.dart';

/// Model provider…: an OpenAI-compatible endpoint — a local
/// llama-server / Ollama / LM Studio, or a cloud API — with its model and an
/// optional key, tested before it is saved. With [controller], the Local
/// model card comes first.
Future<void> showProviderDialog(BuildContext context, ProviderSettings settings, {MiniAiController? controller}) async {
  await showOverlay<void>(
    context,
    const DialogConfiguration(),
    builder: (dialogContext) => _ProviderDialog(settings: settings, controller: controller, close: () => closeOverlay(dialogContext)),
  ).future;
}

class _ProviderDialog extends StatefulWidget {
  const _ProviderDialog({required this.settings, required this.close, this.controller});

  final ProviderSettings settings;
  final MiniAiController? controller;
  final VoidCallback close;

  @override
  State<_ProviderDialog> createState() => _ProviderDialogState();
}

class _ProviderDialogState extends State<_ProviderDialog> {
  late final TextEditingController _name;
  late final TextEditingController _url;
  late final TextEditingController _model;
  final TextEditingController _key = TextEditingController();
  List<String> _models = const [];
  String? _status;
  bool _statusError = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    final selected = widget.settings.selected;
    // The local model's entry belongs to the manager; the form edits others.
    final current = selected == null || selected.id == MiniAiController.localProviderId || selected.isClaudeCode ? null : selected;
    _name = TextEditingController(text: current?.name ?? 'Local model');
    _url = TextEditingController(text: current?.baseUrl ?? 'http://127.0.0.1:8080/v1');
    _model = TextEditingController(text: current?.model ?? '');
  }

  @override
  void dispose() {
    for (final c in [_name, _url, _model, _key]) {
      c.dispose();
    }
    super.dispose();
  }

  OpenAiCompatProvider _provider() {
    final current = widget.settings.selected;
    final key = _key.text.isNotEmpty ? _key.text : (current == null ? null : widget.settings.keyFor(current));
    return OpenAiCompatProvider(name: 'test', baseUrl: _url.text.trim(), apiKey: key, client: widget.settings.httpClient);
  }

  Future<void> _test() async {
    setState(() {
      _busy = true;
      _status = null;
    });
    try {
      final models = await _provider().listModels();
      setState(() {
        _models = models;
        _status = models.isEmpty
            ? 'Connected; the server lists no models.'
            : 'Connected: ${models.length} model${models.length == 1 ? '' : 's'} — ${models.take(4).join(', ')}';
        _statusError = false;
        if (_model.text.isEmpty && models.isNotEmpty) _model.text = models.first;
      });
    } catch (e) {
      setState(() {
        _status = 'Cannot connect: $e';
        _statusError = true;
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save() async {
    final url = _url.text.trim();
    final name = _name.text.trim().isEmpty ? 'Model' : _name.text.trim();
    final selected = widget.settings.selected;
    final id =
        (selected == null || selected.id == MiniAiController.localProviderId || selected.isClaudeCode ? null : selected.id) ??
            name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '_');
    await widget.settings.save(
      ProviderConfig(id: id, name: name, baseUrl: url, model: _model.text.trim(), local: ProviderConfig.isLoopback(url)),
      apiKey: _key.text.isEmpty ? null : _key.text,
    );
    widget.close();
  }

  Widget _field(String label, Widget field, {String? help}) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600)),
        const SizedBox(height: 4),
        field,
        if (help != null) ...[const SizedBox(height: 3), Text(help, style: const TextStyle(fontSize: 10)).muted()],
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final selected = widget.settings.selected;
    final current = selected == null || selected.isClaudeCode ? null : selected;
    final hasKey = current != null && widget.settings.hasKey(current);
    return AlertDialog(
      title: const Text('Model provider'),
      content: SizedBox(
        width: 460,
        height: MediaQuery.sizeOf(context).height * 0.7,
        child: SingleChildScrollView(
          child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (widget.controller != null) ...[
              LocalModelSection(controller: widget.controller!),
              const SizedBox(height: 14),
              ClaudeCodeSection(controller: widget.controller!, onUsed: widget.close),
              const SizedBox(height: 14),
              const Text('Or an endpoint', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
              const SizedBox(height: 4),
            ],
            const Text(
              'Any OpenAI-compatible endpoint: a local llama-server (MiniCPM5), Ollama, LM Studio, vLLM, OpenRouter or OpenAI.',
              style: TextStyle(fontSize: 11),
            ).muted(),
            const SizedBox(height: 12),
            _field('Name', TextField(key: const ValueKey('miniai_provider_name'), controller: _name)),
            _field(
              'Base URL',
              TextField(key: const ValueKey('miniai_provider_url'), controller: _url),
              help: 'Ends with /v1, e.g. http://127.0.0.1:8080/v1',
            ),
            _field(
              'Model',
              TextField(key: const ValueKey('miniai_provider_model'), controller: _model),
              help: _models.isEmpty ? 'Test the connection to list the server\'s models.' : null,
            ),
            if (_models.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final m in _models)
                      OutlineButton(
                        key: ValueKey('miniai_provider_pick_$m'),
                        density: ButtonDensity.compact,
                        onPressed: () => setState(() => _model.text = m),
                        child: Text(m, style: const TextStyle(fontSize: 10)),
                      ),
                  ],
                ),
              ),
            _field(
              'API key',
              TextField(
                key: const ValueKey('miniai_provider_key'),
                controller: _key,
                obscureText: true,
                placeholder: Text(hasKey ? 'Stored: ${ProviderSettings.mask(widget.settings.keyFor(current) ?? '')} — leave empty to keep' : 'Optional'),
              ),
              help: 'Kept in MiniAI\'s own credentials file, never in the project or the log.',
            ),
            if (_status != null)
              Text(
                _status!,
                key: const ValueKey('miniai_provider_status'),
                style: TextStyle(fontSize: 11, color: _statusError ? Theme.of(context).colorScheme.destructive : null),
              ),
          ],
          ),
        ),
      ),
      actions: [
        OutlineButton(key: const ValueKey('miniai_provider_test'), onPressed: _busy ? null : _test, child: const Text('Test connection')),
        GhostButton(onPressed: widget.close, child: const Text('Cancel')),
        PrimaryButton(key: const ValueKey('miniai_provider_save'), onPressed: _busy ? null : _save, child: const Text('Save')),
      ],
    );
  }
}
