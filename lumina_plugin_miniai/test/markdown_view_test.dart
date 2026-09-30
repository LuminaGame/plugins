// The assistant's answers as styled Markdown (MarkdownView), and the chat
// panel showing them.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_editor_api/lumina_editor_api.dart';
import 'package:lumina_plugin_miniai/lumina_plugin_miniai.dart';
import 'package:lumina_plugin_miniai/src/markdown_view.dart';
import 'package:flutter/rendering.dart' show RenderEditable;
import 'package:flutter/widgets.dart' as widgets show Table;
import 'package:shadcn_flutter/shadcn_flutter.dart';

import 'support/local_mcp.dart';

void main() {
  Future<void> pump(WidgetTester tester, String data, {Future<void> Function(String)? onOpenLink}) async {
    await tester.pumpWidget(ShadcnApp(
      theme: const ThemeData(colorScheme: ColorSchemes.darkZinc),
      home: Scaffold(
        child: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(width: 420, child: MarkdownView(data: data, onOpenLink: onOpenLink ?? (_) async {})),
        ),
      ),
    ));
    await tester.pump();
  }

  /// Every selectable paragraph's plain text.
  List<String> paragraphs(WidgetTester tester) => [
        for (final w in tester.widgetList<SelectableText>(find.byType(SelectableText))) w.data ?? w.textSpan!.toPlainText(),
      ];

  /// The styled span whose text is [text].
  TextSpan span(WidgetTester tester, String text) {
    TextSpan? found;
    for (final w in tester.widgetList<SelectableText>(find.byType(SelectableText))) {
      w.textSpan?.visitChildren((s) {
        if (s is TextSpan && s.text == text) found = s;
        return found == null;
      });
    }
    expect(found, isNotNull, reason: 'no span "$text"');
    return found!;
  }

  /// The effective style of [text] (the styles above it merged).
  TextStyle styleOf(WidgetTester tester, String text) {
    for (final w in tester.widgetList<SelectableText>(find.byType(SelectableText))) {
      TextStyle? found;
      void walk(InlineSpan s, TextStyle inherited) {
        final style = inherited.merge(s.style);
        if (s is TextSpan && s.text == text) found = style;
        if (s is TextSpan) {
          for (final c in s.children ?? const <InlineSpan>[]) {
            walk(c, style);
          }
        }
      }

      if (w.textSpan != null) walk(w.textSpan!, const TextStyle());
      if (found != null) return found!;
    }
    fail('no span "$text"');
  }

  testWidgets('the user\'s answer: bold labels, inline code, bullet lists, no raw markers', (tester) async {
    await pump(tester, '''
Endless runner is ready.

**Controls:** A / ← left lane, D / → right lane, Space jumps.

**Gameplay:**
- **Run:** the character runs along +X; speed grows from 900 to 2200 cm/s.
- **Lanes:** 3 lanes (Y = -250 / 0 / 250).

**Added:**
- `L_Runner` level; PlayerStart at (0, 0, 100).
- `BP_RunnerCharacter`, `BP_RoadTile`''');
    final text = paragraphs(tester).join('\n');
    expect(text, isNot(contains('**')));
    expect(text, isNot(contains('`')));
    expect(text, isNot(contains('- ')));
    expect(styleOf(tester, 'Controls:').fontWeight, FontWeight.w700);
    expect(styleOf(tester, 'Run:').fontWeight, FontWeight.w700);
    expect(styleOf(tester, 'L_Runner').fontFamily, 'monospace');
    expect(styleOf(tester, 'L_Runner').backgroundColor, isNotNull);
    expect(find.text('•'), findsNWidgets(4));
    expect(paragraphs(tester), contains('L_Runner level; PlayerStart at (0, 0, 100).'));
  });

  testWidgets('headings, emphasis, strikethrough, numbered and nested lists, a quote, a rule', (tester) async {
    await pump(tester, '''
# Title
## Section
### Sub

*soft* and ~~gone~~

3. three
4. four
   - nested

> quoted

---
after''');
    expect(styleOf(tester, 'Title').fontSize, greaterThan(styleOf(tester, 'Sub').fontSize!));
    expect(styleOf(tester, 'Section').fontWeight, FontWeight.w700);
    expect(styleOf(tester, 'soft').fontStyle, FontStyle.italic);
    expect(styleOf(tester, 'gone').decoration, TextDecoration.lineThrough);
    expect(find.text('3.'), findsOneWidget, reason: 'a list keeps its start number');
    expect(find.text('4.'), findsOneWidget);
    expect(find.text('•'), findsOneWidget, reason: 'the nested bullet');
    expect(paragraphs(tester), containsAll(['nested', 'quoted', 'after']));
    expect(tester.getTopLeft(find.text('•')).dx, greaterThan(tester.getTopLeft(find.text('4.')).dx), reason: 'nested lists are indented');
  });

  testWidgets('a fenced code block is a code snippet with its language; a table is a table', (tester) async {
    await pump(tester, '''
```dart
void main() => print('hi');
```

| Key | Action |
|---|---|
| A | left |
| D | right |''');
    expect(find.byType(CodeSnippet), findsOneWidget);
    expect(paragraphs(tester), contains("void main() => print('hi');"));
    expect(find.text('dart'), findsOneWidget);
    expect(find.byType(widgets.Table), findsOneWidget);
    expect(styleOf(tester, 'Key').fontWeight, FontWeight.w700, reason: 'the header row');
    expect(paragraphs(tester), containsAll(['A', 'left', 'D', 'right']));
  });

  testWidgets('a link is styled and a click opens it', (tester) async {
    final opened = <String>[];
    await pump(tester, 'See [the docs](https://example.com/docs) now.', onOpenLink: (u) async => opened.add(u));
    final link = span(tester, 'the docs');
    expect(styleOf(tester, 'the docs').decoration, TextDecoration.underline);
    expect(link.recognizer, isNotNull);
    // Click the middle of "the docs" (the paragraph is an EditableText).
    final editable = tester.renderObject<RenderEditable>(find.descendant(of: find.byType(EditableText), matching: find.byWidgetPredicate((w) => w.runtimeType.toString() == '_Editable')));
    final start = 'See '.length;
    final box = editable.getBoxesForSelection(TextSelection(baseOffset: start, extentOffset: start + 'the docs'.length)).first;
    await tester.tapAt(editable.localToGlobal(box.toRect().center));
    await tester.pump();
    expect(opened, ['https://example.com/docs']);
  });

  testWidgets('entities are shown as characters; a half-streamed answer renders', (tester) async {
    await pump(tester, 'Tom & Jerry say "hi" <3\n\n**bold not closed');
    expect(paragraphs(tester).first, 'Tom & Jerry say "hi" <3');
    expect(paragraphs(tester).last, '**bold not closed');
  });

  testWidgets('the chat panel shows an assistant answer as Markdown', (tester) async {
    final temp = Directory.systemTemp.createTempSync('miniai_md_');
    addTearDown(() => temp.deleteSync(recursive: true));
    final controller = MiniAiController(storage: PluginStorage(userDir: Directory('${temp.path}/user')), mcp: LocalMcp(), environment: const {});
    addTearDown(controller.dispose);
    controller.chat.items
      ..add(UserItem('hi'))
      ..add(AssistantItem()..text.write('**Done.** Added `BP_Coin`.'));
    tester.view.physicalSize = const Size(460, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ShadcnApp(home: Scaffold(child: ChatPanel(controller: controller))));
    await tester.pump();
    expect(find.byKey(const ValueKey('miniai_assistant_1')), findsOneWidget);
    expect(tester.widget(find.byKey(const ValueKey('miniai_assistant_1'))), isA<MarkdownView>());
    expect(styleOf(tester, 'Done.').fontWeight, FontWeight.w700);
    expect(styleOf(tester, 'BP_Coin').fontFamily, 'monospace');
    await tester.pumpWidget(const SizedBox());
  });
}
