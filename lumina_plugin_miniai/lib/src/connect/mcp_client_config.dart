import 'dart:convert';
import 'dart:io';

import 'package:lumina_editor_api/lumina_editor_api.dart';

/// An MCP client MiniAI can register the editor with.
enum McpClientKind { antigravity, claudeCode }

/// Where a client keeps its MCP servers, and how an entry looks there.
class McpClientTarget {
  const McpClientTarget({required this.kind, required this.label, required this.file, required this.scope});

  final McpClientKind kind;
  final String label;
  final File file;

  /// "all your projects" / "this project".
  final String scope;

  /// The `mcpServers.lumina` entry for [launch].
  Map<String, Object?> entryFor(McpClientLaunch launch) => {
        if (kind == McpClientKind.claudeCode) 'type': 'stdio',
        'command': launch.command,
        'args': launch.args,
      };
}

enum McpConfigState { missing, notConfigured, configured, outdated, unreadable }

class McpConfigStatus {
  const McpConfigStatus(this.state, [this.message]);
  final McpConfigState state;

  /// Why an [McpConfigState.unreadable] file cannot be used.
  final String? message;
}

/// Writes the editor's MCP server (the stdio bridge, no token) into an MCP
/// client's config: a merge that keeps every other server and key, a backup
/// of the old file, an atomic write; a file that does not parse is never
/// overwritten.
class McpClientConfig {
  const McpClientConfig._();

  static const String serverName = 'lumina';

  /// Antigravity's user-wide file and Claude Code's project file.
  static List<McpClientTarget> targets({required Map<String, String> environment, String? projectDir}) {
    final home = environment['USERPROFILE'] ?? environment['HOME'] ?? '.';
    return [
      McpClientTarget(
        kind: McpClientKind.antigravity,
        label: 'Antigravity',
        file: File('$home/.gemini/config/mcp_config.json'),
        scope: 'app, IDE and agy CLI — all your projects',
      ),
      if (projectDir != null)
        McpClientTarget(
          kind: McpClientKind.claudeCode,
          label: 'Claude Code',
          file: File('$projectDir/.mcp.json'),
          scope: 'this project',
        ),
    ];
  }

  static Future<Map<String, Object?>> _read(File file) async {
    final text = await file.readAsString();
    if (text.trim().isEmpty) return {};
    final Object? data;
    try {
      data = jsonDecode(text);
    } on FormatException catch (e) {
      throw FormatException('${file.path} is not valid JSON (${e.message}); it was left unchanged.');
    }
    if (data is! Map) throw FormatException('${file.path} is not a JSON object; it was left unchanged.');
    final servers = data['mcpServers'];
    if (servers != null && servers is! Map) throw FormatException('${file.path}: "mcpServers" is not an object; it was left unchanged.');
    return Map<String, Object?>.from(data);
  }

  static bool _sameEntry(Object? a, Object? b) => jsonEncode(a) == jsonEncode(b);

  static Future<McpConfigStatus> status(McpClientTarget target, McpClientLaunch launch) async {
    if (!await target.file.exists()) return const McpConfigStatus(McpConfigState.missing);
    try {
      final data = await _read(target.file);
      final entry = (data['mcpServers'] as Map?)?[serverName];
      if (entry == null) return const McpConfigStatus(McpConfigState.notConfigured);
      return McpConfigStatus(_sameEntry(entry, target.entryFor(launch)) ? McpConfigState.configured : McpConfigState.outdated);
    } on FormatException catch (e) {
      return McpConfigStatus(McpConfigState.unreadable, e.message);
    }
  }

  /// Adds or updates `mcpServers.lumina`. Returns the backup's path (null
  /// when there was no file). Throws [FormatException] for an unreadable
  /// file, which stays byte-identical.
  static Future<String?> connect(McpClientTarget target, McpClientLaunch launch, {DateTime? now}) async {
    final exists = await target.file.exists();
    final data = exists ? await _read(target.file) : <String, Object?>{};
    final servers = Map<String, Object?>.from(data['mcpServers'] as Map? ?? const {});
    servers[serverName] = target.entryFor(launch);
    data['mcpServers'] = servers;
    return _write(target.file, data, backup: exists, now: now);
  }

  /// Removes `mcpServers.lumina` only. Returns the backup's path, or null
  /// when there was nothing to remove.
  static Future<String?> disconnect(McpClientTarget target, {DateTime? now}) async {
    if (!await target.file.exists()) return null;
    final data = await _read(target.file);
    final servers = Map<String, Object?>.from(data['mcpServers'] as Map? ?? const {});
    if (servers.remove(serverName) == null) return null;
    data['mcpServers'] = servers;
    return _write(target.file, data, backup: true, now: now);
  }

  static Future<String?> _write(File file, Map<String, Object?> data, {required bool backup, DateTime? now}) async {
    String? backupPath;
    if (backup) {
      final t = (now ?? DateTime.now()).toLocal();
      String two(int v) => v.toString().padLeft(2, '0');
      final stamp = '${t.year}${two(t.month)}${two(t.day)}-${two(t.hour)}${two(t.minute)}${two(t.second)}';
      var candidate = '${file.path}.lumina-backup-$stamp';
      for (var n = 2; File(candidate).existsSync(); n++) {
        candidate = '${file.path}.lumina-backup-$stamp-$n';
      }
      await file.copy(candidate);
      backupPath = candidate;
    }
    await file.parent.create(recursive: true);
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString('${const JsonEncoder.withIndent('  ').convert(data)}\n', flush: true);
    await tmp.rename(file.path);
    return backupPath;
  }
}
