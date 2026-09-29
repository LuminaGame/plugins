// The provider and the agent loop against a real llama-server
// running MiniCPM5-2B on GPU 1. Skipped unless the model and the server are
// installed in `miniai/` of Lumina's data directory (the local model card installs them).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_editor_api/lumina_editor_api.dart';
import 'package:lumina_plugin_miniai/lumina_plugin_miniai.dart';

import 'support/local_mcp.dart';

final _root = LocalModelManager.defaultRoot(Platform.environment);
final _model = File('$_root/models/MiniCPM5-2B-Q4_K_M.gguf');
final _server = File('$_root/bin/b11239/${Platform.isWindows ? 'llama-server.exe' : 'llama-server'}');

/// The Vulkan device of the workspace's GPU 1 (the RTX PRO 2000), by name.
Future<String?> _gpu1Device() async {
  final r = await Process.run(_server.path, ['--list-devices']);
  final line = '${r.stdout}\n${r.stderr}'.split('\n').firstWhere((l) => l.contains('RTX PRO 2000'), orElse: () => '');
  return RegExp(r'(Vulkan\d+)').firstMatch(line)?.group(1);
}

void main() {
  final installed = _model.existsSync() && _server.existsSync();
  Process? process;
  late int port;

  setUpAll(() async {
    if (!installed) return;
    final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    port = probe.port;
    await probe.close();
    final device = await _gpu1Device();
    process = await Process.start(_server.path, [
      '-m', _model.path,
      if (device != null) ...['--device', device],
      '-ngl', '99', '-c', '8192', '--jinja', '--min-p', '0.0',
      '--host', '127.0.0.1', '--port', '$port', '--alias', 'MiniCPM5-2B-Q4_K_M',
    ]);
    process!.stdout.drain<void>();
    process!.stderr.drain<void>();
    final client = HttpClient();
    for (var i = 0; i < 120; i++) {
      try {
        final r = await (await client.getUrl(Uri.parse('http://127.0.0.1:$port/health'))).close();
        if (r.statusCode == 200) break;
      } catch (_) {}
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    client.close();
  });

  tearDownAll(() => process?.kill());

  test('MiniCPM5 answers a question as text', () async {
    if (!installed) return markTestSkipped('MiniCPM5-2B / llama-server not installed in $_root');
    final provider = OpenAiCompatProvider(name: 'local', baseUrl: 'http://127.0.0.1:$port/v1');
    expect(await provider.listModels(), contains('MiniCPM5-2B-Q4_K_M'));
    final events = await provider
        .stream(const LlmRequest(model: 'MiniCPM5-2B-Q4_K_M', messages: [LlmMessage.user('What is 2+2? Answer with the number only.')], temperature: 0),
            cancel: CancelToken())
        .toList();
    expect(events.whereType<TextDelta>().map((e) => e.text).join(), contains('4'));
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('MiniCPM5 calls the offered tool and answers with its result', () async {
    if (!installed) return markTestSkipped('MiniCPM5-2B / llama-server not installed in $_root');
    final mcp = LocalMcp()
      ..registerTool(McpTool(
        name: 'count_actors',
        description: 'Counts the actors in the open level.',
        inputSchema: McpSchema.object({}),
        handler: (_) => McpToolResult.json({'count': 7}),
        risk: McpToolRisk.readOnly,
        groups: {McpToolGroups.level},
      ));
    final chat = Chat(id: 'live');
    await AgentLoop(
      provider: OpenAiCompatProvider(name: 'local', baseUrl: 'http://127.0.0.1:$port/v1'),
      model: 'MiniCPM5-2B-Q4_K_M',
      mcp: mcp,
    ).run(chat, 'How many actors are in the level? Use the tool.');
    expect(mcp.recorded.map((c) => c.$1), contains('count_actors'));
    expect(chat.items.whereType<AssistantItem>().last.text.toString(), contains('7'));
  }, timeout: const Timeout(Duration(minutes: 3)));
}
