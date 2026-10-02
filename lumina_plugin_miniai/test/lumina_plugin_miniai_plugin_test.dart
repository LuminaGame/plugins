// What the plugin registers, and the AI button's live state.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show ValueNotifier;
import 'package:flutter_test/flutter_test.dart';
import 'package:lumina/lumina.dart' show PluginRepository, PluginOrigin;
import 'package:lumina_editor_api/lumina_editor_api.dart';
import 'package:lumina_plugin_miniai/lumina_plugin_miniai.dart';

class _TestEditorContext implements LuminaEditorContext {
  final Map<String, (EditorCommand, EditorMenuItemOptions)> menu = {};
  final List<EditorPanelDescriptor> registeredPanels = [];
  final List<EditorSlotButton> slotButtons = [];

  @override
  void registerMenuItem(String menuPath, EditorCommand command, {EditorMenuItemOptions options = const EditorMenuItemOptions()}) =>
      menu[menuPath] = (command, options);

  @override
  void registerMenu(EditorMenuDescriptor menu) {}

  @override
  void registerToolbarButton(EditorToolbarButton button) {}

  @override
  void registerSlotButton(EditorSlotButton button) => slotButtons.add(button);

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
  void registerAssetType(EditorAssetTypeHandler handler) {}

  @override
  void registerImporter(EditorImporter importer) {}

  @override
  void registerDetailsCustomization(DetailsCustomization c) {}

  @override
  void registerConsoleCommand(String name, String help, void Function(List<String> args) handler) {}

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

void main() {
  late _TestEditorContext context;

  setUp(() {
    context = _TestEditorContext();
    LuminaPluginMiniaiPlugin().register(context);
  });

  test('registers the AI Assistant right-dock panel, the AI slot button and the MiniAI menu', () {
    final panel = context.registeredPanels.single;
    expect(panel.id, 'miniai.chat');
    expect(panel.title, 'AI Assistant');
    expect(panel.defaultDock, PanelDefaultDock.right);

    final button = context.slotButtons.single;
    expect(button.id, 'ai');
    expect(button.slot, EditorSlot.levelToolbarAfterBlueprints);
    expect(button.state.value.label, 'AI');

    expect(context.menu.keys, containsAll(['Plugins/MiniAI/AI Assistant', 'Plugins/MiniAI/About MiniAI']));
    expect(context.menu['Plugins/MiniAI/AI Assistant']!.$2.checked, isNotNull);
  });

  test('the AI button is warning-toned until a provider exists, and active while the panel is open', () async {
    final state = context.slotButtons.single.state;
    expect(state.value.active, isFalse);
    expect(state.value.tone, EditorTone.warning);
    expect(state.value.tooltip, contains('No model provider'));

    context.panels.show('miniai.chat');
    expect(state.value.active, isTrue);
    expect(context.menu['Plugins/MiniAI/AI Assistant']!.$2.checked!.value, isTrue);

    await context.slotButtons.single.command.execute(null);
    expect(context.panels.isVisible('miniai.chat'), isFalse, reason: 'the button toggles the panel');
    expect(state.value.active, isFalse);
  });

  test('the manifest parses with lumina and declares MIT and the changelog', () async {
    final descriptor = await PluginRepository(roots: []).loadInternal(File('lumina_plugin_miniai.lmplugin'), PluginOrigin.engine);
    expect(descriptor.name, 'lumina_plugin_miniai');
    expect(descriptor.friendlyName, 'MiniAI');
    expect(descriptor.modules.single.registrationClass, 'LuminaPluginMiniaiPlugin');
    final manifest = File('lumina_plugin_miniai.lmplugin').readAsStringSync();
    expect(manifest, contains('"license": "MIT"'));
    expect(manifest, contains('"changelog": "CHANGELOG.md"'));
    expect(File('LICENSE').readAsStringSync(), startsWith('MIT License'));
  });

  // Project Settings ▸ Plugins ▸ AI Assistant.
  test('registers the AI Assistant project settings page; new chats follow its default mode', () {
    context.projectSettingsSections.clear();
    final plugin = LuminaPluginMiniaiPlugin();
    plugin.register(context);
    expect(context.projectSettingsSections.map((s) => (s.id, s.title)), [('miniai', 'AI Assistant')]);
    expect(context.projectSettingsSections.single.keywords, contains('approval'));
    final c = plugin.controller!;
    expect(c.chat.gate.mode, ApprovalMode.ask, reason: 'unset → Ask');

    context.pluginSettings.value = {'defaultMode': 'plan'};
    c.newChat();
    expect(c.chat.gate.mode, ApprovalMode.plan, reason: 'an empty chat takes up the default');
    context.pluginSettings.value = {'defaultMode': 'acceptEdits'};
    c.chat.items.add(UserItem('something'));
    c.newChat();
    expect(c.chat.gate.mode, ApprovalMode.acceptEdits);
    expect(c.chat.items, isEmpty);
    expect(MiniAiProjectSettings.defaultMode({'defaultMode': 'nonsense'}), ApprovalMode.ask);
    plugin.unregister(context);
  });
}
