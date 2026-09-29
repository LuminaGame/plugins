// The panel's + New, History and the editable title, on a real temp
// project with three chats made against the replay server.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_editor_api/lumina_editor_api.dart';
import 'package:lumina_plugin_miniai/lumina_plugin_miniai.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';

import 'support/local_mcp.dart';
import 'support/replay_server.dart';

void main() {
  late Directory temp;
  late ReplayServer server;
  late MiniAiController c;
  late List<String> ids;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('miniai_history_view_');
    server = await ReplayServer.start();
    c = MiniAiController(
      storage: PluginStorage(userDir: Directory('${temp.path}/user'), projectDir: Directory('${temp.path}/Project/.lumina/plugins/lumina_plugin_miniai')),
      mcp: LocalMcp(),
      environment: const {},
      httpClient: realHttpClient,
    );
    await c.load();
    await c.settings.save(ProviderConfig(id: 'replay', name: 'Replay', baseUrl: server.baseUrl, model: 'MiniCPM5-2B-Q4_K_M', local: true));
    ids = [];
    for (final q in ['Place a barrel near the door', 'What is 2+2?', 'Explain the lighting']) {
      c.newChat();
      server.queue.add('text');
      await c.send(q);
      ids.add(c.chat.id);
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  });

  tearDown(() async {
    c.dispose();
    await server.close();
    // Windows releases a just-renamed file a moment later.
    for (var i = 0; i < 20; i++) {
      try {
        await temp.delete(recursive: true);
        break;
      } on FileSystemException {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }
  });

  Future<void> pumpPanel(WidgetTester tester) async {
    tester.view.physicalSize = const Size(460, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ShadcnApp(home: Scaffold(child: ChatPanel(controller: c))));
    await tester.pump();
  }

  /// Lets real file IO run (outside the fake clock) until [done], then a few
  /// more frames.
  Future<void> settleIo(WidgetTester tester, [bool Function()? done]) async {
    for (var i = 0; i < 300 && !(done?.call() ?? false); i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump(const Duration(milliseconds: 20));
      if (done == null && i >= 20) break;
    }
    for (var i = 0; i < 3; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
  }

  List<String> rowTitles(WidgetTester tester) => [
        for (final e in find.byWidgetPredicate((w) => w.key is ValueKey<String> && (w.key! as ValueKey<String>).value.startsWith('miniai_history_open_')).evaluate())
          (e.widget.key! as ValueKey<String>).value.substring('miniai_history_open_'.length),
      ];

  testWidgets('History lists, searches, renames, deletes and opens chats', (tester) async {
    await pumpPanel(tester);
    String title() => (tester.widget(find.byKey(const ValueKey('miniai_chat_title'))) as Text).data!;
    expect(title(), 'Explain the lighting', reason: 'the last chat is open');

    await tester.tap(find.byKey(const ValueKey('miniai_history')));
    await settleIo(tester, () => rowTitles(tester).length == 3);
    expect(find.byKey(const ValueKey('miniai_history_view')), findsOneWidget);
    expect(rowTitles(tester), ids.reversed.toList(), reason: 'latest first');

    // Search over content.
    await tester.enterText(find.byKey(const ValueKey('miniai_history_search')), 'DOOR');
    await settleIo(tester, () => rowTitles(tester).length == 1);
    expect(rowTitles(tester), [ids[0]]);
    await tester.enterText(find.byKey(const ValueKey('miniai_history_search')), '');
    await settleIo(tester, () => rowTitles(tester).length == 3);

    // Rename.
    await tester.tap(find.byKey(ValueKey('miniai_history_rename_${ids[1]}')));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.enterText(find.byKey(const ValueKey('miniai_rename_field')), 'Math');
    await tester.tap(find.byKey(const ValueKey('miniai_rename_save')));
    await settleIo(tester, () => c.summaries.any((s) => s.title == 'Math'));
    expect(find.text('Math'), findsOneWidget);
    expect((await tester.runAsync(() => c.store!.load(ids[1])))!.title, 'Math');

    // Delete asks first.
    await tester.tap(find.byKey(ValueKey('miniai_history_delete_${ids[0]}')));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Delete chat?'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('miniai_delete_confirm')));
    await settleIo(tester, () => c.summaries.length == 2);
    expect(rowTitles(tester), [ids[2], ids[1]]);
    expect(File('${temp.path}/Project/.lumina/plugins/lumina_plugin_miniai/chats/${ids[0]}.json').existsSync(), isFalse);

    // Open → back to the conversation.
    await tester.tap(find.byKey(ValueKey('miniai_history_open_${ids[1]}')));
    await settleIo(tester, () => c.chat.id == ids[1] && find.byKey(const ValueKey('miniai_history_view')).evaluate().isEmpty);
    expect(find.byKey(const ValueKey('miniai_history_view')), findsNothing);
    expect(c.chat.id, ids[1]);
    expect(title(), 'Math');
    expect(find.text('What is 2+2?'), findsOneWidget, reason: 'the user bubble');
    await tester.pumpWidget(const SizedBox());
    await settleIo(tester);
  });

  testWidgets('the title edits in place; + New starts an empty chat', (tester) async {
    await pumpPanel(tester);
    await tester.tap(find.byKey(const ValueKey('miniai_chat_title')));
    await tester.pump();
    await tester.pump();
    await tester.enterText(find.byKey(const ValueKey('miniai_chat_title_field')), 'Lighting notes');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await settleIo(tester, () => c.summaries.any((s) => s.title == 'Lighting notes'));
    expect((tester.widget(find.byKey(const ValueKey('miniai_chat_title'))) as Text).data, 'Lighting notes');
    expect((await tester.runAsync(() => c.store!.load(ids[2])))!.title, 'Lighting notes');

    await tester.tap(find.byKey(const ValueKey('miniai_new_chat')));
    await tester.pump();
    expect((tester.widget(find.byKey(const ValueKey('miniai_chat_title'))) as Text).data, 'New chat');
    expect(c.chat.items, isEmpty);

    // The new chat takes a message.
    server.queue.add('text');
    await tester.enterText(find.byKey(const ValueKey('miniai_message')), 'A new question');
    await tester.tap(find.byKey(const ValueKey('miniai_send')));
    await settleIo(tester, () => !c.running && c.chat.items.whereType<AssistantItem>().isNotEmpty && c.summaries.length == 4);
    expect(c.chat.items.whereType<UserItem>().single.text, 'A new question');
    expect(c.summaries, hasLength(4));
    await tester.pumpWidget(const SizedBox());
    await settleIo(tester);
  });
}
