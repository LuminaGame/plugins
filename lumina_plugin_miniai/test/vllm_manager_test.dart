import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_editor_api/lumina_editor_api.dart';
import 'package:lumina_plugin_miniai/src/local/vllm_manager.dart';
import 'package:lumina_plugin_miniai/src/settings/provider_settings.dart';
import 'package:lumina_plugin_miniai/src/llm/sampling.dart';

void main() {
  test(
    'vllm runtime configuration persists independently of legacy local models',
    () async {
      final root = await Directory.systemTemp.createTemp('vllm_settings_');
      addTearDown(() => root.delete(recursive: true));
      final storage = PluginStorage(userDir: root);
      final providers = ProviderSettings(storage);
      final runtime = VllmManager(storage, providers);
      addTearDown(runtime.dispose);
      addTearDown(providers.dispose);
      runtime.endpoint = 'http://10.5.10.3:8098/v1';
      runtime.runtimeRoot = '/home/machine/.local/share/lumina/vllm';
      runtime.gpu = '0';
      runtime.backend = 'cpu';
      runtime.nativeBinary = '${root.path}/runtime/bin/vllm-server.exe';
      runtime.nativeModel = '${root.path}/models/gemma';
      runtime.vulkanGpu = '0';
      await runtime.use();
      final restored = VllmManager(storage, providers);
      addTearDown(restored.dispose);
      await restored.load();
      expect(restored.endpoint, runtime.endpoint);
      expect(restored.gpu, '0');
      expect(restored.backend, 'cpu');
      expect(restored.nativeBinary, runtime.nativeBinary);
      expect(restored.nativeModel, runtime.nativeModel);
      expect(restored.vulkanGpu, '0');
      expect(providers.selected?.model, VllmManager.modelId);
      expect(providers.selected?.effectiveBackend, ServerBackend.vllmCpp);
      expect(providers.selected?.acceptsImages, isFalse);
      expect(
        VllmManager.wslPath(r'C:\Users\test user\runtime.py'),
        '/mnt/c/Users/test user/runtime.py',
      );
    },
  );

  test('missing native Windows executable reports a startup failure', () async {
    if (!Platform.isWindows) return;
    final root = await Directory.systemTemp.createTemp('vllm_native_');
    addTearDown(() => root.delete(recursive: true));
    final storage = PluginStorage(userDir: root);
    final providers = ProviderSettings(storage);
    final runtime = VllmManager(storage, providers);
    addTearDown(runtime.dispose);
    addTearDown(providers.dispose);
    runtime.nativeBinary = '${root.path}/missing-vllm-server.exe';
    final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    runtime.endpoint = 'http://127.0.0.1:${probe.port}/v1';
    await probe.close();
    await runtime.start();
    expect(runtime.ready, isFalse);
    expect(runtime.busy, isFalse);
    expect(runtime.failed, isTrue);
    expect(runtime.status, contains('Native vllm.cpp executable is missing'));
    expect(runtime.ownsServer, isFalse);
  });

  test(
    'failed vllm connection exposes the reason without replacing the selected provider',
    () async {
      final root = await Directory.systemTemp.createTemp('vllm_connection_');
      addTearDown(() => root.delete(recursive: true));
      final storage = PluginStorage(userDir: root);
      final providers = ProviderSettings(storage);
      final runtime = VllmManager(storage, providers);
      addTearDown(runtime.dispose);
      addTearDown(providers.dispose);
      final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      runtime.endpoint = 'http://127.0.0.1:${probe.port}/v1';
      await probe.close();
      expect(await runtime.connect(), isFalse);
      expect(runtime.failed, isTrue);
      expect(runtime.status, isNotEmpty);
      expect(providers.providers, isEmpty);
    },
  );
}
