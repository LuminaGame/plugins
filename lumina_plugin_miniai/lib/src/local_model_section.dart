import 'dart:async';

import 'package:shadcn_flutter/shadcn_flutter.dart';

import 'package:lumina_plugin_miniai/src/llm/sampling.dart';
import 'package:lumina_plugin_miniai/src/local/local_catalog.dart';
import 'package:lumina_plugin_miniai/src/local/local_model_manager.dart';
import 'package:lumina_plugin_miniai/src/miniai_controller.dart';
import 'package:lumina_plugin_miniai/src/sampling_section.dart';
import 'package:lumina_plugin_miniai/src/settings/provider_settings.dart';

/// Local model (recommended): pick a MiniCPM5 variant, download
/// it with llama.cpp, start / stop / restart it on a GPU, and see its state.
class LocalModelSection extends StatefulWidget {
  const LocalModelSection({super.key, required this.controller});

  final MiniAiController controller;

  @override
  State<LocalModelSection> createState() => _LocalModelSectionState();
}

class _LocalModelSectionState extends State<LocalModelSection> {
  LocalModelManager get m => widget.controller.local;

  @override
  void initState() {
    super.initState();
    m.addListener(_changed);
    if (m.serverBinary.existsSync() && m.devices == null) unawaited(m.listDevices());
  }

