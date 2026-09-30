import 'package:flutter/services.dart' show LogicalKeyboardKey, HardwareKeyboard, KeyDownEvent;
import 'package:lumina_editor_api/lumina_editor_api.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';

import 'agent/approval.dart';
import 'agent/chat.dart';
import 'claude_code/claude_code_protocol.dart';
import 'context/editor_context.dart';
import 'history_view.dart';
import 'local/local_model_manager.dart';
import 'local_model_section.dart';
import 'markdown_view.dart';
import 'miniai_controller.dart';
import 'provider_dialog.dart';
import 'thinking_row.dart';
import 'tool_card_parts.dart';
import 'tool_images.dart';

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
    final theme = Theme.of(context);
    final chat = c.chat;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 6, 0),
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
                      style: TextStyle(fontSize: 12, color: theme.colorScheme.foreground, fontWeight: _history ? FontWeight.w600 : null),
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

  void _setMode(BuildContext context, ApprovalMode mode) {
    if (mode != ApprovalMode.auto) {
      c.mode = mode;
      return;
    }
    showOverlay<void>(
      context,
      const DialogConfiguration(),
      builder: (d) => AlertDialog(
        title: const Text('Run every tool without asking?'),
        content: const Text(
          'In Auto mode MiniAI deletes, overwrites and reaches outside the project without asking. '
          'Level edits can still be undone; files it removes go to the project trash.',
        ),
        actions: [
          GhostButton(onPressed: () => closeOverlay(d), child: const Text('Cancel')),
          DestructiveButton(
            key: const ValueKey('miniai_auto_confirm'),
            onPressed: () {
              c.mode = ApprovalMode.auto;
              closeOverlay(d);
            },
            child: const Text('Use Auto'),
          ),
        ],
      ),
    );
  }

  static IconData _mentionIcon(MentionCandidate m) => switch (m.kind) {
        MentionKind.folder => LucideIcons.folder,
        MentionKind.actor => LucideIcons.shapes,
        MentionKind.asset => switch (m.type) {
            'filamesh' || 'staticMesh' || 'skeletalMesh' => LucideIcons.box,
            'texture' => LucideIcons.image,
            'filamat' || 'material' || 'materialInstance' => LucideIcons.palette,
            'actor' || 'blueprint' => LucideIcons.puzzle,
            'level' => LucideIcons.map,
            'sound' || 'audio' => LucideIcons.audioLines,
            'animation' || 'animSequence' => LucideIcons.film,
            'skeleton' => LucideIcons.bone,
            _ => LucideIcons.file,
          },
      };

  /// The project's assets, folders and actors matching the `@…` typed so
  /// far; a click (or Enter / Tab) inserts one.
  Widget _mentionMenu(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.mutedForeground;
    final matches = _mentionMatches;
    final Widget body;
    if (matches.isEmpty) {
      body = Padding(
        padding: const EdgeInsets.all(8),
        child: Text(
          c.mentions.candidates.isEmpty ? 'Reading the project…' : 'No asset, folder or actor matches.',
          style: TextStyle(fontSize: 10, color: muted),
        ),
      );
    } else {
      body = ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.symmetric(vertical: 4),
        children: [
          for (var i = 0; i < matches.length; i++)
            GestureDetector(
              key: ValueKey('miniai_mention_${matches[i].kind.name}_$i'),
              onTap: () => _pickMention(matches[i]),
              child: Container(
                color: i == _mentionIndex ? theme.colorScheme.accent : null,
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                child: Row(
                  children: [
                    Icon(_mentionIcon(matches[i]), size: 12, color: muted),
                    const SizedBox(width: 6),
                    Text(matches[i].name, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600)),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        [
                          if (matches[i].type != null) matches[i].type!,
                          matches[i].path ?? (matches[i].kind == MentionKind.actor ? 'actor in the level' : ''),
                        ].where((s) => s.isNotEmpty).join(' · '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 10, color: muted),
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      );
    }
    return Container(
      key: const ValueKey('miniai_mention_menu'),
      margin: const EdgeInsets.only(bottom: 6),
      constraints: const BoxConstraints(maxHeight: 220),
      decoration: BoxDecoration(
        color: theme.colorScheme.popover,
        border: Border.all(color: theme.colorScheme.border),
        borderRadius: BorderRadius.circular(6),
      ),
      child: body,
    );
  }

  /// The editor selection that goes with the next message; ✕ drops it for
  /// that message.
  Widget _selectionChip(BuildContext context) {
    final selection = c.selection.attachable;
    final label = selection?.label;
    if (label == null || !c.attachSelection) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        key: const ValueKey('miniai_selection_chip'),
        margin: const EdgeInsets.only(bottom: 6),
        padding: const EdgeInsets.fromLTRB(8, 2, 2, 2),
        decoration: BoxDecoration(
          color: theme.colorScheme.muted,
          border: Border.all(color: theme.colorScheme.border),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(LucideIcons.mousePointerClick, size: 11, color: theme.colorScheme.mutedForeground),
            const SizedBox(width: 5),
            Flexible(
              child: Tooltip(
                tooltip: (_) => const TooltipContainer(child: Text('Your editor selection goes with the next message as context')),
                child: Text(label, key: const ValueKey('miniai_selection_label'), maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 10)),
              ),
            ),
            IconButton.ghost(
              key: const ValueKey('miniai_selection_remove'),
              density: ButtonDensity.iconDense,
              icon: const Icon(LucideIcons.x, size: 10),
              onPressed: c.selection.dismiss,
            ),
          ],
        ),
      ),
    );
  }

  /// The commands matching the `/…` typed so far; a click sends one.
  Widget _slashMenu(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.mutedForeground;
    final matches = _slashMatches;
    final Widget body;
    if (c.claudeError != null) {
      body = Padding(
        padding: const EdgeInsets.all(8),
        child: Text(c.claudeError!, key: const ValueKey('miniai_slash_error'), style: TextStyle(fontSize: 10, color: theme.colorScheme.destructive)),
      );
    } else if (c.claudeCommands.isEmpty) {
      body = Padding(padding: const EdgeInsets.all(8), child: Text('Asking Claude Code for its commands…', style: TextStyle(fontSize: 10, color: muted)));
    } else if (matches.isEmpty) {
      body = Padding(padding: const EdgeInsets.all(8), child: Text('No command matches.', style: TextStyle(fontSize: 10, color: muted)));
    } else {
      body = ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.symmetric(vertical: 4),
        children: [
          for (var i = 0; i < matches.length; i++)
            GestureDetector(
              key: ValueKey('miniai_slash_${matches[i].name}'),
              onTap: () => _sendCommand(matches[i]),
              child: Container(
                color: i == _slashIndex ? theme.colorScheme.accent : null,
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('/${matches[i].name}', style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600)),
                    if (matches[i].argumentHint.isNotEmpty) ...[
                      const SizedBox(width: 4),
                      Flexible(
                        flex: 0,
                        child: Text(matches[i].argumentHint, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 10, color: muted)),
                      ),
                    ],
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(matches[i].description, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 10, color: muted)),
                    ),
                  ],
                ),
              ),
            ),
        ],
      );
    }
    return Container(
      key: const ValueKey('miniai_slash_menu'),
      margin: const EdgeInsets.only(bottom: 6),
      constraints: const BoxConstraints(maxHeight: 200),
      decoration: BoxDecoration(
        color: theme.colorScheme.popover,
        border: Border.all(color: theme.colorScheme.border),
        borderRadius: BorderRadius.circular(6),
      ),
      child: body,
    );
  }

  /// [turn] changed the project (so its footer is shown).
  bool _turnChanged(Chat chat, TurnRecord turn) {
    if (turn.sceneStep || turn.fileWrites > 0 || turn.untracked > 0) return true;
    if (turn.undoUnavailable == null) return false;
    final end = _turnEnd(chat, turn);
    for (var i = turn.userItemIndex; i <= end && i < chat.items.length; i++) {
      final item = chat.items[i];
      if (item is ToolCallItem && item.status == ToolCallStatus.done && (item.risk?.index ?? 0) > McpToolRisk.editorState.index) return true;
    }
    return false;
  }

  /// The index of [turn]'s last item (the next turn starts after it).
  int _turnEnd(Chat chat, TurnRecord turn) {
    final at = chat.turns.indexOf(turn);
    final next = at + 1 < chat.turns.length ? chat.turns[at + 1].userItemIndex : chat.items.length;
    return next - 1;
  }

  /// Under the newest Plan-mode turn that needed hidden tools: a one-click
  /// switch to Ask.
  Widget _planHint(BuildContext context, TurnRecord turn) {
    final chat = c.chat;
    if (turn.planBlocked.isEmpty || c.mode != ApprovalMode.plan || c.running || !identical(turn, chat.turns.lastOrNull)) {
      return const SizedBox.shrink();
    }
    final theme = Theme.of(context);
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        key: ValueKey('miniai_plan_hint_${turn.id}'),
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.fromLTRB(8, 4, 4, 4),
        decoration: BoxDecoration(
          color: theme.colorScheme.primary.withValues(alpha: 0.08),
          border: Border.all(color: theme.colorScheme.primary.withValues(alpha: 0.5)),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(LucideIcons.lightbulb, size: 12, color: theme.colorScheme.primary),
            const SizedBox(width: 6),
            Flexible(
              child: Tooltip(
                tooltip: (_) => TooltipContainer(child: Text('Plan mode hides: ${turn.planBlocked.join(', ')}')),
                child: const Text('Switch to Ask to let MiniAI make these changes', style: TextStyle(fontSize: 10)),
              ),
            ),
            const SizedBox(width: 6),
            PrimaryButton(
              key: const ValueKey('miniai_plan_switch'),
              density: ButtonDensity.compact,
              onPressed: () => c.mode = ApprovalMode.ask,
              child: const Text('Switch to Ask', style: TextStyle(fontSize: 10)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _turnFooter(BuildContext context, TurnRecord turn) {
    if (!_turnChanged(c.chat, turn)) return const SizedBox.shrink();
    final muted = Theme.of(context).colorScheme.mutedForeground;
    final (enabled, reason) = c.canUndoTurn(turn);
    return Align(
      alignment: Alignment.centerLeft,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: turn.undone
            ? Text('↶ Turn undone', key: ValueKey('miniai_turn_undone_${turn.id}'), style: TextStyle(fontSize: 10, color: muted))
            : Tooltip(
                tooltip: (_) => TooltipContainer(child: Text(reason)),
                child: GhostButton(
                  key: ValueKey('miniai_undo_turn_${turn.id}'),
                  density: ButtonDensity.compact,
                  onPressed: enabled ? () => c.undoTurn(turn.id) : null,
                  leading: const Icon(LucideIcons.undo2, size: 12),
                  child: const Text('Undo this turn', style: TextStyle(fontSize: 10)),
                ),
              ),
      ),
    );
  }

  Widget _item(BuildContext context, Chat chat, ChatItem item, int index) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: switch (item) {
        UserItem(:final text, context: final attached) => Align(
          alignment: Alignment.centerRight,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                decoration: BoxDecoration(color: theme.colorScheme.primary.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(8)),
                child: Text(text, style: const TextStyle(fontSize: 11)),
              ),
              if (attached != null)
                Padding(
                  padding: const EdgeInsets.only(top: 3),
                  child: Text(
                    attached,
                    key: ValueKey('miniai_user_context_$index'),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 9, color: theme.colorScheme.mutedForeground),
                  ),
                ),
            ],
          ),
        ),
        // The reasoning as one collapsible row, then the answer. Before the
        // first token of a model that does not reason: animated dots.
        AssistantItem() => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (item.hasThinking)
              ThinkingRow(key: ValueKey('miniai_thinking_$index'), item: item, active: chat.running && item.thinkingActive)
            else if (item.text.isEmpty && chat.running && identical(item, chat.items.whereType<AssistantItem>().lastOrNull))
              Row(
                key: ValueKey('miniai_waiting_$index'),
                children: [
                  Text('Thinking', style: TextStyle(fontSize: 10, color: theme.colorScheme.mutedForeground)),
                  ThinkingDots(style: TextStyle(fontSize: 10, color: theme.colorScheme.mutedForeground)),
                ],
              ),
            if (item.hasThinking && item.text.isNotEmpty) const SizedBox(height: 4),
            if (item.text.isNotEmpty)
              MarkdownView(key: ValueKey('miniai_assistant_$index'), data: item.text.toString().trim()),
          ],
        ),
        NoteItem(:final text, :final isError) => Text(
          text,
          key: ValueKey('miniai_note_$index'),
          style: TextStyle(fontSize: 10, color: isError ? theme.colorScheme.destructive : theme.colorScheme.mutedForeground),
        ),
        ToolCallItem() => _ToolCallCard(key: ValueKey('miniai_tool_$index'), chat: chat, item: item),
      },
    );
  }
}

