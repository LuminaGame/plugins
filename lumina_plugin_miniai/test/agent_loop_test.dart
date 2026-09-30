// The agent loop over real recorded MiniCPM5 streams.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_editor_api/lumina_editor_api.dart';
import 'package:lumina_plugin_miniai/lumina_plugin_miniai.dart';

import 'support/local_mcp.dart';
import 'support/replay_server.dart';

void main() {
  late ReplayServer server;
  late LocalMcp mcp;
  late List<String> transactions;
  var actors = 5;

  setUp(() async {
    server = await ReplayServer.start();
    mcp = LocalMcp();
    transactions = [];
    actors = 5;
    mcp.registerTool(McpTool(
      name: 'probe.count',
      description: 'Counts the actors in the open level.',
      inputSchema: McpSchema.object({}),
      handler: (_) => McpToolResult.json({'count': actors}),
      risk: McpToolRisk.readOnly,
      groups: {McpToolGroups.level},
    ));
    mcp.registerTool(McpTool(
      name: 'spawn_actor_from_asset',
      description: 'Places a mesh asset in the open level as a new actor.',
      inputSchema: McpSchema.object({
        'asset': McpSchema.string('asset path'),
        'location': McpSchema.vector3('[x, y, z]'),
      }, required: ['asset']),
      handler: (args) {
        actors++;
        return McpToolResult.json({'placed': args.string('asset'), 'at': args['location']});
      },
      risk: McpToolRisk.mutating,
      groups: {McpToolGroups.level},
    ));
  });
  tearDown(() => server.close());

  AgentLoop loop({int maxRounds = 6}) => AgentLoop(
        provider: OpenAiCompatProvider(name: 'local', baseUrl: server.baseUrl),
        model: 'MiniCPM5-2B-Q4_K_M',
        mcp: mcp,
        maxRounds: maxRounds,
        transaction: (label, body) async {
          transactions.add(label);
          await body();
        },
      );

  test('a read-only tool runs without asking, its result goes back, and the model answers; one transaction', () async {
    server.queue.addAll(['tool_call', 'tool_result_answer']);
    final chat = Chat(id: 'c1');
    await loop().run(chat, 'How many actors are in the level? Use the tool.');

    expect(mcp.recorded.single.$1, 'probe.count');
    expect(mcp.recorded.single.$3, 'miniai:c1:1', reason: 'attributed to MiniAI, per turn');
    final second = server.requests[1]['messages'] as List;
    final toolMessage = second.lastWhere((m) => (m as Map)['role'] == 'tool') as Map;
    expect(jsonDecode(toolMessage['content'] as String), {'count': 5});
    final answer = chat.items.whereType<AssistantItem>().last.text.toString();
    expect(answer, contains('5 actors'));
    expect(chat.items.whereType<ToolCallItem>().single.status, ToolCallStatus.done);
    expect(transactions, ['AI: How many actors are in the level? Use the tool.']);
    expect(chat.running, isFalse);
    expect(chat.title, 'How many actors are in the level? Use the tool.');
  });

  test('ask mode: each mutating call waits; Allow runs it, Deny sends the reason back', () async {
    server.queue.addAll(['two_tool_calls', 'text']);
    final chat = Chat(id: 'c2');
    var answered = 0;
    chat.addListener(() {
      for (final item in chat.pendingApprovals) {
        answered++;
        chat.answer(item, answered == 1 ? const ApprovalAnswer.allow() : const ApprovalAnswer.deny('not there'));
      }
    });
    await loop().run(chat, 'Place the barrel twice');
    final cards = chat.items.whereType<ToolCallItem>().toList();
    expect(cards.map((c) => c.status), [ToolCallStatus.done, ToolCallStatus.denied]);
    expect(mcp.recorded.map((c) => c.$1), ['spawn_actor_from_asset'], reason: 'only the allowed call ran');
    expect(actors, 6);
    final second = server.requests[1]['messages'] as List;
    final denied = second.where((m) => (m as Map)['role'] == 'tool').last as Map;
    expect(denied['content'], contains('not there'));
  });

  test('"always allow in this chat" lets the second call through without a card', () async {
    server.queue.addAll(['two_tool_calls', 'text']);
    final chat = Chat(id: 'c3');
    var cards = 0;
    chat.addListener(() {
      for (final item in chat.pendingApprovals) {
        cards++;
        chat.answer(item, const ApprovalAnswer.alwaysAllow());
      }
    });
    await loop().run(chat, 'Place the barrel twice');
    expect(cards, 1);
    expect(mcp.recorded, hasLength(2));
  });

  test('plan mode never offers the mutating tool, and refuses a call to it', () async {
    server.queue.addAll(['two_tool_calls', 'text']);
    final chat = Chat(id: 'c4', mode: ApprovalMode.plan);
    await loop().run(chat, 'Place the barrel twice');
    final offered = [for (final t in (server.requests.first['tools'] as List? ?? const [])) ((t as Map)['function'] as Map)['name']];
    expect(offered, isNot(contains('spawn_actor_from_asset')));
    expect(chat.items.whereType<ToolCallItem>().map((c) => c.status), everyElement(ToolCallStatus.denied));
    expect(mcp.recorded, isEmpty);
  });

  test('plan mode: the model is told its mode and the tools a plan would use; the turn records them', () async {
    server.queue.addAll(['two_tool_calls', 'text']);
    final chat = Chat(id: 'p1', mode: ApprovalMode.plan);
    await loop().run(chat, 'Place the barrel twice');
    final system = ((server.requests.first['messages'] as List).first as Map)['content'] as String;
    expect(system, contains('You are in Plan mode: you can read and look around but cannot change the project. '
        'Propose a plan; the user can switch to Ask or Auto to execute it.'));
    expect(system, contains('spawn_actor_from_asset'));
    expect(chat.turns.single.planBlocked, ['spawn_actor_from_asset']);
    expect(Chat.fromJson(chat.toJson()).turns.single.planBlocked, ['spawn_actor_from_asset'], reason: 'saved with the chat');
  });

  test('ask mode: the prompt says so, nothing is Plan-blocked, and a mode change rewrites the prompt', () async {
    server.queue.addAll(['tool_call', 'tool_result_answer', 'text']);
    final chat = Chat(id: 'p2');
    await loop().run(chat, 'How many actors are in the level? Use the tool.');
    final first = ((server.requests.first['messages'] as List).first as Map)['content'] as String;
    expect(first, contains("You are in Ask mode: you may change the project. Changes wait for the user's approval."));
    expect(first, isNot(contains('Plan mode')));
    expect(chat.turns.single.planBlocked, isEmpty);
    chat.gate.mode = ApprovalMode.plan;
    await loop().run(chat, 'What is in the level?');
    final third = ((server.requests.last['messages'] as List).first as Map)['content'] as String;
    expect(third, contains('You are in Plan mode'));
    expect(chat.turns.last.planBlocked, isEmpty, reason: 'a question, no change asked for');
  });

  test('the round limit stops the turn with a note', () async {
    server.queue.addAll(['tool_call', 'tool_call']);
    final chat = Chat(id: 'c5');
    await loop(maxRounds: 1).run(chat, 'How many actors?');
    expect(chat.items.whereType<NoteItem>().last.text, contains('Stopped after 1 round'));
  });

  test('Stop cancels the stream and runs no tool call', () async {
    server.chunkDelay = const Duration(milliseconds: 40);
    server.queue.add('two_tool_calls');
    final chat = Chat(id: 'c6');
    final cancel = CancelToken();
    final running = loop().run(chat, 'Place the barrel twice', cancel: cancel);
    await Future<void>.delayed(const Duration(milliseconds: 150));
    cancel.cancel();
    await running.timeout(const Duration(seconds: 5));
    expect(mcp.recorded, isEmpty);
    expect(chat.items.whereType<NoteItem>().last.text, 'Stopped.');
    expect(chat.running, isFalse);
  });

  test('a provider error ends the turn with the message', () async {
    server.nextError = (401, jsonEncode({'error': {'message': 'Invalid API key'}}));
    final chat = Chat(id: 'c7');
    await loop().run(chat, 'hi');
    final note = chat.items.whereType<NoteItem>().single;
    expect(note.isError, isTrue);
    expect(note.text, contains('Invalid API key'));
  });
}
