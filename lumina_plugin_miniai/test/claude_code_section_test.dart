// Model provider… ▸ Claude Code: detection of the real `claude` on this
// machine (skipped without one) and "claude not found" with the install hint.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_editor_api/lumina_editor_api.dart';
import 'package:lumina_plugin_miniai/lumina_plugin_miniai.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';

import 'support/local_mcp.dart';

void main() {
  late MiniAiController controller;

  late Directory temp;
  MiniAiController make(Map<String, String> environment) => controller = MiniAiController(
        storage: PluginStorage(userDir: Directory('${temp.path}/user')),
        mcp: LocalMcp(),
        environment: environment,
        projectRoot: temp.path,
      );

  setUp(() {
    temp = Directory.systemTemp.createTempSync('miniai_cc_section_');
  });

  tearDown(() {
    controller.dispose();
    try {
      temp.deleteSync(recursive: true);
    } catch (_) {}
  });

  Future<void> pump(WidgetTester tester) async {
    tester.view.physicalSize = const Size(700, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ShadcnApp(home: Scaffold(child: SingleChildScrollView(child: ClaudeCodeSection(controller: controller)))));
    await tester.pump();
  }

  Future<void> drive(WidgetTester tester, bool Function() done) async {
    for (var i = 0; i < 600 && !done(); i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(done(), isTrue);
  }

  String status(WidgetTester tester) => tester.widget<Text>(find.byKey(const ValueKey('miniai_claude_status'))).data ?? '';

  testWidgets('a path that does not exist: "claude not found" with the install hint; Use is off', (tester) async {
    // No PATH and no home: nothing is found until the path is typed.
    make(const {});
    await pump(tester);
    await drive(tester, () => status(tester) == 'claude not found');
    final missing = '${temp.path}/no/claude.exe';
    await tester.enterText(find.byKey(const ValueKey('miniai_claude_path')), missing);
    await tester.tap(find.byKey(const ValueKey('miniai_claude_detect')));
    await tester.pump();
    await drive(tester, () => status(tester).startsWith('claude not found'));
    expect(status(tester), 'claude not found at $missing');
    expect(find.textContaining('claude.ai/install'), findsOneWidget);
    expect(tester.widget<PrimaryButton>(find.byKey(const ValueKey('miniai_claude_use'))).onPressed, isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('the installed claude: version and login; Use Claude Code saves a provider with no key', (tester) async {
    final found = const ClaudeCodeCli().find();
    if (found == null) {
      markTestSkipped('claude is not installed here');
      return;
    }
    make(Platform.environment);
    await pump(tester);
    await drive(tester, () => status(tester).contains('Claude Code') || status(tester).contains('not'));
    expect(status(tester), contains('(Claude Code)'));
    expect(status(tester), anyOf(contains('Logged in'), contains('Not logged in')));
    expect(find.text(found), findsOneWidget);
    // The model list comes from the CLI (no model call); the button waits for it.
    await drive(tester, () => tester.widget<PrimaryButton>(find.byKey(const ValueKey('miniai_claude_use'))).onPressed != null);
    await tester.tap(find.byKey(const ValueKey('miniai_claude_use')));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
    await tester.pump();
    final selected = controller.settings.selected!;
    expect(selected.isClaudeCode, isTrue);
    expect(selected.model, isEmpty, reason: "the CLI's default");
    expect(controller.settings.storedKeys, isEmpty);
    expect(controller.settings.isConfigured, isTrue);
    await tester.pumpWidget(const SizedBox());
  });
}