class _ToolCallCard extends StatefulWidget {
  const _ToolCallCard({super.key, required this.chat, required this.item});

  final Chat chat;
  final ToolCallItem item;

  @override
  State<_ToolCallCard> createState() => _ToolCallCardState();
}

class _ToolCallCardState extends State<_ToolCallCard> {
  bool _open = false;
  final TextEditingController _reason = TextEditingController();

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final theme = Theme.of(context);
    final (icon, color, label) = switch (item.status) {
      ToolCallStatus.waitingApproval => (LucideIcons.shieldQuestion, theme.colorScheme.primary, 'waiting for approval'),
      ToolCallStatus.waitingAnswer => (LucideIcons.messageCircleQuestion, theme.colorScheme.primary, 'waiting for your answer'),
      ToolCallStatus.running => (LucideIcons.loader, theme.colorScheme.mutedForeground, 'running'),
      ToolCallStatus.done => (LucideIcons.check, const Color(0xFF58A547), item.elapsed == null ? 'done' : '${item.elapsed!.inMilliseconds} ms'),
      ToolCallStatus.failed => (LucideIcons.x, theme.colorScheme.destructive, 'failed'),
      ToolCallStatus.denied => (LucideIcons.ban, theme.colorScheme.mutedForeground, 'denied'),
    };
    final waiting = item.status == ToolCallStatus.waitingApproval;
    final asking = item.status == ToolCallStatus.waitingAnswer;
    final questions = asking ? UserQuestion.listFrom(JsonSpans.tryParse(item.call.argumentsJson)?.$1) : const <UserQuestion>[];
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: waiting || asking ? theme.colorScheme.primary : theme.colorScheme.border),
        borderRadius: BorderRadius.circular(6),
      ),
      padding: const EdgeInsets.all(8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          GestureDetector(
            onTap: () => setState(() => _open = !_open),
            child: Row(
              children: [
                Icon(icon, size: 12, color: color),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(item.call.name, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600)),
                ),
                Text(
                  '${item.risk?.name ?? 'unknown'} · $label',
                  key: ValueKey('miniai_tool_status_${item.call.id}'),
                  style: TextStyle(fontSize: 10, color: color),
                ),
                const SizedBox(width: 4),
                Icon(_open ? LucideIcons.chevronDown : LucideIcons.chevronRight, size: 11),
              ],
            ),
          ),
          if (item.images.isNotEmpty) ...[
            const SizedBox(height: 6),
            ToolImageThumbnails(callId: item.call.id, images: item.images),
          ],
          if (asking && questions.isNotEmpty) ...[
            const SizedBox(height: 8),
            QuestionForm(key: ValueKey('miniai_questions_${item.call.id}'), chat: widget.chat, item: item, questions: questions),
          ],
          if (!asking && item.answers != null) QuestionAnswers(key: ValueKey('miniai_answers_${item.call.id}'), answers: item.answers!),
          if (_open || waiting || (asking && questions.isEmpty)) ...[
            const SizedBox(height: 6),
            ToolPayloadView(key: ValueKey('miniai_tool_args_${item.call.id}'), text: item.call.argumentsJson),
          ],
          if (_open && item.result.isNotEmpty) ...[
            const SizedBox(height: 6),
            ToolPayloadView(key: ValueKey('miniai_tool_result_${item.call.id}'), text: item.result, muted: true),
          ],
          if (asking && questions.isEmpty) ...[
            const SizedBox(height: 8),
            OutlineButton(
              key: ValueKey('miniai_question_skip_${item.call.id}'),
              density: ButtonDensity.compact,
              onPressed: () => widget.chat.answerQuestions(item, null),
              child: const Text('Skip', style: TextStyle(fontSize: 10)),
            ),
          ],
          if (waiting) ...[
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                PrimaryButton(
                  key: const ValueKey('miniai_allow'),
                  density: ButtonDensity.compact,
                  onPressed: () => widget.chat.answer(item, const ApprovalAnswer.allow()),
                  child: const Text('Allow', style: TextStyle(fontSize: 10)),
                ),
                OutlineButton(
                  key: const ValueKey('miniai_always'),
                  density: ButtonDensity.compact,
                  onPressed: () => widget.chat.answer(item, const ApprovalAnswer.alwaysAllow()),
                  child: const Text('Always allow in this chat', style: TextStyle(fontSize: 10)),
                ),
                DestructiveButton(
                  key: const ValueKey('miniai_deny'),
                  density: ButtonDensity.compact,
                  onPressed: () => widget.chat.answer(item, ApprovalAnswer.deny(_reason.text.trim().isEmpty ? null : _reason.text.trim())),
                  child: const Text('Deny', style: TextStyle(fontSize: 10)),
                ),
              ],
            ),
            const SizedBox(height: 6),
            TextField(key: const ValueKey('miniai_deny_reason'), controller: _reason, placeholder: const Text('Reason for denying (optional)')),
          ],
        ],
      ),
    );
  }
}
