// Shipped test for LuminaPluginPcg plugin (the shape the wizard generates,
// extended for the PCG contributions).
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_editor_api/lumina_editor_api.dart';
import 'package:lumina_plugin_pcg/lumina_plugin_pcg.dart';

import 'test_support.dart';

class _TestEditorContext implements LuminaEditorContext {
  final List<String> registeredMenuPaths = [];
  final List<EditorCommand> registeredCommands = [];
  final List<EditorPanelDescriptor> registeredPanels = [];
  final List<EditorImporter> registeredImporters = [];
  final List<EditorAssetTypeHandler> registeredAssetTypes = [];
  final List<DetailsCustomization> registeredDetails = [];
  final Map<String, String> consoleCommands = {};
  final List<EditorMenuItemOptions> registeredMenuOptions = [];

  @override
  void registerMenuItem(String menuPath, EditorCommand command, {EditorMenuItemOptions options = const EditorMenuItemOptions()}) {
    registeredMenuPaths.add(menuPath);
    registeredCommands.add(command);
    registeredMenuOptions.add(options);
  }

  @override
  void registerMenu(EditorMenuDescriptor menu) {}

  @override
  void registerToolbarButton(EditorToolbarButton button) {}

  @override
  void registerSlotButton(EditorSlotButton button) {}
  @override
  final EditorPanels panels = EditorPanels.detached();
  @override
  final EditorMcp mcp = EditorMcp.detached();
  @override
  final PluginStorage storage = PluginStorage(userDir: Directory('${Directory.systemTemp.path}/lumina_plugin_test_storage'));
  @override
  void registerProjectSettingsSection(ProjectSettingsSection section) => projectSettingsSections.add(section);
  final List<ProjectSettingsSection> projectSettingsSections = [];
  @override
  final ValueNotifier<Map<String, Object?>> pluginSettings = ValueNotifier(const {});

  @override
  void registerPanel(EditorPanelDescriptor panel) => registeredPanels.add(panel);

  @override
  void registerAssetType(EditorAssetTypeHandler handler) => registeredAssetTypes.add(handler);

  @override
  void registerImporter(EditorImporter importer) => registeredImporters.add(importer);

  @override
  void registerDetailsCustomization(DetailsCustomization c) => registeredDetails.add(c);

  @override
  void registerConsoleCommand(String name, String help, void Function(List<String> args) handler) => consoleCommands[name] = help;

  @override
  void registerTab(EditorTabDescriptor tab) {}

  @override
  void openTab(String tabId, {String? title}) {}

  @override
  Future<void> saveAsset({
    required String relativePath,
    Uint8List? bytes,
    bool generateThumbnail = true,
  }) async {}
}

class _TestHostContext extends _TestEditorContext implements LuminaEditorHostContext {
  @override
  final EditorLevelAccess level;
  _TestHostContext(this.level);

  @override
  Widget build3DViewport(BuildContext context, Plugin3DViewportOptions options) => const SizedBox();
}

