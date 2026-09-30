// Screenshot thumbnails in tool cards, the enlarge dialog, and the
// provider's "Model accepts images" setting.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_editor_api/lumina_editor_api.dart';
import 'package:lumina_plugin_miniai/lumina_plugin_miniai.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';

import 'support/local_mcp.dart';
import 'support/png.dart';
import 'support/replay_server.dart';

void main() {
  late Directory temp;
  late ReplayServer server;
  late LocalMcp mcp;
  late MiniAiController controller;
  late Uint8List png;

  setUp(() async {
    temp = Directory.systemTemp.createTempSync('miniai_thumbs_');
    server = await ReplayServer.start();
    png = await renderPng(320, 180);
    mcp = LocalMcp()
      ..registerTool(McpTool(
        name: 'probe.count',
        description: 'Counts the actors and shows the viewport.',
        inputSchema: McpSchema.object({}),
        handler: (_) => McpToolResult([McpContent.text('{"count": 5}'), McpContent.image(png)]),
        risk: McpToolRisk.readOnly,
        groups: {McpToolGroups.level},
      ));
    controller = MiniAiController(storage: PluginStorage(userDir: Directory('${temp.path}/user')), mcp: mcp, environment: const {}, httpClient: realHttpClient);
  });

  tearDown(() async {
    controller.dispose();
    await server.close();
    temp.deleteSync(recursive: true);
  });

  Future<void> pumpPanel(WidgetTester tester) async {
    tester.view.physicalSize = const Size(900, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ShadcnApp(home: Scaffold(child: ChatPanel(controller: controller))));
    await tester.pump();
  }

  Future<void> drive(WidgetTester tester, bool Function() done) async {
    for (var i = 0; i < 200 && !done(); i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(done(), isTrue);
  }

  testWidgets('a tool result with an image shows a thumbnail; a click enlarges it', (tester) async {
    await tester.runAsync(() => controller.settings.save(ProviderConfig(id: 'local', name: 'Local', baseUrl: server.baseUrl, model: 'MiniCPM5-2B-Q4_K_M', local: true)));
    await pumpPanel(tester);
    server.queue.addAll(['tool_call', 'tool_result_answer']);
    await tester.enterText(find.byKey(const ValueKey('miniai_message')), 'How many actors are in the level? Use the tool.');
    await tester.tap(find.byKey(const ValueKey('miniai_send')));
    await drive(tester, () => !controller.running && controller.chat.items.whereType<AssistantItem>().any((a) => a.text.isNotEmpty));
    final card = controller.chat.items.whereType<ToolCallItem>().single;
    final thumb = find.byKey(ValueKey('miniai_tool_thumb_${card.call.id}_0'));
    expect(thumb, findsOneWidget, reason: 'visible without expanding the card');
    final image = find.descendant(of: thumb, matching: find.byType(Image));
    expect(image, findsOneWidget);
    expect(tester.getSize(thumb).height, lessThanOrEqualTo(72));
    expect(find.textContaining('[image]'), findsNothing);

    await tester.tap(thumb);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('miniai_image_dialog')), findsOneWidget);
    expect(tester.widget<Text>(find.byKey(const ValueKey('miniai_image_dialog_size'))).data, startsWith('image/png 320×180, '));
    final big = find.descendant(of: find.byKey(const ValueKey('miniai_image_dialog')), matching: find.byType(Image));
    expect(tester.getSize(big).width, greaterThan(tester.getSize(image).width));
    await tester.tap(find.byKey(const ValueKey('miniai_image_dialog_close')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('miniai_image_dialog')), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a card without images has no thumbnail; an image the chat no longer keeps says so', (tester) async {
    final call = const LlmToolCall(id: 'call_a', name: 'list_actors', argumentsJson: '{}');
    final old = ChatImage.fromContent(McpContent.image(png), id: 'img1', source: 'viewport_screenshot (call_b)')!..data = null;
    controller.chat.items
      ..add(UserItem('hi'))
      ..add(ToolCallItem(call: call, risk: McpToolRisk.readOnly)..status = ToolCallStatus.done)
      ..add(ToolCallItem(call: const LlmToolCall(id: 'call_b', name: 'viewport_screenshot', argumentsJson: '{}'), risk: McpToolRisk.readOnly)
        ..status = ToolCallStatus.done
        ..images = [old]);
    await pumpPanel(tester);
    expect(find.byKey(const ValueKey('miniai_tool_thumb_call_a_0')), findsNothing);
    expect(find.byKey(const ValueKey('miniai_tool_thumb_call_b_0')), findsOneWidget);
    expect(find.text('image no longer kept'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('miniai_tool_thumb_call_b_0')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('miniai_image_dialog')), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('Model accepts images follows the model name until the user sets it, and is saved', (tester) async {
    tester.view.physicalSize = const Size(900, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ShadcnApp(
      home: Scaffold(
        child: Builder(
          builder: (context) => PrimaryButton(key: const ValueKey('open'), onPressed: () => showProviderDialog(context, controller.settings), child: const Text('open')),
        ),
      ),
    ));
    await tester.tap(find.byKey(const ValueKey('open')));
    await tester.pumpAndSettle();
    Checkbox box() => tester.widget<Checkbox>(find.byKey(const ValueKey('miniai_provider_vision')));
    await tester.enterText(find.byKey(const ValueKey('miniai_provider_model')), 'MiniCPM5-2B-Q4_K_M');
    await tester.pump();
    expect(box().state, CheckboxState.unchecked);
    await tester.enterText(find.byKey(const ValueKey('miniai_provider_model')), 'gpt-4o');
    await tester.pump();
    expect(box().state, CheckboxState.checked, reason: 'a known vision model');
    await tester.ensureVisible(find.byKey(const ValueKey('miniai_provider_vision')));
    await tester.tap(find.byKey(const ValueKey('miniai_provider_vision')));
    await tester.pump();
    expect(box().state, CheckboxState.unchecked);
    await tester.tap(find.byKey(const ValueKey('miniai_provider_save')));
    await drive(tester, () => find.byKey(const ValueKey('miniai_provider_save')).evaluate().isEmpty);
    await tester.pumpAndSettle();
    final saved = jsonDecode(File('${temp.path}/user/providers.json').readAsStringSync()) as Map;
    final provider = (saved['providers'] as List).cast<Map>().single;
    expect(provider['model'], 'gpt-4o');
    expect(provider['vision'], isFalse);
    expect(controller.settings.selected!.acceptsImages, isFalse);
  });
}
