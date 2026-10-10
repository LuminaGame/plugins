import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:lumina_editor_api/lumina_editor_api.dart';

import 'package:lumina_plugin_miniai/src/local/local_model_manager.dart'
    show LocalModelManager;
import 'package:lumina_plugin_miniai/src/llm/openai_compat_provider.dart';
import 'package:lumina_plugin_miniai/src/llm/sampling.dart';
import 'package:lumina_plugin_miniai/src/settings/provider_settings.dart';

/// Gemma 4 E4B through a pinned vllm.cpp process, or a configured LAN endpoint.
/// Windows supports a native build; published Linux binaries run through WSL.
class VllmManager extends ChangeNotifier {
  VllmManager(this.storage, this.providers);
  static const providerId = 'miniai_vllm';
  static const modelId = 'gemma-4-E4B-it';
  final PluginStorage storage;
  final ProviderSettings providers;
  String endpoint = 'http://127.0.0.1:8098/v1';
  String runtimeRoot = '~/.local/share/lumina/vllm';
  String distribution = 'Ubuntu';
  String backend = 'cuda-fat';
  String gpu = '1';
  String nativeBinary = '';
  String nativeModel = '';
  String vulkanGpu = '0';
  String nativeDevice = 'cpu';
  bool busy = false;
  bool ready = false;
  bool failed = false;
  String status = 'Gemma 4 E4B · vllm.cpp';
  Process? _job;
  Process? _server;
  bool _disposed = false;
  bool get ownsServer => _server != null;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<void> load() async {
    final settings = await storage.readJson('vllm');
    endpoint = settings?['endpoint'] as String? ?? endpoint;
    runtimeRoot = settings?['root'] as String? ?? runtimeRoot;
    distribution = settings?['distribution'] as String? ?? distribution;
    backend = settings?['backend'] as String? ?? backend;
    gpu = settings?['gpu'] as String? ?? gpu;
    nativeBinary = settings?['nativeBinary'] as String? ?? '';
    nativeModel = settings?['nativeModel'] as String? ?? '';
    vulkanGpu = settings?['vulkanGpu'] as String? ?? vulkanGpu;
    nativeDevice = settings?['nativeDevice'] as String? ?? nativeDevice;
    if (Platform.isWindows && nativeBinary.isEmpty) {
      final root =
          '${LocalModelManager.defaultRoot(Platform.environment)}/vllm_native';
      final binary = '$root/runtime/bin/vllm-server.exe';
      final model = '$root/models/gemma-4-E4B-it';
      if (await File(binary).exists() &&
          await File('$model/model.safetensors').exists()) {
        nativeBinary = binary;
        nativeModel = model;
      }
    }
    _notify();
  }

  Future<void> save() => storage.writeJson('vllm', {
    'endpoint': endpoint,
    'root': runtimeRoot,
    'distribution': distribution,
    'backend': backend,
    'gpu': gpu,
    'nativeBinary': nativeBinary,
    'nativeModel': nativeModel,
    'vulkanGpu': vulkanGpu,
    'nativeDevice': nativeDevice,
  });

  Future<void> use() async {
    await save();
    await providers.save(
      ProviderConfig(
        id: providerId,
        name: 'Gemma 4 E4B · vllm.cpp',
        baseUrl: endpoint,
        model: modelId,
        local: true,
        backend: ServerBackend.vllmCpp,
        // Upstream HTTP Gemma image support is limited; do not send unsupported PNG parts.
        vision: false,
      ),
    );
  }

  Future<String> _script() async {
    final root = Directory(
      '${LocalModelManager.defaultRoot(Platform.environment)}/vllm_tools',
    );
    await root.create(recursive: true);
    final file = File('${root.path}/vllm_runtime.py');
    await file.writeAsString(
      await rootBundle.loadString(
        'packages/lumina_plugin_miniai/resources/vllm_runtime.py',
      ),
    );
    return file.path;
  }

  static String wslPath(String path) {
    final normalized = path.replaceAll('\\', '/');
    if (RegExp(r'^[A-Za-z]:/').hasMatch(normalized)) {
      return '/mnt/${normalized[0].toLowerCase()}/${normalized.substring(3)}';
    }
    return normalized;
  }

