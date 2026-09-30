import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:lumina_editor_api/lumina_editor_api.dart';

import '../agent/toolset_selector.dart';
import 'editor_context.dart';

/// The editor selection while the chat panel is on screen: re-read with
/// the host's `get_selection` tool on every level change and once per
/// [interval] (Content Browser and sub-editor selections have no change
/// event for plugins).
class SelectionWatcher extends ChangeNotifier {
  SelectionWatcher(this.mcp, {this.level, this.interval = const Duration(seconds: 1)});

  final EditorMcp mcp;
  final Listenable? level;
  final Duration interval;

  /// The host tool it reads.
  static const String toolName = 'get_selection';

  /// The caller MiniAI's own UI reads with.
  static const String caller = 'miniai:ui';

  /// The last selection read; null before the first read or without the tool.
  EditorSelection? selection;

  /// The user dropped the chip for the next message.
  bool dismissed = false;
  String? _dismissedSignature;

  int _watchers = 0;
  Timer? _timer;
  bool _reading = false;
  bool _disposed = false;

  /// The selection to attach to the next message, or null.
  EditorSelection? get attachable => dismissed || selection == null || selection!.isEmpty ? null : selection;

  /// Starts watching (counted: each [watch] needs an [unwatch]).
  void watch() {
    if (_watchers++ > 0) return;
    level?.addListener(_levelChanged);
    _timer = Timer.periodic(interval, (_) => unawaited(refresh()));
    unawaited(refresh());
  }

  void unwatch() {
    if (_watchers == 0 || --_watchers > 0) return;
    level?.removeListener(_levelChanged);
    _timer?.cancel();
    _timer = null;
  }

  bool get watching => _watchers > 0;

  void _levelChanged() => unawaited(refresh());

  /// Reads the selection now.
  Future<void> refresh() async {
    if (_reading || _disposed) return;
    if (!mcp.listTools().any((t) => t.name == toolName)) {
      _set(null);
      return;
    }
    _reading = true;
    try {
      final result = await mcp.callTool(toolName, {'include_components': false}, caller: caller);
      if (_disposed) return;
      if (result.isError) return;
      final data = result.structuredContent ?? jsonDecode('${result.content.first['text']}');
      if (data is Map) _set(EditorSelection.fromJson(Map<String, Object?>.from(data)));
    } on Object {
      // A tool error or an editor shutting down: keep the last selection.
    } finally {
      _reading = false;
    }
  }

  void _set(EditorSelection? next) {
    final changed = next?.signature != selection?.signature;
    selection = next;
    // A new selection brings the chip back.
    if (dismissed && next?.signature != _dismissedSignature) dismissed = false;
    if (changed) notifyListeners();
  }

  /// ✕ on the chip: not with the next message.
  void dismiss() {
    dismissed = true;
    _dismissedSignature = selection?.signature;
    notifyListeners();
  }

  /// A message was sent: the chip comes back for the next one.
  void sent() {
    if (!dismissed) return;
    dismissed = false;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    level?.removeListener(_levelChanged);
    super.dispose();
  }
}

/// The project's content and the level's actors for `@` mentions, read
/// through the host's `list_assets`, `list_content_folders` and
/// `list_actors` tools.
class MentionIndex {
  MentionIndex(this.mcp, {this.maxAge = const Duration(seconds: 5)});

  final EditorMcp mcp;

  /// How long a read stays fresh.
  final Duration maxAge;

  List<MentionCandidate> candidates = const [];
  DateTime? _loaded;
  Future<void>? _loading;

  /// Reads the candidates unless the last read is fresh.
  Future<void> load({bool force = false}) {
    final loaded = _loaded;
    if (!force && loaded != null && DateTime.now().difference(loaded) < maxAge) return Future.value();
    return _loading ??= _read().whenComplete(() => _loading = null);
  }

  Future<Map<String, Object?>?> _call(String name, Map<String, Object?> args) async {
    if (!mcp.listTools().any((t) => t.name == name)) return null;
    try {
      final r = await mcp.callTool(name, args, caller: SelectionWatcher.caller);
      if (r.isError) return null;
      final data = r.structuredContent ?? jsonDecode('${r.content.first['text']}');
      return data is Map ? Map<String, Object?>.from(data) : null;
    } on Object {
      return null;
    }
  }

  static String _base(String path) {
    final file = path.substring(path.lastIndexOf('/') + 1);
    return file.endsWith('.lmas') ? file.substring(0, file.length - 5) : file;
  }

  Future<void> _read() async {
    final assets = await _call('list_assets', const {});
    final folders = await _call('list_content_folders', const {});
    final actors = await _call('list_actors', const {});
    final found = <MentionCandidate>[];
    for (final a in (assets?['assets'] as List? ?? const [])) {
      if (a is! Map || a['path'] is! String) continue;
      final path = (a['path'] as String).replaceAll(r'\', '/');
      found.add(MentionCandidate(kind: MentionKind.asset, name: _base(path), path: path, type: a['type'] as String?));
    }
    void folder(Object? node) {
      if (node is! Map || node['path'] is! String) return;
      final path = node['path'] as String;
      if (path != 'contents') found.add(MentionCandidate(kind: MentionKind.folder, name: '${node['name'] ?? _base(path)}', path: path));
      for (final child in (node['children'] as List? ?? const [])) {
        folder(child);
      }
    }

    for (final f in (folders?['folders'] as List? ?? const [])) {
      folder(f);
    }
    for (final a in (actors?['actors'] as List? ?? const [])) {
      if (a is! Map || a['id'] == null) continue;
      if (a['type'] == 'Folder') continue;
      found.add(MentionCandidate(kind: MentionKind.actor, name: '${a['name']}', id: '${a['id']}', type: a['type'] as String?));
    }
    candidates = found;
    _loaded = DateTime.now();
  }

  /// The candidates matching [query] (name or path, case- and
  /// Turkish-i-insensitive): names starting with it first, at most [limit].
  List<MentionCandidate> search(String query, {int limit = 8}) {
    final q = ToolsetSelector.fold(query);
    if (q.isEmpty) return candidates.take(limit).toList();
    final starts = <MentionCandidate>[];
    final contains = <MentionCandidate>[];
    for (final c in candidates) {
      final name = ToolsetSelector.fold(c.name);
      if (name.startsWith(q)) {
        starts.add(c);
      } else if (name.contains(q) || ToolsetSelector.fold(c.path ?? '').contains(q)) {
        contains.add(c);
      }
    }
    return [...starts, ...contains].take(limit).toList();
  }
}
