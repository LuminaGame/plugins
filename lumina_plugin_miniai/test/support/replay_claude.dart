import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:lumina_plugin_miniai/lumina_plugin_miniai.dart';

/// Starts `claude_code_replay.dart` subprocesses in place of the CLI, one
/// fixture per start, and plays the CLI's side of a permission request: at
/// a recorded request it calls [onPermission] (MiniAI's `permission_prompt`
/// tool, as the CLI would over MCP) and hands the answer back.
class ReplayClaude {
  ReplayClaude(this.fixtures, {required this.logDir, this.onPermission});

  /// Fixture names (`turns_and_tools`) or paths, used in order.
  final List<String> fixtures;
  final Directory logDir;
  Future<Map<String, Object?>> Function(Map<String, Object?> request)? onPermission;

  /// Each start's arguments.
  final List<List<String>> starts = [];

  /// The answers MiniAI gave to permission requests.
  final List<Map<String, Object?>> answers = [];

  static String fixture(String name) => name.endsWith('.jsonl') ? name : 'test/fixtures/claude_code/$name.jsonl';

  /// The SDK's `dart` (under `flutter test` the running executable is the
  /// test shell, not `dart`).
  static String get dart {
    final exe = Platform.resolvedExecutable.replaceAll(r'\', '/');
    final cache = exe.indexOf('/bin/cache/');
    if (cache >= 0) {
      final sdkDart = '${exe.substring(0, cache)}/bin/cache/dart-sdk/bin/dart${Platform.isWindows ? '.exe' : ''}';
      if (File(sdkDart).existsSync()) return sdkDart;
    }
    return 'dart';
  }

  /// The lines start [n] read from its stdin.
  List<Map<String, Object?>> inputs(int n) => [
        for (final l in File('${logDir.path}/start_$n.log').readAsLinesSync())
          if (l.trim().isNotEmpty && (jsonDecode(l) as Map).containsKey('stdin')) Map<String, Object?>.from(jsonDecode((jsonDecode(l) as Map)['stdin'] as String) as Map),
      ];

  Future<ClaudeCodeProcess> start(String executable, List<String> args, {required String workingDirectory, Map<String, String>? environment}) async {
    final n = starts.length;
    if (n >= fixtures.length) throw StateError('no fixture left for start ${n + 1}');
    starts.add(args);
    final process = await Process.start(dart, [
      File('test/support/claude_code_replay.dart').absolute.path,
      File(fixture(fixtures[n])).absolute.path,
      '${logDir.path}/start_$n.log',
      ...args,
    ], workingDirectory: workingDirectory);
    return _ReplayProcess(process, this);
  }
}

class _ReplayProcess implements ClaudeCodeProcess {
  _ReplayProcess(this._process, this._replay) {
    _process.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen((line) async {
      if (line.contains('"__replay_permission"')) {
        final request = Map<String, Object?>.from((jsonDecode(line) as Map)['request'] as Map);
        final handler = _replay.onPermission;
        final answer = handler == null ? <String, Object?>{'behavior': 'deny', 'message': 'no handler'} : await handler(request);
        _replay.answers.add(answer);
        _process.stdin.writeln(jsonEncode({'type': '__replay_permission_answer', 'answer': answer}));
        return;
      }
      _lines.add(line);
    }, onDone: _lines.close);
  }

  final Process _process;
  final ReplayClaude _replay;
  final StreamController<String> _lines = StreamController.broadcast();

  @override
  Stream<String> get lines => _lines.stream;

  @override
  Stream<String> get errors => _process.stderr.transform(utf8.decoder);

  @override
  void writeLine(String line) => _process.stdin.writeln(line);

  @override
  Future<void> closeInput() async {
    try {
      await _process.stdin.close();
    } on Object {
      // Gone already.
    }
  }

  @override
  Future<int> get exitCode => _process.exitCode;

  @override
  void kill() => _process.kill();
}
