import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter/foundation.dart';
import 'package:lumina_editor_api/lumina_editor_api.dart';

import 'package:lumina_plugin_miniai/src/local/downloader.dart';
import 'package:lumina_plugin_miniai/src/local/local_catalog.dart';

/// Where the local model is in its life.
enum LocalModelStatus { notInstalled, downloading, installed, starting, ready, crashed, stopped, failed }

/// One llama.cpp device from `llama-server --list-devices`.
@immutable
class GpuDevice {
  const GpuDevice(this.id, this.description);

  /// e.g. `Vulkan0`.
  final String id;

  /// e.g. `NVIDIA RTX PRO 2000 Blackwell (16051 MiB, 15283 MiB free)`.
  final String description;

  /// The description without the memory figures.
  String get name => description.replaceFirst(RegExp(r'\s*\(.*\)\s*$'), '');

  @override
  String toString() => '$id: $description';
}

/// Installs, starts and watches the local llama-server + MiniCPM5: pinned
/// downloads under [root], the server on the GPU picked
/// by name, `/health` polling, crash detection, a pid file for servers a
/// crashed editor left behind, and [stop] on editor shutdown.
class LocalModelManager extends ChangeNotifier {
  LocalModelManager({
    String? root,
    this.storage,
    Map<String, String>? environment,
    HttpClient Function()? httpClient,
    this.startTimeout = const Duration(seconds: 90),
  }) : _environment = environment ?? Platform.environment,
       _httpClient = httpClient ?? HttpClient.new,
       root = root ?? defaultRoot(environment ?? Platform.environment) {
    status = isInstalled() ? LocalModelStatus.installed : LocalModelStatus.notInstalled;
  }

  /// `LUMINA_MINIAI_DIR`, else `miniai/` in Lumina's per-user data directory:
  /// `LUMINA_DATA_DIR`, else `%LOCALAPPDATA%\Lumina` on Windows,
  /// `~/Library/Application Support/Lumina` on macOS and
  /// `$XDG_DATA_HOME/lumina` or `~/.local/share/lumina` elsewhere.
  static String defaultRoot(Map<String, String> env, {String? operatingSystem}) {
    final override = env['LUMINA_MINIAI_DIR'];
    if (override != null && override.isNotEmpty) return override;
    return '${_dataDir(env, operatingSystem ?? Platform.operatingSystem)}/miniai';
  }

  static String _dataDir(Map<String, String> env, String os) {
    String? set(String key) => (env[key]?.isNotEmpty ?? false) ? env[key] : null;
    final data = set('LUMINA_DATA_DIR');
    if (data != null) return data;
    final home = set('HOME') ?? set('USERPROFILE') ?? '.';
    switch (os) {
      case 'windows':
        return '${set('LOCALAPPDATA') ?? '${set('USERPROFILE') ?? home}/AppData/Local'}/Lumina';
      case 'macos':
        return '$home/Library/Application Support/Lumina';
      default:
        final xdg = set('XDG_DATA_HOME');
        return xdg != null ? '$xdg/lumina' : '$home/.local/share/lumina';
    }
  }

  final String root;

  /// The plugin's store for `local.json` (the variant, the GPU, autostart).
  final PluginStorage? storage;
  final Map<String, String> _environment;
  final HttpClient Function() _httpClient;
  final Duration startTimeout;

  ModelVariant variant = ModelVariant.defaultVariant;

  /// The GPU the user picked by name; null = `FILAMENT_GPU`, else the first.
  String? gpuName;

  /// Start the server when a message is sent to the local provider.
  bool autostart = true;

  /// The default context size passed to llama-server (-c).
  static const int defaultContextSize = 16384;

  /// The context size passed to llama-server (-c).
  int contextSize = defaultContextSize;

  /// Automatically compact conversation history when approaching context size
  /// or when a context overflow error occurs.
  bool autoCompact = true;

  late LocalModelStatus status;

  /// Why the last install / start failed, or how the server died.
  String? message;

  /// While downloading: what, received, total.
  String? progressLabel;
  int progressReceived = 0;
  int progressTotal = 0;

  int? port;

  /// The device the running server uses (e.g. `Vulkan0`).
  String? device;

  List<GpuDevice>? _devices;
  Process? _process;
  bool _stopping = false;
  DownloadCancel? _cancel;
  IOSink? _log;
  final List<String> _logTail = [];

  Directory get binDir => Directory('$root/bin/${LlamaBuild.tag}');
  File get serverBinary => File('${binDir.path}/${LlamaBuild.serverExecutable}');
  File modelFile([ModelVariant? v]) => File('$root/models/${(v ?? variant).file.name}');
  File get pidFile => File('$root/server.pid');
  File get logFile => File('$root/server.log');

