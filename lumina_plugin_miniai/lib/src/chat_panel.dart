import 'dart:convert';

import 'package:flutter/services.dart' show LogicalKeyboardKey, HardwareKeyboard, KeyDownEvent;
import 'package:lumina_editor_api/lumina_editor_api.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';

import 'agent/approval.dart';
import 'agent/chat.dart';
import 'claude_code/claude_code_protocol.dart';
import 'history_view.dart';
import 'local/local_model_manager.dart';
import 'local_model_section.dart';
import 'miniai_controller.dart';
import 'provider_dialog.dart';

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

  MiniAiController get c => widget.controller;

  @override
  void initState() {
    super.initState();
    c.addListener(_changed);
    c.mcp.toolsChanged.addListener(_changed);
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
      c.addListener(_changed);
      c.mcp.toolsChanged.addListener(_changed);
    }
  }

  @override
  void dispose() {
    c.removeListener(_changed);
    c.mcp.toolsChanged.removeListener(_changed);
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

  void _send() {
    final text = _message.text;
    if (text.trim().isEmpty || c.running || !c.settings.isConfigured) return;
    _message.clear();
    c.send(text);
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
                        if (_turnEnd(chat, t) == i) _turnFooter(context, t),
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
              if (_slashQuery != null) _slashMenu(context),
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: Focus(
                      onKeyEvent: (_, event) {
                        if (event is! KeyDownEvent) return KeyEventResult.ignored;
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
        UserItem(:final text) => Align(
          alignment: Alignment.centerRight,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
            decoration: BoxDecoration(color: theme.colorScheme.primary.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(8)),
            child: Text(text, style: const TextStyle(fontSize: 11)),
          ),
        ),
        // Reasoning without text yet: "Thinking…" while the turn runs, then
        // nothing (the thinking itself stays in the chat model).
        AssistantItem() =>
          item.text.isEmpty
              ? (chat.running && identical(item, chat.items.whereType<AssistantItem>().lastOrNull)
                    ? Text(
                        'Thinking…',
                        style: TextStyle(fontSize: 10, color: theme.colorScheme.mutedForeground, fontStyle: FontStyle.italic),
                      )
                    : const SizedBox.shrink())
              : SelectableText(item.text.toString().trim(), key: ValueKey('miniai_assistant_$index'), style: const TextStyle(fontSize: 11)),
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

  String _pretty(String json) {
    try {
      return const JsonEncoder.withIndent('  ').convert(jsonDecode(json));
    } catch (_) {
      return json;
    }
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final theme = Theme.of(context);
    final (icon, color, label) = switch (item.status) {
      ToolCallStatus.waitingApproval => (LucideIcons.shieldQuestion, theme.colorScheme.primary, 'waiting for approval'),
      ToolCallStatus.running => (LucideIcons.loader, theme.colorScheme.mutedForeground, 'running'),
      ToolCallStatus.done => (LucideIcons.check, const Color(0xFF58A547), item.elapsed == null ? 'done' : '${item.elapsed!.inMilliseconds} ms'),
      ToolCallStatus.failed => (LucideIcons.x, theme.colorScheme.destructive, 'failed'),
      ToolCallStatus.denied => (LucideIcons.ban, theme.colorScheme.mutedForeground, 'denied'),
    };
    final waiting = item.status == ToolCallStatus.waitingApproval;
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: waiting ? theme.colorScheme.primary : theme.colorScheme.border),
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
          if (_open || waiting) ...[
            const SizedBox(height: 6),
            Text(_pretty(item.call.argumentsJson), style: const TextStyle(fontSize: 10, fontFamily: 'monospace')),
          ],
          if (_open && item.result.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              item.result.length > 1500 ? '${item.result.substring(0, 1500)}…' : item.result,
              style: TextStyle(fontSize: 10, fontFamily: 'monospace', color: theme.colorScheme.mutedForeground),
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
