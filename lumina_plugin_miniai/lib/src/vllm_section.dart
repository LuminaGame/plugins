import 'dart:async';
import 'package:shadcn_flutter/shadcn_flutter.dart';
import 'package:lumina_plugin_miniai/src/local/vllm_manager.dart';

/// Managed local Gemma inference and a verified alternative LAN endpoint.
class VllmSection extends StatefulWidget {
  const VllmSection({super.key, required this.manager});
  final VllmManager manager;
  @override
  State<VllmSection> createState() => _VllmSectionState();
}

class _VllmSectionState extends State<VllmSection> {
  late final TextEditingController _endpoint = TextEditingController(
    text: widget.manager.endpoint,
  );
  late final TextEditingController _root = TextEditingController(
    text: widget.manager.runtimeRoot,
  );
  late final TextEditingController _distribution = TextEditingController(
    text: widget.manager.distribution,
  );
  late final TextEditingController _gpu = TextEditingController(
    text: widget.manager.gpu,
  );
  late final TextEditingController _nativeBinary = TextEditingController(
    text: widget.manager.nativeBinary,
  );
  late final TextEditingController _nativeModel = TextEditingController(
    text: widget.manager.nativeModel,
  );
  VllmManager get manager => widget.manager;
  late final TextEditingController _vulkanGpu = TextEditingController(
    text: widget.manager.vulkanGpu,
  );
  @override
  void dispose() {
    _endpoint.dispose();
    _root.dispose();
    _distribution.dispose();
    _gpu.dispose();
    _nativeBinary.dispose();
    _nativeModel.dispose();
    _vulkanGpu.dispose();
    super.dispose();
  }

  Future<void> _action(Future<void> Function() action) async {
    manager.endpoint = _endpoint.text.trim();
    manager.runtimeRoot = _root.text.trim();
    manager.distribution = _distribution.text.trim();
    manager.gpu = _gpu.text.trim();
    manager.nativeBinary = _nativeBinary.text.trim();
    manager.nativeModel = _nativeModel.text.trim();
    manager.vulkanGpu = _vulkanGpu.text.trim();
    await action();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: manager,
    builder: (_, _) => Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('Gemma 4 E4B · vllm.cpp').semiBold(),
          const Gap(8),
          const Text(
            'Local inference. Windows can use a native executable or Ubuntu WSL. A LAN server is also supported.',
          ),
          const Gap(8),
          TextField(
            controller: _nativeBinary,
            enabled: !manager.busy && !manager.ownsServer,
            placeholder: const Text(
              'Native Windows vllm-server.exe (optional)',
            ),
          ),
          const Gap(6),
          TextField(
            controller: _nativeModel,
            enabled: !manager.busy && !manager.ownsServer,
            placeholder: const Text('Native Gemma model folder'),
          ),
          const Gap(8),
          TextField(
            key: const ValueKey('miniai_vllm_endpoint'),
            controller: _endpoint,
            enabled: !manager.busy && !manager.ownsServer,
            placeholder: const Text('http://127.0.0.1:8098/v1'),
          ),
          const Gap(6),
          TextField(
            controller: _root,
            enabled: !manager.busy && !manager.ownsServer,
            placeholder: const Text('Runtime folder (Linux/WSL path)'),
          ),
          const Gap(6),
          TextField(
            controller: _distribution,
            enabled: !manager.busy && !manager.ownsServer,
            placeholder: const Text('WSL distribution'),
          ),
          const Gap(6),
          TextField(
            controller: _gpu,
            enabled: !manager.busy && !manager.ownsServer,
            placeholder: const Text('CUDA GPU index'),
          ),
          const Gap(6),
          TextField(
            controller: _vulkanGpu,
            enabled: !manager.busy && !manager.ownsServer,
            placeholder: const Text('Native Vulkan GPU index'),
          ),
          const Gap(6),
          Select<String>(
            value: manager.nativeDevice,
            onChanged: manager.busy || manager.ownsServer
                ? null
                : (value) {
                    if (value != null) {
                      setState(() => manager.nativeDevice = value);
                    }
                  },
            itemBuilder: (_, value) => Text('Native device: $value'),
            popup: SelectPopup(
              items: SelectItemList(
                children: [
                  for (final value in ['cpu', 'auto'])
                    SelectItemButton(value: value, child: Text(value)),
                ],
              ),
            ).call,
          ),
          const Gap(6),
          Select<String>(
            value: manager.backend,
            onChanged: manager.busy || manager.ownsServer
                ? null
                : (value) {
                    if (value != null) setState(() => manager.backend = value);
                  },
            itemBuilder: (_, value) => Text(value),
            popup: SelectPopup(
              items: SelectItemList(
                children: [
                  for (final value in ['cuda-fat', 'vulkan', 'cpu'])
                    SelectItemButton(value: value, child: Text(value)),
                ],
              ),
            ).call,
          ),
          const Gap(8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              OutlineButton(
                key: const ValueKey('miniai_vllm_install'),
                onPressed: manager.busy
                    ? null
                    : () => unawaited(_action(manager.install)),
                child: const Text('Install'),
              ),
              PrimaryButton(
                key: const ValueKey('miniai_vllm_start'),
                onPressed: manager.busy || manager.ready
                    ? null
                    : () => unawaited(_action(manager.start)),
                child: const Text('Start'),
              ),
              OutlineButton(
                key: const ValueKey('miniai_vllm_connect'),
                onPressed: manager.busy
                    ? null
                    : () => unawaited(
                        _action(() async {
                          await manager.connect();
                        }),
                      ),
                child: const Text('Connect & use'),
              ),
              OutlineButton(
                onPressed: () => unawaited(manager.stop()),
                child: const Text('Stop'),
              ),
            ],
          ),
          const Gap(8),
          if (manager.busy) const LinearProgressIndicator(),
          Text(
            manager.status,
            key: const ValueKey('miniai_vllm_status'),
            style: TextStyle(
              fontSize: 10,
              color: manager.failed
                  ? Theme.of(context).colorScheme.destructive
                  : null,
            ),
          ),
        ],
      ),
    ),
  );
}
