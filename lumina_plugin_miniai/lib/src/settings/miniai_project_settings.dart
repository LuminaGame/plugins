import 'package:lumina_editor_api/lumina_editor_api.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';

import 'package:lumina_plugin_miniai/src/agent/agent_loop.dart';
import 'package:lumina_plugin_miniai/src/agent/approval.dart';

/// Project Settings ▸ Plugins ▸ AI Assistant:
/// MiniAI's settings shared with the project
/// (`plugin_settings.lumina_plugin_miniai`). Keys and other secrets stay in
/// the user store.
class MiniAiProjectSettings {
  const MiniAiProjectSettings._();

  static const String defaultModeKey = 'defaultMode';
  static const String providerKey = 'provider';
  static const String disabledToolGroupsKey = 'disabledToolGroups';
  static const String maxRoundsKey = 'maxRounds';
  static const String projectNotesKey = 'projectNotes';
  static const String attachSelectionKey = 'attachSelection';

  /// The groups a project can switch off (`core` never).
  static const List<String> toggleableGroups = [
    McpToolGroups.level,
    McpToolGroups.asset,
    McpToolGroups.material,
    McpToolGroups.blueprint,
    McpToolGroups.component,
    McpToolGroups.pie,
    McpToolGroups.view,
    McpToolGroups.log,
    McpToolGroups.plugin,
  ];

  /// The mode a new chat starts in; Ask when unset or unknown.
  static ApprovalMode defaultMode(Map<String, Object?> values) =>
      ApprovalMode.values.where((m) => m.name == values[defaultModeKey]).firstOrNull ?? ApprovalMode.ask;

  /// The provider id the project prefers, or null.
  static String? provider(Map<String, Object?> values) {
    final v = values[providerKey];
    return v is String && v.isNotEmpty ? v : null;
  }

  static Set<String> disabledToolGroups(Map<String, Object?> values) => {
        for (final g in (values[disabledToolGroupsKey] as List? ?? const []))
          if (g is String && g != McpToolGroups.core) g,
      };

  /// Rounds per turn, or null for the built-in default.
  static int? maxRounds(Map<String, Object?> values) {
    final v = values[maxRoundsKey];
    final n = v is int ? v : (v is num ? v.toInt() : int.tryParse('$v'));
    return n != null && n >= 1 ? n : null;
  }

  /// Whether messages carry the editor selection (on unless turned off).
  static bool attachSelection(Map<String, Object?> values) => values[attachSelectionKey] != false;

  static String? projectNotes(Map<String, Object?> values) {
    final v = values[projectNotesKey];
    if (v is! String || v.trim().isEmpty) return null;
    return v.length <= AgentLoop.maxProjectNotes ? v : v.substring(0, AgentLoop.maxProjectNotes);
  }

  /// The page; [providers] lists this user's providers as (id, name).
  static ProjectSettingsSection section({List<(String, String)> Function()? providers}) => ProjectSettingsSection(
        id: 'miniai',
        title: 'AI Assistant',
        icon: LucideIcons.sparkles,
        keywords: const ['ai', 'assistant', 'miniai', 'approval', 'mode', 'chat', 'provider', 'tool groups', 'rounds', 'notes', 'selection', 'context'],
        builder: (context, settings) => MiniAiSettingsPage(settings: settings, providers: providers?.call() ?? const []),
      );
}

class MiniAiSettingsPage extends StatefulWidget {
  const MiniAiSettingsPage({super.key, required this.settings, this.providers = const []});

  final PluginSettingsHandle settings;
  final List<(String, String)> providers;

  @override
  State<MiniAiSettingsPage> createState() => _MiniAiSettingsPageState();
}

class _MiniAiSettingsPageState extends State<MiniAiSettingsPage> {
  late final TextEditingController _rounds;
  late final TextEditingController _notes;

  PluginSettingsHandle get settings => widget.settings;

  @override
  void initState() {
    super.initState();
    _rounds = TextEditingController(text: MiniAiProjectSettings.maxRounds(settings.values)?.toString() ?? '');
    _notes = TextEditingController(text: settings.get<String>(MiniAiProjectSettings.projectNotesKey) ?? '');
  }

  @override
  void dispose() {
    _rounds.dispose();
    _notes.dispose();
    super.dispose();
  }

