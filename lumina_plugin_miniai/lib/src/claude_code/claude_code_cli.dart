import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// A running `claude` process as MiniAI uses it: output lines, input lines,
/// the exit code. Tests start a replay process through the same seam.
abstract class ClaudeCodeProcess {
  /// stdout, one line per event.
  Stream<String> get lines;

  /// stderr, as it comes.
  Stream<String> get errors;
  void writeLine(String line);
  Future<void> closeInput();
  Future<int> get exitCode;
  void kill();

  /// Starts [executable] (a `.cmd`/`.bat` through the shell on Windows).
  static Future<ClaudeCodeProcess> start(String executable, List<String> args,
      {required String workingDirectory, Map<String, String>? environment}) async {
    final lower = executable.toLowerCase();
    final process = await Process.start(
      executable,
      args,
      workingDirectory: workingDirectory,
      environment: environment,
      runInShell: Platform.isWindows && (lower.endsWith('.cmd') || lower.endsWith('.bat')),
    );
    return _IoClaudeCodeProcess(process);
  }
}

/// How MiniAI starts the CLI; tests pass a replay.
typedef ClaudeCodeStarter = Future<ClaudeCodeProcess> Function(String executable, List<String> args,
    {required String workingDirectory, Map<String, String>? environment});

class _IoClaudeCodeProcess implements ClaudeCodeProcess {
  _IoClaudeCodeProcess(this._process)
      : lines = _process.stdout.transform(utf8.decoder).transform(const LineSplitter()).asBroadcastStream(),
        errors = _process.stderr.transform(utf8.decoder).asBroadcastStream();

  final Process _process;

  @override
  final Stream<String> lines;

  @override
  final Stream<String> errors;

  @override
  void writeLine(String line) => _process.stdin.writeln(line);

  @override
  Future<void> closeInput() async {
    try {
      await _process.stdin.flush();
      await _process.stdin.close();
    } on Object {
      // Already gone.
    }
  }

  @override
  Future<int> get exitCode => _process.exitCode;

  @override
  void kill() => _process.kill();
}

/// `claude auth status`: whether the CLI is logged in (the account's
/// email is never kept).
class ClaudeAuthStatus {
  const ClaudeAuthStatus({required this.loggedIn, this.method, this.plan});

  final bool loggedIn;

  /// `claude.ai`, `api_key`, …
  final String? method;

  /// `max`, `pro`, …
  final String? plan;

  String get label => loggedIn ? 'Logged in${method == null ? '' : ' ($method${plan == null ? '' : ', $plan'})'}' : 'Not logged in';
}

/// What detection found.
class ClaudeCodeInstall {
  const ClaudeCodeInstall({required this.path, this.version, this.auth, this.error});

  /// Null when no `claude` was found.
  final String? path;
  final String? version;
  final ClaudeAuthStatus? auth;

  /// Why [path] could not be run.
  final String? error;

  bool get found => path != null && error == null;
  bool get ready => found && (auth?.loggedIn ?? false);
}

/// Finds and asks the user's installed Claude Code CLI.
class ClaudeCodeCli {
  const ClaudeCodeCli({this.environmentOverride});

  /// The environment detection reads; null: the process's.
  final Map<String, String>? environmentOverride;

  Map<String, String> get environment => environmentOverride ?? Platform.environment;

  static const String installHint =
      'Install Claude Code (https://claude.com/claude-code): on Windows `irm https://claude.ai/install.ps1 | iex`, '
      'on Linux and macOS `curl -fsSL https://claude.ai/install.sh | bash`, or `npm install -g @anthropic-ai/claude-code`. '
      'Then run `claude` once in a terminal to log in.';

  static const String loginHint = 'Run `claude` in a terminal and log in (or `claude auth login`); MiniAI uses that login.';

