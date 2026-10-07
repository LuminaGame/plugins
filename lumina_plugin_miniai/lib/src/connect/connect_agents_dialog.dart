import 'dart:async';
import 'dart:io';

import 'package:lumina_editor_api/lumina_editor_api.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';

import 'package:lumina_plugin_miniai/src/connect/mcp_client_config.dart';

/// Plugins ▸ MiniAI ▸ Connect External Agents…: registers the
/// editor's MCP server with Antigravity and Claude Code.
Future<void> showConnectAgentsDialog(BuildContext context, {required EditorMcp mcp, String? projectDir, Map<String, String>? environment}) async {
  await showOverlay<void>(
    context,
    const DialogConfiguration(),
    builder: (dialog) => ConnectAgentsDialog(
      launch: mcp.clientLaunch,
      targets: McpClientConfig.targets(environment: environment ?? Platform.environment, projectDir: projectDir),
      close: () => closeOverlay(dialog),
    ),
  ).future;
}

class ConnectAgentsDialog extends StatefulWidget {
  const ConnectAgentsDialog({super.key, required this.launch, required this.targets, required this.close});

  final McpClientLaunch? launch;
  final List<McpClientTarget> targets;
  final VoidCallback close;

  @override
  State<ConnectAgentsDialog> createState() => _ConnectAgentsDialogState();
}

class _ConnectAgentsDialogState extends State<ConnectAgentsDialog> {
  final Map<McpClientKind, McpConfigStatus> _status = {};
  final Map<McpClientKind, String> _notes = {};
  final Set<McpClientKind> _busy = {};

  @override
  void initState() {
    super.initState();
    unawaited(_refresh());
  }

  Future<void> _refresh() async {
    final launch = widget.launch;
    if (launch == null) return;
    for (final t in widget.targets) {
      final s = await McpClientConfig.status(t, launch);
      if (!mounted) return;
      setState(() => _status[t.kind] = s);
    }
  }

  Future<void> _run(McpClientTarget t, Future<String?> Function() action, String done) async {
    setState(() => _busy.add(t.kind));
    try {
      final backup = await action();
      _notes[t.kind] = backup == null ? done : '$done Previous file kept as $backup.';
    } on FormatException catch (e) {
      _notes[t.kind] = e.message;
    } on FileSystemException catch (e) {
      _notes[t.kind] = '${e.message}: ${e.path}';
    } finally {
      _busy.remove(t.kind);
      await _refresh();
    }
  }

  Widget _badge(McpConfigStatus? s) => switch (s?.state) {
        McpConfigState.configured => const PrimaryBadge(child: Text('Connected')),
        McpConfigState.outdated => const SecondaryBadge(child: Text('Out of date')),
        McpConfigState.unreadable => const DestructiveBadge(child: Text('Unreadable')),
        McpConfigState.missing || McpConfigState.notConfigured => const OutlineBadge(child: Text('Not connected')),
        null => const OutlineBadge(child: Text('…')),
      };

  Widget _card(BuildContext context, McpClientTarget t) {
    final launch = widget.launch!;
    final muted = Theme.of(context).colorScheme.mutedForeground;
    final s = _status[t.kind];
    final busy = _busy.contains(t.kind);
    final state = s?.state;
    final connected = state == McpConfigState.configured || state == McpConfigState.outdated;
    return Card(
      key: ValueKey('miniai_connect_${t.kind.name}'),
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(child: Text(t.label, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600))),
              KeyedSubtree(key: ValueKey('miniai_connect_status_${t.kind.name}'), child: _badge(s)),
            ],
          ),
          const SizedBox(height: 4),
          Text('${t.scope} · ${t.file.path}', style: TextStyle(fontSize: 10, color: muted)),
          if (t.kind == McpClientKind.claudeCode)
            Text('.mcp.json holds this machine\'s paths; Claude Code asks you to approve the server on first use.',
                style: TextStyle(fontSize: 10, color: muted)),
          if (state == McpConfigState.unreadable)
            Text(s!.message ?? '', style: TextStyle(fontSize: 10, color: Theme.of(context).colorScheme.destructive)),
          if (_notes[t.kind] != null) ...[
            const SizedBox(height: 4),
            Text(_notes[t.kind]!, key: ValueKey('miniai_connect_note_${t.kind.name}'), style: const TextStyle(fontSize: 10)),
          ],
          const SizedBox(height: 8),
          Row(
            children: [
              PrimaryButton(
                key: ValueKey('miniai_connect_do_${t.kind.name}'),
                density: ButtonDensity.compact,
                onPressed: busy || state == McpConfigState.configured || state == McpConfigState.unreadable || s == null
                    ? null
                    : () => _run(t, () => McpClientConfig.connect(t, launch), 'Connected.'),
                child: Text(state == McpConfigState.outdated ? 'Update' : 'Connect'),
              ),
              const SizedBox(width: 6),
              if (connected)
                OutlineButton(
                  key: ValueKey('miniai_connect_remove_${t.kind.name}'),
                  density: ButtonDensity.compact,
                  onPressed: busy ? null : () => _run(t, () => McpClientConfig.disconnect(t), 'Disconnected.'),
                  child: const Text('Disconnect'),
                ),
            ],
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final launch = widget.launch;
    final muted = Theme.of(context).colorScheme.mutedForeground;
    return AlertDialog(
      title: const Text('Connect External Agents'),
      content: SizedBox(
        width: 560,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Lets an agent outside the editor use the same editor tools as MiniAI, through the stdio bridge. '
              'The entry holds no token: the bridge finds the running editor itself, so it keeps working after a restart.',
              style: TextStyle(fontSize: 11, color: muted),
            ),
            const SizedBox(height: 12),
            if (launch == null)
              Text('This editor has no MCP server to connect to.', style: TextStyle(fontSize: 11, color: muted))
            else ...[
              for (final t in widget.targets) ...[_card(context, t), const SizedBox(height: 8)],
              Text('Command: ${launch.command} ${launch.args.join(' ')}',
                  key: const ValueKey('miniai_connect_command'), style: TextStyle(fontSize: 10, color: muted)),
            ],
          ],
        ),
      ),
      actions: [PrimaryButton(onPressed: widget.close, child: const Text('Close'))],
    );
  }
}
