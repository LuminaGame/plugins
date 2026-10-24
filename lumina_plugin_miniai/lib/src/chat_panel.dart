import 'package:flutter/services.dart' show LogicalKeyboardKey, HardwareKeyboard, KeyDownEvent;
import 'package:lumina_editor_api/lumina_editor_api.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';

import 'package:lumina_plugin_miniai/src/agent/approval.dart';
import 'package:lumina_plugin_miniai/src/agent/chat.dart';
import 'package:lumina_plugin_miniai/src/claude_code/claude_code_protocol.dart';
import 'package:lumina_plugin_miniai/src/context/editor_context.dart';
import 'package:lumina_plugin_miniai/src/history_view.dart';
import 'package:lumina_plugin_miniai/src/local/local_model_manager.dart';
import 'package:lumina_plugin_miniai/src/local_model_section.dart';
import 'package:lumina_plugin_miniai/src/markdown_view.dart';
import 'package:lumina_plugin_miniai/src/miniai_controller.dart';
import 'package:lumina_plugin_miniai/src/provider_dialog.dart';
import 'package:lumina_plugin_miniai/src/thinking_row.dart';
import 'package:lumina_plugin_miniai/src/tool_card_parts.dart';
import 'package:lumina_plugin_miniai/src/tool_images.dart';

part 'chat_panel/composer_sections.dart';
part 'chat_panel/conversation_items.dart';
part 'chat_panel/tool_call_card.dart';

/// The AI Assistant panel, right-docked as `miniai.chat`: the
/// chat title, mode and model; the conversation with tool-call and approval
/// cards; the composer with Stop; and a status line.
class ChatPanel extends StatefulWidget {
  const ChatPanel({super.key, required this.controller});

  final MiniAiController controller;

  @override
  State<ChatPanel> createState() => _ChatPanelState();
}

class _ChatPanelState extends State<ChatPanel> {
  final TextEditingController _message = TextEditingController();
  final ScrollController _scroll = ScrollController();
  final TextEditingController _title = TextEditingController();
  final FocusNode _titleFocus = FocusNode();

  /// History replaces the conversation.
  bool _history = false;
  bool _editingTitle = false;

  /// The highlighted row of the `/` command list.
  int _slashIndex = 0;

  /// Escape closed the list until the text changes.
  String? _slashDismissed;

  /// The highlighted row of the `@` list.
  int _mentionIndex = 0;

  /// Escape closed the `@` list until the text changes.
  String? _mentionDismissed;

  /// The mentions picked from the `@` list for the message being typed.
  final List<MentionCandidate> _picked = [];

  MiniAiController get c => widget.controller;

  @override
  void initState() {
    super.initState();
    c.addListener(_changed);
    c.mcp.toolsChanged.addListener(_changed);
    c.selection
      ..addListener(_selectionChanged)
      ..watch();
    _message.addListener(_messageChanged);
    _titleFocus.addListener(() {
      if (!_titleFocus.hasFocus && _editingTitle) _saveTitle();
    });
  }

  void _startTitleEdit() {
    if (c.running) return;
    _title.text = c.chat.title;
    setState(() => _editingTitle = true);
    WidgetsBinding.instance.addPostFrameCallback((_) => _titleFocus.requestFocus());
  }

  void _saveTitle() {
    setState(() => _editingTitle = false);
    c.renameChat(c.chat.id, _title.text);
  }