  Widget _row(String label, Widget field, {String? help}) {
    final muted = Theme.of(context).colorScheme.mutedForeground;
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 200, child: Padding(padding: const EdgeInsets.only(top: 6), child: Text(label, style: const TextStyle(fontSize: 11)))),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                field,
                if (help != null) ...[const SizedBox(height: 4), Text(help, style: TextStyle(fontSize: 10, color: muted))],
              ],
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: settings.changes,
      builder: (context, _) {
        final values = settings.values;
        final mode = MiniAiProjectSettings.defaultMode(values);
        final provider = MiniAiProjectSettings.provider(values);
        final disabled = MiniAiProjectSettings.disabledToolGroups(values);
        final knownProvider = provider == null || widget.providers.any((p) => p.$1 == provider);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _row(
              'Default mode for new chats',
              SizedBox(
                width: 360,
                child: Select<ApprovalMode>(
                  key: const ValueKey('miniai_settings_default_mode'),
                  value: mode,
                  onChanged: (m) => settings.set(MiniAiProjectSettings.defaultModeKey, m == null || m == ApprovalMode.ask ? null : m.name),
                  itemBuilder: (_, m) => Text('${m.label} — ${m.help}', style: const TextStyle(fontSize: 11)),
                  popup: SelectPopup(
                    items: SelectItemList(children: [
                      for (final m in ApprovalMode.values)
                        SelectItemButton(
                          key: ValueKey('miniai_settings_mode_${m.name}'),
                          value: m,
                          child: Text('${m.label} — ${m.help}', style: const TextStyle(fontSize: 11)),
                        ),
                    ]),
                  ).call,
                ),
              ),
              help: 'A chat can still switch modes.',
            ),
            _row(
              'Preferred model provider',
              SizedBox(
                width: 360,
                child: Select<String>(
                  key: const ValueKey('miniai_settings_provider'),
                  value: provider ?? '',
                  onChanged: (id) => settings.set(MiniAiProjectSettings.providerKey, id == null || id.isEmpty ? null : id),
                  itemBuilder: (_, id) => Text(
                    id.isEmpty ? 'Each user\'s own choice' : widget.providers.where((p) => p.$1 == id).firstOrNull?.$2 ?? '$id (not set up on this machine)',
                    style: const TextStyle(fontSize: 11),
                  ),
                  popup: SelectPopup(
                    items: SelectItemList(children: [
                      const SelectItemButton(value: '', child: Text('Each user\'s own choice', style: TextStyle(fontSize: 11))),
                      for (final (id, name) in widget.providers)
                        SelectItemButton(key: ValueKey('miniai_settings_provider_$id'), value: id, child: Text(name, style: const TextStyle(fontSize: 11))),
                    ]),
                  ).call,
                ),
              ),
              help: knownProvider
                  ? 'Used for this project when the user has a provider with this id; their own saved choice is not changed.'
                  : '"$provider" is not set up on this machine; each user\'s own choice is used.',
            ),
            _row(
              'Tool groups the assistant never gets',
              Wrap(
                spacing: 14,
                runSpacing: 6,
                children: [
                  for (final g in MiniAiProjectSettings.toggleableGroups)
                    Checkbox(
                      key: ValueKey('miniai_settings_group_$g'),
                      state: disabled.contains(g) ? CheckboxState.checked : CheckboxState.unchecked,
                      onChanged: (s) {
                        final next = {...disabled};
                        s == CheckboxState.checked ? next.add(g) : next.remove(g);
                        settings.set(MiniAiProjectSettings.disabledToolGroupsKey, next.isEmpty ? null : (next.toList()..sort()));
                      },
                      trailing: Text(g, style: const TextStyle(fontSize: 11)),
                    ),
                ],
              ),
              help: 'In every mode. The core tools (listing, help) always stay.',
            ),
            _row(
              'Editor selection',
              Checkbox(
                key: const ValueKey('miniai_settings_attach_selection'),
                state: MiniAiProjectSettings.attachSelection(values) ? CheckboxState.checked : CheckboxState.unchecked,
                onChanged: (s) => settings.set(MiniAiProjectSettings.attachSelectionKey, s == CheckboxState.checked ? null : false),
                trailing: const Text('Attach the editor selection to messages', style: TextStyle(fontSize: 11)),
              ),
              help: 'The selected actors and assets go with each message as context; the chip above the message box can drop them for one message.',
            ),
            _row(
              'Max tool rounds per turn',
              SizedBox(
                width: 120,
                child: TextField(
                  key: const ValueKey('miniai_settings_max_rounds'),
                  controller: _rounds,
                  placeholder: const Text('Default'),
                  onChanged: (t) {
                    final n = int.tryParse(t.trim());
                    settings.set(MiniAiProjectSettings.maxRoundsKey, n != null && n >= 1 ? n : null);
                  },
                ),
              ),
              help: 'Empty: 6 for a local model, 25 for a cloud model.',
            ),
            _row(
              'Project notes',
              TextArea(
                key: const ValueKey('miniai_settings_notes'),
                controller: _notes,
                initialHeight: 90,
                placeholder: const Text('e.g. Every actor name starts with BP_.'),
                onChanged: (t) => settings.set(MiniAiProjectSettings.projectNotesKey, t.trim().isEmpty ? null : t),
              ),
              help: 'Added to the assistant\'s instructions for everyone who opens this project (up to ${AgentLoop.maxProjectNotes} characters).',
            ),
          ],
        );
      },
    );
  }
}