  @override
  void didUpdateWidget(LocalModelSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller.local != m) {
      oldWidget.controller.local.removeListener(_changed);
      m.addListener(_changed);
    }
  }

  @override
  void dispose() {
    m.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  ProviderConfig? _localConfig() =>
      widget.controller.settings.providers.where((p) => p.id == MiniAiController.localProviderId).firstOrNull;

  /// What a download still fetches.
  int _downloadSize(ModelVariant v) {
    final model = m.modelFile(v);
    final haveModel = model.existsSync() && model.lengthSync() == v.file.size;
    return (m.serverBinary.existsSync() ? 0 : LlamaBuild.current.size) + (haveModel ? 0 : v.file.size);
  }

  String _statusText() => switch (m.status) {
    LocalModelStatus.notInstalled => 'Not downloaded',
    LocalModelStatus.downloading => 'Downloading…',
    LocalModelStatus.installed => 'Downloaded · not running',
    LocalModelStatus.stopped => 'Stopped',
    LocalModelStatus.starting => 'Starting on ${m.device ?? 'the GPU'}…',
    LocalModelStatus.ready => 'Ready at 127.0.0.1:${m.port} on ${_deviceLabel(m.device)}',
    LocalModelStatus.crashed => 'Crashed',
    LocalModelStatus.failed => 'Failed',
  };

  String _deviceLabel(String? id) {
    final d = m.devices?.where((d) => d.id == id).firstOrNull;
    return d == null ? (id ?? 'the CPU') : '${d.name} ($id)';
  }

  void _showLog(BuildContext context) {
    showOverlay<void>(
      context,
      const DialogConfiguration(),
      builder: (c) => AlertDialog(
        title: const Text('llama-server log'),
        content: SizedBox(
          width: 560,
          height: 320,
          child: SingleChildScrollView(
            child: SelectableText(m.message ?? m.logTail, style: const TextStyle(fontSize: 10, fontFamily: 'monospace')),
          ),
        ),
        actions: [PrimaryButton(onPressed: () => closeOverlay(c), child: const Text('Close'))],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.mutedForeground;
    final installed = m.isInstalled();
    final locked = m.isRunning || m.isBusy;
    final status = m.status;
    final bad = status == LocalModelStatus.crashed || status == LocalModelStatus.failed;
    const small = TextStyle(fontSize: 10);

    return Card(
      key: const ValueKey('miniai_local_model'),
      padding: const EdgeInsets.all(10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              const Icon(LucideIcons.cpu, size: 14),
              const SizedBox(width: 6),
              const Expanded(
                child: Text('Local model (recommended)', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
              ),
            ],
          ),
          const SizedBox(height: 4),
          // Its own line: "Ready at … on <GPU> (Vulkan0)" is long.
          Text(
            _statusText(),
            key: const ValueKey('miniai_local_status'),
            style: TextStyle(fontSize: 11, fontWeight: FontWeight.w500, color: bad ? theme.colorScheme.destructive : null),
          ),
          const SizedBox(height: 4),
          Text('Runs on this machine with llama.cpp ${LlamaBuild.tag}; nothing leaves your computer.', style: TextStyle(fontSize: 10, color: muted)),
          const SizedBox(height: 8),
          Select<ModelVariant>(
            key: const ValueKey('miniai_local_variant'),
            value: m.variant,
            onChanged: locked ? null : (v) => v == null ? null : m.selectVariant(v),
            itemBuilder: (_, v) => Text('${v.label} · ${formatBytes(v.file.size)}', style: small),
            popup: SelectPopup(
              items: SelectItemList(
                children: [
                  for (final v in ModelVariant.all)
                    SelectItemButton(
                      value: v,
                      child: Text('${v.label} · ${formatBytes(v.file.size)}${m.isInstalled(v) ? ' · downloaded' : ''}', style: small),
                    ),
                ],
              ),
            ).call,
          ),
          const SizedBox(height: 8),
          if (status == LocalModelStatus.downloading) ...[
            Text(
              '${m.progressLabel ?? ''} · ${formatBytes(m.progressReceived)} / ${formatBytes(m.progressTotal)}',
              key: const ValueKey('miniai_local_progress_label'),
              style: small,
            ),
            const SizedBox(height: 4),
            LinearProgressIndicator(key: const ValueKey('miniai_local_progress'), value: m.progressTotal == 0 ? null : m.progressReceived / m.progressTotal),
            const SizedBox(height: 6),
            OutlineButton(key: const ValueKey('miniai_local_cancel'), density: ButtonDensity.compact, onPressed: m.cancelInstall, child: const Text('Cancel')),
          ] else if (!installed)
            PrimaryButton(
              key: const ValueKey('miniai_local_download'),
              density: ButtonDensity.compact,
              leading: const Icon(LucideIcons.download, size: 14),
              onPressed: () => unawaited(m.install()),
              child: Text('Download (${formatBytes(_downloadSize(m.variant))})'),
            )
          else ...[
            Row(
              children: [
                const Text('GPU', style: small),
                const SizedBox(width: 8),
                Expanded(
                  child: Select<String>(
                    key: const ValueKey('miniai_local_gpu'),
                    value: m.devices == null
                        ? null
                        : (m.effectiveGpuName == null ? null : LocalModelManager.matchDevice(m.devices!, m.effectiveGpuName!)?.name) ??
                              m.devices!.firstOrNull?.name,
                    placeholder: const Text('Default', style: small),
                    onChanged: locked ? null : (name) => m.selectGpu(name),
                    itemBuilder: (_, name) => Text(name, style: small),
                    popup: SelectPopup(
                      items: SelectItemList(
                        children: [
                          for (final d in m.devices ?? const <GpuDevice>[])
                            SelectItemButton(
                              value: d.name,
                              child: Text('${d.id}: ${d.description}', style: small),
                            ),
                        ],
                      ),
                    ).call,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                if (m.isRunning) ...[
                  OutlineButton(
                    key: const ValueKey('miniai_local_stop'),
                    density: ButtonDensity.compact,
                    onPressed: () => unawaited(m.stop()),
                    child: const Text('Stop'),
                  ),
                  const SizedBox(width: 6),
                  OutlineButton(
                    key: const ValueKey('miniai_local_restart'),
                    density: ButtonDensity.compact,
                    onPressed: status == LocalModelStatus.ready ? () => unawaited(m.restart()) : null,
                    child: const Text('Restart'),
                  ),
                ] else
                  PrimaryButton(
                    key: const ValueKey('miniai_local_start'),
                    density: ButtonDensity.compact,
                    leading: const Icon(LucideIcons.play, size: 14),
                    onPressed: () => unawaited(m.start()),
                    child: Text(status == LocalModelStatus.crashed ? 'Restart' : 'Start'),
                  ),
                const Spacer(),
                if (bad || m.logTail.isNotEmpty)
                  GhostButton(
                    key: const ValueKey('miniai_local_log'),
                    density: ButtonDensity.compact,
                    onPressed: () => _showLog(context),
                    child: const Text('Show log', style: small),
                  ),
              ],
            ),
          ],
          // The local provider's sampling, once it exists (after the first
          // start); saved as it changes.
          if ((installed ? _localConfig() : null) case final config?) ...[
            const SizedBox(height: 6),
            Builder(builder: (context) {
              final (defaults, source) = SamplingDefaults.withSource(config.model, ServerBackend.llamaCpp);
              return SamplingSection(
                keyPrefix: 'miniai_local_sampling',
                value: config.sampling ?? defaults,
                defaults: defaults,
                defaultsSource: source,
                backend: ServerBackend.llamaCpp,
                onChanged: (v) {
                  unawaited(widget.controller.settings.updateSampling(config.id, v == defaults ? null : v, backend: ServerBackend.llamaCpp));
                  setState(() {});
                },
              );
            }),
          ],
          if (bad && m.message != null) ...[
            const SizedBox(height: 6),
            Text(
              m.message!.split('\n').first,
              key: const ValueKey('miniai_local_error'),
              style: TextStyle(fontSize: 10, color: theme.colorScheme.destructive),
            ),
          ] else if (m.message != null && status != LocalModelStatus.ready) ...[
            const SizedBox(height: 6),
            Text(m.message!, style: TextStyle(fontSize: 10, color: muted)),
          ],
        ],
      ),
    );
  }
}
