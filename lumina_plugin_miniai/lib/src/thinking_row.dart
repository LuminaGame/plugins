import 'dart:async';

import 'package:shadcn_flutter/shadcn_flutter.dart';

import 'agent/chat.dart';

/// Three dots that cycle (`.`, `..`, `...`) while a model works.
class ThinkingDots extends StatefulWidget {
  const ThinkingDots({super.key, this.style, this.step = const Duration(milliseconds: 400)});

  final TextStyle? style;

  /// One dot more per step.
  final Duration step;

  @override
  State<ThinkingDots> createState() => _ThinkingDotsState();
}

class _ThinkingDotsState extends State<ThinkingDots> {
  int _dots = 1;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(widget.step, (_) {
      if (mounted) setState(() => _dots = _dots % 3 + 1);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // A fixed width: the row does not jump as the dots change.
    return SizedBox(
      width: 14,
      child: Text('.' * _dots, key: const ValueKey('miniai_thinking_dots'), style: widget.style, maxLines: 1, softWrap: false),
    );
  }
}

/// One assistant item's reasoning: "Thinking…" (animated) while the model
/// thinks, "Thought for N s" after; a click shows the text in a box at most
/// [maxHeight] high that follows the stream unless the user scrolled up.
class ThinkingRow extends StatefulWidget {
  const ThinkingRow({super.key, required this.item, required this.active, this.maxHeight = 100});

  final AssistantItem item;

  /// The model is thinking now (the turn runs and the reasoning has not
  /// ended).
  final bool active;
  final double maxHeight;

  /// "Thought for 4 s".
  static String took(Duration? d) {
    if (d == null) return 'Thought';
    final s = (d.inMilliseconds / 1000).round();
    return 'Thought for ${s < 1 ? 1 : s} s';
  }

  @override
  State<ThinkingRow> createState() => _ThinkingRowState();
}

class _ThinkingRowState extends State<ThinkingRow> {
  bool _open = false;
  final ScrollController _scroll = ScrollController();

  /// Follow new text to the bottom; off once the user scrolls up.
  bool _follow = true;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_scrolled);
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _scrolled() {
    if (!_scroll.hasClients) return;
    final p = _scroll.position;
    _follow = p.pixels >= p.maxScrollExtent - 4;
  }

  void _toBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_follow || !_scroll.hasClients) return;
      final max = _scroll.position.maxScrollExtent;
      if (_scroll.position.pixels != max) _scroll.jumpTo(max);
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.mutedForeground;
    final style = TextStyle(fontSize: 10, color: muted);
    final text = widget.item.thinking.toString().trim();
    if (_open) _toBottom();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        GestureDetector(
          key: const ValueKey('miniai_thinking_toggle'),
          onTap: () => setState(() {
            _open = !_open;
            _follow = true;
          }),
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            child: Row(
              children: [
                Icon(LucideIcons.brain, size: 11, color: muted),
                const SizedBox(width: 5),
                if (widget.active) ...[
                  Text('Thinking', style: style),
                  ThinkingDots(style: style),
                ] else
                  Text(ThinkingRow.took(widget.item.thinkingTook), key: const ValueKey('miniai_thinking_took'), style: style),
                const SizedBox(width: 3),
                Icon(_open ? LucideIcons.chevronDown : LucideIcons.chevronRight, size: 10, color: muted),
              ],
            ),
          ),
        ),
        if (_open) const SizedBox(height: 4),
        if (_open)
          Container(
            key: const ValueKey('miniai_thinking_box'),
            margin: const EdgeInsets.only(left: 16),
            constraints: BoxConstraints(maxHeight: widget.maxHeight),
            decoration: BoxDecoration(
              border: Border(left: BorderSide(color: theme.colorScheme.border, width: 2)),
            ),
            padding: const EdgeInsets.only(left: 8),
            child: SingleChildScrollView(
              controller: _scroll,
              child: Text(
                text.isEmpty ? (widget.active ? '…' : 'The model did not share its reasoning text.') : text,
                key: const ValueKey('miniai_thinking_text'),
                style: style.copyWith(fontStyle: text.isEmpty ? FontStyle.italic : null, height: 1.35),
              ),
            ),
          ),
      ],
    );
  }
}
