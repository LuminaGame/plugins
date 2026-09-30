import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:lumina_editor_api/lumina_editor_api.dart';

import '../agent/agent_loop.dart';
import '../agent/approval.dart';
import '../agent/chat.dart';
import '../llm/llm_types.dart';
import 'claude_code_cli.dart';
import 'claude_code_protocol.dart';
import 'claude_code_session.dart';

/// MiniAI's tool that answers Claude Code's permission requests, as the
/// plugin registers it and as the CLI names it.
abstract final class ClaudeCodePermissions {
  /// The name MiniAI registers (the host prefixes the plugin's name).
  static const String toolName = 'permission_prompt';

  /// The name on the editor's MCP server.
  static const String serverName = 'lumina_plugin_miniai.permission_prompt';

  /// The name Claude Code gives it (`mcp__<server>__<tool>`, dots become `_`).
  static const String cliName = 'mcp__lumina__lumina_plugin_miniai_permission_prompt';

  /// Claude Code's own tools, by what they do to the project.
  static const Map<String, McpToolRisk> builtInRisk = {
    'Read': McpToolRisk.readOnly,
    'Glob': McpToolRisk.readOnly,
    'Grep': McpToolRisk.readOnly,
    'LS': McpToolRisk.readOnly,
    'ToolSearch': McpToolRisk.readOnly,
    'TodoWrite': McpToolRisk.readOnly,
    'NotebookRead': McpToolRisk.readOnly,
    'ListMcpResourcesTool': McpToolRisk.readOnly,
    'ReadMcpResourceTool': McpToolRisk.readOnly,
    'ReadMcpResourceDirTool': McpToolRisk.readOnly,
    'Edit': McpToolRisk.mutating,
    'Write': McpToolRisk.mutating,
    'MultiEdit': McpToolRisk.mutating,
    'NotebookEdit': McpToolRisk.mutating,
  };

  /// Claude Code tools that change files outside the editor's undo.
  static const Set<String> untrackedEdits = {'Edit', 'Write', 'MultiEdit', 'NotebookEdit', 'Bash', 'PowerShell'};

  /// Tools shown as no card (Claude Code's own bookkeeping).
  static const Set<String> hidden = {'ToolSearch', 'TodoWrite'};
}

/// Runs chats on the user's installed Claude Code CLI: one process per
/// chat, its tool calls as tool cards, its permission requests through the
/// chat's approval gate, its level and file changes attributed to the turn.
class ClaudeCodeAgent {
  ClaudeCodeAgent({
    required this.mcp,
    required this.workingDirectory,
    this.configDir,
    this.transaction,
    ClaudeCodeStarter? starter,
    ClaudeCodeCli? cli,
  })  : starter = starter ?? ClaudeCodeProcess.start,
        cli = cli ?? const ClaudeCodeCli();

  final EditorMcp mcp;

  /// The project folder the CLI runs in.
  final String workingDirectory;

  /// Where the per-chat MCP config files go (the project's MiniAI folder).
  final Directory? configDir;
  final TurnTransaction? transaction;
  final ClaudeCodeStarter starter;
  final ClaudeCodeCli cli;

  ClaudeCodeSession? _session;
  String? _sessionChat;
  String? _sessionModel;
  String? _sessionCommand;

  /// The running turn (permission requests go to it).
  _Turn? _turn;

  /// The open chat's process, if it runs.
  ClaudeCodeSession? get session => _session;

  static const String systemPrompt =
      'You are running inside Lumina Studio, a 3D game editor, as its AI Assistant (MiniAI). '
      'Change the open project through the tools of the "lumina" MCP server (level, assets, blueprints, files): '
      'their edits can be undone in the editor. Units are centimetres and Z is up. Answer briefly.';

  /// The tag the chat's bridge connects with (`--caller`).
  static String callerTag(String chatId) => 'miniai-cc-$chatId';

  /// The chat's process: reused while [chat], [model] and [command] stay
  /// the same, else (re)started, continuing the stored session.
  Future<ClaudeCodeSession> ensureSession(Chat chat, {String? model, String? command}) async {
    final current = _session;
    if (current != null && current.alive && _sessionChat == chat.id && _sessionModel == (model ?? '') && _sessionCommand == command) {
      return current;
    }
    await close();
    final exe = cli.find(override: command);
    if (exe == null) throw StateError(command == null ? 'Claude Code (claude) was not found. ${ClaudeCodeCli.installHint}' : 'No Claude Code at $command.');
    final launch = mcp.clientLaunch;
    String? config;
    if (launch != null) config = await _writeMcpConfig(chat.id, launch);
    final data = chat.providerData[providerKey];
    final resume = data is Map ? data['sessionId'] as String? : null;
    final session = ClaudeCodeSession(
      executable: exe,
      workingDirectory: workingDirectory,
      starter: starter,
      model: model,
      resume: resume,
      mcpConfigPath: config,
      permissionPromptTool: config == null ? null : ClaudeCodePermissions.cliName,
      appendSystemPrompt: systemPrompt,
    );
    _session = session;
    _sessionChat = chat.id;
    _sessionModel = model ?? '';
    _sessionCommand = command;
    await session.start();
    return session;
  }

