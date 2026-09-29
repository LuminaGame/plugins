// The local model manager's pure parts — device matching on the
// real `--list-devices` output of this workspace's machine, the install check
// on the real installed files, the server's command line, the settings and
// the archive extraction.
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_editor_api/lumina_editor_api.dart';
import 'package:lumina_plugin_miniai/lumina_plugin_miniai.dart';

void main() {
  final realRoot = LocalModelManager.defaultRoot(Platform.environment);
  late Directory temp;

  setUp(() async => temp = await Directory.systemTemp.createTemp('miniai_local_'));
  tearDown(() async => temp.delete(recursive: true));

  test('--list-devices picks GPU 1 by name, never the 4080', () {
    final devices = LocalModelManager.parseDevices(File('test/fixtures/list_devices_windows.txt').readAsStringSync());
    expect(devices.map((d) => d.id), ['Vulkan0', 'Vulkan1']);
    expect(devices.first.name, 'NVIDIA RTX PRO 2000 Blackwell');
    expect(LocalModelManager.matchDevice(devices, 'RTX PRO 2000')?.id, 'Vulkan0');
    expect(LocalModelManager.matchDevice(devices, 'rtx 4080')?.id, 'Vulkan1');
    expect(LocalModelManager.matchDevice(devices, 'Radeon'), isNull);
  });

  test('an empty root is not installed; the command line carries the llama-server flags', () {
    final m = LocalModelManager(root: temp.path, environment: const {});
    expect(m.isInstalled(), isFalse);
    expect(m.status, LocalModelStatus.notInstalled);
    final args = m.serverArgs(port: 8123, device: 'Vulkan0');
    expect(args.join(' '), contains('--device Vulkan0'));
    expect(args, containsAll(['--jinja', '-ngl', '99', '-c', '8192', '--min-p', '0.0']));
    expect(args.join(' '), contains('--host 127.0.0.1 --port 8123 --alias MiniCPM5-2B-Q4_K_M'));
    expect(args[1], endsWith('models/MiniCPM5-2B-Q4_K_M.gguf'));
    m.dispose();
  });

  test('the files installed on this machine count as installed', () {
    final m = LocalModelManager(root: realRoot);
    if (!m.serverBinary.existsSync()) return markTestSkipped('llama-server is not installed in $realRoot');
    expect(m.isInstalled(), isTrue);
    expect(m.status, LocalModelStatus.installed);
    expect(m.isInstalled(ModelVariant.minicpm5_2bQ8), m.modelFile(ModelVariant.minicpm5_2bQ8).existsSync());
    m.dispose();
  });

  test('FILAMENT_GPU is the default GPU; the user pick wins', () {
    final m = LocalModelManager(root: temp.path, environment: const {'FILAMENT_GPU': 'RTX PRO 2000'});
    expect(m.effectiveGpuName, 'RTX PRO 2000');
    m.gpuName = 'RTX 4080';
    expect(m.effectiveGpuName, 'RTX 4080');
    m.dispose();
  });

  test('the settings round-trip through local.json', () async {
    final storage = PluginStorage(userDir: Directory('${temp.path}/user'));
    final a = LocalModelManager(root: temp.path, storage: storage, environment: const {});
    await a.selectVariant(ModelVariant.minicpm5_1bQ4);
    await a.selectGpu('RTX PRO 2000');
    a.autostart = false;
    await a.saveSettings();
    a.dispose();

    final b = LocalModelManager(root: temp.path, storage: storage, environment: const {});
    await b.load();
    expect(b.variant, ModelVariant.minicpm5_1bQ4);
    expect(b.gpuName, 'RTX PRO 2000');
    expect(b.autostart, isFalse);
    b.dispose();
  });

  test('a llama.cpp archive extracts with the server at bin/<build>/', () async {
    // A real zip with the release's layout: a top folder holding the server.
    final exe = LlamaBuild.serverExecutable;
    final archive = Archive()
      ..add(ArchiveFile.bytes('build/bin/$exe', 'server'.codeUnits))
      ..add(ArchiveFile.bytes('build/bin/ggml.dll', 'ggml'.codeUnits));
    final zip = File('${temp.path}/llama.zip')..writeAsBytesSync(ZipEncoder().encode(archive));
    final m = LocalModelManager(root: '${temp.path}/root', environment: const {});
    await LocalModelManager.extractServer(zip, m.binDir);
    expect(m.serverBinary.readAsStringSync(), 'server');
    expect(File('${m.binDir.path}/ggml.dll').existsSync(), isTrue);
    expect(Directory('${m.binDir.path}.extract').existsSync(), isFalse);

    // A flat archive (the Windows release) extracts in place.
    final flat = File('${temp.path}/flat.zip')..writeAsBytesSync(ZipEncoder().encode(Archive()..add(ArchiveFile.bytes(exe, 'flat'.codeUnits))));
    await LocalModelManager.extractServer(flat, m.binDir);
    expect(m.serverBinary.readAsStringSync(), 'flat');
    m.dispose();
  });

  test('a stale pid file of a dead process is removed without killing anything', () async {
    final m = LocalModelManager(root: temp.path, environment: const {});
    m.pidFile
      ..createSync(recursive: true)
      ..writeAsStringSync('{"pid": 999999, "port": 1}');
    expect(await m.cleanStaleServer(), isFalse);
    expect(m.pidFile.existsSync(), isFalse);
    m.dispose();
  });
}
