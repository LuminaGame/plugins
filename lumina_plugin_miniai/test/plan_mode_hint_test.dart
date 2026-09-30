// The "Switch to Ask" chip after a Plan-mode turn that needed changes.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_editor_api/lumina_editor_api.dart';
import 'package:lumina_plugin_miniai/lumina_plugin_miniai.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';

import 'support/local_mcp.dart';
import 'support/replay_server.dart';

McpTool _tool(String name, {McpToolRisk risk = McpToolRisk.readOnly}) => McpTool(
      name: name,
      description: name,
      inputSchema: name == 'spawn_actor_from_asset'
          ? McpSchema.object({'asset': McpSchema.string('asset'), 'location': McpSchema.vector3('xyz')}, required: ['asset'])
          : McpSchema.object({}),
      handler: (_) => McpToolResult.json({'count': 5}),
      risk: risk,
      groups: {McpToolGroups.level},
    );

void main() {
  late Directory temp;
  late ReplayServer server;
  late MiniAiController controller;

  setUp(() async {
    temp = Directory.systemTemp.createTempSync('miniai_plan_');
    server = await ReplayServer.start();
    final mcp = LocalMcp()
      ..registerTool(_tool('probe.count'))
      ..registerTool(_tool('spawn_actor_from_asset', risk: McpToolRisk.mutating));
    controller = MiniAiController(
      storage: PluginStorage(userDir: Directory('${temp.path}/user')),
      mcp: mcp,
      environment: const {},
      httpClient: realHttpClient,
      defaultMode: () => ApprovalMode.plan,
    );
  });

  tearDown(() async {
    controller.dispose();
    await server.close();
    temp.deleteSync(recursive: true);
  });

  Future<void> send(WidgetTester tester, String text) async {
    await tester.enterText(find.byKey(const ValueKey('miniai_message')), text);
    await tester.tap(find.byKey(const ValueKey('miniai_send')));
    for (var i = 0; i < 200 && (controller.running || controller.chat.turns.isEmpty); i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 20));
    }
    await tester.pump();
  }

  Future<void> pumpPanel(WidgetTester tester) async {
    tester.view.physicalSize = const Size(520, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.runAsync(() => controller.settings.save(ProviderConfig(id: 'local', name: 'Local', baseUrl: server.baseUrl, model: 'MiniCPM5-2B-Q4_K_M', local: true)));
    await tester.pumpWidget(ShadcnApp(home: Scaffold(child: ChatPanel(controller: controller))));
    await tester.pump();
  }

  testWidgets('a Plan turn that needed a change shows the chip; one click switches to Ask', (tester) async {
    await pumpPanel(tester);
    expect(controller.mode, ApprovalMode.plan);
    server.queue.addAll(['two_tool_calls', 'text']);
    await send(tester, 'Place the barrel twice');
    final turn = controller.chat.turns.single;
    expect(turn.planBlocked, contains('spawn_actor_from_asset'));
    expect(find.byKey(ValueKey('miniai_plan_hint_${turn.id}')), findsOneWidget);
    expect(find.text('Switch to Ask to let MiniAI make these changes'), findsOneWidget);
    await tester.ensureVisible(find.byKey(const ValueKey('miniai_plan_switch')));
    await tester.tap(find.byKey(const ValueKey('miniai_plan_switch')));
    await tester.pump();
    expect(controller.mode, ApprovalMode.ask);
    expect(controller.chat.gate.mode, ApprovalMode.ask);
    expect(find.byKey(ValueKey('miniai_plan_hint_${turn.id}')), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a Plan turn that only looked shows no chip', (tester) async {
    await pumpPanel(tester);
    server.queue.addAll(['tool_call', 'tool_result_answer']);
    await send(tester, 'How many actors are in the level? Use the tool.');
    expect(controller.chat.turns.single.planBlocked, isEmpty);
    expect(find.text('Switch to Ask to let MiniAI make these changes'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });
}