  Future<Process> _run(String action) async {
    if (Platform.isWindows && nativeBinary.isNotEmpty && action == 'start') {
      if (!await File(nativeBinary).exists()) {
        throw StateError(
          'Native vllm.cpp executable is missing: $nativeBinary',
        );
      }
      if (!await File('$nativeModel/config.json').exists()) {
        throw StateError('Gemma model config is missing: $nativeModel');
      }
      return Process.start(
        nativeBinary,
        [
          '--model',
          nativeModel,
          '--host',
          '127.0.0.1',
          '--port',
          '${Uri.parse(endpoint).port}',
          '--served-model-name',
          modelId,
          '--tool-call-parser',
          'gemma4',
          '--reasoning-parser',
          'think_auto',
          '--max-model-len',
          '4096',
          '--num-blocks',
          '129',
          '--max-num-seqs',
          '1',
          '--language-model-only',
          '--device',
          nativeDevice,
          '--no-enable-thinking',
        ],
        environment: {
          ...Platform.environment,
          'VT_VULKAN_DEVICE': vulkanGpu,
          'CUDA_VISIBLE_DEVICES': gpu,
        },
      );
    }
    final script = await _script();
    if (Platform.isWindows && nativeBinary.isNotEmpty && action == 'install') {
      if (nativeModel.isEmpty) {
        throw StateError('Choose the native Gemma model folder first.');
      }
      return Process.start('python', [
        script,
        'model',
        '--model-dir',
        nativeModel,
      ]);
    }
    final args = [
      Platform.isWindows ? wslPath(script) : script,
      action,
      '--root',
      runtimeRoot,
      '--backend',
      backend,
      '--port',
      '${Uri.parse(endpoint).port}',
    ];
    final environment = {...Platform.environment, 'CUDA_VISIBLE_DEVICES': gpu};
    if (Platform.isWindows) {
      return Process.start('wsl.exe', [
        '-d',
        distribution,
        '--exec',
        'env',
        'CUDA_VISIBLE_DEVICES=$gpu',
        'python3',
        ...args,
      ]);
    }
    return Process.start('python3', args, environment: environment);
  }

  void _output(Process process) {
    void listen(Stream<List<int>> stream) => stream
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .listen((line) {
          if (_disposed) return;
          status = line;
          _notify();
        });
    listen(process.stdout);
    listen(process.stderr);
  }

  Future<void> install() async {
    if (busy || _server != null) return;
    busy = true;
    failed = false;
    status = 'Installing vllm.cpp and Gemma 4 E4B…';
    _notify();
    try {
      await save();
      final job = _job = await _run('install');
      _output(job);
      final code = await job.exitCode;
      if (code != 0) {
        throw StateError('Installation exited with code $code: $status');
      }
      status = 'Installed · click Start';
    } catch (error) {
      failed = true;
      status = '$error';
    } finally {
      _job = null;
      busy = false;
      _notify();
    }
  }

  Future<bool> connect() async {
    try {
      final provider = OpenAiCompatProvider(
        name: 'vllm.cpp',
        baseUrl: endpoint,
      );
      final models = await provider.listModels();
      if (!models.contains(modelId)) {
        throw StateError(
          'Endpoint does not serve $modelId: ${models.join(', ')}',
        );
      }
      await use();
      ready = true;
      failed = false;
      status = 'Ready · $endpoint';
      _notify();
      return true;
    } catch (error) {
      ready = false;
      failed = true;
      status = '$error';
      _notify();
      return false;
    }
  }

  Future<void> start() async {
    if (busy || _server != null) return;
    busy = true;
    failed = false;
    _notify();
    try {
      if (!ProviderConfig.isLoopback(endpoint)) {
        await connect();
        return;
      }
      if (await _healthy()) {
        await connect();
        return;
      }
      await save();
      final server = _server = await _run('start');
      _output(server);
      unawaited(
        server.exitCode.then((code) {
          if (!identical(_server, server)) return;
          _server = null;
          ready = false;
          failed = true;
          status = 'vllm.cpp exited with code $code: $status';
          _notify();
        }),
      );
      final deadline = DateTime.now().add(const Duration(minutes: 5));
      while (_server == server && DateTime.now().isBefore(deadline)) {
        if (await _healthy()) {
          if (await connect()) return;
        }
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
      throw StateError('Server did not become ready: $status');
    } catch (error) {
      final reason = '$error';
      await stop();
      failed = true;
      status = reason;
    } finally {
      busy = false;
      _notify();
    }
  }

  Future<bool> _healthy() async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 2);
    try {
      final response = await (await client.getUrl(
        Uri.parse(endpoint).replace(path: '/health'),
      )).close().timeout(const Duration(seconds: 2));
      await response.drain<void>();
      return response.statusCode == 200;
    } catch (_) {
      return false;
    } finally {
      client.close(force: true);
    }
  }

  Future<void> stop() async {
    _job?.kill();
    final owned = _server;
    _server = null;
    if (owned != null) {
      try {
        if (Platform.isWindows && nativeBinary.isNotEmpty) {
          owned.kill();
          await owned.exitCode.timeout(const Duration(seconds: 10));
        } else {
          final stop = await _run('stop');
          _output(stop);
          final code = await stop.exitCode;
          if (code != 0) {
            throw StateError('Could not stop vllm.cpp (exit $code)');
          }
        }
      } catch (error) {
        failed = true;
        status = '$error';
        _notify();
        return;
      } finally {
        owned.kill();
      }
    }
    ready = false;
    status = 'Stopped';
    _notify();
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(stop());
    super.dispose();
  }
}
