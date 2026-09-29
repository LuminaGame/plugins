import 'dart:async';

import 'package:lumina_editor_api/lumina_editor_api.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';

import 'api_keys_dialog.dart';
import 'chat_panel.dart';
import 'connect/connect_agents_dialog.dart';
import 'miniai_button_state.dart';
import 'miniai_controller.dart';
import 'settings/miniai_project_settings.dart';
import 'settings/provider_settings.dart';

/// MiniAI: the ✦ AI toolbar button and the AI Assistant right-dock panel,
/// with the model providers, the agent loop and per-project chat storage.
class LuminaPluginMiniaiPlugin extends LuminaEditorPlugin {
  static const String version = '0.1.0';

  /// The chat panel's id.
  static const String chatPanelId = 'miniai.chat';

  /// The environment Connect External Agents… resolves the home folder from
  /// (smoke tests point it at a temp dir); null = the process's.
  @visibleForTesting
  static Map<String, String>? connectEnvironment;

  MiniAiButtonState? _button;
  MiniAiController? _controller;

  /// The running session (the panel, the button and the agent share it).
  MiniAiController? get controller => _controller;

  static String _projectName(String dir) => dir.replaceAll(r'\', '/').split('/').where((s) => s.isNotEmpty).last;

  @override
  String get pluginName => 'lumina_plugin_miniai';

  @override
  void register(LuminaEditorContext context) {
    final panels = context.panels;
    // One assistant turn is one undo step.
    final level = context is LuminaEditorHostContext ? context.level : null;
    _controller?.dispose();
    // Project Settings ▸ Plugins ▸ AI Assistant.
    final projectSettings = context.pluginSettings;
    context.registerProjectSettingsSection(MiniAiProjectSettings.section(
      providers: () => [for (final p in _controller?.settings.providers ?? const <ProviderConfig>[]) (p.id, p.name)],
    ));
    final controller = _controller = MiniAiController(
      defaultMode: () => MiniAiProjectSettings.defaultMode(projectSettings.value),
      projectSettings: () => projectSettings.value,
      storage: context.storage,
      mcp: context.mcp,
      transaction: level == null ? null : (label, body) => level.runTransaction(label, body),
      level: level,
      projectName: level == null ? null : _projectName(level.projectDirPath),
    );
    unawaited(controller.load());

    context.registerPanel(
      EditorPanelDescriptor(
        id: chatPanelId,
        title: 'AI Assistant',
        icon: LucideIcons.sparkles,
        defaultDock: PanelDefaultDock.right,
        builder: (_) => ChatPanel(controller: controller),
      ),
    );

    _button?.dispose();
    final button = _button = MiniAiButtonState(panelVisibility: panels.visibility(chatPanelId), controller: controller);
    final toggle = EditorCommand(
      id: 'miniai.togglePanel',
      label: 'AI Assistant',
      icon: LucideIcons.sparkles,
      canExecute: () => true,
      execute: (_) => panels.toggle(chatPanelId),
    );
    context.registerSlotButton(EditorSlotButton(id: 'ai', slot: EditorSlot.levelToolbarAfterBlueprints, state: button.state, command: toggle));

    context.registerMenuItem(
      'Plugins/MiniAI/AI Assistant',
      EditorCommand(
        id: 'miniai.menu.togglePanel',
        label: 'AI Assistant',
        icon: LucideIcons.sparkles,
        canExecute: () => true,
        execute: (_) => panels.toggle(chatPanelId),
      ),
      options: EditorMenuItemOptions(checked: panels.visibility(chatPanelId), section: 'panel'),
    );
    // Register the editor with Antigravity / Claude Code.
    final mcp = context.mcp;
    context.registerMenuItem(
      'Plugins/MiniAI/Connect External Agents…',
      EditorCommand(
        id: 'miniai.connectAgents',
        label: 'Connect External Agents…',
        icon: LucideIcons.plug,
        canExecute: () => true,
        execute: (ctx) {
          if (ctx == null) return;
          unawaited(showConnectAgentsDialog(ctx, mcp: mcp, projectDir: level?.projectDirPath, environment: connectEnvironment));
        },
      ),
      options: const EditorMenuItemOptions(section: 'connect'),
    );
    // The stored keys, masked, with Remove.
    context.registerMenuItem(
      'Plugins/MiniAI/API Keys…',
      EditorCommand(
        id: 'miniai.apiKeys',
        label: 'API Keys…',
        icon: LucideIcons.keyRound,
        canExecute: () => true,
        execute: (ctx) {
          if (ctx == null) return;
          unawaited(showApiKeysDialog(ctx, controller.settings));
        },
      ),
      options: const EditorMenuItemOptions(section: 'connect'),
    );
    context.registerMenuItem(
      'Plugins/MiniAI/About MiniAI',
      EditorCommand(
        id: 'miniai.about',
        label: 'About MiniAI',
        canExecute: () => true,
        execute: (ctx) {
          if (ctx == null) return;
          showOverlay(
            ctx,
            const DialogConfiguration(),
            builder: (c) => AlertDialog(
              title: const Text('MiniAI'),
              content: const Text(
                'An AI assistant inside Lumina Studio: chat with a local or cloud model that works on your project '
                'through the editor\'s MCP tools.\nVersion $version · MIT License',
              ),
              actions: [PrimaryButton(onPressed: () => closeOverlay(c), child: const Text('Close'))],
            ),
          );
        },
      ),
      options: const EditorMenuItemOptions(section: 'about'),
    );
  }

  /// The last turn's chat is on disk before the project closes.
  @override
  Future<void> onProjectClosing() async => _controller?.flush();

  /// The local llama-server never outlives the editor.
  @override
  Future<void> onEditorShutdown() async => _controller?.local.stop();

  @override
  void unregister(LuminaEditorContext context) {
    _button?.dispose();
    _button = null;
    _controller?.dispose();
    _controller = null;
  }
}
