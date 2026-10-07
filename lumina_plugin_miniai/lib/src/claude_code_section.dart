import 'dart:async';

import 'package:shadcn_flutter/shadcn_flutter.dart';

import 'package:lumina_plugin_miniai/src/claude_code/claude_code_cli.dart';
import 'package:lumina_plugin_miniai/src/claude_code/claude_code_protocol.dart';
import 'package:lumina_plugin_miniai/src/miniai_controller.dart';
import 'package:lumina_plugin_miniai/src/settings/provider_settings.dart';

/// Model provider… ▸ Claude Code: the detected `claude` (path, version,
/// login), the model, and **Use Claude Code**. No key: the CLI's own login
/// is used.
class ClaudeCodeSection extends StatefulWidget {
  const ClaudeCodeSection({super.key, required this.controller, this.onUsed});

  final MiniAiController controller;

  /// Called after **Use Claude Code** saved the provider.
  final VoidCallback? onUsed;

  @override
  State<ClaudeCodeSection> createState() => _ClaudeCodeSectionState();
}

class _ClaudeCodeSectionState extends State<ClaudeCodeSection> {
  final TextEditingController _path = TextEditingController();
  ClaudeCodeInstall? _install;
  List<ClaudeModel> _models = const [];
  String _model = '';
  bool _busy = false;

  MiniAiController get c => widget.controller;

  ProviderConfig? get _saved => c.settings.providers.where((p) => p.isClaudeCode).firstOrNull;

  @override
  void initState() {
    super.initState();
    _path.text = _saved?.command ?? '';
    _model = _saved?.model ?? '';
    unawaited(_detect());
  }

  @override
  void dispose() {
    _path.dispose();
    super.dispose();
  }

  String? get _override => _path.text.trim().isEmpty ? null : _path.text.trim();

  Future<void> _detect() async {
    setState(() => _busy = true);
    try {
      final install = await c.claude.cli.detect(override: _override);
      var models = const <ClaudeModel>[];
      if (install.ready) {
        try {
          models = await c.claude.probeModels(install.path!);
        } on Object {
          // The list is a convenience; the CLI default still works.
        }
      }
      if (!mounted) return;
      setState(() {
        _install = install;
        _models = models;
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _use() async {
    await c.settings.save(ProviderConfig(
      id: ProviderConfig.claudeCodeId,
      name: 'Claude Code',
      baseUrl: '',
      model: _model == 'default' ? '' : _model,
      kind: ProviderKind.claudeCode,
      command: _override,
    ));
    widget.onUsed?.call();
  }

  Widget _status(BuildContext context) {
    final theme = Theme.of(context);
    final install = _install;
    final muted = theme.colorScheme.mutedForeground;
    if (install == null) {
      return Text('Looking for claude…', key: const ValueKey('miniai_claude_status'), style: TextStyle(fontSize: 11, color: muted));
    }
    if (install.path == null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(_override == null ? 'claude not found' : 'claude not found at ${_override!}',
              key: const ValueKey('miniai_claude_status'), style: TextStyle(fontSize: 11, color: theme.colorScheme.destructive)),
          const SizedBox(height: 3),
          Text(ClaudeCodeCli.installHint, key: const ValueKey('miniai_claude_hint'), style: TextStyle(fontSize: 10, color: muted)),
        ],
      );
    }
    if (install.error != null) {
      return Text('${install.path} does not run: ${install.error}',
          key: const ValueKey('miniai_claude_status'), style: TextStyle(fontSize: 11, color: theme.colorScheme.destructive));
    }
    final auth = install.auth;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('${install.version ?? 'claude'} · ${auth?.label ?? 'login unknown'}',
            key: const ValueKey('miniai_claude_status'),
            style: TextStyle(fontSize: 11, color: auth?.loggedIn ?? false ? null : theme.colorScheme.destructive)),
        Text(install.path!, key: const ValueKey('miniai_claude_path_found'), style: TextStyle(fontSize: 10, color: muted)),
        if (!(auth?.loggedIn ?? false)) ...[
          const SizedBox(height: 3),
          Text(ClaudeCodeCli.loginHint, key: const ValueKey('miniai_claude_hint'), style: TextStyle(fontSize: 10, color: muted)),
        ],
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final install = _install;
    final active = c.settings.selected?.isClaudeCode ?? false;
    final models = [const ClaudeModel(value: '', displayName: 'Default (the CLI\'s choice)'), ..._models.where((m) => m.value != 'default')];
    if (_model.isNotEmpty && !models.any((m) => m.value == _model)) models.add(ClaudeModel(value: _model, displayName: _model));
    return Card(
      key: const ValueKey('miniai_claude_section'),
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              const Expanded(child: Text('Claude Code', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600))),
              if (active) const PrimaryBadge(child: Text('In use')),
            ],
          ),
          const SizedBox(height: 4),
          const Text(
            'Runs your installed Claude Code CLI in the project folder, on your own Claude Code login: MiniAI never asks for '
            'or stores a key for it. It uses the editor tools like MiniAI does, with the same approvals and Undo this turn.',
            style: TextStyle(fontSize: 10),
          ).muted(),
          const SizedBox(height: 8),
          _status(context),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: TextField(
                  key: const ValueKey('miniai_claude_path'),
                  controller: _path,
                  placeholder: const Text('claude path (optional; found automatically)'),
                ),
              ),
              const SizedBox(width: 6),
              OutlineButton(
                key: const ValueKey('miniai_claude_detect'),
                density: ButtonDensity.compact,
                onPressed: _busy ? null : _detect,
                child: const Text('Detect'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: Select<String>(
                  key: const ValueKey('miniai_claude_model'),
                  value: _model,
                  onChanged: (v) => setState(() => _model = v ?? ''),
                  itemBuilder: (_, v) => Text(
                    'Model: ${models.where((m) => m.value == v).firstOrNull?.displayName ?? v}',
                    style: const TextStyle(fontSize: 10),
                  ),
                  popup: SelectPopup(
                    items: SelectItemList(
                      children: [
                        for (final m in models)
                          SelectItemButton(
                            value: m.value,
                            child: Text(m.description.isEmpty ? m.displayName : '${m.displayName} — ${m.description}',
                                style: const TextStyle(fontSize: 10)),
                          ),
                      ],
                    ),
                  ).call,
                ),
              ),
              const SizedBox(width: 6),
              PrimaryButton(
                key: const ValueKey('miniai_claude_use'),
                density: ButtonDensity.compact,
                onPressed: _busy || install == null || !install.found ? null : _use,
                child: Text(active ? 'Save' : 'Use Claude Code'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
