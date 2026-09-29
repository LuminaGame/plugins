// The local model manager runs the real llama-server + MiniCPM5 on
// GPU 1 — ready, a crash from outside, a restart, a stop, and a stale server
// cleaned up. Skipped unless installed in `miniai/` of Lumina's data directory.
// The live tests share the one installed server (and its pid file): run
// them with `flutter test --concurrency=1`, or a start in one file cleans up
// the other's server as stale.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_editor_api/lumina_editor_api.dart';
import 'package:lumina_plugin_miniai/lumina_plugin_miniai.dart';

import 'support/local_mcp.dart';
import 'support/replay_server.dart';

Future<bool> _alive(int pid) => LocalModelManager.isLlamaServer(pid);

Future<void> _until(bool Function() done, {Duration timeout = const Duration(seconds: 20)}) async {
  final end = DateTime.now().add(timeout);
  while (!done() && DateTime.now().isBefore(end)) {
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
}

void main() {
  final env = {...Platform.environment, 'FILAMENT_GPU': 'RTX PRO 2000'};
  final installed = LocalModelManager(root: LocalModelManager.defaultRoot(env)).isInstalled();
  late Directory temp;

  setUp(() async => temp = await Directory.systemTemp.createTemp('miniai_live_'));
  tearDown(() async {
    try {
      await temp.delete(recursive: true);
    } catch (_) {}
  });

  test('start → ready on GPU 1, crash from outside, restart, stop', () async {
    if (!installed) return markTestSkipped('MiniCPM5 / llama-server not installed');
    final controller = MiniAiController(
      storage: PluginStorage(userDir: Directory('${temp.path}/user')),
      mcp: LocalMcp(),
      environment: env,
      httpClient: realHttpClient,
      localHttpClient: realIoHttpClient,
    );
    await controller.load();
    final m = controller.local;
    await m.start();
    expect(m.status, LocalModelStatus.ready, reason: m.message);
    expect(m.device, 'Vulkan0');
    final health = await (await realIoHttpClient().getUrl(Uri.parse('http://127.0.0.1:${m.port}/health'))).close();
    expect(health.statusCode, 200);
    expect(m.pidFile.existsSync(), isTrue);
    await _until(() => controller.settings.selected?.id == MiniAiController.localProviderId);
    expect(controller.settings.selected!.baseUrl, 'http://127.0.0.1:${m.port}/v1');
    expect(controller.settings.selected!.local, isTrue);

    // Killed from outside → crashed.
    final pid = m.pid!;
    await Process.run(Platform.isWindows ? 'taskkill' : 'kill', Platform.isWindows ? ['/F', '/PID', '$pid'] : ['-9', '$pid']);
    await _until(() => m.status == LocalModelStatus.crashed);
    expect(m.status, LocalModelStatus.crashed);
    expect(m.message, contains('exited'));

    await m.start();
    expect(m.status, LocalModelStatus.ready, reason: m.message);
    final pid2 = m.pid!;
    await m.stop();
    expect(m.status, LocalModelStatus.stopped);
    expect(m.pidFile.existsSync(), isFalse);
    expect(await _alive(pid2), isFalse);
    controller.dispose();
  }, timeout: const Timeout(Duration(minutes: 4)));

  test('a server a crashed editor left behind is killed by the next start', () async {
    if (!installed) return markTestSkipped('MiniCPM5 / llama-server not installed');
    final a = LocalModelManager(root: LocalModelManager.defaultRoot(env), environment: env, httpClient: realIoHttpClient);
    await a.start();
    expect(a.status, LocalModelStatus.ready, reason: a.message);
    final orphan = a.pid!;
    // The editor "crashes": the manager is dropped without stop(); the pid
    // file stays behind.
    expect(a.pidFile.existsSync(), isTrue);

    final b = LocalModelManager(root: LocalModelManager.defaultRoot(env), environment: env, httpClient: realIoHttpClient);
    await b.start();
    expect(b.status, LocalModelStatus.ready, reason: b.message);
    expect(await _alive(orphan), isFalse);
    final pid = b.pid!;
    await b.stop();
    expect(await _alive(pid), isFalse);
    a.dispose();
    b.dispose();
  }, timeout: const Timeout(Duration(minutes: 4)));
}
