// Claude Code's AskUserQuestion in MiniAI: the question card the panel shows
// for it and the answers that go back to the CLI, against a session recorded
// with the real CLI (ask_user_question) replayed by a real subprocess; and
// the tool cards' coloured, height-capped, scrolling JSON.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_editor_api/lumina_editor_api.dart';
import 'package:lumina_plugin_miniai/lumina_plugin_miniai.dart';
import 'package:lumina_plugin_miniai/src/tool_card_parts.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';

import 'support/local_mcp.dart';
import 'support/replay_claude.dart';

void main() {
  late Directory temp;
  late MiniAiController controller;
  late ReplayClaude replay;

  const question = 'Which colour do you prefer?';

  Future<void> make({ApprovalMode mode = ApprovalMode.ask}) async {
    temp = Directory.systemTemp.createTempSync('miniai_ask_');
    final claude = File('${temp.path}/claude.exe')..writeAsStringSync('');
    replay = ReplayClaude(['ask_user_question'], logDir: Directory('${temp.path}/logs')..createSync());
    controller = MiniAiController(
      storage: PluginStorage(userDir: Directory('${temp.path}/user'), projectDir: Directory('${temp.path}/project/.lumina/miniai')),
      mcp: LocalMcp(),
      environment: const {},
      projectRoot: temp.path,
      claudeStarter: replay.start,
      defaultMode: () => mode,
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
    controller.newChat();
  }

  tearDown(() async {
    controller.dispose();
    try {
      temp.deleteSync(recursive: true);
    } catch (_) {}
  });

  String answers() => controller.chat.items.whereType<AssistantItem>().map((a) => a.text.toString()).join('|');

  Future<void> untilAsked() async {
    for (var i = 0; i < 400 && controller.chat.pendingQuestions.isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
  }

  test('the question waits on its card, in Plan mode too; the answers go back as updatedInput.answers', () async {
    await make(mode: ApprovalMode.plan);
    final turn = controller.send('Ask me which colour I prefer.');
    await untilAsked();
    final card = controller.chat.pendingQuestions.single;
    expect(card.call.name, 'AskUserQuestion');
    expect(card.status, ToolCallStatus.waitingAnswer);
    expect(controller.chat.pendingApprovals, isEmpty, reason: 'a question is not an approval');
    final questions = UserQuestion.listFrom(jsonDecode(card.call.argumentsJson));
    expect(questions.single.question, question);
    expect(questions.single.options.map((o) => o.label), ['Red', 'Blue']);
    expect(questions.single.multiSelect, isFalse);

    controller.chat.answerQuestions(card, {question: 'Blue'});
    await turn;
    final sent = replay.answers.single;
    expect(sent['behavior'], 'allow');
    final updated = sent['updatedInput'] as Map;
    expect(updated['answers'], {question: 'Blue'});
    expect(updated['questions'], isA<List>(), reason: 'the questions go back with the answers');
    expect(card.status, ToolCallStatus.done);
    expect(card.answers, {question: 'Blue'});
    expect(card.result, contains('"$question"="Blue"'));
    expect(answers(), contains('Blue'));

    // The answers are kept with the chat.
    await controller.saveChat();
    final stored = Chat.fromJson(controller.chat.toJson());
    expect(stored.items.whereType<ToolCallItem>().single.answers, {question: 'Blue'});
  });

  test('Skip denies the question with a message the model can act on', () async {
    await make();
    final turn = controller.send('Ask me which colour I prefer.');
    await untilAsked();
    final card = controller.chat.pendingQuestions.single;
    controller.chat.answerQuestions(card, null);
    await turn;
    expect(replay.answers.single['behavior'], 'deny');
    expect('${replay.answers.single['message']}', contains('skipped'));
    expect(card.answers, isNull);
  });

  group('panel', () {
    Future<void> drive(WidgetTester tester, bool Function() done) async {
      for (var i = 0; i < 400 && !done(); i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(done(), isTrue);
      await tester.pump();
    }

    testWidgets('the question card: options, Answer enabled once picked, then the answer under the card', (tester) async {
      await tester.runAsync(make);
      tester.view.physicalSize = const Size(460, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(ShadcnApp(home: Scaffold(child: ChatPanel(controller: controller))));
      await tester.pump();

      await tester.enterText(find.byKey(const ValueKey('miniai_message')), 'Ask me which colour I prefer.');
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('miniai_send')));
      await drive(tester, () => controller.chat.pendingQuestions.isNotEmpty);
      final id = controller.chat.pendingQuestions.single.call.id;

      expect(find.byKey(ValueKey('miniai_question_${id}_0')), findsOneWidget);
      expect(find.text(question), findsOneWidget);
      expect(find.text('Colour'), findsOneWidget, reason: 'the header chip');
      expect(find.text('Red'), findsOneWidget);
      expect(find.text('The colour blue'), findsOneWidget);
      expect(find.textContaining('waiting for your answer'), findsOneWidget);
      expect(find.byKey(ValueKey('miniai_tool_args_$id')), findsNothing, reason: 'the questions, not their JSON');
      PrimaryButton answerButton() => tester.widget<PrimaryButton>(find.byKey(ValueKey('miniai_question_answer_$id')));
      expect(answerButton().onPressed, isNull, reason: 'nothing picked yet');

      await tester.tap(find.byKey(ValueKey('miniai_question_option_${id}_0_0')));
      await tester.pump();
      await tester.tap(find.byKey(ValueKey('miniai_question_option_${id}_0_1')));
      await tester.pump();
      expect(answerButton().onPressed, isNotNull);
      await tester.tap(find.byKey(ValueKey('miniai_question_answer_$id')));
      await tester.pump();
      await drive(tester, () => !controller.running);

      expect((replay.answers.single['updatedInput'] as Map)['answers'], {question: 'Blue'}, reason: 'one choice: the last pick');
      expect(find.byKey(ValueKey('miniai_questions_$id')), findsNothing);
      expect(find.byKey(ValueKey('miniai_answers_$id')), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() => controller.claude.close());
    });

    testWidgets('"Other" answers in the user\'s words', (tester) async {
      await tester.runAsync(make);
      tester.view.physicalSize = const Size(460, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(ShadcnApp(home: Scaffold(child: ChatPanel(controller: controller))));
      await tester.pump();
      await tester.enterText(find.byKey(const ValueKey('miniai_message')), 'Ask me which colour I prefer.');
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('miniai_send')));
      await drive(tester, () => controller.chat.pendingQuestions.isNotEmpty);
      final id = controller.chat.pendingQuestions.single.call.id;
      await tester.enterText(find.byKey(ValueKey('miniai_question_other_${id}_0')), 'Teal');
      await tester.pump();
      await tester.tap(find.byKey(ValueKey('miniai_question_answer_$id')));
      await tester.pump();
      await drive(tester, () => !controller.running);
      expect((replay.answers.single['updatedInput'] as Map)['answers'], {question: 'Teal'});
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() => controller.claude.close());
    });
  });

  group('tool card JSON', () {
    setUp(() => temp = Directory.systemTemp.createTempSync('miniai_json_'));

    Future<void> pump(WidgetTester tester, Widget child, {Brightness brightness = Brightness.dark}) async {
      // A fresh app: no theme animation from the previous one.
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(ShadcnApp(
        theme: ThemeData(colorScheme: brightness == Brightness.dark ? ColorSchemes.darkZinc : ColorSchemes.lightZinc),
        home: Scaffold(child: Align(alignment: Alignment.topLeft, child: SizedBox(width: 300, child: child))),
      ));
      await tester.pump();
    }

    /// The coloured spans of the view's text.
    List<TextSpan> spans(WidgetTester tester) {
      final text = tester.widget<SelectableText>(find.byType(SelectableText));
      final out = <TextSpan>[];
      text.textSpan!.visitChildren((s) {
        if (s is TextSpan && s.text != null) out.add(s);
        return true;
      });
      return out;
    }

    testWidgets('JSON is pretty-printed and coloured: keys, strings, numbers, literals', (tester) async {
      controller = MiniAiController(storage: PluginStorage(userDir: Directory('${temp.path}/user')), mcp: LocalMcp(), environment: const {});
      await pump(tester, const ToolPayloadView(text: '{"name":"Wall","count":34,"visible":true,"parent":null,"tags":["a"]}'));
      final all = spans(tester);
      expect(all.map((s) => s.text).join(), '{\n  "name": "Wall",\n  "count": 34,\n  "visible": true,\n  "parent": null,\n  "tags": [\n    "a"\n  ]\n}');
      Color? colourOf(String t) => all.firstWhere((s) => s.text == t).style?.color;
      expect(colourOf('"name"'), const Color(0xFF9CDCFE));
      expect(colourOf('"Wall"'), const Color(0xFFCE9178));
      expect(colourOf('34'), const Color(0xFFB5CEA8));
      expect(colourOf('true'), const Color(0xFF569CD6));
      expect(colourOf('null'), const Color(0xFF569CD6));

      await pump(tester, const ToolPayloadView(text: '{"name":"Wall"}'), brightness: Brightness.light);
      expect(spans(tester).firstWhere((s) => s.text == '"name"').style?.color, const Color(0xFF0451A5), reason: 'a light theme palette');
    });

    testWidgets('a long payload is at most 200 tall and scrolls; plain text stays plain', (tester) async {
      controller = MiniAiController(storage: PluginStorage(userDir: Directory('${temp.path}/user')), mcp: LocalMcp(), environment: const {});
      final long = jsonEncode({for (var i = 0; i < 80; i++) 'actor_$i': {'x': i, 'y': i * 2}});
      await pump(tester, ToolPayloadView(text: long));
      expect(tester.getSize(find.byType(ToolPayloadView)).height, ToolPayloadView.maxHeight);
      final scroll = tester.state<ScrollableState>(find.byType(Scrollable).first).position;
      expect(scroll.maxScrollExtent, greaterThan(0));
      await tester.drag(find.byType(ToolPayloadView), const Offset(0, -300));
      await tester.pump();
      expect(scroll.pixels, greaterThan(0));

      await pump(tester, const ToolPayloadView(text: 'Error: no such actor'));
      expect(tester.getSize(find.byType(ToolPayloadView)).height, lessThan(40), reason: 'a short payload keeps its own height');
      expect(spans(tester).single.text, 'Error: no such actor');
    });
  });
}
