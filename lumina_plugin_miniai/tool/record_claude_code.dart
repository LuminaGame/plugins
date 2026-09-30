// Records real Claude Code stream-json sessions into
// test/fixtures/claude_code/ (the Claude Code provider fixtures).
//
//   dart tool/record_claude_code.dart --project <dir> --bridge <lumina_mcp_bridge.dart>
//       [--config-dir <dir>] [--claude <path>] [--dart <path>] [--model haiku] [--case <name>]
//       [--resume-session <id>]
//
// Every session starts with `initialize`, as MiniAI's does.
// It runs the user's installed `claude` CLI headless in <dir>, with the editor's
// MCP server through the stdio bridge (a Lumina Studio with its MCP server on,
// or any editor whose connection file is in --config-dir). Permission prompts
// go to a small MCP server this script starts from itself
// (`--permission-server <port>`), which allows read-only tools and denies the
// rest, and they are recorded in order with the stream.
//
// Every case is one or two cheap model calls on the user's own login. The
// transcripts are sanitized before they are written: no account, email or
// absolute paths, and only built-in and project commands.
//
// Pure dart:io: runs without Flutter.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> args) async {
  final permissionPort = _option(args, 'permission-server');
  if (permissionPort != null) return _permissionServer(int.parse(permissionPort));

  final project = _option(args, 'project');
  final bridge = _option(args, 'bridge');
  if (project == null || bridge == null) {
    stderr.writeln('usage: dart tool/record_claude_code.dart --project <dir> --bridge <lumina_mcp_bridge.dart> '
        '[--config-dir <dir>] [--claude <path>] [--dart <path>] [--model haiku] [--case <name>]');
    exit(64);
  }
  final claude = _option(args, 'claude') ?? 'claude';
  final dart = _option(args, 'dart') ?? Platform.resolvedExecutable;
  final model = _option(args, 'model') ?? 'haiku';
  final only = _option(args, 'case');
  final configDir = _option(args, 'config-dir');
  // Resume this session instead of the one turns_and_tools records.
  final resumeSession = _option(args, 'resume-session');
  final out = Directory('test/fixtures/claude_code')..createSync(recursive: true);

  // A project command, so the recorded command list has one.
  final command = File('$project/.claude/commands/hello.md');
  if (!command.existsSync()) {
    command
      ..parent.createSync(recursive: true)
      ..writeAsStringSync('---\ndescription: Say hello from a custom project command\n---\nReply with exactly: HELLO-CUSTOM\n');
  }

  final permissions = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final mcpConfig = File('${Directory.systemTemp.path}/record_claude_code_${pid}_mcp.json');
  mcpConfig.writeAsStringSync(jsonEncode({
    'mcpServers': {
      'lumina': {
        'type': 'stdio',
        'command': dart,
        'args': [bridge],
        if (configDir != null) 'env': {'LUMINA_CONFIG_DIR': configDir},
      },
      'recorder': {
        'type': 'stdio',
        'command': dart,
        'args': [Platform.script.toFilePath(), '--permission-server', '${permissions.port}'],
      },
    },
  }));

  final recorder = _Recorder(
    claude: claude,
    project: project,
    baseArgs: [
      '-p', '--input-format', 'stream-json', '--output-format', 'stream-json', '--verbose', '--include-partial-messages',
      '--mcp-config', mcpConfig.path, '--strict-mcp-config', '--permission-mode', 'default',
      '--permission-prompt-tool', 'mcp__recorder__permission_prompt',
    ],
    permissions: permissions,
  );

  Map<String, Object?> user(String text) => {
        'type': 'user',
        'message': {'role': 'user', 'content': text},
      };
  const initialize = {
    'type': 'control_request',
    'request_id': 'init-1',
    'request': {'subtype': 'initialize'},
  };

  String? firstSession = resumeSession;
  final cases = <String, Future<void> Function()>{
    // Two turns in one process: a read-only editor tool, then a mutating
    // one whose permission prompt is denied.
    'turns_and_tools': () async {
      firstSession = await recorder.record(File('${out.path}/turns_and_tools.jsonl'), ['--model', model], [
        _Send(initialize),
        _Send(user('Call the list_actors tool of the lumina MCP server once, then reply with the number of actors only.'), wait: true),
        _Send(user('Call the lumina spawn_actor tool once with type PointLight, then answer in one short sentence.'), wait: true),
      ]);
    },
    // A local command (no model call) and a project command.
    'slash_commands': () async {
      await recorder.record(File('${out.path}/slash_commands.jsonl'), ['--model', model], [
        _Send(initialize),
        _Send(user('/context'), wait: true),
        _Send(user('/hello'), wait: true),
      ]);
    },
    // A new process on the first case's session.
    'resume': () async {
      final session = firstSession;
      if (session == null) {
        stderr.writeln('resume: record turns_and_tools first (in the same run)');
        return;
      }
      await recorder.record(File('${out.path}/resume.jsonl'), ['--model', model, '--resume', session], [
        _Send(initialize),
        _Send(user('What number did you reply with in your first answer? Answer with the number only.'), wait: true),
      ]);
    },
    // An unknown model: the CLI's error result.
    'error_model': () async {
      await recorder.record(File('${out.path}/error_model.jsonl'), ['--model', 'claude-not-a-model-x'], [
        _Send(initialize),
        _Send(user('Reply with OK.'), wait: true),
      ]);
    },
    // Claude Code asks the user a multiple-choice question (AskUserQuestion,
    // through the permission prompt); the answer goes back in the input.
    'ask_user_question': () async {
      await recorder.record(File('${out.path}/ask_user_question.jsonl'), ['--model', model], [
        _Send(initialize),
        _Send(
          user('Use the AskUserQuestion tool exactly once to ask me which colour I prefer, with the options Red and Blue. '
              'Then reply with only the colour I chose.'),
          wait: true,
        ),
      ]);
    },
    // Stop while the answer streams.
    'interrupt': () async {
      await recorder.record(File('${out.path}/interrupt.jsonl'), ['--model', model], [
        _Send(initialize),
        _Send(user('Count from 1 to 300, one number per line, no other text.'), waitForText: true),
        _Send({
          'type': 'control_request',
          'request_id': 'interrupt-1',
          'request': {'subtype': 'interrupt'},
        }, wait: true),
      ]);
    },
  };
  for (final e in cases.entries) {
    if (only != null && e.key != only && !(only == 'resume' && e.key == 'turns_and_tools' && resumeSession == null)) continue;
    stdout.writeln('recording ${e.key}…');
    await e.value();
  }
  await permissions.close();
  mcpConfig.deleteSync();
  // The permission connections stay open until the CLI's children exit.
  exit(0);
}