  /// The key of [Chat.providerData].
  static const String providerKey = 'claude_code';

  Future<String> _writeMcpConfig(String chatId, McpClientLaunch launch) async {
    final dir = Directory('${(configDir ?? Directory.systemTemp).path}/claude_code');
    await dir.create(recursive: true);
    final file = File('${dir.path}/$chatId.mcp.json');
    await file.writeAsString(const JsonEncoder.withIndent('  ').convert({
      'mcpServers': {
        'lumina': {
          'type': 'stdio',
          'command': launch.command,
          'args': [...launch.args, '--caller', callerTag(chatId)],
          if (launch.environment.isNotEmpty) 'env': launch.environment,
        },
      },
    }));
    return file.path;
  }

  /// The models the CLI at [executable] offers: a process with no MCP
  /// servers answers `initialize` and exits, without a model call.
  Future<List<ClaudeModel>> probeModels(String executable) async {
    final probe = ClaudeCodeSession(executable: executable, workingDirectory: workingDirectory, starter: starter);
    try {
      await probe.start();
      return probe.capabilities?.models ?? const [];
    } finally {
      await probe.close();
    }
  }

  /// Stops the process (a chat switch, the editor closing).
  Future<void> close() async {
    final s = _session;
    _session = null;
    _sessionChat = null;
    await s?.close();
  }

  /// Runs [userText] as one turn of [chat] on Claude Code.
  Future<void> run(Chat chat, String userText, {String? model, String? command, CancelToken? cancel}) async {
    final token = cancel ?? CancelToken();
    if (chat.history.isEmpty) chat.history.add(LlmMessage.system(AgentLoop.systemPrompt()));
    final label = 'AI: ${AgentLoop.titleOf(userText)}';
    final turn = TurnRecord(id: '${chat.id}:${chat.turns.length + 1}', label: label, userItemIndex: chat.items.length);
    if (!mcp.attributesExternalCalls) {
      turn.undoUnavailable = "This editor cannot tie Claude Code's tool calls to a turn; use Edit ▸ Undo instead.";
    }
    chat.turns.add(turn);
    chat.items.add(UserItem(userText));
    chat.history.add(LlmMessage.user(userText));
    if (chat.title == Chat.defaultTitle) chat.title = AgentLoop.titleOf(userText);
    chat.running = true;
    chat.changed();
    try {
      Future<void> body() => mcp.attributeExternalCalls(callerTag(chat.id), turn.caller, () => _stream(chat, turn, userText, token, model, command));
      final tx = transaction;
      if (tx != null) {
        await tx(label, body);
      } else {
        await body();
      }
    } catch (e) {
      chat.items.add(NoteItem('Claude Code: $e', isError: true));
    } finally {
      _turn = null;
      chat.running = false;
      chat.changed();
    }
  }

  Future<void> _stream(Chat chat, TurnRecord record, String userText, CancelToken token, String? model, String? command) async {
    final session = await ensureSession(chat, model: model, command: command);
    final turn = _turn = _Turn(chat, record, this);
    final done = Completer<void>();
    final sub = session.events.listen((event) {
      if (done.isCompleted) return;
      if (turn.handle(event)) done.complete();
    });
    final stop = token.whenCancelled.then((_) async {
      turn.stopped = true;
      turn.denyPending('stopped');
      await session.interrupt();
      // An interrupt ends the turn with a result; a dead process never does.
      await Future<void>.delayed(const Duration(seconds: 10));
      if (!done.isCompleted) done.complete();
    });
    session.sendUser(userText);
    await done.future;
    await sub.cancel();
    unawaited(stop);
    turn.finish();
    if (turn.stopped) chat.items.add(NoteItem('Stopped.'));
    final text = turn.answer.toString().trim();
    if (text.isNotEmpty) chat.history.add(LlmMessage.assistant(text));
  }

  /// Answers one of Claude Code's permission requests
  /// (`{tool_name, input, tool_use_id}`) with `{"behavior": "allow", …}` or
  /// `{"behavior": "deny", "message"}`.
  Future<Map<String, Object?>> permission(Map<String, Object?> request) async {
    final turn = _turn;
    if (turn == null) return {'behavior': 'deny', 'message': 'No MiniAI turn is running; MiniAI answers only its own Claude Code sessions.'};
    return turn.permission(request);
  }