  /// The server binary is there and the model has its pinned size (the full
  /// hash runs right after the download only).
  bool isInstalled([ModelVariant? v]) {
    final model = modelFile(v);
    return serverBinary.existsSync() && model.existsSync() && model.lengthSync() == (v ?? variant).file.size;
  }

  bool get isRunning => status == LocalModelStatus.starting || status == LocalModelStatus.ready;
  bool get isBusy => status == LocalModelStatus.downloading || status == LocalModelStatus.starting;

  /// `http://127.0.0.1:<port>/v1` while ready.
  String? get baseUrl => status == LocalModelStatus.ready && port != null ? 'http://127.0.0.1:$port/v1' : null;

  /// The last lines the server printed.
  String get logTail => _logTail.join('\n');

  // ── settings ────────────────────────────────────────────────────────────

  Future<void> load() async {
    final data = await storage?.readJson('local');
    if (data != null) {
      variant = ModelVariant.byId(data['variant'] as String?);
      gpuName = data['gpu'] as String?;
      autostart = data['autostart'] as bool? ?? true;
      contextSize = data['contextSize'] as int? ?? defaultContextSize;
      autoCompact = data['autoCompact'] as bool? ?? true;
    }
    if (!isRunning && status != LocalModelStatus.downloading) _refreshInstalled();
    notifyListeners();
  }

  Future<void> saveSettings() async {
    await storage?.writeJson('local', {
      'variant': variant.id,
      if (gpuName != null) 'gpu': gpuName,
      'autostart': autostart,
      'contextSize': contextSize,
      'autoCompact': autoCompact,
    });
  }

  Future<void> setContextSize(int next) async {
    if (isRunning || isBusy || next == contextSize) return;
    contextSize = next;
    notifyListeners();
    await saveSettings();
  }

  Future<void> setAutoCompact(bool next) async {
    if (next == autoCompact) return;
    autoCompact = next;
    notifyListeners();
    await saveSettings();
  }

  /// Picks [next] (not while the server runs or downloads).
  Future<void> selectVariant(ModelVariant next) async {
    if (isRunning || isBusy) return;
    variant = next;
    _refreshInstalled();
    notifyListeners();
    await saveSettings();
  }

  Future<void> selectGpu(String? name) async {
    gpuName = name;
    notifyListeners();
    await saveSettings();
  }

  void _refreshInstalled() {
    status = isInstalled() ? LocalModelStatus.installed : LocalModelStatus.notInstalled;
  }

  void _set(LocalModelStatus next, {String? message}) {
    status = next;
    this.message = message;
    notifyListeners();
  }

  // ── install ─────────────────────────────────────────────────────────────

  /// Downloads (resumably) and verifies llama.cpp and [variant], and
  /// extracts the server. A cancel keeps the partial files.
  Future<void> install() async {
    if (isBusy || isRunning) return;
    final cancel = _cancel = DownloadCancel();
    final downloader = Downloader(httpClient: _httpClient);
    _set(LocalModelStatus.downloading);
    try {
      if (!serverBinary.existsSync()) {
        final pinned = LlamaBuild.current;
        final archive = File('$root/downloads/${pinned.name}');
        await _fetch(downloader, 'llama.cpp ${LlamaBuild.tag}', pinned, archive, cancel);
        await extractServer(archive, binDir);
        await archive.delete();
      }
      if (!isInstalled()) {
        await _fetch(downloader, variant.label, variant.file, modelFile(), cancel);
      }
      progressLabel = null;
      _set(LocalModelStatus.installed);
    } on DownloadCancelled {
      progressLabel = null;
      _set(isInstalled() ? LocalModelStatus.installed : LocalModelStatus.notInstalled, message: 'Download cancelled; it resumes where it stopped.');
    } catch (e) {
      progressLabel = null;
      _set(LocalModelStatus.failed, message: '$e');
    } finally {
      _cancel = null;
    }
  }

  Future<void> _fetch(Downloader d, String label, PinnedFile pinned, File target, DownloadCancel cancel) {
    progressLabel = label;
    progressReceived = 0;
    progressTotal = pinned.size;
    notifyListeners();
    var lastNotify = DateTime.fromMillisecondsSinceEpoch(0);
    return d.fetch(
      Uri.parse(pinned.url),
      target,
      sha256: pinned.sha256,
      size: pinned.size,
      cancel: cancel,
      onProgress: (received, total) {
        progressReceived = received;
        progressTotal = total;
        final now = DateTime.now();
        if (now.difference(lastNotify).inMilliseconds >= 100 || received == total) {
          lastNotify = now;
          notifyListeners();
        }
      },
    );
  }

