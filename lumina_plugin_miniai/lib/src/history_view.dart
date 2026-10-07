import 'dart:async';

import 'package:shadcn_flutter/shadcn_flutter.dart';

import 'package:lumina_plugin_miniai/src/agent/chat_store.dart';
import 'package:lumina_plugin_miniai/src/miniai_controller.dart';

/// "just now" / "5 min ago" / "3 h ago" / "2 d ago" / the date.
String relativeTime(DateTime at, {DateTime? now}) {
  final d = (now ?? DateTime.now()).toUtc().difference(at.toUtc());
  if (d.inMinutes < 1) return 'just now';
  if (d.inHours < 1) return '${d.inMinutes} min ago';
  if (d.inDays < 1) return '${d.inHours} h ago';
  if (d.inDays < 7) return '${d.inDays} d ago';
  final l = at.toLocal();
  return '${l.year}-${l.month.toString().padLeft(2, '0')}-${l.day.toString().padLeft(2, '0')}';
}

/// History: the project's chats, pinned first then
/// the most recent; search over titles and content; open, rename, pin and
/// delete (confirmed).
class HistoryView extends StatefulWidget {
  const HistoryView({super.key, required this.controller, this.onOpened});

  final MiniAiController controller;

  /// A chat was opened (the panel goes back to the conversation).
  final VoidCallback? onOpened;

  @override
  State<HistoryView> createState() => _HistoryViewState();
}

class _HistoryViewState extends State<HistoryView> {
  final TextEditingController _query = TextEditingController();
  List<ChatSummary>? _hits;
  int _searchSeq = 0;

  MiniAiController get c => widget.controller;

  @override
  void initState() {
    super.initState();
    c.addListener(_changed);
    unawaited(c.refreshSummaries());
  }

  @override
  void dispose() {
    c.removeListener(_changed);
    _query.dispose();
    super.dispose();
  }

  void _changed() {
    if (!mounted) return;
    if (_query.text.trim().isNotEmpty) unawaited(_search(_query.text));
    setState(() {});
  }

  Future<void> _search(String q) async {
    final seq = ++_searchSeq;
    if (q.trim().isEmpty) {
      setState(() => _hits = null);
      return;
    }
    final hits = await c.search(q);
    if (mounted && seq == _searchSeq) setState(() => _hits = hits);
  }

  Future<void> _open(ChatSummary s) async {
    await c.openChat(s.id);
    widget.onOpened?.call();
  }

  Future<void> _rename(BuildContext context, ChatSummary s) async {
    final field = TextEditingController(text: s.id == c.chat.id ? c.chat.title : s.title);
    await showOverlay<void>(
      context,
      const DialogConfiguration(),
      builder: (dialog) {
        Future<void> save() async {
          closeOverlay(dialog);
          await c.renameChat(s.id, field.text);
        }

        return AlertDialog(
          title: const Text('Rename chat'),
          content: SizedBox(
            width: 360,
            child: TextField(key: const ValueKey('miniai_rename_field'), controller: field, autofocus: true, onSubmitted: (_) => save()),
          ),
          actions: [
            GhostButton(onPressed: () => closeOverlay(dialog), child: const Text('Cancel')),
            PrimaryButton(key: const ValueKey('miniai_rename_save'), onPressed: save, child: const Text('Rename')),
          ],
        );
      },
    ).future;
    field.dispose();
  }

  Future<void> _delete(BuildContext context, ChatSummary s) async {
    await showOverlay<void>(
      context,
      const DialogConfiguration(),
      builder: (dialog) => AlertDialog(
        title: const Text('Delete chat?'),
        content: Text('"${s.title}" and its ${s.messageCount} message${s.messageCount == 1 ? '' : 's'} are removed from this project. '
            'Changes the assistant made to the level stay.'),
        actions: [
          GhostButton(onPressed: () => closeOverlay(dialog), child: const Text('Cancel')),
          DestructiveButton(
            key: const ValueKey('miniai_delete_confirm'),
            onPressed: () async {
              closeOverlay(dialog);
              await c.deleteChat(s.id);
            },
            child: const Text('Delete'),
          ),
        ],
      ),
    ).future;
  }

  Widget _row(BuildContext context, ChatSummary s) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.mutedForeground;
    final open = s.id == c.chat.id;
    return Container(
      key: ValueKey('miniai_history_row_${s.id}'),
      margin: const EdgeInsets.only(bottom: 4),
      decoration: BoxDecoration(
        color: open ? theme.colorScheme.muted : null,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        children: [
          Expanded(
            child: GhostButton(
              key: ValueKey('miniai_history_open_${s.id}'),
              onPressed: () => _open(s),
              alignment: Alignment.centerLeft,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      if (s.pinned) ...[Icon(LucideIcons.pin, size: 11, color: muted), const SizedBox(width: 4)],
                      Expanded(child: Text(s.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12))),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    [relativeTime(s.updatedAt), if (s.model != null) s.model!, '${s.messageCount} message${s.messageCount == 1 ? '' : 's'}'].join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 10, color: muted),
                  ),
                ],
              ),
            ),
          ),
          IconButton.ghost(
            key: ValueKey('miniai_history_pin_${s.id}'),
            density: ButtonDensity.iconDense,
            icon: Icon(s.pinned ? LucideIcons.pinOff : LucideIcons.pin, size: 13),
            onPressed: () => c.setPinned(s.id, !s.pinned),
          ),
          IconButton.ghost(
            key: ValueKey('miniai_history_rename_${s.id}'),
            density: ButtonDensity.iconDense,
            icon: const Icon(LucideIcons.pencil, size: 13),
            onPressed: () => _rename(context, s),
          ),
          IconButton.ghost(
            key: ValueKey('miniai_history_delete_${s.id}'),
            density: ButtonDensity.iconDense,
            icon: Icon(LucideIcons.trash2, size: 13, color: theme.colorScheme.destructive),
            onPressed: c.running && open ? null : () => _delete(context, s),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).colorScheme.mutedForeground;
    final rows = _hits ?? c.summaries;
    final warnings = c.store?.warnings ?? const <String>[];
    return Column(
      key: const ValueKey('miniai_history_view'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 0, 10, 8),
          child: TextField(
            key: const ValueKey('miniai_history_search'),
            controller: _query,
            placeholder: const Text('Search chats'),
            features: const [InputFeature.leading(Icon(LucideIcons.search, size: 14))],
            onChanged: _search,
          ),
        ),
        for (final w in warnings)
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 0, 10, 6),
            child: Text(w, key: const ValueKey('miniai_history_warning'), style: TextStyle(fontSize: 10, color: Theme.of(context).colorScheme.destructive)),
          ),
        Expanded(
          child: c.store == null
              ? Center(child: Text('Open a project to keep chats.', style: TextStyle(fontSize: 11, color: muted)))
              : rows.isEmpty
                  ? Center(
                      child: Text(_hits == null ? 'No chats in this project yet' : 'No chat matches "${_query.text.trim()}"',
                          key: const ValueKey('miniai_history_empty'), style: TextStyle(fontSize: 11, color: muted)),
                    )
                  : ListView(
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      children: [for (final s in rows) _row(context, s)],
                    ),
        ),
      ],
    );
  }
}
