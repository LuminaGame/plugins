import 'dart:convert';

/// Claude Code's headless stream-json protocol (`claude -p --input-format
/// stream-json --output-format stream-json --verbose`), one JSON object per
/// line each way.
abstract final class ClaudeCodeProtocol {
  /// A user message line.
  static String userMessage(String text) => jsonEncode({
        'type': 'user',
        'message': {'role': 'user', 'content': text},
      });

  /// A control request line (`initialize`, `interrupt`).
  static String controlRequest(String requestId, String subtype) => jsonEncode({
        'type': 'control_request',
        'request_id': requestId,
        'request': {'subtype': subtype},
      });

  /// The event one output line carries; null for a line MiniAI does not use
  /// (status, rate limits, thinking token counts) or that is not JSON.
  static ClaudeEvent? parse(String line) {
    final Object? decoded;
    try {
      decoded = jsonDecode(line);
    } on FormatException {
      return null;
    }
    if (decoded is! Map) return null;
    final m = Map<String, Object?>.from(decoded);
    switch (m['type']) {
      case 'system':
        switch (m['subtype']) {
          case 'init':
            return ClaudeInit.fromJson(m);
          case 'compact_boundary':
            final meta = m['compact_metadata'];
            return ClaudeCompacted(
              preTokens: meta is Map ? (meta['pre_tokens'] as num?)?.toInt() : null,
              postTokens: meta is Map ? (meta['post_tokens'] as num?)?.toInt() : null,
            );
        }
        return null;
      case 'stream_event':
        final event = m['event'];
        if (event is! Map) return null;
        if (event['type'] == 'message_start') {
          final message = event['message'];
          return ClaudeMessageStart(message is Map ? '${message['id']}' : '');
        }
        if (event['type'] == 'content_block_start') {
          final block = event['content_block'];
          if (block is Map && block['type'] == 'thinking') return ClaudeThinkingDelta('${block['thinking'] ?? ''}');
        }
        if (event['type'] == 'content_block_delta') {
          final delta = event['delta'];
          if (delta is Map && delta['type'] == 'text_delta' && delta['text'] is String) return ClaudeTextDelta(delta['text'] as String);
          // With the CLI's default thinking display the text is empty.
          if (delta is Map && delta['type'] == 'thinking_delta') return ClaudeThinkingDelta('${delta['thinking'] ?? ''}');
        }
        return null;
      case 'assistant':
        final message = m['message'];
        if (message is! Map) return null;
        final blocks = <ClaudeBlock>[];
        for (final b in (message['content'] as List? ?? const [])) {
          if (b is! Map) continue;
          switch (b['type']) {
            case 'text':
              blocks.add(ClaudeTextBlock('${b['text'] ?? ''}'));
            case 'tool_use':
              blocks.add(ClaudeToolUse(
                id: '${b['id']}',
                name: '${b['name']}',
                input: b['input'] is Map ? Map<String, Object?>.from(b['input'] as Map) : const {},
              ));
          }
        }
        return ClaudeAssistant(
          messageId: '${message['id'] ?? ''}',
          blocks: blocks,
          synthetic: message['model'] == '<synthetic>',
          parentToolUseId: m['parent_tool_use_id'] as String?,
        );
      case 'user':
        final message = m['message'];
        if (message is! Map) return null;
        final content = message['content'];
        if (content is String) {
          final local = RegExp(r'<local-command-stdout>([\s\S]*?)</local-command-stdout>').firstMatch(content);
          if (local != null) return ClaudeLocalOutput(local.group(1)!.trim());
          return null;
        }
        if (content is! List) return null;
        for (final b in content) {
          if (b is Map && b['type'] == 'tool_result') {
            return ClaudeToolResult(
              toolUseId: '${b['tool_use_id']}',
              text: _resultText(b['content']),
              images: [
                if (b['content'] is List)
                  for (final c in b['content'] as List)
                    if (c is Map && c['type'] == 'image') Map<String, Object?>.from(c),
              ],
              isError: b['is_error'] == true,
              parentToolUseId: m['parent_tool_use_id'] as String?,
            );
          }
        }
        return null;
      case 'result':
        return ClaudeResult.fromJson(m);
      case 'control_response':
        final response = m['response'];
        if (response is! Map) return null;
        return ClaudeControlResponse(
          requestId: '${response['request_id']}',
          success: response['subtype'] == 'success',
          body: response['response'] is Map ? Map<String, Object?>.from(response['response'] as Map) : const {},
          error: response['error'] as String?,
        );
    }
    return null;
  }

