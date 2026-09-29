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

  @override
  McpChangeSignal get toolsChanged => _changed;
}
