// The AI Assistant project settings change what the model is
// offered, told and allowed; API keys can be listed (masked) and removed.
// Real temp stores, a real replay server with recorded MiniCPM5 streams.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_editor_api/lumina_editor_api.dart';
import 'package:lumina_plugin_miniai/lumina_plugin_miniai.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';

import 'support/local_mcp.dart';
import 'support/replay_server.dart';

McpTool _tool(String name, String group, McpToolRisk risk) => McpTool(
      name: name,
      description: name,
      inputSchema: McpSchema.object({}),
      handler: (_) => McpToolResult.json({'count': 5}),
      risk: risk,
      groups: {group},
    );

void main() {
  late Directory temp;
  late ReplayServer server;
  late LocalMcp mcp;
  Map<String, Object?> project = {};

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('miniai_m06_');
    server = await ReplayServer.start();
    project = {};
    mcp = LocalMcp()
      ..registerTool(_tool('probe.count', McpToolGroups.level, McpToolRisk.readOnly))
      ..registerTool(_tool('spawn_actor_from_asset', McpToolGroups.level, McpToolRisk.mutating))
      ..registerTool(_tool('list_assets', McpToolGroups.asset, McpToolRisk.readOnly))
      ..registerTool(_tool('help', McpToolGroups.core, McpToolRisk.readOnly));
  });

  tearDown(() async {
    await server.close();
    for (var i = 0; i < 20; i++) {
      try {
        await temp.delete(recursive: true);
        break;
      } on FileSystemException {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }
  });

  PluginStorage storage() => PluginStorage(userDir: Directory('${temp.path}/user'), projectDir: Directory('${temp.path}/Game/.lumina/plugins/lumina_plugin_miniai'));

  Future<MiniAiController> controller({Map<String, String> environment = const {}}) async {
    final c = MiniAiController(
      storage: storage(),
      mcp: mcp,
      environment: environment,
      httpClient: realHttpClient,
      projectSettings: () => project,
      defaultMode: () => MiniAiProjectSettings.defaultMode(project),
    );
    await c.load();
    if (c.settings.providers.isEmpty) {
      await c.settings.save(ProviderConfig(id: 'replay', name: 'Replay', baseUrl: server.baseUrl, model: 'MiniCPM5-2B-Q4_K_M', local: true));
    }
    return c;
  }

  List<String> offered(int request) => [for (final t in (server.requests[request]['tools'] as List? ?? const [])) '${((t as Map)['function'] as Map)['name']}'];

  test('disabled tool groups are never offered, in any mode; core stays', () async {
    project = {'disabledToolGroups': ['level']};
    final c = await controller();
    for (final mode in ApprovalMode.values) {
      c.mode = mode;
      server.queue.add('text');
      await c.send('Place a barrel near the door');
      final names = offered(server.requests.length - 1);
      expect(names.where((n) => n == 'probe.count' || n == 'spawn_actor_from_asset'), isEmpty, reason: mode.name);
      expect(names, contains('help'));
    }
    c.dispose();
  });

  test('project notes end the system prompt, delimited and capped', () async {
    project = {'projectNotes': 'Every actor name starts with BP_.'};
    final c = await controller();
    server.queue.add('text');
    await c.send('Hello');
    final system = ((server.requests.single['messages'] as List).first as Map)['content'] as String;
    expect(system, endsWith('Project notes from the team (follow them unless they conflict with the rules above):\n<<<\nEvery actor name starts with BP_.\n>>>'));
    expect(MiniAiProjectSettings.projectNotes({'projectNotes': 'x' * 5000})!.length, AgentLoop.maxProjectNotes);
    c.dispose();
  });

  test('max rounds 1 stops a turn that keeps calling tools', () async {
    project = {'maxRounds': 1};
    final c = await controller();
    server.queue.add('tool_call');
    await c.send('How many actors are in the level? Use the tool.');
    expect(server.requests, hasLength(1));
    expect(c.chat.items.whereType<NoteItem>().last.text, 'Stopped after 1 rounds of tool calls. Send "continue" to go on.');
    c.dispose();
  });

  test('the preferred provider applies to the session only; an unknown one changes nothing', () async {
    final a = await controller();
    await a.settings.save(ProviderConfig(id: 'cloud', name: 'Cloud', baseUrl: 'https://api.example.com/v1', model: 'm'));
    await a.settings.save(ProviderConfig(id: 'local', name: 'Local', baseUrl: server.baseUrl, model: 'MiniCPM5-2B-Q4_K_M', local: true));
    a.dispose();

    project = {'provider': 'cloud'};
    final b = await controller();
    expect(b.settings.selected!.id, 'cloud');
    expect((await storage().readJson('providers'))!['selected'], 'local', reason: 'the user\'s own choice is kept');
    b.dispose();

    project = {'provider': 'nowhere'};
    final c = await controller();
    expect(c.settings.selected!.id, 'local');
    c.dispose();
  });

  test('keys are listed masked, removed, sourced from the environment, and never reach a chat file', () async {
    const key = 'sk-test-0123456789abcdef';
    final c = await controller(environment: const {'OPENAI_API_KEY': 'sk-env-999999999999'});
    await c.settings.save(ProviderConfig(id: 'replay', name: 'Replay', baseUrl: server.baseUrl, model: 'MiniCPM5-2B-Q4_K_M'), apiKey: key);
    final openai = ProviderConfig(id: 'openai', name: 'OpenAI', baseUrl: 'https://api.openai.com/v1', model: 'gpt');
    expect(c.settings.storedKeys, [('replay', 'sk-…cdef')]);
    expect(c.settings.storedKeys.expand((e) => [e.$1, e.$2]).any((s) => s.contains(key)), isFalse);
    expect(c.settings.keySource(openai), 'OPENAI_API_KEY');
    expect(c.settings.keySource(c.settings.selected!), 'stored');

    server.queue.add('text');
    await c.send('Hello');
    final chatFile = File('${temp.path}/Game/.lumina/plugins/lumina_plugin_miniai/chats/${c.chat.id}.json');
    expect(chatFile.existsSync(), isTrue);
    expect(chatFile.readAsStringSync(), isNot(contains(key)));

    await c.settings.removeKey('replay');
    expect(c.settings.storedKeys, isEmpty);
    expect(File('${temp.path}/user/credentials.json').readAsStringSync(), isNot(contains(key)));
    c.dispose();
  });

  testWidgets('the AI Assistant page edits all five settings through the handle', (tester) async {
    final handle = MapPluginSettingsHandle();
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ShadcnApp(
      home: Scaffold(
        child: MiniAiSettingsPage(settings: handle, providers: const [('local', 'Local (MiniCPM5)'), ('cloud', 'Cloud')]),
      ),
    ));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('miniai_settings_group_pie')));
    await tester.pump();
    await tester.enterText(find.byKey(const ValueKey('miniai_settings_max_rounds')), '3');
    await tester.enterText(find.byKey(const ValueKey('miniai_settings_notes')), 'Answer in one word.');
    await tester.tap(find.byKey(const ValueKey('miniai_settings_provider')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('miniai_settings_provider_cloud')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('miniai_settings_default_mode')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('miniai_settings_mode_acceptEdits')));
    await tester.pumpAndSettle();
    expect(handle.values, {
      'disabledToolGroups': ['pie'],
      'maxRounds': 3,
      'projectNotes': 'Answer in one word.',
      'provider': 'cloud',
      'defaultMode': 'acceptEdits',
    });
  });

  testWidgets('API Keys lists a stored key masked and removes it', (tester) async {
    final settings = ProviderSettings(PluginStorage(userDir: Directory('${temp.path}/user')), environment: const {});
    await tester.runAsync(() => settings.save(const ProviderConfig(id: 'cloud', name: 'Cloud', baseUrl: 'https://api.example.com/v1', model: 'm'), apiKey: 'sk-live-abcdefghijkl'));
    await tester.pumpWidget(ShadcnApp(home: Scaffold(child: ApiKeysDialog(settings: settings, close: () {}))));
    await tester.pump();
    expect(find.text('Stored · sk-…ijkl'), findsOneWidget);
    expect(find.textContaining('abcdefgh'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('miniai_key_remove_cloud')));
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
    }
    expect(find.text('No key'), findsOneWidget);
    expect(settings.storedKeys, isEmpty);
  });
}
