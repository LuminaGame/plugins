// The controller keeps the project's chats — a turn is saved, a
// new controller restores the last chat, New chat is not saved until used,
// and deleting the open chat opens a fresh one. Real temp project, real
// replay server.
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

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('miniai_history_');
    server = await ReplayServer.start();
    mcp = LocalMcp()
      ..registerTool(McpTool(
        name: 'probe.count',
        description: 'Counts the actors in the open level.',
        inputSchema: McpSchema.object({}),
        handler: (_) => McpToolResult.json({'count': 5}),
        risk: McpToolRisk.readOnly,
        groups: {McpToolGroups.level},
      ));
  });

  tearDown(() async {
    await server.close();
    await temp.delete(recursive: true);
  });

  PluginStorage storage() => PluginStorage(
        userDir: Directory('${temp.path}/user'),
        projectDir: Directory('${temp.path}/Project/.lumina/plugins/lumina_plugin_miniai'),
      );

  Future<MiniAiController> controller() async {
    final c = MiniAiController(storage: storage(), mcp: mcp, environment: const {}, httpClient: realHttpClient);
    await c.load();
    await c.settings.save(ProviderConfig(id: 'replay', name: 'Replay', baseUrl: server.baseUrl, model: 'MiniCPM5-2B-Q4_K_M', local: true));
    return c;
  }

  final chats = '/Project/.lumina/plugins/lumina_plugin_miniai/chats';

  test('a turn is saved in the project; a new controller restores that chat', () async {
    final a = await controller();
    server.queue.addAll(['tool_call', 'tool_result_answer']);
    await a.send('How many actors are in the level? Use the tool.');
    final id = a.chat.id;
    expect(File('${temp.path}$chats/$id.json').existsSync(), isTrue);
    expect(a.summaries.single.title, 'How many actors are in the level? Use the tool.');
    expect(a.summaries.single.model, 'MiniCPM5-2B-Q4_K_M');
    final items = a.chat.items.length;
    a.dispose();

    final b = await controller();
    expect(b.chat.id, id);
    expect(b.chat.title, 'How many actors are in the level? Use the tool.');
    expect(b.chat.items, hasLength(items));
    expect(b.chat.items.whereType<AssistantItem>().last.text.toString(), contains('5 actors'));
    b.dispose();
  });

  test('New chat is not saved until its first message; opening switches chats', () async {
    final c = await controller();
    server.queue.addAll(['text']);
    await c.send('Hello');
    final first = c.chat.id;
    c.newChat();
    expect(c.chat.id, isNot(first));
    expect(c.chat.items, isEmpty);
    await c.flush();
    expect(Directory('${temp.path}$chats').listSync().whereType<File>(), hasLength(1));
    expect(c.summaries.map((s) => s.id), [first]);

    server.queue.addAll(['text']);
    await c.send('Second question');
    final second = c.chat.id;
    expect(c.summaries.map((s) => s.id).toSet(), {first, second});

    await c.openChat(first);
    expect(c.chat.id, first);
    expect(c.chat.items.whereType<UserItem>().first.text, 'Hello');
    c.dispose();
  });

  test('rename and pin reach the file; deleting the open chat opens a fresh one', () async {
    final c = await controller();
    server.queue.addAll(['text']);
    await c.send('Hello');
    final id = c.chat.id;
    await c.renameChat(id, 'Greeting');
    await c.setPinned(id, true);
    expect(c.chat.title, 'Greeting');
    final stored = (await c.store!.load(id))!;
    expect((stored.title, stored.pinned), ('Greeting', true));

    await c.deleteChat(id);
    expect(c.chat.id, isNot(id));
    expect(c.chat.items, isEmpty);
    expect(c.summaries, isEmpty);
    expect(File('${temp.path}$chats/$id.json').existsSync(), isFalse);
    c.dispose();
  });

  test('the chat that was open comes back, not only the most recent one', () async {
    final a = await controller();
    server.queue.addAll(['text']);
    await a.send('Older');
    final older = a.chat.id;
    a.newChat();
    server.queue.addAll(['text']);
    await a.send('Newer');
    await a.openChat(older);
    a.dispose();

    final b = await controller();
    expect(b.chat.id, older);
    expect(b.chat.items.whereType<UserItem>().first.text, 'Older');
    b.dispose();
  });

  test('a chat that is not open is renamed and pinned in the store', () async {
    final c = await controller();
    server.queue.addAll(['text']);
    await c.send('First');
    final first = c.chat.id;
    c.newChat();
    server.queue.addAll(['text']);
    await c.send('Second');
    await c.renameChat(first, 'Renamed');
    await c.setPinned(first, true);
    final s = c.summaries.firstWhere((s) => s.id == first);
    expect((s.title, s.pinned), ('Renamed', true));
    expect(c.summaries.first.id, first, reason: 'pinned first');
    expect(c.chat.title, 'Second', reason: 'the open chat is untouched');
    c.dispose();
  });

  test('without a project the chat stays in memory', () async {
    final c = MiniAiController(storage: PluginStorage(userDir: Directory('${temp.path}/user')), mcp: mcp, environment: const {}, httpClient: realHttpClient);
    await c.load();
    expect(c.store, isNull);
    await c.settings.save(ProviderConfig(id: 'replay', name: 'Replay', baseUrl: server.baseUrl, model: 'MiniCPM5-2B-Q4_K_M'));
    server.queue.addAll(['text']);
    await c.send('Hello');
    expect(c.chat.items, isNotEmpty);
    expect(c.summaries, isEmpty);
    c.dispose();
  });
}
