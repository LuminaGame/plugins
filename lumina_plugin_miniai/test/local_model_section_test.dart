// The Local model card — Download for an empty root, Start for the
// files installed on this machine, and Ready / Stop against the real server
// on GPU 1 (skipped when not installed).
// The live tests share the one installed server (and its pid file): run
// them with `flutter test --concurrency=1`, or a start in one file cleans up
// the other's server as stale.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_editor_api/lumina_editor_api.dart';
import 'package:lumina_plugin_miniai/lumina_plugin_miniai.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';

import 'support/local_mcp.dart';
import 'support/replay_server.dart';

void main() {
  final env = {...Platform.environment, 'FILAMENT_GPU': 'RTX PRO 2000'};
  final realRoot = LocalModelManager.defaultRoot(env);
  late Directory temp;

  setUp(() async => temp = await Directory.systemTemp.createTemp('miniai_section_'));
  tearDown(() async {
    try {
      await temp.delete(recursive: true);
    } catch (_) {}
  });

  MiniAiController controllerFor(String root) {
    final storage = PluginStorage(userDir: Directory('${temp.path}/user'));
    return MiniAiController(
      storage: storage,
      mcp: LocalMcp(),
      environment: env,
      httpClient: realHttpClient,
      local: LocalModelManager(root: root, storage: storage, environment: env, httpClient: realIoHttpClient),
    );
  }

  Future<void> pumpPanel(WidgetTester tester, MiniAiController c) async {
    await tester.binding.setSurfaceSize(const Size(420, 900));
    await tester.pumpWidget(
      ShadcnApp(
        home: Scaffold(child: ChatPanel(controller: c)),
      ),
    );
    await tester.pump();
  }

  testWidgets('an empty root offers Download with the variant size', (tester) async {
    final c = controllerFor('${temp.path}/root');
    await pumpPanel(tester, c);
    expect(find.byKey(const ValueKey('miniai_local_model')), findsOneWidget);
    expect(find.text('Not downloaded'), findsOneWidget);
    final size = formatBytes(LlamaBuild.current.size + ModelVariant.defaultVariant.file.size);
    expect(find.text('Download ($size)'), findsOneWidget);
    expect(find.byKey(const ValueKey('miniai_setup_provider')), findsOneWidget);
    c.dispose();
  });

  testWidgets('the installed model offers Start, then runs Ready on GPU 1 and stops', (tester) async {
    final c = controllerFor(realRoot);
    if (!c.local.isInstalled()) {
      c.dispose();
      return markTestSkipped('MiniCPM5 / llama-server not installed in $realRoot');
    }
    await pumpPanel(tester, c);
    await tester.runAsync(() => c.local.listDevices());
    await tester.pump();
    expect(find.text('Downloaded · not running'), findsOneWidget);
    expect(find.byKey(const ValueKey('miniai_local_start')), findsOneWidget);
    expect(find.text('NVIDIA RTX PRO 2000 Blackwell'), findsOneWidget);

    await tester.runAsync(() => c.local.start());
    await tester.pump();
    expect(c.local.status, LocalModelStatus.ready, reason: c.local.message);
    expect(find.textContaining('Ready at 127.0.0.1:${c.local.port} on NVIDIA RTX PRO 2000 Blackwell (Vulkan0)'), findsOneWidget);
    expect(find.byKey(const ValueKey('miniai_local_stop')), findsOneWidget);

    // The process I/O runs outside the fake-async zone.
    Object? error;
    await tester.runAsync(() => c.local.stop().catchError((Object e, StackTrace s) => error = '$e\n$s'));
    expect(error, isNull);
    await tester.pump();
    expect(c.local.status, LocalModelStatus.stopped, reason: c.local.message);
    expect(find.text('Stopped'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 2));
    c.dispose();
  }, timeout: const Timeout(Duration(minutes: 3)));
}
