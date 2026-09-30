import 'dart:async';

import 'package:lumina_editor_api/lumina_editor_api.dart';

/// An in-memory tool registry that runs real handlers under their own names
/// (the host's tools are not prefixed, unlike a plugin's), and records every
/// call.
class LocalMcp extends EditorMcp {
  final Map<String, McpTool> tools = {};
  final List<(String, Map<String, Object?>, String?)> recorded = [];
  final StreamController<McpToolCallEvent> _calls = StreamController.broadcast();
  final McpChangeSignal _changed = McpChangeSignal();

  @override
  void registerTool(McpTool tool) {
    tools[tool.name] = tool;
    _changed.notify();
  }

  @override
  List<McpTool> listTools({Set<String>? groups}) =>
      [for (final t in tools.values) if (groups == null || t.groups.intersection(groups).isNotEmpty) t];

  @override
  Future<McpToolResult> callTool(String name, Map<String, Object?> args, {String? caller}) async {
    final tool = tools[name];
    if (tool == null) throw JsonRpcException(JsonRpcErrorCode.invalidParams, 'Unknown tool "$name"');
    recorded.add((name, args, caller));
    return await tool.handler(McpArgs(args));
  }

  @override
  Stream<McpToolCallEvent> get calls => _calls.stream;

  /// The stdio launch an editor would hand out; null: no editor server.
  McpClientLaunch? launch;

  @override
  McpClientLaunch? get clientLaunch => launch;

  /// Whether this registry ties tagged external sessions to a caller, like
  /// the editor's; each binding is recorded as (tag, caller).
  bool attributes = false;
  final List<(String, String)> attributions = [];

  @override
  bool get attributesExternalCalls => attributes;

  @override
  Future<T> attributeExternalCalls<T>(String clientTag, String caller, Future<T> Function() body) {
    if (attributes) attributions.add((clientTag, caller));
    return body();
  }

  @override
  McpChangeSignal get toolsChanged => _changed;
}
