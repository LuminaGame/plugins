// Writing the editor's MCP server into Antigravity's and Claude
// Code's config files, in real temp home and project directories.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_editor_api/lumina_editor_api.dart';
import 'package:lumina_plugin_miniai/lumina_plugin_miniai.dart';

void main() {
  late Directory temp;
  late List<McpClientTarget> targets;
  const launch = McpClientLaunch(command: r'C:\flutter\bin\cache\dart-sdk\bin\dart.exe', args: [r'D:\lumina\lumina_ui\bin\lumina_mcp_bridge.dart']);

  setUp(() {
    temp = Directory.systemTemp.createTempSync('miniai_connect_');
    Directory('${temp.path}/Game').createSync();
    targets = McpClientConfig.targets(environment: {'USERPROFILE': '${temp.path}/home', 'HOME': '${temp.path}/home'}, projectDir: '${temp.path}/Game');
  });
  tearDown(() => temp.deleteSync(recursive: true));

  McpClientTarget target(McpClientKind kind) => targets.firstWhere((t) => t.kind == kind);
  Map<String, dynamic> read(McpClientTarget t) => jsonDecode(t.file.readAsStringSync()) as Map<String, dynamic>;

  test('the targets are Antigravity\'s user file and Claude Code\'s project file', () {
    expect(target(McpClientKind.antigravity).file.path.replaceAll(r'\', '/'), '${temp.path}/home/.gemini/config/mcp_config.json'.replaceAll(r'\', '/'));
    expect(target(McpClientKind.claudeCode).file.path.replaceAll(r'\', '/'), '${temp.path}/Game/.mcp.json'.replaceAll(r'\', '/'));
  });

  test('connect creates a missing file with the stdio entry and no backup', () async {
    final ag = target(McpClientKind.antigravity);
    expect((await McpClientConfig.status(ag, launch)).state, McpConfigState.missing);
    expect(await McpClientConfig.connect(ag, launch), isNull);
    expect(read(ag), {
      'mcpServers': {
        'lumina': {'command': launch.command, 'args': launch.args},
      },
    });
    final cc = target(McpClientKind.claudeCode);
    await McpClientConfig.connect(cc, launch);
    expect(read(cc)['mcpServers']['lumina'], {'type': 'stdio', 'command': launch.command, 'args': launch.args});
    expect((await McpClientConfig.status(ag, launch)).state, McpConfigState.configured);
  });

  test('connect merges: other servers and keys stay, the old file is backed up, no .tmp left', () async {
    final ag = target(McpClientKind.antigravity);
    ag.file.parent.createSync(recursive: true);
    const before = '{"mcpServers": {"other": {"serverUrl": "http://localhost:9000/mcp"}}, "theme": "dark"}';
    ag.file.writeAsStringSync(before);
    expect((await McpClientConfig.status(ag, launch)).state, McpConfigState.notConfigured);

    final backup = await McpClientConfig.connect(ag, launch, now: DateTime(2026, 9, 29, 10, 11, 12));
    expect(backup, endsWith('mcp_config.json.lumina-backup-20260929-101112'));
    expect(File(backup!).readAsStringSync(), before);
    final after = read(ag);
    expect(after['theme'], 'dark');
    expect(after['mcpServers']['other'], {'serverUrl': 'http://localhost:9000/mcp'});
    expect(after['mcpServers']['lumina'], {'command': launch.command, 'args': launch.args});
    expect(ag.file.parent.listSync().where((e) => e.path.endsWith('.tmp')), isEmpty);
  });

  test('status: outdated when the command changed; disconnect removes only lumina', () async {
    final ag = target(McpClientKind.antigravity);
    ag.file.parent.createSync(recursive: true);
    ag.file.writeAsStringSync('{"mcpServers": {"other": {"command": "x"}}}');
    await McpClientConfig.connect(ag, launch);
    const moved = McpClientLaunch(command: r'C:\flutter\bin\cache\dart-sdk\bin\dart.exe', args: [r'E:\moved\lumina_mcp_bridge.dart']);
    expect((await McpClientConfig.status(ag, moved)).state, McpConfigState.outdated);

    expect(await McpClientConfig.disconnect(ag), isNotNull);
    expect(read(ag)['mcpServers'], {
      'other': {'command': 'x'},
    });
    expect((await McpClientConfig.status(ag, launch)).state, McpConfigState.notConfigured);
    expect(await McpClientConfig.disconnect(ag), isNull, reason: 'nothing left to remove');
  });

  test('an unreadable file is reported and never overwritten', () async {
    final cc = target(McpClientKind.claudeCode);
    cc.file.writeAsStringSync('{broken');
    final status = await McpClientConfig.status(cc, launch);
    expect(status.state, McpConfigState.unreadable);
    expect(status.message, contains('.mcp.json'));
    await expectLater(McpClientConfig.connect(cc, launch), throwsFormatException);
    expect(cc.file.readAsStringSync(), '{broken');
    expect(cc.file.parent.listSync().where((e) => e.path.contains('lumina-backup')), isEmpty);
  });
}
