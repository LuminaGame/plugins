// The Thinking row: the dots, the 100 px box that follows the stream, the
// duration; and the reasoning each provider streams.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_editor_api/lumina_editor_api.dart';
import 'package:lumina_plugin_miniai/lumina_plugin_miniai.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';

import 'support/local_mcp.dart';
import 'support/replay_claude.dart';
import 'support/replay_server.dart';

/// A line of reasoning long enough to overflow the box.
String _reasoning(int lines) => [for (var i = 1; i <= lines; i++) 'Step $i: the level needs a barrel next to the wall, so check the asset first.'].join('\n');

void main() {
  Future<ValueNotifier<int>> pumpRow(WidgetTester tester, AssistantItem item, {required bool Function() active}) async {
    final tick = ValueNotifier(0);
    await tester.pumpWidget(ShadcnApp(
      home: Scaffold(
        child: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: 320,
            child: ValueListenableBuilder<int>(
              valueListenable: tick,
              builder: (_, _, _) => ThinkingRow(item: item, active: active()),
            ),
          ),
        ),
      ),
    ));
    await tester.pump();
    return tick;
  }

  ScrollPosition box(WidgetTester tester) =>
      tester.state<ScrollableState>(find.descendant(of: find.byKey(const ValueKey('miniai_thinking_box')), matching: find.byType(Scrollable))).position;

  testWidgets('the dots cycle one step per 400 ms', (tester) async {
    await tester.pumpWidget(const ShadcnApp(home: Scaffold(child: ThinkingDots())));
    String dots() => tester.widget<Text>(find.byKey(const ValueKey('miniai_thinking_dots'))).data!;
    expect(dots(), '.');
    await tester.pump(const Duration(milliseconds: 400));
    expect(dots(), '..');
    await tester.pump(const Duration(milliseconds: 400));
    expect(dots(), '...');
    await tester.pump(const Duration(milliseconds: 400));
    expect(dots(), '.');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('while thinking: the row expands into a box of at most 100 px that follows the stream', (tester) async {
    final item = AssistantItem()..addThinking(_reasoning(3));
    final tick = await pumpRow(tester, item, active: () => item.thinkingActive);
    expect(find.text('Thinking'), findsOneWidget);
    expect(find.byType(ThinkingDots), findsOneWidget);
    expect(find.byKey(const ValueKey('miniai_thinking_box')), findsNothing, reason: 'collapsed by default');

    await tester.tap(find.byKey(const ValueKey('miniai_thinking_toggle')));
    await tester.pump();
    await tester.pump();
    item.addThinking('\n${_reasoning(20)}');
    tick.value++;
    await tester.pump();
    await tester.pump();
    expect(tester.getSize(find.byKey(const ValueKey('miniai_thinking_box'))).height, lessThanOrEqualTo(100));
    expect(box(tester).maxScrollExtent, greaterThan(0), reason: 'scrollable');
    expect(box(tester).pixels, box(tester).maxScrollExtent, reason: 'at the bottom');

    item.addThinking('\nMore: then place it.');
    tick.value++;
    await tester.pump();
    await tester.pump();
    expect(box(tester).pixels, box(tester).maxScrollExtent, reason: 'follows the new text');
    expect(find.textContaining('More: then place it.'), findsOneWidget);

    // The user scrolls up: new text no longer moves the box.
    await tester.drag(find.byKey(const ValueKey('miniai_thinking_box')), const Offset(0, 60));
    await tester.pump();
    final held = box(tester).pixels;
    expect(held, lessThan(box(tester).maxScrollExtent));
    item.addThinking('\n${_reasoning(4)}');
    tick.value++;
    await tester.pump();
    await tester.pump();
    expect(box(tester).pixels, held);

    // Back at the bottom: it follows again.
    await tester.drag(find.byKey(const ValueKey('miniai_thinking_box')), const Offset(0, -2000));
    await tester.pump();
    item.addThinking('\nLast line.');
    tick.value++;
    await tester.pump();
    await tester.pump();
    expect(box(tester).pixels, box(tester).maxScrollExtent);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('after thinking: "Thought for 4 s", collapsed, and it still expands and collapses', (tester) async {
    final start = DateTime(2026, 9, 30, 12);
    final item = AssistantItem()
      ..addThinking('Check the level first.', now: start)
      ..endThinking(now: start.add(const Duration(milliseconds: 4200)));
    await pumpRow(tester, item, active: () => false);
    expect(find.text('Thought for 4 s'), findsOneWidget);
    expect(find.byType(ThinkingDots), findsNothing);
    expect(find.byKey(const ValueKey('miniai_thinking_box')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('miniai_thinking_toggle')));
    await tester.pump();
    expect(find.text('Check the level first.'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('miniai_thinking_toggle')));
    await tester.pump();
    expect(find.byKey(const ValueKey('miniai_thinking_box')), findsNothing);
  });

  testWidgets('thinking without shared text says so', (tester) async {
    final start = DateTime(2026, 9, 30, 12);
    final item = AssistantItem()
      ..addThinking('', now: start)
      ..endThinking(now: start.add(const Duration(seconds: 2)));
    await pumpRow(tester, item, active: () => false);
    await tester.tap(find.byKey(const ValueKey('miniai_thinking_toggle')));
    await tester.pump();
    expect(find.text('The model did not share its reasoning text.'), findsOneWidget);
  });

  test('<think> tags cut across chunks split into reasoning and answer', () {
    final s = ThinkTagSplitter();
    final out = [...s.feed('<thi'), ...s.feed('nk>a</th'), ...s.feed('ink>b'), ...s.flush()];
    expect(out, [(true, 'a'), (false, 'b')]);
    final plain = ThinkTagSplitter();
    expect([...plain.feed('x < y'), ...plain.feed(' and y > z'), ...plain.flush()].map((e) => e.$2).join(), 'x < y and y > z');
  });

  group('providers', () {
    late ReplayServer server;
    setUp(() async => server = await ReplayServer.start());
    tearDown(() => server.close());

    Future<List<LlmEvent>> events() =>
        OpenAiCompatProvider(name: 'local', baseUrl: server.baseUrl, client: realHttpClient).stream(const LlmRequest(model: 'm', messages: [LlmMessage.user('hi')]), cancel: CancelToken()).toList();

    String sse(List<Map<String, Object?>> deltas) => [
          for (final d in deltas) 'data: ${jsonEncode({'choices': [{'index': 0, 'delta': d, 'finish_reason': null}]})}\n\n',
          'data: [DONE]\n\n',
        ].join();

    test('the recorded MiniCPM5 stream: reasoning first, then the answer', () async {
      server.queue.add('text');
      final e = await events();
      expect(e.whereType<ThinkingDelta>().map((d) => d.text).join(), isNotEmpty);
      expect(e.indexWhere((x) => x is ThinkingDelta), lessThan(e.indexWhere((x) => x is TextDelta)));
    });

    test('a `reasoning` field (OpenRouter, Ollama) is reasoning too', () async {
      server.queue.add(sse([
        {'role': 'assistant', 'reasoning': 'Two plus two'},
        {'reasoning': ' is four.'},
        {'content': '4'},
      ]));
      final e = await events();
      expect(e.whereType<ThinkingDelta>().map((d) => d.text).join(), 'Two plus two is four.');
      expect(e.whereType<TextDelta>().map((d) => d.text).join(), '4');
    });

    test('inline <think> tags split over three chunks', () async {
      server.queue.add(sse([
        {'content': '<thi'},
        {'content': 'nk>a</think'},
        {'content': '>b'},
      ]));
      final e = await events();
      expect(e.whereType<ThinkingDelta>().map((d) => d.text).join(), 'a');
      expect(e.whereType<TextDelta>().map((d) => d.text).join(), 'b');
    });

    test('the agent loop times the reasoning, keeps it out of the answer, and a saved chat keeps the time', () async {
      server.queue.add('text');
      final chat = Chat(id: 't1');
      await AgentLoop(provider: OpenAiCompatProvider(name: 'local', baseUrl: server.baseUrl, client: realHttpClient), model: 'MiniCPM5-2B-Q4_K_M', mcp: LocalMcp()).run(chat, 'What is 2+2?');
      final item = chat.items.whereType<AssistantItem>().single;
      expect(item.thinking.toString(), isNotEmpty);
      expect(item.thinkingTook, isNotNull);
      expect(item.thinkingActive, isFalse);
      expect(item.text.toString().trim(), '4');
      expect(chat.history.last.content.trim(), '4', reason: 'the reasoning is not sent back');
      final temp = Directory.systemTemp.createTempSync('miniai_think_');
      addTearDown(() => temp.deleteSync(recursive: true));
      await ChatStore(temp).save(chat);
      final loaded = (await ChatStore(temp).load('t1'))!.items.whereType<AssistantItem>().single;
      expect(loaded.thinkingTook!.inMilliseconds, item.thinkingTook!.inMilliseconds);
      expect(loaded.thinking.toString(), item.thinking.toString());
    });
  });

  test('Claude Code: redacted thinking blocks become a timed row without text', () async {
    final temp = Directory.systemTemp.createTempSync('miniai_cc_think_');
    addTearDown(() {
      try {
        temp.deleteSync(recursive: true);
      } catch (_) {}
    });
    Directory('${temp.path}/project').createSync();
    final claude = File('${temp.path}/claude.exe')..writeAsStringSync('');
    final mcp = LocalMcp()
      ..registerTool(McpTool(
        name: 'list_actors',
        description: 'list',
        inputSchema: McpSchema.object({}),
        handler: (_) => McpToolResult.json({'count': 1}),
        risk: McpToolRisk.readOnly,
        groups: {McpToolGroups.level},
      ));
    final replay = ReplayClaude(['turns_and_tools'], logDir: Directory('${temp.path}/logs')..createSync());
    final c = MiniAiController(
      storage: PluginStorage(userDir: Directory('${temp.path}/user'), projectDir: Directory('${temp.path}/project/.lumina/miniai')),
      mcp: mcp,
      environment: const {},
      projectRoot: '${temp.path}/project',
      claudeStarter: replay.start,
      defaultMode: () => ApprovalMode.plan,
    );
    addTearDown(c.dispose);
    replay.onPermission = c.answerPermission;
    await c.settings.save(ProviderConfig(id: ProviderConfig.claudeCodeId, name: 'Claude Code', baseUrl: '', model: '', kind: ProviderKind.claudeCode, command: claude.path));
    c.newChat();
    await c.send('Call the list_actors tool of the lumina MCP server once, then reply with the number of actors only.');
    final thought = c.chat.items.whereType<AssistantItem>().where((a) => a.hasThinking).toList();
    expect(thought, isNotEmpty);
    expect(thought.every((a) => a.thinking.isEmpty && a.thinkingTook != null), isTrue);
    await c.claude.close();
  });
}
