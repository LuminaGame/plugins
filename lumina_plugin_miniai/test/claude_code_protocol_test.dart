// Claude Code's stream-json lines, from sessions recorded with the real CLI
// (tool/record_claude_code.dart).
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_plugin_miniai/lumina_plugin_miniai.dart';

List<ClaudeEvent> _events(String name) => [
      for (final l in File('test/fixtures/claude_code/$name.jsonl').readAsLinesSync())
        if (l.trim().isNotEmpty && (jsonDecode(l) as Map).containsKey('out'))
          ?ClaudeCodeProtocol.parse(jsonEncode((jsonDecode(l) as Map)['out'])),
    ];

void main() {
  test('initialize reports the commands with descriptions and the models, with no model call', () {
    final response = _events('slash_commands').whereType<ClaudeControlResponse>().first;
    expect(response.success, isTrue);
    final caps = ClaudeCapabilities.fromInitialize(response.body);
    final names = caps.commands.map((c) => c.name).toList();
    expect(names, containsAll(['hello', 'compact', 'context', 'usage']));
    final hello = caps.commands.firstWhere((c) => c.name == 'hello');
    expect(hello.description, 'Say hello from a custom project command (project)');
    expect(caps.commands.firstWhere((c) => c.name == 'compact').argumentHint, isNotEmpty);
    expect(caps.models.map((m) => m.value), containsAll(['default', 'sonnet', 'haiku']));
    expect(caps.permissionMode, 'default');
  });

  test('system/init: session, model, permission mode, commands and the MCP servers', () {
    final init = _events('turns_and_tools').whereType<ClaudeInit>().first;
    expect(init.sessionId, hasLength(36));
    expect(init.model, startsWith('claude-haiku'));
    expect(init.permissionMode, 'default');
    expect(init.slashCommands, containsAll(['hello', 'compact', 'context']));
    expect(init.terminalCommands, contains('doctor'));
    expect(init.mcpServers['lumina'], 'connected');
    expect(init.tools, contains('mcp__lumina__list_actors'));
    expect(init.version, '2.1.285');
    // A process whose editor is not running reports the server failed.
    expect(_events('resume').whereType<ClaudeInit>().first.mcpServers['lumina'], 'failed');
  });

  test('a tool turn: text deltas, a tool_use, its tool_result, one result with the cost', () {
    final events = _events('turns_and_tools');
    final uses = [
      for (final a in events.whereType<ClaudeAssistant>())
        for (final b in a.blocks.whereType<ClaudeToolUse>())
          if (b.name != 'ToolSearch') b,
    ];
    expect(uses.map((u) => u.name), ['mcp__lumina__list_actors', 'mcp__lumina__spawn_actor']);
    expect(uses.last.input, {'type': 'PointLight'});
    final results = [for (final r in events.whereType<ClaudeToolResult>()) if (uses.any((u) => u.id == r.toolUseId)) r];
    expect(results.first.toolUseId, uses.first.id);
    expect(results.first.isError, isFalse);
    expect(results.first.text, contains('"count"'));
    expect(results.last.isError, isTrue, reason: 'the permission prompt denied spawn_actor');
    expect(events.whereType<ClaudeTextDelta>(), isNotEmpty);
    final done = events.whereType<ClaudeResult>().toList();
    expect(done, hasLength(2));
    expect(done.last.isError, isFalse);
    expect(done.last.totalCostUsd, greaterThan(done.first.totalCostUsd!), reason: 'the cost adds up over the process');
    expect(done.first.numTurns, greaterThanOrEqualTo(2));
  });

  test('local commands answer with a synthetic message and no cost', () {
    final events = _events('slash_commands');
    final synthetic = events.whereType<ClaudeAssistant>().where((a) => a.synthetic).first;
    expect((synthetic.blocks.first as ClaudeTextBlock).text, contains('Context Usage'));
    final firstResult = events.whereType<ClaudeResult>().first;
    expect(firstResult.totalCostUsd, 0);
    expect(events.whereType<ClaudeResult>().last.result, contains('HELLO-CUSTOM'));
  });

  test('errors: an unknown model is an error result; an interrupt ends with error_during_execution', () {
    final error = _events('error_model').whereType<ClaudeResult>().single;
    expect(error.isError, isTrue);
    expect(error.subtype, 'success');
    expect(error.apiErrorStatus, 404);
    expect(error.result, contains('claude-not-a-model-x'));
    final interrupted = _events('interrupt');
    expect(interrupted.whereType<ClaudeControlResponse>().last.requestId, 'interrupt-1');
    expect(interrupted.whereType<ClaudeResult>().single.subtype, 'error_during_execution');
  });

  test('lines MiniAI does not use are skipped', () {
    expect(ClaudeCodeProtocol.parse('not json'), isNull);
    expect(ClaudeCodeProtocol.parse('{"type":"rate_limit_event"}'), isNull);
    expect(ClaudeCodeProtocol.parse('{"type":"system","subtype":"status","status":"requesting"}'), isNull);
    expect(ClaudeCodeProtocol.userMessage('hi'), '{"type":"user","message":{"role":"user","content":"hi"}}');
  });
}
