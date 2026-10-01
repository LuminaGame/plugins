import 'package:shadcn_flutter/shadcn_flutter.dart';

import 'claude_code_section.dart';
import 'llm/chat_image.dart';
import 'llm/openai_compat_provider.dart';
import 'llm/sampling.dart';
import 'local_model_section.dart';
import 'miniai_controller.dart';
import 'sampling_section.dart';
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

  /// "Model accepts images" as the user set it; null follows the model name.
  bool? _vision;

  /// The server type: stored, found by Test connection or picked; null
  /// guesses it from the URL.
  ServerBackend? _backend;

  /// The user picked [_backend] in this dialog: Test connection keeps it.
  bool _backendPicked = false;

  /// The sampling the user set; null follows the model's defaults.
  SamplingSettings? _sampling;
  bool _samplingValid = true;

  ServerBackend get _effectiveBackend => _backend ?? ServerBackend.guess(_url.text.trim());

  @override
  void initState() {
    super.initState();
    final selected = widget.settings.selected;
    // The local model's entry belongs to the manager; the form edits others.
    final current = selected == null || selected.id == MiniAiController.localProviderId || selected.isClaudeCode ? null : selected;
    _name = TextEditingController(text: current?.name ?? 'Local model');
    _url = TextEditingController(text: current?.baseUrl ?? 'http://127.0.0.1:8080/v1');
    _model = TextEditingController(text: current?.model ?? '')..addListener(_modelChanged);
    _vision = current?.vision;
    _backend = current?.backend;
    _sampling = current?.sampling;
  }

  void _modelChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    for (final c in [_name, _url, _model, _key]) {
      c.dispose();
    }
    super.dispose();
  }

  String? _apiKey() {
    final current = widget.settings.selected;
    return _key.text.isNotEmpty ? _key.text : (current == null ? null : widget.settings.keyFor(current));
  }

  OpenAiCompatProvider _provider() =>
      OpenAiCompatProvider(name: 'test', baseUrl: _url.text.trim(), apiKey: _apiKey(), client: widget.settings.httpClient);

  Future<ServerBackend> _detect() =>
      ServerBackendProbe.detect(_url.text.trim(), apiKey: _apiKey(), client: widget.settings.httpClient);

  Future<void> _test() async {
    setState(() {
      _busy = true;
      _status = null;
    });
    try {
      final models = await _provider().listModels();
      final backend = _backendPicked ? _backend! : await _detect();
      if (!mounted) return;
      setState(() {
        _backend = backend;
        _models = models;
        _status = models.isEmpty
            ? 'Connected (${backend.label}); the server lists no models.'
            : 'Connected: ${models.length} model${models.length == 1 ? '' : 's'} — ${models.take(4).join(', ')} · server: ${backend.label}';
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
    final model = _model.text.trim();
    final sampling = _sampling;
    await widget.settings.save(
      ProviderConfig(
        id: id,
        name: name,
        baseUrl: url,
        model: model,
        local: ProviderConfig.isLoopback(url),
        vision: _vision,
        backend: _backend,
        // Equal to the defaults: keep following them.
        sampling: sampling == null || sampling == SamplingDefaults.forModel(model, _effectiveBackend) ? null : sampling,
      ),
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
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Checkbox(
                    key: const ValueKey('miniai_provider_vision'),
                    state: (_vision ?? VisionModels.guess(_model.text)) ? CheckboxState.checked : CheckboxState.unchecked,
                    onChanged: (s) => setState(() => _vision = s == CheckboxState.checked),
                    trailing: const Text('Model accepts images', style: TextStyle(fontSize: 11)),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    _vision == null
                        ? 'Automatic from the model name. Screenshots from the editor tools go to the model as images when on; '
                            'as a short text note when off.'
                        : 'Set by you. Screenshots from the editor tools go to the model as images when on; as a short text note when off.',
                    style: const TextStyle(fontSize: 10),
                  ).muted(),
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
            Builder(builder: (context) {
              final backend = _effectiveBackend;
              final (defaults, source) = SamplingDefaults.withSource(_model.text.trim(), backend);
              return Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: SamplingSection(
                  value: _sampling ?? defaults,
                  defaults: defaults,
                  defaultsSource: source,
                  backend: backend,
                  onChanged: (v) => setState(() => _sampling = v == defaults ? null : v),
                  onBackendChanged: (b) => setState(() {
                    _backend = b;
                    _backendPicked = true;
                  }),
                  onValidChanged: (valid) => setState(() => _samplingValid = valid),
                ),
              );
            }),
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
        PrimaryButton(key: const ValueKey('miniai_provider_save'), onPressed: _busy || !_samplingValid ? null : _save, child: const Text('Save')),
      ],
    );
  }
}
