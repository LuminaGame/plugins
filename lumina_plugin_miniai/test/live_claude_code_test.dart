// One tiny prompt through the user's real Claude Code CLI, end to end
// (skipped when `claude` is not installed or not logged in). It is one cheap
// model call on the user's own login.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_editor_api/lumina_editor_api.dart';
import 'package:lumina_plugin_miniai/lumina_plugin_miniai.dart';

import 'support/local_mcp.dart';

void main() {
  test('a tiny prompt answers through the real CLI and the session id is kept', () async {
    final install = await const ClaudeCodeCli().detect();
    if (!install.ready) {
      markTestSkipped('claude is not installed or not logged in (${install.path ?? 'not found'})');
      return;
    }
    final temp = Directory.systemTemp.createTempSync('miniai_cc_live_');
    addTearDown(() {
      try {
        temp.deleteSync(recursive: true);
      } catch (_) {}
    });
    final controller = MiniAiController(
      storage: PluginStorage(userDir: Directory('${temp.path}/user'), projectDir: Directory('${temp.path}/project/.lumina/miniai')),
      mcp: LocalMcp(),
      environment: Platform.environment,
      projectRoot: temp.path,
      defaultMode: () => ApprovalMode.plan,
    );
    addTearDown(controller.dispose);
    await controller.settings.save(const ProviderConfig(
      id: ProviderConfig.claudeCodeId,
      name: 'Claude Code',
      baseUrl: '',
      model: 'haiku',
      kind: ProviderKind.claudeCode,
    ));
    controller.newChat();
    await controller.send('Reply with exactly: PONG');
    final answer = controller.chat.items.whereType<AssistantItem>().map((a) => a.text.toString()).join();
    expect(answer, contains('PONG'), reason: [for (final n in controller.chat.items.whereType<NoteItem>()) n.text].join(' | '));
    final data = controller.chat.providerData['claude_code'] as Map;
    expect(data['sessionId'], hasLength(36));
    expect(data['costUsd'], greaterThan(0));
    await controller.claude.close();
  }, timeout: const Timeout(Duration(minutes: 3)));
}