class _Send {
  const _Send(this.message, {this.wait = false, this.waitForText = false});
  final Map<String, Object?> message;

  /// Wait for the `result` (or the control response) this message causes.
  final bool wait;

  /// Wait for the first streamed text of the answer.
  final bool waitForText;
}

class _Recorder {
  _Recorder({required this.claude, required this.project, required this.baseArgs, required ServerSocket permissions}) {
    permissions.listen(_permissionConnection);
  }

  final String claude;
  final String project;
  final List<String> baseArgs;
  IOSink? _fixture;
  void Function()? _onEvent;
  final List<Map<String, Object?>> _events = [];
  final Set<String> _keptCommands = {};

  void _write(Map<String, Object?> record) => _fixture?.writeln(jsonEncode(record));

  void _permissionConnection(Socket socket) {
    utf8.decoder.bind(socket).transform(const LineSplitter()).listen((line) {
      final request = Map<String, Object?>.from(jsonDecode(line) as Map);
      final tool = '${request['tool_name']}';
      final readOnly = RegExp(r'(^|__)(list_|get_|project_info)').hasMatch(tool) || const {'ToolSearch', 'Read', 'Glob', 'Grep'}.contains(tool);
      final input = request['input'];
      final answer = tool == 'AskUserQuestion' && input is Map
          // The user picks each question's second option (as MiniAI's
          // question card answers: `{question: label}`).
          ? {
              'behavior': 'allow',
              'updatedInput': {
                ...input,
                'answers': {
                  for (final q in (input['questions'] as List? ?? const []))
                    if (q is Map) '${q['question']}': '${((q['options'] as List)[1] as Map)['label']}',
                },
              },
            }
          : readOnly
          ? {'behavior': 'allow', 'updatedInput': input}
          : {'behavior': 'deny', 'message': 'The user denied $tool.'};
      _write({'permission': request, 'answer': answer});
      socket.writeln(jsonEncode(answer));
    });
  }

