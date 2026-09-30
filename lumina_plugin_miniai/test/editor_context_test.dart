// The editor selection and @ mentions as message context: labels, the
// block the model reads, the live watcher and the mention index, over a real
// temp project answered by the host's tool shapes.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_plugin_miniai/lumina_plugin_miniai.dart';

import 'support/local_mcp.dart';
import 'support/temp_project.dart';

void main() {
  late Directory temp;
  late TempProject project;
  late LocalMcp mcp;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('miniai_ctx_');
    project = TempProject(temp);
    mcp = LocalMcp();
    project.register(mcp);
  });
  tearDown(() => temp.deleteSync(recursive: true));

  Future<EditorSelection> read() async {
    final r = await mcp.callTool('get_selection', {});
    return EditorSelection.fromJson(Map<String, Object?>.from(r.structuredContent!));
  }

  test('chip labels: one actor, several, one asset, nothing', () async {
    expect((await read()).label, isNull);
    expect((await read()).isEmpty, isTrue);
    project.selectedActors.add('actor_wall');
    expect((await read()).label, 'Divider_Wall · Primitive');
    project.selectedActors.addAll(['actor_light', 'actor_barrel']);
    expect((await read()).label, '3 actors');
    project.selectedActors.clear();
    project.selectedAssets.add('contents/meshes/fuel_barrel_red.lmas');
    expect((await read()).label, 'fuel_barrel_red · filamesh');
    project.selectedAssets.add('contents/materials/M_Brick.lmas');
    expect((await read()).label, '2 assets');
  });

  test('the context block: compact selection and the mentions, as JSON', () async {
    project.selectedActors.add('actor_wall');
    final context = MessageContext(selection: await read(), mentions: const [
      MentionCandidate(kind: MentionKind.asset, name: 'fuel_barrel_red', path: 'contents/meshes/fuel_barrel_red.lmas', type: 'filamesh'),
      MentionCandidate(kind: MentionKind.actor, name: 'Sun', id: 'actor_light', type: 'DirectionalLight'),
    ]);
    final message = context.messageFor('Put two of these next to it');
    expect(message, startsWith('<editor_context>\n'));
    expect(message, endsWith('\n</editor_context>\n\nPut two of these next to it'));
    final json = jsonDecode(message.split('\n')[1]) as Map;
    final actor = ((json['selection'] as Map)['level'] as Map)['selected_actors'][0] as Map;
    expect(actor, {'id': 'actor_wall', 'name': 'Divider_Wall', 'type': 'Primitive', 'location': [120.0, 0.0, 0.0]});
    expect(actor.containsKey('components'), isFalse);
    expect(json['mentions'], [
      {'kind': 'asset', 'name': 'fuel_barrel_red', 'path': 'contents/meshes/fuel_barrel_red.lmas', 'type': 'filamesh'},
      {'kind': 'actor', 'name': 'Sun', 'id': 'actor_light', 'type': 'DirectionalLight'},
    ]);
    expect(context.displayLine, 'Context: Divider_Wall · Primitive, @fuel_barrel_red, @Sun');
    expect(const MessageContext().messageFor('hi'), 'hi', reason: 'nothing to attach: the plain text');
    project.selectedActors.clear();
    expect(MessageContext(selection: await read()).json, isNull, reason: 'an empty selection is not attached');
  });

  test('the watcher follows the selection: level changes at once, the rest by polling; unwatch stops', () async {
    final level = ValueNotifier(0);
    final watcher = SelectionWatcher(mcp, level: level, interval: const Duration(milliseconds: 60));
    addTearDown(watcher.dispose);
    var notified = 0;
    watcher.addListener(() => notified++);
    watcher.watch();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(watcher.selection!.label, isNull);

    project.selectedActors.add('actor_wall');
    level.value++;
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(watcher.selection!.label, 'Divider_Wall · Primitive', reason: 'a level change reads at once');

    project.selectedAssets.add('contents/Props/crate_wood.lmas');
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(watcher.selection!.label, 'Divider_Wall · Primitive, crate_wood · filamesh', reason: 'the poll sees the Content Browser');
    final before = notified;
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(notified, before, reason: 'no change, no notification');

    watcher.dismiss();
    expect(watcher.attachable, isNull);
    watcher.sent();
    expect(watcher.attachable, isNotNull, reason: 'dropped for one message only');
    watcher.dismiss();
    project.selectedActors.clear();
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(watcher.dismissed, isFalse, reason: 'a new selection brings the chip back');

    watcher.unwatch();
    expect(watcher.watching, isFalse);
    project.selectedActors.add('actor_light');
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(watcher.selection!.label, 'crate_wood · filamesh', reason: 'no reads after unwatch');
  });

  test('the mention index reads assets, folders and actors; prefix matches first', () async {
    final index = MentionIndex(mcp);
    await index.load();
    final kinds = {for (final c in index.candidates) '${c.kind.name}:${c.name}'};
    expect(kinds, containsAll(['asset:fuel_barrel_red', 'asset:M_Brick', 'folder:Props', 'folder:meshes', 'actor:Divider_Wall', 'actor:Sun']));
    final fu = index.search('fu');
    expect(fu.first.name, 'fuel_barrel_red');
    expect(fu.first.path, 'contents/meshes/fuel_barrel_red.lmas');
    expect(fu.map((c) => c.name), contains('fuel_barrel_red_1'), reason: 'the actor too');
    expect(index.search('props').map((c) => c.name), contains('Props'), reason: 'folders by name, assets by path');
    expect(index.search('DIVIDER').map((c) => c.kind), containsAll([MentionKind.asset, MentionKind.actor]));
    expect(index.search('').length, lessThanOrEqualTo(8));
  });
}
