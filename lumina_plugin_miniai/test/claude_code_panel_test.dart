// The AI Assistant panel on the Claude Code provider: the provider state,
// the `/` command list and the session cost, with a recorded real session
// replayed by a real subprocess in place of `claude`.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_editor_api/lumina_editor_api.dart';
import 'package:lumina_plugin_miniai/lumina_plugin_miniai.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';

import 'support/local_mcp.dart';
import 'support/replay_claude.dart';

void main() {
  late Directory temp;
  late MiniAiController controller;
  late ReplayClaude replay;

  setUp(() async {
    temp = Directory.systemTemp.createTempSync('miniai_cc_panel_');
    final claude = File('${temp.path}/claude.exe')..writeAsStringSync('');
    replay = ReplayClaude(['slash_commands'], logDir: Directory('${temp.path}/logs')..createSync());
    controller = MiniAiController(
      storage: PluginStorage(userDir: Directory('${temp.path}/user'), projectDir: Directory('${temp.path}/project/.lumina/miniai')),
      mcp: LocalMcp(),
      environment: const {},
      projectRoot: temp.path,
      claudeStarter: replay.start,
    );
    replay.onPermission = controller.answerPermission;
    await controller.settings.save(ProviderConfig(
      id: ProviderConfig.claudeCodeId,
      name: 'Claude Code',
      baseUrl: '',
      model: '',
      kind: ProviderKind.claudeCode,
      command: claude.path,
    ));
  });

  tearDown(() {
    controller.dispose();
    try {
      temp.deleteSync(recursive: true);
    } catch (_) {}
  });

  /// An assistant answer containing [text].
  Finder answer(String text) => find.byWidgetPredicate((w) => w is SelectableText && (w.data ?? '').contains(text), skipOffstage: false);

  Future<void> drive(WidgetTester tester, bool Function() done) async {
    for (var i = 0; i < 300 && !done(); i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(done(), isTrue);
    // The frame after the last change.
    await tester.pump();
  }

  testWidgets('/ lists the reported commands, typing narrows them, a click sends one; state and cost are shown', (tester) async {
    tester.view.physicalSize = const Size(460, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ShadcnApp(home: Scaffold(child: ChatPanel(controller: controller))));
    await tester.pump();
    expect(find.textContaining('Model: Claude Code'), findsOneWidget);
    expect(find.byKey(const ValueKey('miniai_claude_state')), findsOneWidget);
    expect(find.text('Claude Code · default model'), findsOneWidget);

    // `@` works next to `/`: in a command line it opens the mention list.
    await tester.enterText(find.byKey(const ValueKey('miniai_message')), '/compact keep @');
    await tester.pump();
    expect(find.byKey(const ValueKey('miniai_mention_menu')), findsOneWidget);
    expect(find.byKey(const ValueKey('miniai_slash_menu')), findsNothing);

    await tester.enterText(find.byKey(const ValueKey('miniai_message')), '/');
    await tester.pump();
    expect(find.byKey(const ValueKey('miniai_slash_menu')), findsOneWidget);
    expect(find.byKey(const ValueKey('miniai_mention_menu')), findsNothing);
    await drive(tester, () => find.byKey(const ValueKey('miniai_slash_hello')).evaluate().isNotEmpty);
    expect(find.text('Say hello from a custom project command (project)'), findsOneWidget);
    expect(controller.claudeCommands.map((c) => c.name), containsAll(['compact', 'context']));
    expect(controller.claudeCommands.map((c) => c.name), isNot(contains('doctor')), reason: 'terminal-only');

    await tester.enterText(find.byKey(const ValueKey('miniai_message')), '/cont');
    await tester.pump();
    expect(find.byKey(const ValueKey('miniai_slash_context')), findsOneWidget);
    expect(find.byKey(const ValueKey('miniai_slash_hello')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('miniai_slash_context')));
    await tester.pump();
    expect(find.byKey(const ValueKey('miniai_slash_menu')), findsNothing);
    await drive(tester, () => !controller.running && controller.chat.items.whereType<AssistantItem>().isNotEmpty);
    expect(answer('Context Usage'), findsOneWidget);
    expect(find.text('/context'), findsOneWidget, reason: 'the command is the user message');

    // A command that goes to the model: the session's cost in the footer.
    await tester.enterText(find.byKey(const ValueKey('miniai_message')), '/hel');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('miniai_slash_hello')));
    await tester.pump();
    await drive(tester, () => !controller.running && answer('HELLO-CUSTOM').evaluate().isNotEmpty);
    expect(find.textContaining(RegExp(r'\$0\.\d{4} this session')), findsOneWidget);
    expect(find.textContaining(RegExp(r'Claude Code · claude-haiku[\w-]* · session [0-9a-f]{8}')), findsOneWidget);
    expect(replay.starts, hasLength(1));
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() => controller.claude.close());
  });
}