  /// Runs one session; returns its session id.
  Future<String?> record(File fixture, List<String> extra, List<_Send> steps) async {
    final sink = _fixture = fixture.openWrite();
    final process = await Process.start(claude, [...baseArgs, ...extra], workingDirectory: project);
    String? session;
    var version = '';
    _write({
      'meta': {'args': _sanitizeArgs([...baseArgs, ...extra])},
    });
    final done = Completer<void>();
    process.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
      if (line.trim().isEmpty) return;
      final Object? decoded;
      try {
        decoded = jsonDecode(line);
      } on FormatException {
        return;
      }
      if (decoded is! Map) return;
      final message = Map<String, Object?>.from(decoded);
      if (message['type'] == 'rate_limit_event') return;
      if (message['type'] == 'system' && message['subtype'] == 'init') {
        session = message['session_id'] as String?;
        version = '${message['claude_code_version']}';
      }
      final clean = _sanitize(message);
      if (clean == null) return;
      _write({'out': clean});
      _events.add(message);
      _onEvent?.call();
    }, onDone: done.complete);
    process.stderr.transform(utf8.decoder).listen(stderr.write);

    for (final step in steps) {
      final before = _events.length;
      _write({'in': step.message});
      process.stdin.writeln(jsonEncode(step.message));
      await process.stdin.flush();
      bool reached() {
        final fresh = _events.skip(before);
        if (step.waitForText) {
          return fresh.any((e) =>
              e['type'] == 'stream_event' && ((e['event'] as Map?)?['delta'] as Map?)?['type'] == 'text_delta');
        }
        if (step.message['type'] == 'control_request') {
          final id = step.message['request_id'];
          final answered = fresh.any((e) => e['type'] == 'control_response' && ((e['response'] as Map?)?['request_id'] == id));
          // An interrupt also ends the turn with a result.
          if ((step.message['request'] as Map)['subtype'] == 'interrupt') return answered && fresh.any((e) => e['type'] == 'result');
          return answered;
        }
        return fresh.any((e) => e['type'] == 'result');
      }

      final waiting = Completer<void>();
      _onEvent = () {
        if (!waiting.isCompleted && reached()) waiting.complete();
      };
      if (reached()) waiting.complete();
      if (step.wait || step.waitForText || step.message['type'] == 'control_request') {
        await waiting.future.timeout(const Duration(minutes: 3));
      }
    }
    await process.stdin.close();
    final code = await process.exitCode;
    await done.future;
    _write({'exit': code});
    await sink.close();
    _fixture = null;
    stdout.writeln('  ${fixture.path}: exit $code, session $session, Claude Code $version');
    return session;
  }

  List<String> _sanitizeArgs(List<String> args) => [
        for (var i = 0; i < args.length; i++)
          i > 0 && args[i - 1] == '--mcp-config' ? '<mcp-config>' : args[i],
      ];

  /// Drops what identifies the user or this machine.
  Map<String, Object?>? _sanitize(Map<String, Object?> message) {
    final copy = Map<String, Object?>.from(_clean(message) as Map);
    if (copy['type'] == 'control_response') {
      final response = Map<String, Object?>.from(copy['response'] as Map? ?? const {});
      final body = response['response'];
      if (body is Map && body['commands'] is List) {
        final inner = Map<String, Object?>.from(body);
        final kept = [
          for (final c in inner['commands'] as List)
            if (c is Map && (c['builtin'] == true || '${c['description']}'.endsWith('(project)'))) c,
        ];
        _keptCommands
          ..clear()
          ..addAll(kept.map((c) => '${c['name']}'));
        inner['commands'] = kept;
        for (final k in const ['account', 'pid', 'agents', 'user_output_styles_dir']) {
          inner.remove(k);
        }
        response['response'] = inner;
        copy['response'] = response;
      }
    }
    if (copy['type'] == 'system' && copy['subtype'] == 'init') {
      for (final k in const ['plugins', 'skills', 'agents', 'memory_paths', 'scratchpad_path', 'messaging_socket_path', 'powershell_path']) {
        copy.remove(k);
      }
      if (_keptCommands.isNotEmpty) {
        copy['slash_commands'] = [for (final c in copy['slash_commands'] as List? ?? const []) if (_keptCommands.contains(c)) c];
      }
    }
    return copy;
  }

  Object? _clean(Object? value) {
    if (value is Map) {
      return {
        for (final e in value.entries)
          if (!const {'email', 'organization', 'orgId', 'orgName'}.contains(e.key))
            '${e.key}': e.key == 'signature' ? '' : _clean(e.value),
      };
    }
    if (value is List) return [for (final v in value) _clean(v)];
    if (value is String) return _paths(value);
    return value;
  }

  late final List<(String, String)> _pathReplacements = () {
    final home = Platform.environment['USERPROFILE'] ?? Platform.environment['HOME'] ?? '';
    // Windows paths the way the CLI writes them, however --project was given.
    var projectPath = Directory(project).absolute.path;
    if (Platform.isWindows) projectPath = projectPath.replaceAll('/', r'\');
    final pairs = <(String, String)>[];
    for (final (path, placeholder) in [(projectPath, '<project>'), (home, '<home>')]) {
      if (path.isEmpty) continue;
      pairs
        ..add((path, placeholder))
        ..add((path.replaceAll(r'\', '/'), placeholder))
        ..add((path.replaceAll(r'\', r'\\'), placeholder));
    }
    return pairs;
  }();

  String _paths(String text) {
    var out = text;
    for (final (path, placeholder) in _pathReplacements) {
      out = out.replaceAll(path, placeholder);
    }
    return out;
  }
}

/// The recorder's own MCP server: one `permission_prompt` tool, answered by
/// the recording process over a loopback socket.
Future<void> _permissionServer(int port) async {
  final socket = await Socket.connect(InternetAddress.loopbackIPv4, port);
  final answers = StreamIterator(utf8.decoder.bind(socket).transform(const LineSplitter()));
  await for (final line in stdin.transform(utf8.decoder).transform(const LineSplitter())) {
    if (line.trim().isEmpty) continue;
    final message = Map<String, Object?>.from(jsonDecode(line) as Map);
    final id = message['id'];
    if (id == null) continue;
    Object? result;
    switch (message['method']) {
      case 'initialize':
        result = {
          'protocolVersion': (message['params'] as Map?)?['protocolVersion'] ?? '2025-06-18',
          'capabilities': {'tools': {}},
          'serverInfo': {'name': 'recorder', 'version': '1'},
        };
      case 'tools/list':
        result = {
          'tools': [
            {
              'name': 'permission_prompt',
              'description': 'Answers a permission request while recording.',
              'inputSchema': {
                'type': 'object',
                'properties': {
                  'tool_name': {'type': 'string'},
                  'input': {'type': 'object'},
                  'tool_use_id': {'type': 'string'},
                },
                'required': ['tool_name', 'input'],
              },
            },
          ],
        };
      case 'tools/call':
        socket.writeln(jsonEncode((message['params'] as Map)['arguments']));
        await socket.flush();
        await answers.moveNext();
        result = {
          'content': [
            {'type': 'text', 'text': answers.current},
          ],
        };
      default:
        result = {};
    }
    stdout.writeln(jsonEncode({'jsonrpc': '2.0', 'id': id, 'result': result}));
  }
  await socket.close();
}

String? _option(List<String> args, String name) {
  for (var i = 0; i < args.length; i++) {
    if (args[i] == '--$name' && i + 1 < args.length) return args[i + 1];
    if (args[i].startsWith('--$name=')) return args[i].substring(name.length + 3);
  }
  return null;
}
