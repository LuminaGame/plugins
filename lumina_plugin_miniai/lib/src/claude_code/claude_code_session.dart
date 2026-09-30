import 'dart:async';

import 'claude_code_cli.dart';
import 'claude_code_protocol.dart';

/// One long-lived headless `claude` process: a chat's conversation. It keeps
/// the context between messages; a new process continues a stored session
/// with `--resume`.
class ClaudeCodeSession {
  ClaudeCodeSession({
    required this.executable,
    required this.workingDirectory,
    required this.starter,
    this.model,
    this.resume,
    this.mcpConfigPath,
    this.permissionPromptTool,
    this.appendSystemPrompt,
    this.environment,
  });

  final String executable;
  final String workingDirectory;
  final ClaudeCodeStarter starter;

  /// `--model`; null or empty: the CLI's default.
  final String? model;

  /// `--resume <session id>`.
  final String? resume;
  final String? mcpConfigPath;

  /// `--permission-prompt-tool`: the MCP tool that answers permission requests.
  final String? permissionPromptTool;
  final String? appendSystemPrompt;
  final Map<String, String>? environment;

  ClaudeCodeProcess? _process;
  final StreamController<ClaudeEvent> _events = StreamController.broadcast();
  final StringBuffer _stderr = StringBuffer();
  int _requests = 0;

  /// What `initialize` reported.
  ClaudeCapabilities? capabilities;

  /// The last `system/init`.
  ClaudeInit? init;

  /// The CLI's session id (known after the first message, or [resume]).
  String? get sessionId => init?.sessionId ?? resume;

  /// Set once the process has exited.
  int? exitCode;

  bool get alive => _process != null && exitCode == null;

  Stream<ClaudeEvent> get events => _events.stream;

  /// The last lines the CLI wrote to stderr.
  String get errorTail {
    final text = _stderr.toString().trim();
    return text.length <= 600 ? text : text.substring(text.length - 600);
  }

  /// The command line (without the executable).
  List<String> get arguments => [
        '-p',
        '--input-format', 'stream-json',
        '--output-format', 'stream-json',
        '--verbose',
        '--include-partial-messages',
        // The user's own `defaultMode` must not skip MiniAI's approvals.
        '--permission-mode', 'default',
        if (mcpConfigPath != null) ...['--mcp-config', mcpConfigPath!, '--strict-mcp-config'],
        if (permissionPromptTool != null) ...['--permission-prompt-tool', permissionPromptTool!],
        if (model != null && model!.isNotEmpty) ...['--model', model!],
        if (resume != null && resume!.isNotEmpty) ...['--resume', resume!],
        if (appendSystemPrompt != null) ...['--append-system-prompt', appendSystemPrompt!],
      ];

  /// Starts the process and asks `initialize` (no model call).
  Future<void> start() async {
    final process = _process = await starter(executable, arguments, workingDirectory: workingDirectory, environment: environment);
    process.lines.listen((line) {
      final event = ClaudeCodeProtocol.parse(line);
      if (event == null) return;
      if (event is ClaudeInit) init = event;
      _events.add(event);
    });
    process.errors.listen(_stderr.write);
    unawaited(process.exitCode.then((code) {
      exitCode = code;
      _events.add(ClaudeExited(code));
    }));
    final response = await request('initialize').timeout(const Duration(seconds: 60));
    if (response != null && response.success) capabilities = ClaudeCapabilities.fromInitialize(response.body);
  }

  /// Sends a control request; completes with its response, or null when the
  /// process exits first.
  Future<ClaudeControlResponse?> request(String subtype) async {
    final id = '${subtype}_${++_requests}';
    final answer = events
        .where((e) => (e is ClaudeControlResponse && e.requestId == id) || e is ClaudeExited)
        .map((e) => e is ClaudeControlResponse ? e : null)
        .first;
    _process?.writeLine(ClaudeCodeProtocol.controlRequest(id, subtype));
    return answer;
  }

  void sendUser(String text) => _process?.writeLine(ClaudeCodeProtocol.userMessage(text));

  /// Stops the running answer; the turn ends with a `result`.
  Future<void> interrupt() async {
    if (!alive) return;
    await request('interrupt').timeout(const Duration(seconds: 10), onTimeout: () => null);
  }

  /// Ends the process: closes its input (the CLI exits and stops its MCP
  /// servers), then kills it if it does not.
  Future<void> close() async {
    final process = _process;
    if (process == null) return;
    if (exitCode == null) {
      await process.closeInput();
      try {
        await process.exitCode.timeout(const Duration(seconds: 5));
      } on TimeoutException {
        process.kill();
      }
    }
    _process = null;
  }
}
