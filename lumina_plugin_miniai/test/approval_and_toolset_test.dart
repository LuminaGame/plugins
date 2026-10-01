// The approval table and the toolset selector.
import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_editor_api/lumina_editor_api.dart';
import 'package:lumina_plugin_miniai/lumina_plugin_miniai.dart';

McpTool _tool(String name, McpToolRisk risk, Set<String> groups) => McpTool(
      name: name,
      description: 'The $name tool. ' * 20,
      inputSchema: McpSchema.object({'asset': McpSchema.string('asset path')}, required: ['asset']),
      handler: (_) => McpToolResult.text('ok'),
      risk: risk,
      groups: groups,
    );

void main() {
  group('approval gate', () {
    const a = ApprovalDecision.allow, q = ApprovalDecision.ask, h = ApprovalDecision.hidden;
    const expected = {
      ApprovalMode.plan: [a, a, h, h, h],
      ApprovalMode.ask: [a, a, q, q, q],
      ApprovalMode.acceptEdits: [a, a, a, q, q],
      ApprovalMode.auto: [a, a, a, a, a],
    };
    for (final mode in ApprovalMode.values) {
      test('${mode.name} across readOnly, editorState, mutating, destructive, external', () {
        expect([for (final r in McpToolRisk.values) ApprovalGate.table(r, mode)], expected[mode]);
      });
    }

    test('"always allow in this chat" turns ask into allow for that tool only', () {
      final gate = ApprovalGate();
      final spawn = _tool('spawn_actor', McpToolRisk.mutating, {McpToolGroups.level});
      final delete = _tool('delete_actors', McpToolRisk.mutating, {McpToolGroups.level});
      expect(gate.decide(spawn), ApprovalDecision.ask);
      gate.alwaysAllow('spawn_actor');
      expect(gate.decide(spawn), ApprovalDecision.allow);
      expect(gate.decide(delete), ApprovalDecision.ask);
      gate.mode = ApprovalMode.plan;
      expect(gate.decide(spawn), ApprovalDecision.hidden, reason: 'plan mode still hides it');
    });
  });

  group('toolset selector', () {
    const selector = ToolsetSelector(maxTools: 4);
    final tools = [
      _tool('list_actors', McpToolRisk.readOnly, {McpToolGroups.level}),
      _tool('spawn_actor_from_asset', McpToolRisk.mutating, {McpToolGroups.level}),
      _tool('add_blueprint_node', McpToolRisk.mutating, {McpToolGroups.blueprint}),
      _tool('list_assets', McpToolRisk.readOnly, {McpToolGroups.asset}),
      _tool('project_info', McpToolRisk.readOnly, {McpToolGroups.core}),
      _tool('undo', McpToolRisk.mutating, {McpToolGroups.core}),
    ];

    test('the groups follow the words; level when nothing matches', () {
      expect(selector.groupsFor('Place three barrels in the level'), {McpToolGroups.level});
      expect(selector.groupsFor('Add a node to the Blueprint graph'), {McpToolGroups.blueprint});
      expect(selector.groupsFor('hello there'), {McpToolGroups.level, McpToolGroups.asset, McpToolGroups.view},
          reason: 'nothing matches: the core working set, not level alone');
    });

    test('Turkish requests find their groups (stems, Turkish case folding)', () {
      expect(selector.groupsFor('Oyunu oynat ve test et'), contains(McpToolGroups.pie));
      expect(selector.groupsFor('Sahneye üç varil yerleştir'), contains(McpToolGroups.level));
      expect(selector.groupsFor('ekran görüntüsü al'), contains(McpToolGroups.view));
      expect(selector.groupsFor('Malzemenin rengini kırmızı yap'), contains(McpToolGroups.material));
      expect(selector.groupsFor('IŞIK ekle'), contains(McpToolGroups.level));
      expect(selector.groupsFor('İçeriği listele'), contains(McpToolGroups.asset));
      expect(selector.groupsFor('Hata günlüğünü göster'), contains(McpToolGroups.log));
      expect(selector.groupsFor("bu blueprint'e bir değişken ekle"), containsAll([McpToolGroups.blueprint, McpToolGroups.level]));
      expect(selector.groupsFor('oyunu çalıştır ve dene'), {McpToolGroups.pie});
    });

    test('Spanish, German and French requests too', () {
      expect(selector.groupsFor('añadir un cubo a la escena'), contains(McpToolGroups.level));
      expect(selector.groupsFor('Spiel starten'), contains(McpToolGroups.pie));
      expect(selector.groupsFor('ajouter une lumière à la scène'), contains(McpToolGroups.level));
    });

    test('the fallback leaves out a disabled group', () {
      const noView = ToolsetSelector(disabledGroups: {McpToolGroups.view});
      expect(noView.groupsFor('merhaba'), {McpToolGroups.level, McpToolGroups.asset});
    });

    test('Turkish verbs point at tool names: "ekle" puts spawn first', () {
      final picked = selector.select([
        _tool('list_actors', McpToolRisk.readOnly, {McpToolGroups.level}),
        _tool('spawn_actor', McpToolRisk.mutating, {McpToolGroups.level}),
      ], 'Sahneye küp ekle', ApprovalGate()).map((t) => t.name).toList();
      expect(picked, ['spawn_actor', 'list_actors']);
    });

    test('change requests, and the tools Plan mode hides for a request', () {
      expect(ToolsetSelector.asksForChanges('Sahneye küp ekle'), isTrue);
      expect(ToolsetSelector.asksForChanges('Place three barrels'), isTrue);
      expect(ToolsetSelector.asksForChanges('How many actors are there?'), isFalse);
      expect(ToolsetSelector.asksForChanges('Sahnede kaç aktör var?'), isFalse);
      final hidden = selector.hiddenFor(tools, 'Place three barrels in the level', ApprovalGate(mode: ApprovalMode.plan)).map((t) => t.name);
      expect(hidden, ['spawn_actor_from_asset']);
      expect(selector.hiddenFor(tools, 'Place three barrels in the level', ApprovalGate()), isEmpty);
    });

    test('the request\'s groups first, then core, capped; plan drops the changes', () {
      final picked = selector.select(tools, 'Place three barrels in the level', ApprovalGate()).map((t) => t.name).toList();
      expect(picked.first, 'spawn_actor_from_asset', reason: 'shares a word with the request');
      expect(picked, containsAll(['list_actors', 'project_info']));
      expect(picked, isNot(contains('add_blueprint_node')));
      expect(picked.length, lessThanOrEqualTo(4));
      final plan = selector.select(tools, 'Place three barrels', ApprovalGate(mode: ApprovalMode.plan)).map((t) => t.name);
      expect(plan, isNot(contains('spawn_actor_from_asset')));
      expect(plan, isNot(contains('undo')));
    });

    test('get_lumina_guide is always picked first, in every mode, ahead of the cap', () {
      final guide = _tool(LuminaPrimer.guideTool, McpToolRisk.readOnly, {McpToolGroups.core});
      final many = [
        for (var i = 0; i < 6; i++) _tool('list_things_$i', McpToolRisk.readOnly, {McpToolGroups.level}),
        _tool('list_assets', McpToolRisk.readOnly, {McpToolGroups.asset}),
        ...tools,
        guide,
      ];
      for (final mode in ApprovalMode.values) {
        for (final request in ['Place three barrels in the level', 'merhaba', 'Add a node to the Blueprint graph']) {
          final picked = selector.select(many, request, ApprovalGate(mode: mode)).map((t) => t.name).toList();
          expect(picked.first, LuminaPrimer.guideTool, reason: '${mode.name}: $request');
          expect(picked.length, lessThanOrEqualTo(4));
        }
      }
      const noLevel = ToolsetSelector(maxTools: 3, disabledGroups: {McpToolGroups.level, McpToolGroups.asset});
      expect(noLevel.select(many, 'Place three barrels', ApprovalGate()).first.name, LuminaPrimer.guideTool,
          reason: 'core stays when the project disables groups');
      expect(selector.select(tools, 'Place three barrels in the level', ApprovalGate()).map((t) => t.name),
          isNot(contains(LuminaPrimer.guideTool)), reason: 'an editor without the tool changes nothing');
    });

    // The phrasing of a real chat where a model without the input tools
    // looped on get_selection.
    final settingsTools = [
      _tool('get_selection', McpToolRisk.readOnly, {McpToolGroups.level, McpToolGroups.asset}),
      _tool('list_actors', McpToolRisk.readOnly, {McpToolGroups.level}),
      _tool('get_project_settings', McpToolRisk.readOnly, {McpToolGroups.settings}),
      _tool('edit_project_input', McpToolRisk.mutating, {McpToolGroups.settings}),
      _tool('apply_project_settings', McpToolRisk.mutating, {McpToolGroups.settings}),
      _tool('set_project_icon', McpToolRisk.mutating, {McpToolGroups.settings}),
      _tool('add_blueprint_node', McpToolRisk.mutating, {McpToolGroups.blueprint}),
      _tool('add_component', McpToolRisk.mutating, {McpToolGroups.component}),
      _tool('start_pie', McpToolRisk.editorState, {McpToolGroups.pie}),
      _tool('project_info', McpToolRisk.readOnly, {McpToolGroups.core}),
    ];

    test('input / keys / controls / settings requests get the Project Settings tools, input first', () {
      for (final request in [
        'Input ayarlarını kontrol ediyorum',
        'Input ayarlarını düzenliyorum',
        'tuşları ayarla',
        'change the input keys',
        'edit the controls',
        'Tasten einstellen',
        'cambiar las teclas',
      ]) {
        expect(selector.groupsFor(request), contains(McpToolGroups.settings), reason: request);
      }
      const wide = ToolsetSelector(maxTools: 5);
      final picked = wide.select(settingsTools, 'Input ayarlarını düzenle', ApprovalGate(mode: ApprovalMode.auto)).map((t) => t.name).toList();
      expect(picked.take(3), containsAll(['edit_project_input', 'get_project_settings', 'apply_project_settings']));
    });

    test('game-building requests get level, Blueprint, component, settings and Play; "run the game" stays Play', () {
      const game = {McpToolGroups.level, McpToolGroups.blueprint, McpToolGroups.component, McpToolGroups.settings, McpToolGroups.pie};
      expect(selector.groupsFor('Bir endless runner oyunu oluştur'), containsAll(game));
      expect(selector.groupsFor('build an endless runner game with a character'), containsAll(game));
      expect(selector.groupsFor('karakter zıplasın'), containsAll(game));
      expect(selector.groupsFor('oyunu çalıştır ve dene'), {McpToolGroups.pie});
    });

    test('a follow-up without keywords keeps the conversation\'s toolset', () {
      const earlier = ['Bir endless runner oyunu oluştur'];
      expect(selector.groupsFor('basla'), ToolsetSelector.fallbackGroups.toSet(), reason: 'alone: the fallback');
      expect(selector.groupsFor('basla', earlier: earlier), selector.groupsFor(earlier.single));
      const wide = ToolsetSelector(maxTools: 12);
      final picked = wide.select(settingsTools, 'basla', ApprovalGate(mode: ApprovalMode.auto), earlier: earlier).map((t) => t.name);
      expect(picked, containsAll(['edit_project_input', 'add_blueprint_node', 'add_component', 'start_pie']));
    });

    test('a tool becomes an LlmToolSpec with its schema unchanged and a short description', () {
      final spec = const ToolsetSelector().specOf(tools[1]);
      expect(spec.name, 'spawn_actor_from_asset');
      expect(spec.parameters, tools[1].inputSchema);
      expect(spec.description.length, lessThanOrEqualTo(160));
    });
  });
}