  static String _resultText(Object? content) {
    if (content is String) return content;
    if (content is List) {
      return [
        for (final c in content)
          if (c is Map && c['type'] == 'text') '${c['text']}',
      ].join('\n');
    }
    return content == null ? '' : jsonEncode(content);
  }
}

sealed class ClaudeEvent {
  const ClaudeEvent();
}

/// `system/init`: sent with every user message.
class ClaudeInit extends ClaudeEvent {
  const ClaudeInit({
    required this.sessionId,
    required this.model,
    required this.permissionMode,
    required this.slashCommands,
    required this.terminalCommands,
    required this.tools,
    required this.mcpServers,
    this.version,
  });

  factory ClaudeInit.fromJson(Map<String, Object?> m) => ClaudeInit(
        sessionId: '${m['session_id'] ?? ''}',
        model: '${m['model'] ?? ''}',
        permissionMode: '${m['permissionMode'] ?? ''}',
        slashCommands: [for (final c in (m['slash_commands'] as List? ?? const [])) '$c'],
        terminalCommands: [for (final c in (m['terminal_slash_commands'] as List? ?? const [])) '$c'],
        tools: [for (final t in (m['tools'] as List? ?? const [])) '$t'],
        mcpServers: {
          for (final s in (m['mcp_servers'] as List? ?? const []))
            if (s is Map) '${s['name']}': '${s['status']}',
        },
        version: m['claude_code_version'] as String?,
      );

  final String sessionId;
  final String model;
  final String permissionMode;

  /// The command names the session accepts (no descriptions).
  final List<String> slashCommands;

  /// Commands that only work in the interactive terminal.
  final List<String> terminalCommands;
  final List<String> tools;

  /// MCP server name → `connected`, `failed`, `pending`, …
  final Map<String, String> mcpServers;
  final String? version;
}

/// A new API message starts streaming.
class ClaudeMessageStart extends ClaudeEvent {
  const ClaudeMessageStart(this.messageId);
  final String messageId;
}

class ClaudeTextDelta extends ClaudeEvent {
  const ClaudeTextDelta(this.text);
  final String text;
}

/// The model thinks: a thinking block starts or grows ([text] may be
/// empty when the CLI does not share it).
class ClaudeThinkingDelta extends ClaudeEvent {
  const ClaudeThinkingDelta(this.text);
  final String text;
}

sealed class ClaudeBlock {
  const ClaudeBlock();
}

class ClaudeTextBlock extends ClaudeBlock {
  const ClaudeTextBlock(this.text);
  final String text;
}

class ClaudeToolUse extends ClaudeBlock {
  const ClaudeToolUse({required this.id, required this.name, required this.input});
  final String id;

  /// `mcp__<server>__<tool>` for MCP tools, else a Claude Code tool name.
  final String name;
  final Map<String, Object?> input;
}

/// A complete assistant message (or one of its blocks). With partial
/// messages on, its text also arrived as [ClaudeTextDelta]s.
class ClaudeAssistant extends ClaudeEvent {
  const ClaudeAssistant({required this.messageId, required this.blocks, this.synthetic = false, this.parentToolUseId});
  final String messageId;
  final List<ClaudeBlock> blocks;

  /// A local command's answer (`/context`) or a CLI error, not the model's.
  final bool synthetic;

  /// Set inside a subagent.
  final String? parentToolUseId;
}

class ClaudeToolResult extends ClaudeEvent {
  const ClaudeToolResult({required this.toolUseId, required this.text, required this.isError, this.parentToolUseId, this.images = const []});
  final String toolUseId;
  final String text;

