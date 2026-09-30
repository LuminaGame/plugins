// The Claude Code provider against sessions recorded with the real CLI,
// replayed by a real subprocess (test/support/claude_code_replay.dart) in
// place of `claude`; a real temp project and chat store.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_editor_api/lumina_editor_api.dart';
import 'package:lumina_plugin_miniai/lumina_plugin_miniai.dart';

import 'support/local_mcp.dart';
import 'support/replay_claude.dart';

McpTool _tool(String name, McpToolRisk risk, {Set<String> groups = const {McpToolGroups.level}}) => McpTool(
      name: name,
      description: name,
      inputSchema: McpSchema.object({}),
      handler: (_) => McpToolResult.json({'ok': true}),
      risk: risk,
      groups: groups,
    );

void main() {
  late Directory temp;
  late LocalMcp mcp;
  late String claudePath;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('miniai_cc_');
    Directory('${temp.path}/project').createSync();
    mcp = LocalMcp()
      ..registerTool(_tool('list_actors', McpToolRisk.readOnly))
      ..registerTool(_tool('spawn_actor', McpToolRisk.mutating));
    // The provider's `claude`: an existing file (the replay stands in for it).
    claudePath = File('${temp.path}/claude.exe').path;
    File(claudePath).writeAsStringSync('');
  });

  tearDown(() {
    try {
      temp.deleteSync(recursive: true);
    } catch (_) {}
  });

  Future<(MiniAiController, ReplayClaude)> make(List<String> fixtures, {ApprovalMode mode = ApprovalMode.ask, String model = ''}) async {
    final replay = ReplayClaude(fixtures, logDir: Directory('${temp.path}/logs')..createSync(recursive: true));
    final controller = MiniAiController(
      storage: PluginStorage(userDir: Directory('${temp.path}/user'), projectDir: Directory('${temp.path}/project/.lumina/miniai')),
      mcp: mcp,
      environment: const {},
      projectRoot: '${temp.path}/project',
      claudeStarter: replay.start,
      defaultMode: () => mode,
    );
    replay.onPermission = controller.answerPermission;
    await controller.settings.save(ProviderConfig(
      id: ProviderConfig.claudeCodeId,
      name: 'Claude Code',
      baseUrl: '',
      model: model,
      kind: ProviderKind.claudeCode,
      command: claudePath,
    ));
    controller.newChat();
    return (controller, replay);
  }

  List<ToolCallItem> cards(MiniAiController c) => c.chat.items.whereType<ToolCallItem>().toList();
  String answers(MiniAiController c) => c.chat.items.whereType<AssistantItem>().map((a) => a.text.toString()).join('|');

  test('two turns in one process: streamed answers, a readOnly tool card, a denied spawn in Plan mode', () async {
    final (c, replay) = await make(['turns_and_tools'], mode: ApprovalMode.plan);
    addTearDown(c.dispose);
    await c.send('Call the list_actors tool of the lumina MCP server once, then reply with the number of actors only.');
    expect(c.chat.items.first, isA<UserItem>());
    final list = cards(c).single;
    expect(list.call.name, 'list_actors');
    expect(list.risk, McpToolRisk.readOnly);
    expect(list.status, ToolCallStatus.done);
    expect(list.result, contains('"count"'));
    expect(list.elapsed, isNotNull);
    expect(answers(c).trim(), isNotEmpty);
    expect(replay.answers.single['behavior'], 'allow', reason: 'a read-only editor tool needs no card');

    await c.send('Call the lumina spawn_actor tool once with type PointLight, then answer in one short sentence.');
    expect(replay.starts, hasLength(1), reason: 'one process for the chat');
    final spawn = cards(c).last;
    expect(spawn.call.name, 'spawn_actor');
    expect(spawn.risk, McpToolRisk.mutating);
    expect(spawn.status, ToolCallStatus.denied);
    expect(replay.answers.last['behavior'], 'deny');
    expect('${replay.answers.last['message']}', contains('Plan mode'));
    expect(c.chat.items.whereType<UserItem>(), hasLength(2));
    expect(c.chat.items.whereType<AssistantItem>().length, greaterThanOrEqualTo(2));

    final inputs = replay.inputs(0);
    expect(inputs.first['type'], 'control_request', reason: 'initialize first');
    expect(inputs.where((i) => i['type'] == 'user'), hasLength(2));
    // Every message states the chat's mode; a Plan refusal is recorded for
    // the panel's "Switch to Ask" chip.
    final firstMessage = (inputs.firstWhere((i) => i['type'] == 'user')['message'] as Map)['content'] as String;
    expect(firstMessage, startsWith('<editor_context>\nYou are in Plan mode: you can read and look around but cannot change the project.'));
    expect(firstMessage, endsWith('</editor_context>\n\nCall the list_actors tool of the lumina MCP server once, then reply with the number of actors only.'));
    expect(c.chat.items.whereType<UserItem>().first.text, startsWith('Call the list_actors'), reason: 'the chat shows the user text only');
    expect(c.chat.turns.first.planBlocked, isEmpty);
    expect(c.chat.turns.last.planBlocked, ['spawn_actor']);
    expect(replay.starts.single.join(' '), contains('<editor_context>'), reason: 'the appended system prompt explains the block');
    final data = c.chat.providerData['claude_code'] as Map;
    expect(data['sessionId'], hasLength(36));
    expect(data['costUsd'], greaterThan(0));
    expect(c.claudeState, allOf(startsWith('Claude Code · claude-haiku'), contains('session ${(data['sessionId'] as String).substring(0, 8)}')));
    expect(c.claudeUsage, contains('this session'));
    // The arguments MiniAI starts the CLI with.
    final args = replay.starts.single;
    expect(args.take(3), ['-p', '--input-format', 'stream-json']);
    expect(args, containsAll(['--output-format', 'stream-json', '--verbose', '--include-partial-messages', '--permission-mode', 'default']));
    expect(args, isNot(contains('--model')), reason: 'no model chosen: the CLI default');
    expect(args, isNot(contains('--mcp-config')), reason: 'no editor MCP server here');
  });

  test('Ask mode: a mutating editor tool waits on an approval card; Deny answers the CLI', () async {
    final (c, replay) = await make(['turns_and_tools']);
    addTearDown(c.dispose);
    await c.send('first');
    final second = c.send('second');
    for (var i = 0; i < 200 && c.chat.pendingApprovals.isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
    final card = c.chat.pendingApprovals.single;
    expect(card.call.name, 'spawn_actor');
    expect(card.status, ToolCallStatus.waitingApproval);
    c.chat.answer(card, const ApprovalAnswer.deny('not now'));
    await second;
    expect(replay.answers.last, {'behavior': 'deny', 'message': 'not now'});
    expect(card.status, ToolCallStatus.denied);
  });

  test('Ask mode: Allow answers allow with the input; Always allow skips the next card', () async {
    final (c, replay) = await make(['turns_and_tools']);
    addTearDown(c.dispose);
    await c.send('first');
    final second = c.send('second');
    for (var i = 0; i < 200 && c.chat.pendingApprovals.isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
    c.chat.answer(c.chat.pendingApprovals.single, const ApprovalAnswer.alwaysAllow());
    await second;
    expect(replay.answers.last, {
      'behavior': 'allow',
      'updatedInput': {'type': 'PointLight'},
    });
    expect(c.chat.gate.isAlwaysAllowed('spawn_actor'), isTrue);
    expect(await c.answerPermission({'tool_name': 'mcp__lumina__spawn_actor', 'input': {}}), containsPair('behavior', 'deny'),
        reason: 'no turn is running now');
  });

  test('slash commands: initialize lists them, terminal-only ones left out; a command is sent as the message', () async {
    final (c, replay) = await make(['slash_commands']);
    addTearDown(c.dispose);
    await c.loadClaudeCommands();
    final names = c.claudeCommands.map((x) => x.name).toList();
    expect(names, containsAll(['hello', 'compact', 'context']));
    expect(names, isNot(contains('doctor')));
    expect(c.claudeCommands.firstWhere((x) => x.name == 'hello').description, contains('custom project command'));
    await c.send('/context');
    expect(answers(c), contains('Context Usage'));
    await c.send('/hello');
    expect(answers(c), contains('HELLO-CUSTOM'));
    expect(replay.starts, hasLength(1));
    expect(replay.inputs(0).where((i) => i['type'] == 'user').map((i) => (i['message'] as Map)['content']), ['/context', '/hello']);
  });

  test('an error result becomes an error note with the CLI message', () async {
    final (c, _) = await make(['error_model'], model: 'claude-not-a-model-x');
    addTearDown(c.dispose);
    await c.send('Reply with OK.');
    final note = c.chat.items.whereType<NoteItem>().where((n) => n.isError).single;
    expect(note.text, contains('claude-not-a-model-x'));
    expect(c.lastTurnFailed, isTrue);
  });

  test('a CLI that exits mid-turn: a note; the next message starts a new process with --resume', () async {
    // The first turn's recording up to the tool call, then the process dies.
    final lines = File('test/fixtures/claude_code/turns_and_tools.jsonl').readAsLinesSync();
    final cut = lines.indexWhere((l) => l.contains('"tool_use"'));
    final dying = File('${temp.path}/dying.jsonl')..writeAsStringSync('${[...lines.take(cut + 1), jsonEncode({'exit': 3, 'now': true})].join('\n')}\n');
    final (c, replay) = await make([dying.path, 'resume']);
    addTearDown(c.dispose);
    await c.send('first');
    final note = c.chat.items.whereType<NoteItem>().last;
    expect(note.text, startsWith('Claude Code exited (code 3)'));
    expect(note.isError, isTrue);
    final session = (c.chat.providerData['claude_code'] as Map)['sessionId'] as String;
    await c.send('What number did you reply with in your first answer?');
    expect(replay.starts, hasLength(2));
    expect(replay.starts.last, containsAllInOrder(['--resume', session]));
    expect(answers(c), contains('1'));
  });

  test('resume after a restart: the stored session id, then a model change', () async {
    final (first, replay) = await make(['turns_and_tools', 'resume', 'resume'], model: 'haiku');
    await first.send('first');
    final id = first.chat.id;
    final session = (first.chat.providerData['claude_code'] as Map)['sessionId'] as String;
    await first.flush();
    first.dispose();

    // The editor restarts: a new controller on the same storage reopens the chat.
    final second = MiniAiController(
      storage: first.storage,
      mcp: mcp,
      environment: const {},
      projectRoot: '${temp.path}/project',
      claudeStarter: replay.start,
    );
    addTearDown(second.dispose);
    replay.onPermission = second.answerPermission;
    await second.load();
    expect(second.chat.id, id);
    expect((second.chat.providerData['claude_code'] as Map)['sessionId'], session);
    await second.send('What number did you reply with in your first answer?');
    expect(replay.starts[1], containsAllInOrder(['--model', 'haiku', '--resume', session]));
    expect(second.chat.items.whereType<AssistantItem>().last.text.toString().trim(), '1');
    // Another model: a new process on the same session.
    final config = second.settings.selected!;
    await second.settings.save(ProviderConfig(
        id: config.id, name: config.name, baseUrl: '', model: 'sonnet', kind: ProviderKind.claudeCode, command: config.command));
    await second.send('again');
    expect(replay.starts, hasLength(3));
    expect(replay.starts[2], containsAllInOrder(['--model', 'sonnet', '--resume', session]));
  });

  test('Stop sends an interrupt while the answer streams, and the turn ends "Stopped."', () async {
    final (c, replay) = await make(['interrupt']);
    addTearDown(c.dispose);
    final turn = c.send('Count from 1 to 300, one number per line, no other text.');
    // The replay waits for the interrupt after the first streamed text.
    for (var i = 0; i < 400 && answers(c).isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
    expect(answers(c), isNotEmpty);
    c.stop();
    await turn;
    expect(c.chat.items.whereType<NoteItem>().last.text, 'Stopped.');
    expect(replay.inputs(0).last['request'], {'subtype': 'interrupt'});
    expect(c.lastTurnFailed, isFalse, reason: [for (final n in c.chat.items.whereType<NoteItem>()) n.text].join(' | '));
  });

  test('the editor MCP server: an explicit --mcp-config with the bridge and the chat caller tag', () async {
    mcp.launch = const McpClientLaunch(command: 'dart', args: ['/lumina_ui/bin/lumina_mcp_bridge.dart'], environment: {'LUMINA_CONFIG_DIR': '/cfg'});
    mcp.attributes = true;
    final (c, replay) = await make(['turns_and_tools'], mode: ApprovalMode.plan);
    addTearDown(c.dispose);
    await c.send('first');
    final args = replay.starts.single;
    final config = File(args[args.indexOf('--mcp-config') + 1]);
    expect(args, contains('--strict-mcp-config'));
    expect(args, containsAllInOrder(['--permission-prompt-tool', 'mcp__lumina__lumina_plugin_miniai_permission_prompt']));
    final server = ((jsonDecode(config.readAsStringSync()) as Map)['mcpServers'] as Map)['lumina'] as Map;
    expect(server['command'], 'dart');
    expect(server['args'], ['/lumina_ui/bin/lumina_mcp_bridge.dart', '--caller', 'miniai-cc-${c.chat.id}']);
    expect(server['env'], {'LUMINA_CONFIG_DIR': '/cfg'});
    expect(mcp.attributions.single, ('miniai-cc-${c.chat.id}', 'miniai:${c.chat.id}:1'));
    expect(c.chat.turns.single.undoUnavailable, isNull);
  });

  test('Undo this turn is off, with the reason, where the editor cannot attribute the calls', () async {
    final (c, _) = await make(['turns_and_tools'], mode: ApprovalMode.plan);
    addTearDown(c.dispose);
    await c.send('first');
    final turn = c.chat.turns.single;
    expect(turn.undoUnavailable, contains('Edit ▸ Undo'));
    final (enabled, reason) = c.canUndoTurn(turn);
    expect(enabled, isFalse);
    expect(reason, turn.undoUnavailable);
    // Kept with the chat.
    await c.flush();
    final stored = await c.store!.load(c.chat.id);
    expect(stored!.turns.single.undoUnavailable, turn.undoUnavailable);
  });
}