  Widget _header(BuildContext context) {
    final chat = c.chat;
    final island = EditorIslandThemeData.active;
    return Container(
      height: EditorIslandStyle.headerHeight,
      padding: const EdgeInsets.only(left: 12, right: 6),
      decoration: BoxDecoration(border: Border(bottom: BorderSide(color: island.border))),
      child: Row(
        children: [
          Expanded(
            child: _editingTitle
                ? TextField(
                    key: const ValueKey('miniai_chat_title_field'),
                    controller: _title,
                    focusNode: _titleFocus,
                    onSubmitted: (_) => _saveTitle(),
                    style: const TextStyle(fontSize: 12),
                  )
                : GestureDetector(
                    onTap: _history ? null : _startTitleEdit,
                    child: Text(
                      _history ? 'History' : chat.title,
                      key: const ValueKey('miniai_chat_title'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: island.ui(fontSize: 12, color: island.foreground, fontWeight: _history ? FontWeight.w700 : FontWeight.w600),
                    ),
                  ),
          ),
          const SizedBox(width: 4),
          Tooltip(
            tooltip: (_) => const TooltipContainer(child: Text('New chat')),
            child: IconButton.ghost(
              key: const ValueKey('miniai_new_chat'),
              density: ButtonDensity.iconDense,
              icon: const Icon(LucideIcons.plus, size: 14),
              onPressed: c.running
                  ? null
                  : () {
                      c.newChat();
                      setState(() => _history = false);
                    },
            ),
          ),
          Tooltip(
            tooltip: (_) => const TooltipContainer(child: Text('History')),
            child: _history
                ? IconButton.secondary(
                    key: const ValueKey('miniai_history'),
                    density: ButtonDensity.iconDense,
                    icon: const Icon(LucideIcons.history, size: 14),
                    onPressed: () => setState(() => _history = false),
                  )
                : IconButton.ghost(
                    key: const ValueKey('miniai_history'),
                    density: ButtonDensity.iconDense,
                    icon: const Icon(LucideIcons.history, size: 14),
                    onPressed: () => setState(() {
                      _history = true;
                      _editingTitle = false;
                    }),
                  ),
          ),
        ],
      ),
    );
  }

  @override
  void didUpdateWidget(ChatPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_changed);
      oldWidget.controller.mcp.toolsChanged.removeListener(_changed);
      oldWidget.controller.selection
        ..removeListener(_selectionChanged)
        ..unwatch();
      c.addListener(_changed);
      c.mcp.toolsChanged.addListener(_changed);
      c.selection
        ..addListener(_selectionChanged)
        ..watch();
    }
  }

  @override
  void dispose() {
    c.removeListener(_changed);
    c.mcp.toolsChanged.removeListener(_changed);
    c.selection
      ..removeListener(_selectionChanged)
      ..unwatch();
    _message.removeListener(_messageChanged);
    _message.dispose();
    _scroll.dispose();
    _title.dispose();
    _titleFocus.dispose();
    super.dispose();
  }

  void _changed() {
    if (!mounted) return;
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  }

  /// The selection chip changed; the conversation keeps its scroll.
  void _selectionChanged() {
    if (mounted) setState(() {});
  }

  void _send() {
    final text = _message.text;
    if (text.trim().isEmpty || c.running || !c.settings.isConfigured) return;
    final mentions = List.of(_picked);
    _picked.clear();
    _message.clear();
    c.send(text, mentions: mentions);
  }

  /// The `@…` being typed before the cursor, or null.
  String? get _mentionQuery {
    final value = _message.value;
    if (value.text == _mentionDismissed) return null;
    final end = value.selection.isValid ? value.selection.baseOffset : value.text.length;
    if (end < 0 || end > value.text.length) return null;
    return RegExp(r'(?:^|\s)@([^\s@]*)$').firstMatch(value.text.substring(0, end))?.group(1);
  }

  List<MentionCandidate> get _mentionMatches {
    final q = _mentionQuery;
    return q == null ? const [] : c.mentions.search(q);
  }

  /// Replaces the `@…` before the cursor with `@<name> ` and remembers the
  /// reference.
  void _pickMention(MentionCandidate m) {
    final value = _message.value;
    final end = value.selection.isValid ? value.selection.baseOffset : value.text.length;
    final before = value.text.substring(0, end);
    final at = before.lastIndexOf('@');
    if (at < 0) return;
    final inserted = '@${m.name} ';
    final text = value.text.replaceRange(at, end, inserted);
    if (!_picked.contains(m)) _picked.add(m);
    _message.value = TextEditingValue(text: text, selection: TextSelection.collapsed(offset: at + inserted.length));
  }

  /// The `/…` being typed (Claude Code only), or null.
  String? get _slashQuery {
    final text = _message.text;
    if (!c.usesClaudeCode || !text.startsWith('/') || text.contains(RegExp(r'\s')) || text == _slashDismissed) return null;
    return text.substring(1).toLowerCase();
  }

  /// The reported commands matching [_slashQuery]: prefix matches first.
  List<ClaudeCommand> get _slashMatches {
    final q = _slashQuery;
    if (q == null) return const [];
    final starts = [for (final cmd in c.claudeCommands) if (cmd.name.toLowerCase().startsWith(q)) cmd];
    final contains = [for (final cmd in c.claudeCommands) if (!starts.contains(cmd) && cmd.name.toLowerCase().contains(q)) cmd];
    return [...starts, ...contains];
  }

  void _messageChanged() {
    if (_slashDismissed != null && _message.text != _slashDismissed) _slashDismissed = null;
    if (_mentionDismissed != null && _message.text != _mentionDismissed) _mentionDismissed = null;
    if (_mentionQuery != null) {
      // The first `@` (or a stale list): read the project's content and actors.
      c.mentions.load().then((_) {
        if (mounted) setState(() {});
      });
    }
    _mentionIndex = 0;
    if (_slashQuery != null && c.claudeCommands.isEmpty && c.claudeError == null) {
      // The first `/`: start the chat's Claude Code process to learn its
      // commands (no model call).
      c.loadClaudeCommands();
    }
    setState(() => _slashIndex = 0);
  }

  /// Sends the chosen command as the message.
  void _sendCommand(ClaudeCommand command) {
    if (c.running) return;
    _message.clear();
    c.send('/${command.name}');
  }

  /// "N editor tools available (level, asset, …)": the groups by tool count.
  String _toolSummary() {
    final tools = c.mcp.listTools();
    final counts = <String, int>{};
    for (final t in tools) {
      for (final g in t.groups) {
        if (g == McpToolGroups.core) continue;
        counts[g] = (counts[g] ?? 0) + 1;
      }
    }
    final groups = counts.keys.toList()..sort((a, b) => counts[b]!.compareTo(counts[a]!));
    final shown = groups.take(5).join(', ');
    return '${tools.length} editor tools available${shown.isEmpty ? '' : ' ($shown${groups.length > 5 ? ', …' : ''})'}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.mutedForeground;
    final configured = c.settings.isConfigured;
    final chat = c.chat;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // The dock's header names the panel ("AI ASSISTANT"); this is the
        // chat's own title with + New and History, then its mode and model.
        _header(context),
        if (_history)
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(top: 8),
              child: HistoryView(controller: c, onOpened: () => setState(() => _history = false)),
            ),
          )
        else ...[
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
          child: Row(
            children: [
              SizedBox(
                width: 132,
                child: Select<ApprovalMode>(
                  key: const ValueKey('miniai_mode'),
                  value: c.mode,
                  onChanged: c.running ? null : (m) => m == null ? null : _setMode(context, m),
                  itemBuilder: (_, m) => Text('Mode: ${m.label}', style: const TextStyle(fontSize: 10)),
                  popup: SelectPopup(
                    items: SelectItemList(
                      children: [
                        for (final m in ApprovalMode.values)
                          SelectItemButton(
                            value: m,
                            child: Text('${m.label} — ${m.help}', style: const TextStyle(fontSize: 10)),
                          ),
                      ],
                    ),
                  ).call,
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: OutlineButton(
                  key: const ValueKey('miniai_model_chip'),
                  density: ButtonDensity.compact,
                  onPressed: () => showProviderDialog(context, c.settings, controller: c),
                  child: Text(
                    configured ? 'Model: ${c.settings.selected!.label}' : 'Set up a model provider…',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 10),
                  ),
                ),
              ),
            ],
          ),
        ),
        if (c.claudeState != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
            child: Text(
              c.claudeState!,
              key: const ValueKey('miniai_claude_state'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 10, color: muted),
            ),
          ),
        const Divider(height: 16),
        Expanded(
          child: chat.items.isEmpty
              ? Center(
                  child: SingleChildScrollView(
                    child: Padding(
                      padding: const EdgeInsets.all(20),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(LucideIcons.messageSquareDashed, size: 28, color: muted),
                          const SizedBox(height: 10),
                          Text(
                            'Ask MiniAI to build, edit or explain your level. It works through the same editor tools as external AI agents, '
                            'and every change it makes can be undone.',
                            textAlign: TextAlign.center,
                            style: TextStyle(fontSize: 11, color: muted),
                          ),
                          if (!configured || c.settings.selected?.id == MiniAiController.localProviderId) ...[
                            const SizedBox(height: 12),
                            LocalModelSection(controller: c),
                          ],
                          if (!configured) ...[
                            const SizedBox(height: 12),
                            OutlineButton(
                              key: const ValueKey('miniai_setup_provider'),
                              onPressed: () => showProviderDialog(context, c.settings, controller: c),
                              child: const Text('Use another model provider…'),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                )
              : ListView(
                  key: const ValueKey('miniai_messages'),
                  controller: _scroll,
                  padding: const EdgeInsets.all(10),
                  children: [
                    for (var i = 0; i < chat.items.length; i++) ...[
                      _item(context, chat, chat.items[i], i),
                      // "Undo this turn" under a turn's last item.
                      for (final t in chat.turns)
                        if (_turnEnd(chat, t) == i) ...[_turnFooter(context, t), _planHint(context, t)],
                    ],
                  ],
                ),
        ),
        // The local server went down mid-chat: its card, to restart it.
        if (chat.items.isNotEmpty &&
                c.settings.selected?.id == MiniAiController.localProviderId &&
                c.local.status != LocalModelStatus.ready &&
                !c.local.autostart ||
            chat.items.isNotEmpty && c.local.status == LocalModelStatus.crashed)
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 0, 10, 8),
            child: LocalModelSection(controller: c),
          ),
        const Divider(height: 1),
        Padding(
          padding: const EdgeInsets.all(10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_mentionQuery != null) _mentionMenu(context) else if (_slashQuery != null) _slashMenu(context),
              _selectionChip(context),
              _pendingQuestions(context),
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: Focus(
                      onKeyEvent: (_, event) {
                        if (event is! KeyDownEvent) return KeyEventResult.ignored;
                        if (_mentionQuery != null) {
                          final key = event.logicalKey;
                          final found = _mentionMatches;
                          if (key == LogicalKeyboardKey.escape) {
                            setState(() => _mentionDismissed = _message.text);
                            return KeyEventResult.handled;
                          }
                          if (found.isNotEmpty) {
                            if (key == LogicalKeyboardKey.arrowDown || key == LogicalKeyboardKey.arrowUp) {
                              setState(() => _mentionIndex = (_mentionIndex + (key == LogicalKeyboardKey.arrowDown ? 1 : -1)) % found.length);
                              return KeyEventResult.handled;
                            }
                            if (key == LogicalKeyboardKey.tab || (key == LogicalKeyboardKey.enter && !HardwareKeyboard.instance.isShiftPressed)) {
                              _pickMention(found[_mentionIndex.clamp(0, found.length - 1)]);
                              return KeyEventResult.handled;
                            }
                          }
                        }
                        final matches = _slashMatches;
                        if (matches.isNotEmpty) {
                          final key = event.logicalKey;
                          if (key == LogicalKeyboardKey.arrowDown || key == LogicalKeyboardKey.arrowUp) {
                            setState(() => _slashIndex = (_slashIndex + (key == LogicalKeyboardKey.arrowDown ? 1 : -1)) % matches.length);
                            return KeyEventResult.handled;
                          }
                          if (key == LogicalKeyboardKey.tab) {
                            final name = '/${matches[_slashIndex.clamp(0, matches.length - 1)].name} ';
                            _message.value = TextEditingValue(text: name, selection: TextSelection.collapsed(offset: name.length));
                            return KeyEventResult.handled;
                          }
                          if (key == LogicalKeyboardKey.escape) {
                            setState(() => _slashDismissed = _message.text);
                            return KeyEventResult.handled;
                          }
                          if (key == LogicalKeyboardKey.enter && !HardwareKeyboard.instance.isShiftPressed) {
                            _sendCommand(matches[_slashIndex.clamp(0, matches.length - 1)]);
                            return KeyEventResult.handled;
                          }
                        }
                        if (event.logicalKey == LogicalKeyboardKey.enter && !HardwareKeyboard.instance.isShiftPressed) {
                          _send();
                          return KeyEventResult.handled;
                        }
                        return KeyEventResult.ignored;
                      },
                      child: TextField(
                        key: const ValueKey('miniai_message'),
                        controller: _message,
                        enabled: configured,
                        placeholder: Text(configured ? 'Message MiniAI…  (Enter to send, Shift+Enter for a new line)' : 'Message MiniAI…'),
                        maxLines: 4,
                        minLines: 1,
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  if (c.running)
                    DestructiveButton(
                      key: const ValueKey('miniai_stop'),
                      onPressed: c.stop,
                      density: ButtonDensity.icon,
                      child: const Icon(LucideIcons.square, size: 14),
                    )
                  else
                    PrimaryButton(
                      key: const ValueKey('miniai_send'),
                      onPressed: configured ? _send : null,
                      density: ButtonDensity.icon,
                      child: const Icon(LucideIcons.sendHorizontal, size: 14),
                    ),
                ],
              ),
              const SizedBox(height: 6),
              if (!configured)
                Text(
                  'Set up a model provider to chat: a local llama-server (MiniCPM5), Ollama, LM Studio, or a cloud API.',
                  key: const ValueKey('miniai_no_provider'),
                  style: TextStyle(fontSize: 10, color: muted),
                ),
              Text(
                [
                  if (configured) c.settings.selected!.label,
                  if (c.usesClaudeCode && c.claudeUsage != null)
                    c.claudeUsage!
                  else if (chat.lastUsage != null)
                    '${chat.lastUsage!.promptTokens + chat.lastUsage!.completionTokens} tokens last turn',
                  _toolSummary(),
                ].join(' · '),
                key: const ValueKey('miniai_tool_summary'),
                style: TextStyle(fontSize: 10, color: muted),
              ),
            ],
          ),
        ),
        ],
      ],
    );
  }
}
