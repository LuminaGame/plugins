part of '../chat_panel.dart';

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
          if (asking) ...[
            const SizedBox(height: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: theme.colorScheme.primary.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Row(
                children: [
                  Icon(LucideIcons.arrowDown, size: 12, color: theme.colorScheme.primary),
                  const SizedBox(width: 6),
                  Text('Answer prompt shown above message input', style: TextStyle(fontSize: 10, color: theme.colorScheme.primary)),
                ],
              ),
            ),
          ],
          if (!asking && item.answers != null) QuestionAnswers(key: ValueKey('miniai_answers_${item.call.id}'), answers: item.answers!),
          if (_open || waiting) ...[
            const SizedBox(height: 6),
            ToolPayloadView(key: ValueKey('miniai_tool_args_${item.call.id}'), text: item.call.argumentsJson),
          ],
          if (_open && item.result.isNotEmpty) ...[
            const SizedBox(height: 6),
            ToolPayloadView(key: ValueKey('miniai_tool_result_${item.call.id}'), text: item.result, muted: true),
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