  void cancelInstall() => _cancel?.cancel();

  /// Extracts a llama.cpp archive (zip or tar.gz) into [dir], flattening a
  /// top-level folder so the server sits at `dir/llama-server[.exe]`.
  static Future<void> extractServer(File archive, Directory dir) async {
    final staging = Directory('${dir.path}.extract');
    if (staging.existsSync()) await staging.delete(recursive: true);
    await extractFileToDisk(archive.path, staging.path);
    File? server;
    await for (final e in staging.list(recursive: true)) {
      if (e is File && e.uri.pathSegments.last == LlamaBuild.serverExecutable) {
        server = e;
        break;
      }
    }
    if (server == null) {
      await staging.delete(recursive: true);
      throw FormatException('${archive.path} holds no ${LlamaBuild.serverExecutable}');
    }
    if (dir.existsSync()) await dir.delete(recursive: true);
    await server.parent.rename(dir.path);
    if (staging.existsSync()) await staging.delete(recursive: true);
    if (!Platform.isWindows) {
      await Process.run('chmod', ['+x', '${dir.path}/${LlamaBuild.serverExecutable}']);
    }
  }

  // ── devices ─────────────────────────────────────────────────────────────

  /// Parses `llama-server --list-devices`.
  static List<GpuDevice> parseDevices(String output) => [
    for (final m in RegExp(r'^\s*(\w+\d+):\s*(.+?)\s*$', multiLine: true).allMatches(output))
      if (m.group(1) != null && !m.group(0)!.contains('Available devices')) GpuDevice(m.group(1)!, m.group(2)!),
  ];

  /// The device whose description contains [name] (case-insensitive).
  static GpuDevice? matchDevice(List<GpuDevice> devices, String name) {
    final needle = name.toLowerCase().trim();
    if (needle.isEmpty) return null;
    return devices.where((d) => d.description.toLowerCase().contains(needle)).firstOrNull;
  }

  /// The devices llama-server sees (cached).
  Future<List<GpuDevice>> listDevices({bool refresh = false}) async {
    if (_devices != null && !refresh) return _devices!;
    if (!serverBinary.existsSync()) return const [];
    final r = await Process.run(serverBinary.path, ['--list-devices'], workingDirectory: binDir.path);
    _devices = parseDevices('${r.stdout}\n${r.stderr}');
    notifyListeners();
    return _devices!;
  }

  List<GpuDevice>? get devices => _devices;

  /// The GPU name in effect: the user's pick, `FILAMENT_GPU`, or null.
  String? get effectiveGpuName {
    if (gpuName != null && gpuName!.isNotEmpty) return gpuName;
    final env = _environment['FILAMENT_GPU'];
    return env == null || env.isEmpty ? null : env;
  }

  /// The device to run on: the named one, else the first.
  Future<GpuDevice?> resolveDevice() async {
    final all = await listDevices();
    final name = effectiveGpuName;
    return (name == null ? null : matchDevice(all, name)) ?? all.firstOrNull;
  }

  /// The server's command line.
  List<String> serverArgs({required int port, String? device}) => [
    '-m',
    modelFile().path,
    if (device != null) ...['--device', device],
    '-ngl',
    '99',
    '-c',
    '$contextSize',
    '--jinja',
    '--min-p',
    '0.0',
    '--host',
    '127.0.0.1',
    '--port',
    '$port',
    '--alias',
    variant.id,
  ];

  // ── run ─────────────────────────────────────────────────────────────────

