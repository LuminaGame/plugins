part of '../chat_panel.dart';

/// The conversation of [ChatPanel]: chat items, plan hints and turn footers.
extension _ChatPanelConversation on _ChatPanelState {
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
