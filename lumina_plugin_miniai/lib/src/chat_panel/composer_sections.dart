part of '../chat_panel.dart';

/// The composer of [ChatPanel]: the approval mode switch, the `@` and `/` menus,
/// the editor selection chip and the pending question cards.
extension _ChatPanelComposer on _ChatPanelState {
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

  /// Active question prompts waiting for an answer, rendered prominently
  /// right above the chat input box.
  Widget _pendingQuestions(BuildContext context) {
    final pending = c.chat.pendingQuestions;
    if (pending.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final item in pending) ...[
          Builder(
            builder: (ctx) {
              final questions = UserQuestion.listFrom(JsonSpans.tryParse(item.call.argumentsJson)?.$1);
              return Container(
                key: ValueKey('miniai_active_question_${item.call.id}'),
                margin: const EdgeInsets.only(bottom: 8),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: theme.colorScheme.card,
                  border: Border.all(color: theme.colorScheme.primary.withValues(alpha: 0.6), width: 1.5),
                  borderRadius: BorderRadius.circular(8),
                  boxShadow: [
                    BoxShadow(
                      color: theme.colorScheme.primary.withValues(alpha: 0.1),
                      blurRadius: 8,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Icon(LucideIcons.messageCircleQuestion, size: 14, color: theme.colorScheme.primary),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            'AI Question',
                            style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: theme.colorScheme.primary),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    if (questions.isNotEmpty)
                      QuestionForm(
                        key: ValueKey('miniai_questions_${item.call.id}'),
                        chat: c.chat,
                        item: item,
                        questions: questions,
                      )
                    else ...[
                      ToolPayloadView(key: ValueKey('miniai_tool_args_${item.call.id}'), text: item.call.argumentsJson),
                      const SizedBox(height: 8),
                      OutlineButton(
                        key: ValueKey('miniai_question_skip_${item.call.id}'),
                        density: ButtonDensity.compact,
                        onPressed: () => c.chat.answerQuestions(item, null),
                        child: const Text('Skip', style: TextStyle(fontSize: 10)),
                      ),
                    ],
                  ],
                ),
              );
            },
          ),
        ],
      ],
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
}
