// The guards against a model that repeats itself: the stream guard (an
// answer or reasoning that repeats a block) and the tool-call loop guard
// (the same call with the same result again and again). Real recorded
// streams on the replay server, real repository files as normal output.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_editor_api/lumina_editor_api.dart';
import 'package:lumina_plugin_miniai/lumina_plugin_miniai.dart';

import 'support/local_mcp.dart';
import 'support/replay_server.dart';

/// The real Ornith-1.0-35B stream recorded from Unsloth Studio
/// (`ornith_text.txt`, max_tokens 64) with its run of reasoning chunks
/// streamed [times] times in a row: what a model stuck in a loop sends.
String loopedOrnith({int times = 12}) {
  final events = ReplayServer.fixture('ornith_text').split('\n\n').where((e) => e.trim().isNotEmpty).toList();
  final first = events.indexWhere((e) => e.contains('"reasoning_content":"') && !e.contains('"reasoning_content":""'));
  final last = events.lastIndexWhere((e) => e.contains('"reasoning_content":"') && !e.contains('"reasoning_content":""'));
  final block = events.sublist(first, last + 1);
  return '${[...events.sublist(0, first), for (var i = 0; i < times; i++) ...block, ...events.sublist(last + 1)].join('\n\n')}\n\n';
}

/// The reasoning text of an SSE body.
String reasoningOf(String sse) => [
      for (final line in sse.split('\n'))
        if (line.startsWith('data: {'))
          for (final c in ((jsonDecode(line.substring(6)) as Map)['choices'] as List? ?? const []))
            ((c as Map)['delta'] as Map?)?['reasoning_content'] as String? ?? '',
    ].join();

/// Feeds [text] to a fresh guard in [chunk]-character pieces.
RepetitionHit? feed(String text, {int chunk = 7}) {
  final guard = RepetitionGuard();
  for (var i = 0; i < text.length; i += chunk) {
    final hit = guard.add(text.substring(i, i + chunk > text.length ? text.length : i + chunk));
    if (hit != null) return hit;
  }
  return guard.check();
}

