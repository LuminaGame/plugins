// The AI Assistant panel, against a real local server
// replaying recorded MiniCPM5 streams.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_editor_api/lumina_editor_api.dart';
import 'package:lumina_plugin_miniai/lumina_plugin_miniai.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';

import 'support/local_mcp.dart';
import 'support/replay_server.dart';

McpTool _tool(String name, String group, {McpToolRisk risk = McpToolRisk.readOnly, McpToolHandler? handler}) => McpTool(
      name: name,
      description: name,
      inputSchema: name == 'spawn_actor_from_asset'
          ? McpSchema.object({'asset': McpSchema.string('asset'), 'location': McpSchema.vector3('xyz')}, required: ['asset'])
          : McpSchema.object({}),
      handler: handler ?? (_) => McpToolResult.json({'count': 5}),
      risk: risk,
      groups: {group},
    );

void main() {
  late Directory temp;
  late ReplayServer server;
  late LocalMcp mcp;
  late MiniAiController controller;

  setUp(() async {
    temp = Directory.systemTemp.createTempSync('miniai_panel_');
    server = await ReplayServer.start();
    mcp = LocalMcp()
      ..registerTool(_tool('probe.count', McpToolGroups.level))
      ..registerTool(_tool('list_assets', McpToolGroups.asset))
      ..registerTool(_tool('spawn_actor_from_asset', McpToolGroups.level, risk: McpToolRisk.mutating, handler: (a) => McpToolResult.json({'placed': a.string('asset')})));
    controller = MiniAiController(storage: PluginStorage(userDir: Directory('${temp.path}/user')), mcp: mcp, environment: const {}, httpClient: realHttpClient);
  });

  tearDown(() async {
    controller.dispose();
    await server.close();
    temp.deleteSync(recursive: true);
  });

  Future<void> pumpPanel(WidgetTester tester, {double width = 460}) async {
    tester.view.physicalSize = Size(width, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ShadcnApp(home: Scaffold(child: ChatPanel(controller: controller))));
    await tester.pump();
  }

  /// Lets real IO (HTTP, files) run, then pumps.
  Future<void> drive(WidgetTester tester, bool Function() done) async {
    for (var i = 0; i < 200 && !done(); i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(done(), isTrue);
  }

  Future<void> configure() => controller.settings.save(ProviderConfig(id: 'local', name: 'Local', baseUrl: server.baseUrl, model: 'MiniCPM5-2B-Q4_K_M', local: true));

  testWidgets('without a provider: the chat title, a disabled composer that says why, a live tool count', (tester) async {
    await pumpPanel(tester);
    expect(find.text('AI ASSISTANT'), findsNothing, reason: 'the right dock header names the panel');
    expect(find.text('New chat'), findsOneWidget);
    expect(tester.widget<PrimaryButton>(find.byKey(const ValueKey('miniai_send'))).onPressed, isNull);
    expect(find.byKey(const ValueKey('miniai_setup_provider')), findsOneWidget);
    expect(find.textContaining('Set up a model provider to chat'), findsOneWidget);
    expect(find.textContaining('3 editor tools available'), findsOneWidget);
    mcp.registerTool(_tool('get_actor', McpToolGroups.level));
    await tester.pump();
    expect(find.textContaining('4 editor tools available'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a turn: the user bubble, a tool card that turns done, then the answer', (tester) async {
    await tester.runAsync(configure);
    await pumpPanel(tester);
    expect(tester.widget<PrimaryButton>(find.byKey(const ValueKey('miniai_send'))).onPressed, isNotNull);
    expect(find.text('Model: MiniCPM5-2B-Q4_K_M'), findsOneWidget);
    server.queue.addAll(['tool_call', 'tool_result_answer']);
    await tester.enterText(find.byKey(const ValueKey('miniai_message')), 'How many actors are in the level? Use the tool.');
    await tester.tap(find.byKey(const ValueKey('miniai_send')));
    await drive(tester, () => !controller.running && controller.chat.items.whereType<AssistantItem>().any((a) => a.text.isNotEmpty));
    expect(find.text('How many actors are in the level? Use the tool.'), findsWidgets);
    expect(find.textContaining('readOnly · '), findsOneWidget);
    expect(controller.chat.items.whereType<ToolCallItem>().single.status, ToolCallStatus.done);
    expect(find.textContaining('5 actors'), findsOneWidget);
    expect(find.textContaining('tokens last turn'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('approval cards: Allow runs the first call, Deny with a reason refuses the second', (tester) async {
    await tester.runAsync(configure);
    await pumpPanel(tester);
    server.queue.addAll(['two_tool_calls', 'text']);
    await tester.enterText(find.byKey(const ValueKey('miniai_message')), 'Place the barrel twice');
    await tester.tap(find.byKey(const ValueKey('miniai_send')));
    await drive(tester, () => controller.chat.pendingApprovals.isNotEmpty);
    expect(find.byKey(const ValueKey('miniai_allow')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('miniai_allow')));
    await drive(tester, () => controller.chat.pendingApprovals.isNotEmpty);
    await tester.ensureVisible(find.byKey(const ValueKey('miniai_deny_reason')));
    await tester.pump();
    await tester.enterText(find.byKey(const ValueKey('miniai_deny_reason')), 'one is enough');
    await tester.tap(find.byKey(const ValueKey('miniai_deny')));
    await drive(tester, () => !controller.running);
    final cards = controller.chat.items.whereType<ToolCallItem>().toList();
    expect(cards.map((c) => c.status), [ToolCallStatus.done, ToolCallStatus.denied]);
    expect(mcp.recorded, hasLength(1));
    expect(cards.last.result, contains('one is enough'));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('the provider dialog tests the connection, lists models, and saves the key apart', (tester) async {
    await pumpPanel(tester, width: 900);
    await tester.tap(find.byKey(const ValueKey('miniai_setup_provider')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('miniai_provider_url')), server.baseUrl);
    await tester.enterText(find.byKey(const ValueKey('miniai_provider_key')), 'sk-test-1234567890');
    await tester.tap(find.byKey(const ValueKey('miniai_provider_test')));
    await drive(tester, () => find.byKey(const ValueKey('miniai_provider_status')).evaluate().isNotEmpty);
    expect(find.textContaining('Connected: 1 model'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('miniai_provider_pick_MiniCPM5-2B-Q4_K_M')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('miniai_provider_save')));
    await drive(tester, () => find.byKey(const ValueKey('miniai_provider_save')).evaluate().isEmpty);
    await tester.pumpAndSettle();
    expect(find.text('Model: MiniCPM5-2B-Q4_K_M'), findsOneWidget);
    final providers = File('${temp.path}/user/providers.json').readAsStringSync();
    expect(providers, contains(server.baseUrl));
    expect(providers, isNot(contains('sk-test')), reason: 'no key in providers.json');
    expect(File('${temp.path}/user/credentials.json').readAsStringSync(), contains('sk-test-1234567890'));
    expect(controller.settings.selected!.local, isTrue, reason: 'a loopback endpoint is a local model');
    await tester.pumpWidget(const SizedBox());
  });
}