  /// The result's image blocks (`{type: image, source: {data, media_type}}`).
  final List<Map<String, Object?>> images;
  final bool isError;
  final String? parentToolUseId;
}

/// A local command's output (`/compact` → "Compacted").
class ClaudeLocalOutput extends ClaudeEvent {
  const ClaudeLocalOutput(this.text);
  final String text;
}

class ClaudeCompacted extends ClaudeEvent {
  const ClaudeCompacted({this.preTokens, this.postTokens});
  final int? preTokens;
  final int? postTokens;
}

/// The end of one user message's turn.
class ClaudeResult extends ClaudeEvent {
  const ClaudeResult({
    required this.subtype,
    required this.isError,
    required this.sessionId,
    this.result,
    this.totalCostUsd,
    this.numTurns,
    this.durationMs,
    this.apiErrorStatus,
    this.inputTokens = 0,
    this.outputTokens = 0,
  });

  factory ClaudeResult.fromJson(Map<String, Object?> m) {
    final usage = m['usage'] is Map ? m['usage'] as Map : const {};
    int n(Object? v) => (v as num?)?.toInt() ?? 0;
    return ClaudeResult(
      subtype: '${m['subtype'] ?? ''}',
      isError: m['is_error'] == true,
      sessionId: '${m['session_id'] ?? ''}',
      result: m['result'] as String?,
      totalCostUsd: (m['total_cost_usd'] as num?)?.toDouble(),
      numTurns: (m['num_turns'] as num?)?.toInt(),
      durationMs: (m['duration_ms'] as num?)?.toInt(),
      apiErrorStatus: (m['api_error_status'] as num?)?.toInt(),
      inputTokens: n(usage['input_tokens']) + n(usage['cache_read_input_tokens']) + n(usage['cache_creation_input_tokens']),
      outputTokens: n(usage['output_tokens']),
    );
  }

  /// `success`, `error_during_execution` (after an interrupt), `error_max_turns`, …
  final String subtype;

  /// An API or CLI error even when [subtype] is `success`.
  final bool isError;
  final String sessionId;
  final String? result;

  /// Adds up over the process, not per message.
  final double? totalCostUsd;
  final int? numTurns;
  final int? durationMs;
  final int? apiErrorStatus;
  final int inputTokens;
  final int outputTokens;
}

/// The process ended.
class ClaudeExited extends ClaudeEvent {
  const ClaudeExited(this.code);
  final int code;
}

class ClaudeControlResponse extends ClaudeEvent {
  const ClaudeControlResponse({required this.requestId, required this.success, required this.body, this.error});
  final String requestId;
  final bool success;
  final Map<String, Object?> body;
  final String? error;
}

/// One command the CLI accepts.
class ClaudeCommand {
  const ClaudeCommand({required this.name, this.description = '', this.argumentHint = ''});
  final String name;
  final String description;
  final String argumentHint;
}

/// One model the CLI offers.
class ClaudeModel {
  const ClaudeModel({required this.value, required this.displayName, this.description = ''});

  /// What `--model` takes (`default`, `sonnet`, a full id).
  final String value;
  final String displayName;
  final String description;
}

/// What `initialize` reports, without a model call.
class ClaudeCapabilities {
  const ClaudeCapabilities({this.commands = const [], this.models = const [], this.permissionMode});

  factory ClaudeCapabilities.fromInitialize(Map<String, Object?> body) => ClaudeCapabilities(
        commands: [
          for (final c in (body['commands'] as List? ?? const []))
            if (c is Map && c['name'] is String)
              ClaudeCommand(name: c['name'] as String, description: '${c['description'] ?? ''}', argumentHint: '${c['argumentHint'] ?? ''}'),
        ],
        models: [
          for (final m in (body['models'] as List? ?? const []))
            if (m is Map && m['value'] is String)
              ClaudeModel(value: m['value'] as String, displayName: '${m['displayName'] ?? m['value']}', description: '${m['description'] ?? ''}'),
        ],
        permissionMode: body['current_permission_mode'] as String?,
      );

  final List<ClaudeCommand> commands;
  final List<ClaudeModel> models;
  final String? permissionMode;
}