  /// The editor tool behind a Claude Code tool name (`mcp__lumina__<name>`).
  McpTool? editorTool(String cliName) {
    const prefix = 'mcp__lumina__';
    if (!cliName.startsWith(prefix)) return null;
    final name = cliName.substring(prefix.length);
    for (final t in mcp.listTools()) {
      if (t.name == name || t.name.replaceAll('.', '_') == name) return t;
    }
    return null;
  }

  /// The name a card shows: the editor tool's name, or Claude Code's.
  String displayName(String cliName) => editorTool(cliName)?.name ?? cliName.replaceFirst('mcp__lumina__', '');

  /// What [cliName] with [input] does to the project.
  McpToolRisk riskOf(String cliName, Map<String, Object?> input) =>
      editorTool(cliName)?.riskOf(input) ?? ClaudeCodePermissions.builtInRisk[cliName] ?? McpToolRisk.external;
}

class _Turn {
  _Turn(this.chat, this.record, this.agent);

  final Chat chat;
  final TurnRecord record;
  final ClaudeCodeAgent agent;
  final StringBuffer answer = StringBuffer();
  final Map<String, ToolCallItem> _calls = {};
  final Map<String, Stopwatch> _clocks = {};
  final Set<String> _streamed = {};
  final Set<String> _denied = {};
  String? _message;
  bool stopped = false;
  bool _warnedTools = false;

  AssistantItem _assistant() {
    final last = chat.items.isEmpty ? null : chat.items.last;
    if (last is AssistantItem) return last;
    final item = AssistantItem();
    chat.items.add(item);
    return item;
  }

  void _text(String text) {
    _assistant().text.write(text);
    answer.write(text);
    chat.changed();
  }

  /// Handles one event; true when the turn is over.
  bool handle(ClaudeEvent event) {
    switch (event) {
      case ClaudeInit():
        _init(event);
      case ClaudeMessageStart(:final messageId):
        _message = messageId;
      case ClaudeTextDelta(:final text):
        if (_message != null) _streamed.add(_message!);
        _text(text);
      case ClaudeAssistant():
        if (event.parentToolUseId != null) return false;
        for (final b in event.blocks) {
          switch (b) {
            case ClaudeTextBlock(:final text):
              // Streamed already, unless the message had no deltas (a local
              // command's answer, a CLI error).
              if (!_streamed.contains(event.messageId) && text.isNotEmpty) {
                if (answer.isNotEmpty) _text('\n\n');
                _text(text);
              }
            case ClaudeToolUse():
              _toolUse(b);
          }
        }
      case ClaudeToolResult():
        if (event.parentToolUseId == null) _toolResult(event);
      case ClaudeLocalOutput(:final text):
        if (text.isNotEmpty) chat.items.add(NoteItem(text));
        chat.changed();
      case ClaudeCompacted(:final preTokens, :final postTokens):
        chat.items.add(NoteItem(preTokens == null ? 'Context compacted.' : 'Context compacted: ${_k(preTokens)} → ${_k(postTokens ?? 0)} tokens.'));
        chat.changed();
      case ClaudeResult():
        _result(event);
        return true;
      case ClaudeExited(:final code):
        if (!stopped) {
          final tail = agent.session?.errorTail ?? '';
          chat.items.add(NoteItem('Claude Code exited (code $code)${tail.isEmpty ? '.' : ': $tail'}', isError: true));
        }
        return true;
      case ClaudeControlResponse():
        break;
    }
    return false;
  }

  static String _k(int n) => n >= 1000 ? '${(n / 1000).toStringAsFixed(1)}k' : '$n';

  void _init(ClaudeInit init) {
    final data = Map<String, Object?>.from(chat.providerData[ClaudeCodeAgent.providerKey] as Map? ?? const {});
    data['sessionId'] = init.sessionId;
    data['model'] = init.model;
    chat.providerData[ClaudeCodeAgent.providerKey] = data;
    final lumina = init.mcpServers['lumina'];
    if (!_warnedTools && agent.mcp.clientLaunch != null && lumina != null && lumina != 'connected') {
      _warnedTools = true;
      chat.items.add(NoteItem('The editor tools are not connected to Claude Code ($lumina). Turn on Tools ▸ AI Agent Access (MCP).', isError: true));
    }
    chat.changed();
  }

  ToolCallItem _card(String id, String name, Map<String, Object?> input) {
    final existing = _calls[id];
    if (existing != null) return existing;
    final item = ToolCallItem(
      call: LlmToolCall(id: id, name: agent.displayName(name), argumentsJson: jsonEncode(input)),
      risk: agent.riskOf(name, input),
    );
    _calls[id] = item;
    _clocks[id] = Stopwatch()..start();
    if (!ClaudeCodePermissions.hidden.contains(name)) chat.items.add(item);
    chat.changed();
    return item;
  }