void main() {
  group('RepetitionGuard', () {
    test('the recorded Ornith reasoning repeated 12 times trips it; once does not', () {
      final once = reasoningOf(ReplayServer.fixture('ornith_text'));
      expect(once.length, greaterThan(150));
      expect(feed(once), isNull);
      final hit = feed(reasoningOf(loopedOrnith()));
      expect(hit, isNotNull);
      expect(hit!.copies, greaterThanOrEqualTo(5));
    });

    test('long real code and Markdown lists do not trip it', () {
      for (final path in [
        'lib/src/agent/toolset_selector.dart',
        'lib/src/agent/agent_loop.dart',
        'lib/src/sampling_section.dart',
        'lib/src/llm/sampling.dart',
        'README.md',
        'CHANGELOG.md',
      ]) {
        final text = File(path).readAsStringSync();
        expect(feed(text), isNull, reason: path);
      }
      // A numbered list whose lines differ only in their numbers.
      final list = [for (var i = 1; i <= 80; i++) '$i. Place barrel_$i at (${i * 100}, 0, 0) and rotate it by ${i * 5} degrees.'].join('\n');
      expect(feed(list), isNull);
    });

    test('one line repeated among other lines trips the line rule', () {
      final lines = [
        for (var i = 0; i < 30; i++) ...['Let me check the input settings again before I continue.', 'Step $i'],
      ].join('\n');
      expect(feed(lines), isNotNull);
    });
  });

  group('agent loop', () {
    late ReplayServer server;
    late LocalMcp mcp;
    var actors = 0;
    var changing = false;

    setUp(() async {
      server = await ReplayServer.start();
      actors = 0;
      changing = false;
      mcp = LocalMcp()
        ..registerTool(McpTool(
          name: 'probe.count',
          description: 'Counts the actors in the open level.',
          inputSchema: McpSchema.object({}),
          // The shape of the user's loop: an empty selection, every time.
          handler: (_) => McpToolResult.json(changing ? {'count': ++actors} : {'selected_actor_ids': <String>[]}),
          risk: McpToolRisk.readOnly,
          groups: {McpToolGroups.level},
        ))
        ..registerTool(McpTool(
          name: 'spawn_actor_from_asset',
          description: 'Places a mesh asset in the open level as a new actor.',
          inputSchema: McpSchema.object({'asset': McpSchema.string('asset path'), 'location': McpSchema.vector3('[x, y, z]')}, required: ['asset']),
          handler: (args) => McpToolResult.json({'placed': args.string('asset'), 'at': args['location']}),
          risk: McpToolRisk.mutating,
          groups: {McpToolGroups.level},
        ));
    });
    tearDown(() => server.close());

    AgentLoop loop({int maxRounds = 8, SamplingSettings sampling = const SamplingSettings()}) => AgentLoop(
          provider: OpenAiCompatProvider(name: 'u', baseUrl: server.baseUrl, backend: ServerBackend.unslothStudio, sampling: sampling, client: realHttpClient),
          model: 's-batman/Ornith-1.0-35B-NVFP4-MTP-GGUF',
          mcp: mcp,
          maxRounds: maxRounds,
        );

    List<String> notes(Chat chat) => [for (final i in chat.items) if (i is NoteItem) i.text];

    test('a looping reasoning stream ends the turn with a note, one copy kept, the request carries the sampling', () async {
      server.queue.add(loopedOrnith(times: 40));
      final chat = Chat(id: 'loop');
      final defaults = SamplingDefaults.forModel('s-batman/Ornith-1.0-35B-NVFP4-MTP-GGUF', ServerBackend.unslothStudio);
      await loop(sampling: defaults).run(chat, 'List the input keys an endless runner needs, one per line.');
      expect(notes(chat), [AgentLoop.repetitionNote]);
      expect([for (final i in chat.items) if (i is NoteItem && i.isError) i], isEmpty);
      expect(chat.running, isFalse);
      final thinking = chat.items.whereType<AssistantItem>().single.thinking.toString();
      final once = reasoningOf(ReplayServer.fixture('ornith_text'));
      expect(thinking.length, lessThan(once.length * 3), reason: 'the repeats were cut');
      expect(thinking, startsWith(once.substring(0, 40)));
      expect(chat.history.last.role, LlmRole.assistant);
      final body = server.requests.single;
      expect(body['presence_penalty'], 1.5);
      expect(body['top_k'], 20);
      expect(body['temperature'], 0.6);
    });

    test('the same call with the same result: the 3rd result carries a note, a 4th ends the turn', () async {
      server.queue.addAll(['tool_call', 'tool_call', 'tool_call', 'tool_call', 'text']);
      final chat = Chat(id: 'calls');
      await loop().run(chat, 'How many actors are in the level? Use the tool.');
      expect(chat.items.whereType<ToolCallItem>(), hasLength(4));
      final results = [for (final m in chat.history) if (m.role == LlmRole.tool) m.content];
      expect(results[0], isNot(contains('[MiniAI:')));
      expect(results[1], isNot(contains('[MiniAI:')));
      expect(results[2], contains(AgentLoop.repeatNote('probe.count', 3)));
      expect(notes(chat).single, contains('kept repeating the same probe.count call'));
      expect(server.requests, hasLength(4), reason: 'no fifth request after the stop');
      expect(chat.running, isFalse);
      // Every call in the history has its result.
      final ids = [for (final m in chat.history) for (final c in m.toolCalls) c.id];
      final answered = [for (final m in chat.history) if (m.role == LlmRole.tool) m.toolCallId];
      expect(answered, ids);
    });

    test('A, B, A, B, A: the same pair again trips on A\'s third call; two different calls in a round do not', () async {
      server.queue.addAll(['two_tool_calls', 'two_tool_calls', 'two_tool_calls', 'two_tool_calls', 'text']);
      final chat = Chat(id: 'pairs', mode: ApprovalMode.auto);
      await loop().run(chat, 'Place two barrels.');
      final results = [for (final m in chat.history) if (m.role == LlmRole.tool) m.content];
      expect(results.take(2).where((r) => r.contains('[MiniAI:')), isEmpty, reason: 'different arguments do not count');
      expect(results[4], contains('[MiniAI:'), reason: "A's third identical call");
      expect(notes(chat).single, contains('kept repeating'));
      final ids = [for (final m in chat.history) for (final c in m.toolCalls) c.id];
      final answered = [for (final m in chat.history) if (m.role == LlmRole.tool) m.toolCallId];
      expect(answered, ids, reason: 'the skipped B call is answered');
    });

    test('the same call with a changing result (polling) is not a loop', () async {
      changing = true;
      server.queue.addAll(['tool_call', 'tool_call', 'tool_call', 'tool_call', 'tool_call', 'text']);
      final chat = Chat(id: 'poll');
      await loop().run(chat, 'How many actors are in the level? Use the tool.');
      expect(chat.items.whereType<ToolCallItem>(), hasLength(5));
      expect([for (final m in chat.history) if (m.role == LlmRole.tool && m.content.contains('[MiniAI:')) m], isEmpty);
      expect(notes(chat), isEmpty);
    });

    test('repeats in the previous turn count toward the note, not toward the stop', () async {
      server.queue.addAll(['tool_call', 'tool_call', 'text']);
      final chat = Chat(id: 'turns');
      await loop().run(chat, 'How many actors are in the level? Use the tool.');
      expect(notes(chat), isEmpty);
      server.queue.addAll(['tool_call', 'tool_call', 'text']);
      await loop().run(chat, 'basla');
      final results = [for (final m in chat.history) if (m.role == LlmRole.tool) m.content];
      expect(results[2], contains(AgentLoop.repeatNote('probe.count', 3)));
      expect(notes(chat).single, contains('kept repeating'), reason: 'the 4th, after the note in this turn');
    });
  });
}