  /// Where `claude` may be, in order: [override], `PATH`, the native
  /// installer's folders, npm's global folder, the VS Code extension.
  List<String> candidates({String? override}) {
    final env = environment;
    final windows = Platform.isWindows;
    final home = env['USERPROFILE'] ?? env['HOME'] ?? '';
    final names = windows ? ['claude.exe', 'claude.cmd', 'claude.bat', 'claude'] : ['claude'];
    final sep = windows ? ';' : ':';
    final out = <String>[
      if (override != null && override.trim().isNotEmpty) override.trim(),
      for (final dir in (env['PATH'] ?? env['Path'] ?? '').split(sep))
        if (dir.trim().isNotEmpty)
          for (final n in names) '${dir.trim()}${Platform.pathSeparator}$n',
      if (home.isNotEmpty) ...[
        for (final n in names) '$home/.local/bin/$n',
        for (final n in names) '$home/.claude/local/$n',
      ],
      if (windows && (env['APPDATA'] ?? '').isNotEmpty) '${env['APPDATA']}/npm/claude.cmd',
      if (!windows) ...['/usr/local/bin/claude', '/opt/homebrew/bin/claude'],
      ..._vscodeBinaries(home),
    ];
    return out;
  }

  /// The newest VS Code extension's bundled CLI first.
  List<String> _vscodeBinaries(String home) {
    if (home.isEmpty) return const [];
    final dir = Directory('$home/.vscode/extensions');
    if (!dir.existsSync()) return const [];
    final found = <(List<int>, String)>[];
    for (final e in dir.listSync().whereType<Directory>()) {
      final name = e.uri.pathSegments.where((s) => s.isNotEmpty).last;
      final m = RegExp(r'^anthropic\.claude-code-(\d+)\.(\d+)\.(\d+)').firstMatch(name);
      if (m == null) continue;
      final exe = File('${e.path}/resources/native-binary/claude${Platform.isWindows ? '.exe' : ''}');
      if (exe.existsSync()) found.add(([for (var i = 1; i <= 3; i++) int.parse(m.group(i)!)], exe.path));
    }
    found.sort((a, b) {
      for (var i = 0; i < 3; i++) {
        final c = b.$1[i].compareTo(a.$1[i]);
        if (c != 0) return c;
      }
      return 0;
    });
    return [for (final f in found) f.$2];
  }

  /// The first candidate that exists; an [override] that does not exist is
  /// not skipped (it is what the user asked for).
  String? find({String? override}) {
    if (override != null && override.trim().isNotEmpty) return File(override.trim()).existsSync() ? override.trim() : null;
    for (final c in candidates()) {
      if (File(c).existsSync()) return c;
    }
    return null;
  }

  /// Path, version and login state.
  Future<ClaudeCodeInstall> detect({String? override}) async {
    final path = find(override: override);
    if (path == null) return const ClaudeCodeInstall(path: null);
    try {
      final version = await _run(path, ['--version']);
      final auth = await authStatus(path);
      return ClaudeCodeInstall(path: path, version: version.trim().split('\n').first, auth: auth);
    } on Object catch (e) {
      return ClaudeCodeInstall(path: path, error: '$e');
    }
  }

  Future<ClaudeAuthStatus> authStatus(String path) async {
    final text = await _run(path, ['auth', 'status']);
    try {
      final data = jsonDecode(text);
      if (data is Map) {
        return ClaudeAuthStatus(
          loggedIn: data['loggedIn'] == true,
          method: data['authMethod'] as String?,
          plan: data['subscriptionType'] as String?,
        );
      }
    } on FormatException {
      // Older CLIs print text.
    }
    return ClaudeAuthStatus(loggedIn: !text.toLowerCase().contains('not logged in'));
  }

  Future<String> _run(String path, List<String> args) async {
    final lower = path.toLowerCase();
    final result = await Process.run(path, args,
            runInShell: Platform.isWindows && (lower.endsWith('.cmd') || lower.endsWith('.bat')), stdoutEncoding: utf8, stderrEncoding: utf8)
        .timeout(const Duration(seconds: 30));
    final out = '${result.stdout}';
    if (result.exitCode != 0 && out.trim().isEmpty) throw ProcessException(path, args, '${result.stderr}'.trim(), result.exitCode);
    return out;
  }
}
