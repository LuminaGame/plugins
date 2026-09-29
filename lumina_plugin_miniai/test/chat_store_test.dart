// Chats stored per project — chats made by the real
// agent loop over recorded MiniCPM5 streams, saved to and read back from a
// real temp directory.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_editor_api/lumina_editor_api.dart';
import 'package:lumina_plugin_miniai/lumina_plugin_miniai.dart';

import 'support/local_mcp.dart';
import 'support/replay_server.dart';

void main() {
  late Directory temp;
  late ReplayServer server;
  late LocalMcp mcp;
  late ChatStore store;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('miniai_store_');
    store = ChatStore(Directory('${temp.path}/.lumina/plugins/lumina_plugin_miniai'));
    server = await ReplayServer.start();
    mcp = LocalMcp()
      ..registerTool(McpTool(
        name: 'probe.count',
        description: 'Counts the actors in the open level.',
        inputSchema: McpSchema.object({}),
        handler: (_) => McpToolResult.json({'count': 5}),
        risk: McpToolRisk.readOnly,
        groups: {McpToolGroups.level},
      ))
      ..registerTool(McpTool(
        name: 'spawn_actor_from_asset',
        description: 'Places a mesh asset in the open level as a new actor.',
        inputSchema: McpSchema.object({'asset': McpSchema.string('asset path'), 'location': McpSchema.vector3('[x, y, z]')}, required: ['asset']),
        handler: (args) => McpToolResult.json({'placed': args.string('asset')}),
        risk: McpToolRisk.mutating,
        groups: {McpToolGroups.level},
      ));
  });

  tearDown(() async {
    await server.close();
    await temp.delete(recursive: true);
  });

  AgentLoop loop() => AgentLoop(provider: OpenAiCompatProvider(name: 'local', baseUrl: server.baseUrl), model: 'MiniCPM5-2B-Q4_K_M', mcp: mcp);

  /// A chat with a tool call and an answer (recorded streams).
  Future<Chat> countChat(String id) async {
    server.queue.addAll(['tool_call', 'tool_result_answer']);
    final chat = Chat(id: id)
      ..provider = 'miniai_local'
      ..model = 'MiniCPM5-2B-Q4_K_M';
    await loop().run(chat, 'How many actors are in the level? Use the tool.');
    return chat;
  }

  /// A chat that placed a barrel (allowed) and was denied the second one.
  Future<Chat> barrelChat(String id) async {
    server.queue.addAll(['two_tool_calls', 'text']);
    final chat = Chat(id: id);
    var n = 0;
    chat.addListener(() {
      for (final item in chat.pendingApprovals) {
        n++;
        chat.answer(item, n == 1 ? const ApprovalAnswer.allow() : const ApprovalAnswer.deny('not there'));
      }
    });
    await loop().run(chat, 'Place the barrel twice');
    return chat;
  }

  test('a chat round-trips: history, items, mode and always-allowed tools; no .tmp left', () async {
    final chat = await countChat('c1');
    chat.gate.mode = ApprovalMode.acceptEdits;
    chat.gate.alwaysAllow('spawn_actor_from_asset');
    await store.save(chat);

    final back = (await store.load('c1'))!;
    expect(back.title, chat.title);
    expect(back.gate.mode, ApprovalMode.acceptEdits);
    expect(back.gate.isAlwaysAllowed('spawn_actor_from_asset'), isTrue);
    expect(back.provider, 'miniai_local');
    expect(back.model, 'MiniCPM5-2B-Q4_K_M');
    String flat(LlmMessage m) => jsonEncode([m.role.name, m.content, m.toolCallId, m.toolName, [for (final c in m.toolCalls) [c.id, c.name, jsonDecode(c.argumentsJson)]]]);
    expect(back.history.map(flat).toList(), chat.history.map(flat).toList());
    expect(back.items.map((i) => i.runtimeType).toList(), chat.items.map((i) => i.runtimeType).toList());
    final card = back.items.whereType<ToolCallItem>().single;
    final original = chat.items.whereType<ToolCallItem>().single;
    expect((card.call.name, card.status, card.result, card.elapsed?.inMilliseconds, card.risk), (original.call.name, original.status, original.result, original.elapsed?.inMilliseconds, original.risk));
    expect(back.items.whereType<AssistantItem>().last.text.toString(), chat.items.whereType<AssistantItem>().last.text.toString());
    expect(back.lastUsage?.promptTokens, chat.lastUsage?.promptTokens);

    final leftovers = store.dir.listSync(recursive: true).where((e) => e.path.endsWith('.tmp'));
    expect(leftovers, isEmpty);
  });

  test('the chat file follows the stored chat format', () async {
    final barrels = await barrelChat('c2');
    barrels.gate.alwaysAllow('spawn_actor_from_asset');
    await store.save(barrels);
    final json = jsonDecode(File('${store.dir.path}/chats/c2.json').readAsStringSync()) as Map;
    expect(json['version'], 1);
    final messages = json['messages'] as List;
    expect(messages[0]['role'], 'system');
    expect(messages[1], {'role': 'user', 'content': [{'type': 'text', 'text': 'Place the barrel twice'}]});
    final call = ((messages[2]['content'] as List).firstWhere((c) => c['type'] == 'tool_call')) as Map;
    expect(call.keys, containsAll(['id', 'name', 'args']));
    expect(call['args'], isA<Map>(), reason: 'args are decoded JSON');
    final tool = messages.firstWhere((m) => m['role'] == 'tool') as Map;
    expect(tool['callId'], call['id']);
    expect((json['settings'] as Map)['alwaysAllowed'], ['spawn_actor_from_asset']);
    final statuses = [for (final i in json['items'] as List) if (i['kind'] == 'tool') i['status']];
    expect(statuses, ['done', 'denied']);
  });

  test('list: pinned first, then the latest; rename, pin and delete change index and files', () async {
    final a = await countChat('a');
    a.updatedAt = DateTime.utc(2026, 9, 1);
    final b = await barrelChat('b');
    b.updatedAt = DateTime.utc(2026, 9, 2);
    final c = await countChat('c');
    c.updatedAt = DateTime.utc(2026, 9, 3);
    for (final chat in [a, b, c]) {
      await store.save(chat);
    }
    expect((await store.list()).map((s) => s.id), ['c', 'b', 'a']);

    await store.setPinned('a', true);
    expect((await store.list()).map((s) => s.id), ['a', 'c', 'b']);
    expect((await store.load('a'))!.pinned, isTrue);

    await store.rename('b', 'Barrels');
    expect((await store.list()).firstWhere((s) => s.id == 'b').title, 'Barrels');
    expect((await store.load('b'))!.title, 'Barrels');

    await store.delete('c');
    expect((await store.list()).map((s) => s.id), ['a', 'b']);
    expect(File('${store.dir.path}/chats/c.json').existsSync(), isFalse);
    final index = jsonDecode(File('${store.dir.path}/index.json').readAsStringSync()) as Map;
    expect((index['chats'] as List).map((e) => e['id']), ['a', 'b']);
  });

  test('search finds a chat by its content, not only its title', () async {
    final barrels = await barrelChat('b');
    barrels.title = 'Level work';
    await store.save(barrels);
    await store.save(await countChat('c'));
    expect((await store.search('BARREL')).map((s) => s.id), ['b']);
    expect((await store.search('level work')).map((s) => s.id), ['b']);
    expect((await store.search('actors')).map((s) => s.id), ['c']);
    expect(await store.search('zeppelin'), isEmpty);
  });

  test('a corrupt chat file is set aside with a warning; a corrupt index is rebuilt', () async {
    await store.save(await countChat('good'));
    await store.save(await barrelChat('bad'));
    File('${store.dir.path}/chats/bad.json').writeAsStringSync('{"id": "bad", "messages": [');

    expect(await store.load('bad'), isNull);
    expect(File('${store.dir.path}/chats/bad.json.corrupt-1').existsSync(), isTrue);
    expect(store.warnings.single, contains('bad.json'));
    expect((await store.list()).map((s) => s.id), ['good']);

    File('${store.dir.path}/index.json').writeAsStringSync('not json');
    final fresh = ChatStore(store.dir);
    expect((await fresh.list()).map((s) => s.id), ['good']);
    expect(fresh.warnings.single, contains('index.json'));
    expect(jsonDecode(File('${store.dir.path}/index.json').readAsStringSync()), isA<Map>());
  });

  test('a card still waiting for approval when saved comes back as interrupted', () async {
    final chat = await countChat('w');
    chat.items.add(ToolCallItem(call: const LlmToolCall(id: 'x', name: 'spawn_actor_from_asset', argumentsJson: '{"asset":"a"}'), risk: McpToolRisk.mutating)
      ..status = ToolCallStatus.waitingApproval);
    await store.save(chat);
    final card = (await store.load('w'))!.items.whereType<ToolCallItem>().last;
    expect(card.status, ToolCallStatus.failed);
    expect(card.result, startsWith('Interrupted'));
  });
}
