import 'dart:convert';

import 'package:shadcn_flutter/shadcn_flutter.dart';

import 'agent/chat.dart';

/// A tool card's arguments or result: JSON pretty-printed and coloured,
/// anything else as plain text, in a box at most [maxHeight] tall that
/// scrolls.
class ToolPayloadView extends StatefulWidget {
  const ToolPayloadView({super.key, required this.text, this.muted = false});

  final String text;

  /// The result (a dimmer box than the arguments).
  final bool muted;

  static const double maxHeight = 200;

  /// Longer payloads are cut here (a screenshot's base64, a huge listing).
  static const int maxChars = 20000;

  @override
  State<ToolPayloadView> createState() => _ToolPayloadViewState();
}

class _ToolPayloadViewState extends State<ToolPayloadView> {
  final ScrollController _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = JsonPalette.of(theme);
    final text = widget.text.length > ToolPayloadView.maxChars ? '${widget.text.substring(0, ToolPayloadView.maxChars)}…' : widget.text;
    const style = TextStyle(fontSize: 10, fontFamily: 'monospace', height: 1.35);
    final json = JsonSpans.tryParse(text);
    final span = json == null
        ? TextSpan(text: text, style: style.copyWith(color: widget.muted ? theme.colorScheme.mutedForeground : theme.colorScheme.foreground))
        : TextSpan(style: style, children: JsonSpans(palette).build(json.$1));
    return Container(
      constraints: const BoxConstraints(maxHeight: ToolPayloadView.maxHeight),
      decoration: BoxDecoration(
        color: theme.colorScheme.muted.withValues(alpha: widget.muted ? 0.25 : 0.4),
        borderRadius: BorderRadius.circular(4),
      ),
      child: RawScrollbar(
        controller: _scroll,
        thumbVisibility: true,
        thickness: 4,
        radius: const Radius.circular(2),
        thumbColor: theme.colorScheme.mutedForeground.withValues(alpha: 0.5),
        child: SingleChildScrollView(
          controller: _scroll,
          padding: const EdgeInsets.fromLTRB(6, 5, 10, 5),
          child: SizedBox(width: double.infinity, child: SelectableText.rich(span)),
        ),
      ),
    );
  }
}

/// The colours of [JsonSpans].
class JsonPalette {
  const JsonPalette({required this.key, required this.string, required this.number, required this.literal, required this.punctuation});

  factory JsonPalette.of(ThemeData theme) => theme.brightness == Brightness.dark
      ? JsonPalette(
          key: const Color(0xFF9CDCFE),
          string: const Color(0xFFCE9178),
          number: const Color(0xFFB5CEA8),
          literal: const Color(0xFF569CD6),
          punctuation: theme.colorScheme.mutedForeground,
        )
      : JsonPalette(
          key: const Color(0xFF0451A5),
          string: const Color(0xFFA31515),
          number: const Color(0xFF098658),
          literal: const Color(0xFF0000FF),
          punctuation: theme.colorScheme.mutedForeground,
        );

  final Color key;
  final Color string;
  final Color number;

  /// true, false and null.
  final Color literal;
  final Color punctuation;
}

/// A JSON value as indented, coloured text spans.
class JsonSpans {
  JsonSpans(this.palette);

  final JsonPalette palette;
  final List<InlineSpan> _out = [];

  /// The decoded value of [text] when it is a JSON object or array.
  static (Object?,)? tryParse(String text) {
    final t = text.trimLeft();
    if (!t.startsWith('{') && !t.startsWith('[')) return null;
    try {
      return (jsonDecode(text),);
    } on FormatException {
      return null;
    }
  }

  List<InlineSpan> build(Object? value) {
    _out.clear();
    _value(value, 0);
    return List.of(_out);
  }

  void _add(String text, Color color) => _out.add(TextSpan(text: text, style: TextStyle(color: color)));

  void _value(Object? v, int depth) {
    final pad = '  ' * (depth + 1);
    final end = '  ' * depth;
    switch (v) {
      case Map():
        if (v.isEmpty) return _add('{}', palette.punctuation);
        _add('{\n', palette.punctuation);
        var i = 0;
        for (final e in v.entries) {
          _add(pad, palette.punctuation);
          _add(jsonEncode('${e.key}'), palette.key);
          _add(': ', palette.punctuation);
          _value(e.value, depth + 1);
          _add(++i < v.length ? ',\n' : '\n', palette.punctuation);
        }
        _add('$end}', palette.punctuation);
      case List():
        if (v.isEmpty) return _add('[]', palette.punctuation);
        _add('[\n', palette.punctuation);
        for (var i = 0; i < v.length; i++) {
          _add(pad, palette.punctuation);
          _value(v[i], depth + 1);
          _add(i + 1 < v.length ? ',\n' : '\n', palette.punctuation);
        }
        _add('$end]', palette.punctuation);
      case String():
        _add(jsonEncode(v), palette.string);
      case num():
        _add('$v', palette.number);
      default:
        _add('$v', palette.literal);
    }
  }
}

/// The questions of an AskUserQuestion card: options to pick (one, or
/// several when the question allows), an "Other" answer, Answer and Skip.
class QuestionForm extends StatefulWidget {
  const QuestionForm({super.key, required this.chat, required this.item, required this.questions});

