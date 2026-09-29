import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'chat.dart';

/// One History row (the index entry of a stored chat).
@immutable
class ChatSummary {
  const ChatSummary({
    required this.id,
    required this.title,
    required this.createdAt,
    required this.updatedAt,
    this.pinned = false,
    this.provider,
    this.model,
    this.mode,
    this.messageCount = 0,
  });

  final String id;
  final String title;
  final DateTime createdAt;
  final DateTime updatedAt;
  final bool pinned;
  final String? provider;
  final String? model;
  final String? mode;
  final int messageCount;

  factory ChatSummary.of(Chat chat) => ChatSummary(
        id: chat.id,
        title: chat.title,
        createdAt: chat.createdAt,
        updatedAt: chat.updatedAt,
        pinned: chat.pinned,
        provider: chat.provider,
        model: chat.model,
        mode: chat.gate.mode.name,
        messageCount: chat.messageCount,
      );

  factory ChatSummary.fromJson(Map<String, Object?> j) => ChatSummary(
        id: j['id'] as String,
        title: j['title'] as String? ?? Chat.defaultTitle,
        createdAt: DateTime.tryParse('${j['createdAt']}')?.toUtc() ?? DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
        updatedAt: DateTime.tryParse('${j['updatedAt']}')?.toUtc() ?? DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
        pinned: j['pinned'] == true,
        provider: j['provider'] as String?,
        model: j['model'] as String?,
        mode: j['mode'] as String?,
        messageCount: j['messageCount'] as int? ?? 0,
      );

  Map<String, Object?> toJson() => {
        'id': id,
        'title': title,
        'createdAt': createdAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
        'pinned': pinned,
        'provider': provider,
        'model': model,
        'mode': mode,
        'messageCount': messageCount,
      };

  ChatSummary copyWith({String? title, bool? pinned}) => ChatSummary(
        id: id,
        title: title ?? this.title,
        createdAt: createdAt,
        updatedAt: updatedAt,
        pinned: pinned ?? this.pinned,
        provider: provider,
        model: model,
        mode: mode,
        messageCount: messageCount,
      );
}

/// A project's MiniAI chats: `index.json` and
/// `chats/<id>.json` under [dir], written atomically. A chat file that does
/// not parse is set aside as `.corrupt-<n>`; an index that does not parse is
/// rebuilt from the chat files.
class ChatStore {
  ChatStore(this.dir);

  final Directory dir;

  /// The files set aside since this store was made.
  final List<String> warnings = [];

  File get _index => File('${dir.path}/index.json');
  Directory get _chats => Directory('${dir.path}/chats');
  File _file(String id) {
    if (id.isEmpty || id.contains('/') || id.contains(r'\') || id.contains('..')) throw ArgumentError.value(id, 'id', 'not a chat id');
    return File('${_chats.path}/$id.json');
  }

  static Future<void> _writeAtomic(File target, Object data) async {
    await target.parent.create(recursive: true);
    final tmp = File('${target.path}.tmp');
    await tmp.writeAsString(const JsonEncoder.withIndent('  ').convert(data), flush: true);
    await tmp.rename(target.path);
  }

  /// Renames a corrupt [file] to `<name>.corrupt-<n>` and records it.
  Future<void> _setAside(File file, Object error) async {
    var n = 1;
    while (File('${file.path}.corrupt-$n').existsSync()) {
      n++;
    }
    final aside = '${file.path}.corrupt-$n';
    await file.rename(aside);
    warnings.add('${file.uri.pathSegments.last} could not be read ($error); it was kept as ${aside.split('/').last}.');
  }

  static List<ChatSummary> _sorted(Iterable<ChatSummary> all) => all.toList()
    ..sort((a, b) {
      if (a.pinned != b.pinned) return a.pinned ? -1 : 1;
      return b.updatedAt.compareTo(a.updatedAt);
    });

  Future<Map<String, ChatSummary>> _readIndex() async {
    if (await _index.exists()) {
      try {
        final data = jsonDecode(await _index.readAsString());
        final list = (data as Map)['chats'] as List;
        return {for (final e in list) (e as Map)['id'] as String: ChatSummary.fromJson(Map<String, Object?>.from(e))};
      } catch (e) {
        await _setAside(_index, e is FormatException ? e.message : e);
      }
    }
    return _rebuildIndex();
  }

  /// Scans `chats/` (a missing or corrupt index).
  Future<Map<String, ChatSummary>> _rebuildIndex() async {
    final result = <String, ChatSummary>{};
    if (await _chats.exists()) {
      await for (final e in _chats.list()) {
        if (e is! File || !e.path.endsWith('.json')) continue;
        final chat = await _read(e);
        if (chat != null) result[chat.id] = ChatSummary.of(chat);
      }
    }
    if (result.isNotEmpty || await _index.exists()) await _writeIndex(result);
    return result;
  }

  Future<void> _writeIndex(Map<String, ChatSummary> index) =>
      _writeAtomic(_index, {'version': 1, 'chats': [for (final s in _sorted(index.values)) s.toJson()]});

  Future<Chat?> _read(File file) async {
    try {
      final data = jsonDecode(await file.readAsString());
      if (data is! Map) throw const FormatException('not a JSON object');
      return Chat.fromJson(Map<String, Object?>.from(data));
    } catch (e) {
      await _setAside(file, e is FormatException ? e.message : e);
      return null;
    }
  }

  /// The chats, pinned first, then the most recently updated.
  Future<List<ChatSummary>> list() async => _sorted((await _readIndex()).values);

  /// Writes [chat] and its index entry.
  Future<void> save(Chat chat) async {
    await _writeAtomic(_file(chat.id), chat.toJson());
    final index = await _readIndex();
    index[chat.id] = ChatSummary.of(chat);
    await _writeIndex(index);
  }

  /// The chat [id], or null when it is missing or corrupt (then set aside).
  Future<Chat?> load(String id) async {
    final file = _file(id);
    if (!await file.exists()) return null;
    final chat = await _read(file);
    if (chat == null) {
      final index = await _readIndex();
      if (index.remove(id) != null) await _writeIndex(index);
    }
    return chat;
  }

  Future<void> rename(String id, String title) => _update(id, (chat) => chat.title = title);

  Future<void> setPinned(String id, bool pinned) => _update(id, (chat) => chat.pinned = pinned);

  Future<void> _update(String id, void Function(Chat chat) change) async {
    final chat = await load(id);
    if (chat == null) return;
    change(chat);
    await save(chat);
  }

  Future<void> delete(String id) async {
    final file = _file(id);
    if (await file.exists()) await file.delete();
    final index = await _readIndex();
    if (index.remove(id) != null) await _writeIndex(index);
  }

  /// Chats whose title or user / assistant text contains [query]
  /// (case-insensitive), in [list] order.
  Future<List<ChatSummary>> search(String query) async {
    final all = await list();
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return all;
    final hits = <ChatSummary>[];
    for (final s in all) {
      if (s.title.toLowerCase().contains(q)) {
        hits.add(s);
        continue;
      }
      final file = _file(s.id);
      if (!await file.exists()) continue;
      try {
        final data = jsonDecode(await file.readAsString()) as Map;
        final text = [
          for (final i in (data['items'] as List? ?? const []))
            if (i is Map && (i['kind'] == 'user' || i['kind'] == 'assistant')) '${i['text']}',
        ].join('\n').toLowerCase();
        if (text.contains(q)) hits.add(s);
      } catch (_) {}
    }
    return hits;
  }
}