  /// Starts the server and waits for `/health`. Kills a server a previous
  /// session left behind first.
  Future<void> start() async {
    if (isRunning || isBusy) return;
    if (!isInstalled()) {
      _set(LocalModelStatus.notInstalled, message: 'Download the model first.');
      return;
    }
    _set(LocalModelStatus.starting);
    try {
      await cleanStaleServer();
      final gpu = await resolveDevice();
      device = gpu?.id;
      final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final p = port = probe.port;
      await probe.close();

      _logTail.clear();
      await _closeLog();
      final log = _log = logFile.openWrite();
      final process = _process = await Process.start(
        serverBinary.path,
        serverArgs(port: p, device: device),
        workingDirectory: binDir.path,
      );
      _stopping = false;
      await pidFile.writeAsString(jsonEncode({'pid': process.pid, 'port': p}));
      void pipe(Stream<List<int>> s) => s.transform(const Utf8Decoder(allowMalformed: true)).transform(const LineSplitter()).listen((line) {
        if (identical(_log, log)) log.writeln(line);
        _logTail.add(line);
        if (_logTail.length > 40) _logTail.removeAt(0);
      });
      pipe(process.stdout);
      pipe(process.stderr);
      unawaited(process.exitCode.then((code) => _onExit(process, code)));

      final deadline = DateTime.now().add(startTimeout);
      while (true) {
        if (_process != process || status != LocalModelStatus.starting) return; // Died or stopped.
        if (await _healthy(p)) break;
        if (DateTime.now().isAfter(deadline)) {
          await stop();
          _set(LocalModelStatus.failed, message: 'llama-server did not become ready in ${startTimeout.inSeconds} s.\n$logTail');
          return;
        }
        await Future<void>.delayed(const Duration(milliseconds: 400));
      }
      _set(LocalModelStatus.ready);
    } catch (e) {
      _set(LocalModelStatus.failed, message: '$e');
    }
  }

  Future<bool> _healthy(int port) async {
    final client = _httpClient();
    try {
      final r = await (await client.getUrl(Uri.parse('http://127.0.0.1:$port/health'))).close().timeout(const Duration(seconds: 2));
      await r.drain<void>();
      return r.statusCode == 200;
    } catch (_) {
      return false;
    } finally {
      client.close(force: true);
    }
  }

  void _onExit(Process process, int code) {
    if (_process != process) return;
    _process = null;
    unawaited(_closeLog());
    _deleteOwnPidFile(process.pid);
    if (_stopping) return;
    _set(LocalModelStatus.crashed, message: 'llama-server exited with code $code.\n$logTail');
  }

  /// Closes `server.log` (lines arriving later stay in [logTail] only).
  Future<void> _closeLog() async {
    final log = _log;
    _log = null;
    try {
      await log?.close();
    } catch (_) {}
  }

  /// Removes [pidFile] when it still names [pid] (another session may own
  /// it by now).
  void _deleteOwnPidFile(int pid) {
    try {
      if (pidFile.existsSync() && (jsonDecode(pidFile.readAsStringSync()) as Map)['pid'] == pid) pidFile.deleteSync();
    } catch (_) {}
  }

  /// Stops the server (the whole process tree).
  Future<void> stop() async {
    final process = _process;
    _stopping = true;
    if (process != null) {
      await _killTree(process.pid);
      process.kill(ProcessSignal.sigkill);
      await process.exitCode.timeout(const Duration(seconds: 5), onTimeout: () => -1);
    }
    _process = null;
    if (process != null) _deleteOwnPidFile(process.pid);
    await _closeLog();
    if (isRunning || status == LocalModelStatus.crashed || process != null) {
      port = null;
      _set(isInstalled() ? LocalModelStatus.stopped : LocalModelStatus.notInstalled);
    }
  }

  Future<void> restart() async {
    await stop();
    await start();
  }

  /// The pid of the running server (tests kill it from outside).
  int? get pid => _process?.pid;

  /// Kills the server recorded in [pidFile] when it is still a live
  /// llama-server, then removes the file.
  Future<bool> cleanStaleServer() async {
    if (!pidFile.existsSync()) return false;
    var killed = false;
    try {
      final pid = (jsonDecode(await pidFile.readAsString()) as Map)['pid'] as int;
      if (await isLlamaServer(pid)) {
        await _killTree(pid);
        killed = true;
      }
    } catch (_) {}
    if (pidFile.existsSync()) await pidFile.delete();
    return killed;
  }

  /// Whether [pid] is a running llama-server.
  static Future<bool> isLlamaServer(int pid) async {
    if (Platform.isWindows) {
      final r = await Process.run('tasklist', ['/FI', 'PID eq $pid', '/FO', 'CSV', '/NH']);
      return '${r.stdout}'.toLowerCase().contains('llama-server');
    }
    final r = await Process.run('ps', ['-p', '$pid', '-o', 'comm=']);
    return '${r.stdout}'.contains('llama-server');
  }

  static Future<void> _killTree(int pid) async {
    if (Platform.isWindows) {
      await Process.run('taskkill', ['/T', '/F', '/PID', '$pid']);
    } else {
      Process.killPid(pid, ProcessSignal.sigkill);
    }
  }

  @override
  void dispose() {
    _cancel?.cancel();
    final process = _process;
    if (process != null) {
      _stopping = true;
      unawaited(_killTree(process.pid));
      process.kill(ProcessSignal.sigkill);
    }
    unawaited(_closeLog());
    super.dispose();
  }
}