  final Chat chat;
  final ToolCallItem item;
  final List<UserQuestion> questions;

  @override
  State<QuestionForm> createState() => _QuestionFormState();
}

class _QuestionFormState extends State<QuestionForm> {
  late final List<Set<String>> _picked = [for (final _ in widget.questions) <String>{}];
  late final List<TextEditingController> _other = [for (final _ in widget.questions) TextEditingController()];

  @override
  void dispose() {
    for (final c in _other) {
      c.dispose();
    }
    super.dispose();
  }

  /// The answer to question [i]: the picked labels (", "-joined) and the
  /// "Other" text; empty when unanswered.
  String _answer(int i) => [..._picked[i], if (_other[i].text.trim().isNotEmpty) _other[i].text.trim()].join(', ');

  bool get _complete => [for (var i = 0; i < widget.questions.length; i++) _answer(i)].every((a) => a.isNotEmpty);

  void _toggle(int i, String label) => setState(() {
        final q = widget.questions[i];
        if (q.multiSelect) {
          if (!_picked[i].remove(label)) _picked[i].add(label);
        } else {
          final was = _picked[i].contains(label);
          _picked[i].clear();
          if (!was) _picked[i].add(label);
          _other[i].clear();
        }
      });

  void _submit() {
    widget.chat.answerQuestions(widget.item, {
      for (var i = 0; i < widget.questions.length; i++) widget.questions[i].question: _answer(i),
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final id = widget.item.call.id;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < widget.questions.length; i++) ...[
          if (i > 0) const SizedBox(height: 10),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (widget.questions[i].header.isNotEmpty) ...[
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primary.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(3),
                  ),
                  child: Text(widget.questions[i].header, style: TextStyle(fontSize: 9, color: theme.colorScheme.primary)),
                ),
                const SizedBox(width: 6),
              ],
              Expanded(
                child: Text(
                  widget.questions[i].question,
                  key: ValueKey('miniai_question_${id}_$i'),
                  style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
          const SizedBox(height: 5),
          for (final (j, o) in widget.questions[i].options.indexed)
            _option(theme, i, j, o.label, o.description),
          const SizedBox(height: 4),
          TextField(
            key: ValueKey('miniai_question_other_${id}_$i'),
            controller: _other[i],
            placeholder: const Text('Other…', style: TextStyle(fontSize: 10)),
            style: const TextStyle(fontSize: 10),
            onChanged: (_) => setState(() {
              if (!widget.questions[i].multiSelect && _other[i].text.trim().isNotEmpty) _picked[i].clear();
            }),
          ),
        ],
        const SizedBox(height: 8),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            PrimaryButton(
              key: ValueKey('miniai_question_answer_$id'),
              density: ButtonDensity.compact,
              onPressed: _complete ? _submit : null,
              child: const Text('Answer', style: TextStyle(fontSize: 10)),
            ),
            OutlineButton(
              key: ValueKey('miniai_question_skip_$id'),
              density: ButtonDensity.compact,
              onPressed: () => widget.chat.answerQuestions(widget.item, null),
              child: const Text('Skip', style: TextStyle(fontSize: 10)),
            ),
          ],
        ),
      ],
    );
  }

  Widget _option(ThemeData theme, int i, int j, String label, String description) {
    final multi = widget.questions[i].multiSelect;
    final on = _picked[i].contains(label);
    return GestureDetector(
      key: ValueKey('miniai_question_option_${widget.item.call.id}_${i}_$j'),
      behavior: HitTestBehavior.opaque,
      onTap: () => _toggle(i, label),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: Container(
          margin: const EdgeInsets.only(bottom: 4),
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 5),
          decoration: BoxDecoration(
            color: on ? theme.colorScheme.primary.withValues(alpha: 0.12) : null,
            border: Border.all(color: on ? theme.colorScheme.primary : theme.colorScheme.border),
            borderRadius: BorderRadius.circular(5),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 1),
                child: Icon(
                  multi ? (on ? LucideIcons.squareCheck : LucideIcons.square) : (on ? LucideIcons.circleDot : LucideIcons.circle),
                  size: 11,
                  color: on ? theme.colorScheme.primary : theme.colorScheme.mutedForeground,
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(label, style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w600)),
                    if (description.isNotEmpty)
                      Text(description, style: TextStyle(fontSize: 9, color: theme.colorScheme.mutedForeground)),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The answers the user gave, under an answered AskUserQuestion card.
class QuestionAnswers extends StatelessWidget {
  const QuestionAnswers({super.key, required this.answers});

  final Map<String, String> answers;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final e in answers.entries)
          Padding(
            padding: const EdgeInsets.only(top: 3),
            child: Text.rich(
              TextSpan(children: [
                TextSpan(text: '${e.key}  ', style: TextStyle(color: theme.colorScheme.mutedForeground)),
                TextSpan(text: e.value, style: const TextStyle(fontWeight: FontWeight.w600)),
              ]),
              style: const TextStyle(fontSize: 10),
            ),
          ),
      ],
    );
  }
}
