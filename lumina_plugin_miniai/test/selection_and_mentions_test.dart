// The selection chip above the message box and the @ list, over a real temp
// project whose files the host's tool shapes answer from; the replay server
// shows what the model receives.
import 'dart:io';

import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_editor_api/lumina_editor_api.dart';
import 'package:lumina_plugin_miniai/lumina_plugin_miniai.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';

import 'support/local_mcp.dart';
import 'support/replay_server.dart';
import 'support/temp_project.dart';

void main() {
  late Directory temp;
  late TempProject project;
  late ReplayServer server;
  late LocalMcp mcp;
  late MiniAiController controller;
  Map<String, Object?> projectSettings = {};

  setUp(() async {
    temp = Directory.systemTemp.createTempSync('miniai_sel_');
    project = TempProject(Directory('${temp.path}/project')..createSync());
    server = await ReplayServer.start();
    mcp = LocalMcp();
    project.register(mcp);
    projectSettings = {};
    controller = MiniAiController(
      storage: PluginStorage(userDir: Directory('${temp.path}/user')),
      mcp: mcp,
      environment: const {},
      httpClient: realHttpClient,
      projectSettings: () => projectSettings,
    );
  });

  tearDown(() async {
    controller.dispose();
    await server.close();
    temp.deleteSync(recursive: true);
  });

  Future<void> pumpPanel(WidgetTester tester) async {
    tester.view.physicalSize = const Size(520, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.runAsync(() => controller.settings.save(ProviderConfig(id: 'local', name: 'Local', baseUrl: server.baseUrl, model: 'MiniCPM5-2B-Q4_K_M', local: true)));
    await tester.pumpWidget(ShadcnApp(home: Scaffold(child: ChatPanel(controller: controller))));
    await tester.pump();
    await tester.pump();
  }

  Future<void> drive(WidgetTester tester, bool Function() done) async {
    for (var i = 0; i < 200 && !done(); i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(done(), isTrue);
    await tester.pump();
  }

  Future<void> send(WidgetTester tester) async {
    final before = server.requests.length;
    await tester.tap(find.byKey(const ValueKey('miniai_send')));
    await drive(tester, () => !controller.running && server.requests.length > before);
  }

  /// The last user message the model received.
  String lastUserMessage() =>
      '${((server.requests.last['messages'] as List).lastWhere((m) => (m as Map)['role'] == 'user') as Map)['content']}';

  String chipLabel(WidgetTester tester) => tester.widget<Text>(find.byKey(const ValueKey('miniai_selection_label'))).data!;

  testWidgets('the chip shows the selection live, ✕ drops it for one message, and the model gets the block', (tester) async {
    project.selectedActors.add('actor_wall');
    await pumpPanel(tester);
    expect(chipLabel(tester), 'Divider_Wall · Primitive');

    // Dropped: the next message goes without it.
    await tester.tap(find.byKey(const ValueKey('miniai_selection_remove')));
    await tester.pump();
    expect(find.byKey(const ValueKey('miniai_selection_chip')), findsNothing);
    await tester.enterText(find.byKey(const ValueKey('miniai_message')), 'What is 2+2?');
    await send(tester);
    expect(lastUserMessage(), 'What is 2+2?');
    expect(find.byKey(const ValueKey('miniai_selection_chip')), findsOneWidget, reason: 'back for the next message');

    // The selection changes: the chip follows within the poll.
    project.selectedActors
      ..clear()
      ..add('actor_light');
    await tester.pump(const Duration(milliseconds: 1100));
    await tester.pump();
    expect(chipLabel(tester), 'Sun · DirectionalLight');

    await tester.enterText(find.byKey(const ValueKey('miniai_message')), 'Make it brighter');
    await send(tester);
    final message = lastUserMessage();
    expect(message, startsWith('<editor_context>\n'));
    expect(message, contains('"id":"actor_light"'));
    expect(message, endsWith('</editor_context>\n\nMake it brighter'));
    final user = controller.chat.items.whereType<UserItem>().last;
    expect(user.text, 'Make it brighter');
    expect(find.text('Make it brighter'), findsOneWidget);
    final index = controller.chat.items.indexOf(user);
    expect(tester.widget<Text>(find.byKey(ValueKey('miniai_user_context_$index'))).data, 'Context: Sun · DirectionalLight');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('turned off in the project settings: no chip and no block', (tester) async {
    projectSettings = {MiniAiProjectSettings.attachSelectionKey: false};
    project.selectedActors.add('actor_wall');
    await pumpPanel(tester);
    expect(find.byKey(const ValueKey('miniai_selection_chip')), findsNothing);
    await tester.enterText(find.byKey(const ValueKey('miniai_message')), 'What is 2+2?');
    await send(tester);
    expect(lastUserMessage(), 'What is 2+2?');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('@ lists the project content and actors; the keyboard picks; the model gets the references', (tester) async {
    await pumpPanel(tester);
    await tester.enterText(find.byKey(const ValueKey('miniai_message')), 'Place @fu');
    await drive(tester, () => find.byKey(const ValueKey('miniai_mention_asset_0')).evaluate().isNotEmpty);
    expect(find.byKey(const ValueKey('miniai_mention_menu')), findsOneWidget);
    final first = find.byKey(const ValueKey('miniai_mention_asset_0'));
    expect(find.descendant(of: first, matching: find.text('fuel_barrel_red')), findsOneWidget);
    expect(find.descendant(of: first, matching: find.byIcon(LucideIcons.box)), findsOneWidget, reason: 'a mesh icon');
    expect(find.descendant(of: first, matching: find.text('filamesh · contents/meshes/fuel_barrel_red.lmas')), findsOneWidget);
    expect(find.byKey(const ValueKey('miniai_mention_actor_1')), findsOneWidget, reason: 'the fuel_barrel_red_1 actor');

    // ↓ ↑ Enter: the first row.
    Color? highlight(String key) => tester.widget<Container>(find.descendant(of: find.byKey(ValueKey(key)), matching: find.byType(Container)).first).color;
    expect(highlight('miniai_mention_asset_0'), isNotNull);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(highlight('miniai_mention_asset_0'), isNull);
    expect(highlight('miniai_mention_actor_1'), isNotNull, reason: '↓ moved the highlight');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    expect(highlight('miniai_mention_asset_0'), isNotNull);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(find.byKey(const ValueKey('miniai_mention_menu')), findsNothing);
    final field = tester.widget<TextField>(find.byKey(const ValueKey('miniai_message')));
    expect(field.controller!.text, 'Place @fuel_barrel_red ');
    expect(controller.running, isFalse, reason: 'Enter picked; it did not send');

    // Esc closes the list; Tab picks an actor.
    field.controller!.value = const TextEditingValue(text: 'Place @fuel_barrel_red next to @Su', selection: TextSelection.collapsed(offset: 34));
    await drive(tester, () => find.byKey(const ValueKey('miniai_mention_actor_0')).evaluate().isNotEmpty);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(find.byKey(const ValueKey('miniai_mention_menu')), findsNothing);
    field.controller!.value = const TextEditingValue(text: 'Place @fuel_barrel_red next to @Sun', selection: TextSelection.collapsed(offset: 35));
    await tester.pump();
    expect(find.byKey(const ValueKey('miniai_mention_menu')), findsOneWidget, reason: 'typing again reopens it');
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(field.controller!.text, 'Place @fuel_barrel_red next to @Sun ');

    // A folder, with a click.
    field.controller!.value = const TextEditingValue(text: 'Place @fuel_barrel_red next to @Sun from @Pro', selection: TextSelection.collapsed(offset: 45));
    await drive(tester, () => find.byKey(const ValueKey('miniai_mention_folder_0')).evaluate().isNotEmpty);
    await tester.tap(find.byKey(const ValueKey('miniai_mention_folder_0')));
    await tester.pump();
    expect(field.controller!.text, 'Place @fuel_barrel_red next to @Sun from @Props ');

    await send(tester);
    final message = lastUserMessage();
    expect(message, startsWith('<editor_context>'));
    expect(message, contains('{"kind":"asset","name":"fuel_barrel_red","path":"contents/meshes/fuel_barrel_red.lmas","type":"filamesh"}'));
    expect(message, contains('{"kind":"actor","name":"Sun","id":"actor_light","type":"DirectionalLight"}'));
    expect(message, contains('{"kind":"folder","name":"Props","path":"contents/Props"}'));
    expect(message, endsWith('Place @fuel_barrel_red next to @Sun from @Props'));
    expect(controller.chat.items.whereType<UserItem>().last.context, 'Context: @fuel_barrel_red, @Sun, @Props');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a mention deleted from the text is not sent', (tester) async {
    await pumpPanel(tester);
    await tester.enterText(find.byKey(const ValueKey('miniai_message')), '@M_');
    await drive(tester, () => find.byKey(const ValueKey('miniai_mention_asset_0')).evaluate().isNotEmpty);
    await tester.tap(find.byKey(const ValueKey('miniai_mention_asset_0')));
    await tester.pump();
    await tester.enterText(find.byKey(const ValueKey('miniai_message')), 'What is 2+2?');
    await send(tester);
    expect(lastUserMessage(), 'What is 2+2?');
    await tester.pumpWidget(const SizedBox());
  });
}