  final Map<String, String> _names = {};

  void _toolUse(ClaudeToolUse use) {
    _names[use.id] = use.name;
    _card(use.id, use.name, use.input);
  }

  void _toolResult(ClaudeToolResult result) {
    final item = _calls[result.toolUseId];
    if (item == null) return;
    item.elapsed = _clocks[result.toolUseId]?.elapsed;
    item.result = result.text;
    item.images = [
      for (final image in result.images) ?ChatImage.fromContent(image, id: chat.newImageId(), source: '${item.call.name} (${result.toolUseId})'),
    ];
    item.status = _denied.contains(result.toolUseId)
        ? ToolCallStatus.denied
        : (result.isError ? ToolCallStatus.failed : ToolCallStatus.done);
    if (item.status == ToolCallStatus.done) {
      final name = _names[result.toolUseId] ?? '';
      final tool = agent.editorTool(name);
      if (tool != null && tool.risk != McpToolRisk.readOnly && tool.groups.any(AgentLoop.fileGroups.contains) && agent.mcp.attributesExternalCalls) {
        record.fileWrites++;
      }
      if (ClaudeCodePermissions.untrackedEdits.contains(name)) record.untracked++;
    }
    chat.changed();
  }

  void _result(ClaudeResult result) {
    final data = Map<String, Object?>.from(chat.providerData[ClaudeCodeAgent.providerKey] as Map? ?? const {});
    if (result.sessionId.isNotEmpty) data['sessionId'] = result.sessionId;
    if (result.totalCostUsd != null) data['costUsd'] = result.totalCostUsd;
    if (result.numTurns != null) data['turns'] = result.numTurns;
    if (result.durationMs != null) data['durationMs'] = result.durationMs;
    chat.providerData[ClaudeCodeAgent.providerKey] = data;
    chat.lastUsage = Usage(promptTokens: result.inputTokens, completionTokens: result.outputTokens);
    if (stopped) {
      // An interrupt ends as `error_during_execution`; the turn says "Stopped.".
    } else if (result.isError) {
      chat.items.add(NoteItem(result.result?.trim().isNotEmpty == true ? result.result!.trim() : 'Claude Code reported an error (${result.subtype}).', isError: true));
    } else if (result.subtype != 'success') {
      chat.items.add(NoteItem('Claude Code stopped: ${result.subtype}.', isError: true));
    }
    chat.changed();
  }

  Future<Map<String, Object?>> permission(Map<String, Object?> request) async {
    final name = '${request['tool_name']}';
    final input = request['input'] is Map ? Map<String, Object?>.from(request['input'] as Map) : <String, Object?>{};
    final id = '${request['tool_use_id'] ?? 'permission_${_calls.length + 1}'}';
    final risk = agent.riskOf(name, input);
    Map<String, Object?> allow() => {'behavior': 'allow', 'updatedInput': input};
    Map<String, Object?> deny(String message) {
      _denied.add(id);
      final item = _calls[id];
      if (item != null) {
        item.status = ToolCallStatus.denied;
        item.result = message;
        chat.changed();
      }
      return {'behavior': 'deny', 'message': message};
    }

    if (stopped) return deny('The user stopped the turn.');
    switch (chat.gate.decideRisk(agent.displayName(name), risk)) {
      case ApprovalDecision.allow:
        return allow();
      case ApprovalDecision.hidden:
        return deny('${agent.displayName(name)} is not available in ${chat.gate.mode.label} mode; do not retry it.');
      case ApprovalDecision.ask:
        final item = _card(id, name, input);
        item.status = ToolCallStatus.waitingApproval;
        final pending = item.approval = Completer<ApprovalAnswer>();
        chat.changed();
        final answer = await pending.future;
        item.approval = null;
        if (!answer.allowed) return deny(answer.reason ?? 'The user denied it.');
        item.status = ToolCallStatus.running;
        _clocks[id] = Stopwatch()..start();
        chat.changed();
        return allow();
    }
  }

  /// Denies every card still waiting (Stop).
  void denyPending(String reason) {
    for (final item in _calls.values) {
      final pending = item.approval;
      if (pending != null && !pending.isCompleted) pending.complete(ApprovalAnswer.deny(reason));
    }
  }

  /// Cards that never got a result end as failed.
  void finish() {
    denyPending('the turn ended');
    for (final item in _calls.values) {
      if (item.status == ToolCallStatus.running || item.status == ToolCallStatus.waitingApproval) {
        item.status = ToolCallStatus.failed;
        if (item.result.isEmpty) item.result = stopped ? 'Stopped.' : 'No result.';
      }
    }
  }
}