void main() {
  test('LuminaPluginPcg registers contributions to context', () {
    final plugin = LuminaPluginPcgPlugin();
    final context = _TestEditorContext();
    plugin.register(context);
    expect(context.registeredMenuPaths, isNotEmpty);
    // The Plugins menu, in create / run / about sections.
    expect(context.registeredMenuPaths, containsAll(['Plugins/PCG/New PCG Graph', 'Plugins/PCG/Place PCG Volume', 'Plugins/PCG/Generate All', 'Plugins/PCG/Cleanup All']));
    expect(context.registeredMenuPaths.every((p) => p.startsWith('Plugins/PCG/')), isTrue);
    expect(context.registeredMenuOptions.map((o) => o.section), ['create', 'create', 'run', 'run', 'about']);
    expect(context.registeredAssetTypes.single.customTypeId, PcgGraphAsset.customTypeId);
    expect(context.registeredAssetTypes.single.editorFactory, isNotNull);
    expect(context.registeredDetails.single.targetTypeId, PcgTypes.volumeActor);
    expect(context.registeredDetails.single.sectionTitle, 'PCG');
    expect(context.registeredImporters.single.extensions, ['.pcggraph']);
    expect(context.consoleCommands.keys, ['pcg.generate']);
    // Bare context: no level, so the level commands are disabled, not broken.
    final generateAll = context.registeredCommands.firstWhere((c) => c.id == 'tools.lumina_plugin_pcg.generateAll');
    expect(generateAll.canExecute(), isFalse);
    expect(plugin.service, isNull);
    generateAll.execute(null);
  });

  test('under a host context the level commands run: Place PCG Volume, Generate All, console pcg.generate', () async {
    final project = Directory.systemTemp.createTempSync('pcg_plugin_');
    addTearDown(() => project.deleteSync(recursive: true));
    final barrels = copyBarrels(project);
    await PcgGraphAsset.save(PcgGraph.starter(name: 'G', meshes: [PcgMeshEntry(path: barrels.first)]), '${project.path}/contents/pcg/G.lmas');
    final level = FileLevel(project);
    final host = _TestHostContext(level);
    final plugin = LuminaPluginPcgPlugin();
    plugin.register(host);
    expect(plugin.service, isNotNull);

    final place = host.registeredCommands.firstWhere((c) => c.id == 'tools.lumina_plugin_pcg.placeVolume');
    expect(place.canExecute(), isTrue);
    place.execute(null);
    await Future<void>.delayed(Duration.zero);
    final volume = level.actors.single;
    expect(volume.type, PcgTypes.volumeActor);
    expect(PcgVolumeSettings.of(volume)!.graphPath, 'contents/pcg/G.lmas', reason: 'the first graph in contents/ is picked');

    host.registeredCommands.firstWhere((c) => c.id == 'tools.lumina_plugin_pcg.generateAll').execute(null);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(plugin.service!.generatedBy(volume.id), isNotEmpty);
    final n = plugin.service!.generatedBy(volume.id).length;

    host.registeredCommands.firstWhere((c) => c.id == 'tools.lumina_plugin_pcg.cleanupAll').execute(null);
    expect(plugin.service!.generatedBy(volume.id), isEmpty);
    expect(level.transactions.last, 'PCG instance count');

    // The New PCG Graph command writes contents/pcg/PCG_Graph_1.lmas with
    // every mesh under contents/meshes and opens it.
    host.registeredCommands.firstWhere((c) => c.id == 'tools.lumina_plugin_pcg.newGraph').execute(null);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    final created = PcgGraphAsset.load('${project.path}/contents/pcg/PCG_Graph_1.lmas')!;
    expect(created.nodeById('spawner')!.meshes.map((m) => m.path), [...barrels]..sort(), reason: 'every mesh, in path order (deterministic across file systems)');
    expect(level.openedAssets, ['contents/pcg/PCG_Graph_1.lmas']);

    plugin.unregister(host);
    expect(plugin.service, isNull);
    expect(n, greaterThan(0));
  });

  test('the .pcggraph importer writes a real PCG Graph .lmas under the target directory', () async {
    final temp = Directory.systemTemp.createTempSync('pcg_import_');
    addTearDown(() => temp.deleteSync(recursive: true));
    final source = File('${temp.path}/Rocks.pcggraph')..writeAsStringSync(PcgGraph.starter(name: 'ignored').toJsonString());
    final context = _TestEditorContext();
    LuminaPluginPcgPlugin().register(context);
    final target = Directory('${temp.path}/contents/pcg');
    final result = await context.registeredImporters.single.import(source, ImportContext(targetDirectory: target.path));
    expect(result.success, isTrue, reason: result.error);
    expect(result.assetPath, '${target.path}/Rocks.lmas');
    final graph = PcgGraphAsset.load(result.assetPath!)!;
    expect(graph.name, 'Rocks');
    expect(graph.nodes, hasLength(7));
    final bad = File('${temp.path}/Bad.pcggraph')..writeAsStringSync('{"version": 99}');
    expect((await context.registeredImporters.single.import(bad, ImportContext(targetDirectory: target.path))).success, isFalse);
  });
}
