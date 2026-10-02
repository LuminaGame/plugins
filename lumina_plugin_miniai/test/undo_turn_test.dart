// "Undo this turn" — a turn's level step comes back off the undo
// stack only while it is the newest; the state is kept with the chat.
// Recorded MiniCPM5 streams from a real replay server; a real temp project.
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_editor_api/lumina_editor_api.dart';
import 'package:lumina_plugin_miniai/lumina_plugin_miniai.dart';

import 'support/local_mcp.dart';
import 'support/replay_server.dart';

/// A level with a linear undo stack of labelled steps, like the host's
/// `TransactionManager`: every edit inside [runTransaction] is one step.
class _StackLevel extends ChangeNotifier implements EditorLevelAccess {
  _StackLevel(this.projectDirPath);

  @override
  final String projectDirPath;
  final List<String> actorNames = [];
  final List<(String, List<String>)> _undo = [];
  (String, List<String>)? _open;

  void add(String name) {
    actorNames.add(name);
    if (_open != null) {
      _open!.$2.add(name);
    } else {
      _undo.add(('Add $name', [name]));
    }
    notifyListeners();
  }

  @override
  Future<T> runTransaction<T>(String label, Future<T> Function() body) async {
    if (_open != null) return body();
    _open = (label, <String>[]);
    try {
      return await body();
    } finally {
      final step = _open!;
      _open = null;
      if (step.$2.isNotEmpty) _undo.add(step);
    }
  }

  @override
  String? get undoTopLabel => _undo.isEmpty ? null : _undo.last.$1;

  @override
  bool undoIfTop(String label) {
    if (undoTopLabel != label) return false;
    for (final n in _undo.removeLast().$2) {
      actorNames.remove(n);
    }
    notifyListeners();
    return true;
  }

  void undo() {
    for (final n in _undo.removeLast().$2) {
      actorNames.remove(n);
    }
  }

  @override
  String get activeLevelPath => 'contents/levels/L_Main.lmas';
  @override
  Listenable get changes => this;
  @override
  List<EditorActorSnapshot> get actors => const [];
  @override
  List<String> get selectedActorIds => const [];
  @override
  Future<List<String>> addActors(List<EditorActorSpec> specs, {String? label}) async {
    for (final s in specs) {
      add(s.name);
    }
    return [for (final s in specs) s.name];
  }
  @override
  void removeActors(Iterable<String> ids, {String? label}) {}
  @override
  void setComponentProperty(String actorId, String componentType, String propertyId, Object? value, {String? label}) {}
  @override
  void selectActors(Iterable<String> ids) {}
  @override
  Future<void> saveLevel() async {}
  @override
  void openAssetEditor(String assetPath) {}
  @override
  Future<bool> openLevel(String relativePath, {bool show = true}) async => false;
  @override
  void log(String message, {String level = 'info', String source = 'Plugin'}) {}
}

void main() {
  late Directory temp;
  late ReplayServer server;
  late LocalMcp mcp;
  late _StackLevel level;
  late MiniAiController c;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('miniai_undo_turn_');
    server = await ReplayServer.start();
    level = _StackLevel('${temp.path}/Game');
    var n = 0;
    mcp = LocalMcp()
      ..registerTool(McpTool(
        name: 'spawn_actor_from_asset',
        description: 'Places a mesh asset in the open level as a new actor.',
        inputSchema: McpSchema.object({'asset': McpSchema.string('asset path'), 'location': McpSchema.vector3('[x, y, z]')}, required: ['asset']),
        handler: (args) {
          level.add('Barrel_${n++}');
          return McpToolResult.json({'placed': args.string('asset')});
        },
        risk: McpToolRisk.mutating,
        groups: {McpToolGroups.level},
      ));
    c = MiniAiController(
      storage: PluginStorage(userDir: Directory('${temp.path}/user'), projectDir: Directory('${temp.path}/Game/.lumina/plugins/lumina_plugin_miniai')),
      mcp: mcp,
      environment: const {},
      httpClient: realHttpClient,
      level: level,
      transaction: level.runTransaction,
      defaultMode: () => ApprovalMode.auto,
    );
    await c.load();
    await c.settings.save(ProviderConfig(id: 'replay', name: 'Replay', baseUrl: server.baseUrl, model: 'MiniCPM5-2B-Q4_K_M', local: true));
  });

  tearDown(() async {
    c.dispose();
    await server.close();
    await temp.delete(recursive: true);
  });

  test('a turn that placed barrels is one step; Undo this turn removes it and is kept with the chat', () async {
    server.queue.addAll(['two_tool_calls', 'text']);
    await c.send('Place the barrel twice');
    final turn = c.chat.turns.single;
    expect(turn.id, '${c.chat.id}:1');
    expect(turn.sceneStep, isTrue);
    expect(level.actorNames, ['Barrel_0', 'Barrel_1']);
    expect(mcp.recorded.map((r) => r.$3).toSet(), {'miniai:${c.chat.id}:1'});
    expect(c.canUndoTurn(turn).$1, isTrue);

    await c.undoTurn(turn.id);
    expect(level.actorNames, isEmpty);
    expect(turn.undone, isTrue);
    expect(c.chat.items.last, isA<NoteItem>().having((n) => n.text, 'text', 'Undone: 1 scene step.'));
    expect(c.canUndoTurn(turn), (false, 'This turn was undone'));

    final stored = (await c.store!.load(c.chat.id))!;
    expect(stored.turns.single.undone, isTrue);
    expect(stored.turns.single.sceneStep, isTrue);
  });

  test('a newer step on top disables the turn\'s undo; a text-only turn has nothing to undo', () async {
    server.queue.addAll(['two_tool_calls', 'text']);
    await c.send('Place the barrel twice');
    final turn = c.chat.turns.single;
    level.add('UserCube');
    expect(c.canUndoTurn(turn), (false, 'Newer changes are on top of this turn in Edit ▸ Undo; undo them first'));
    await c.undoTurn(turn.id);
    expect(level.actorNames, contains('Barrel_0'), reason: 'nothing was undone');
    level.undo();
    expect(c.canUndoTurn(turn).$1, isTrue);

    server.queue.add('text');
    await c.send('Just say hello');
    final chatty = c.chat.turns.last;
    expect(chatty.sceneStep, isFalse);
    expect(c.canUndoTurn(chatty), (false, 'This turn changed nothing'));
  });
}
