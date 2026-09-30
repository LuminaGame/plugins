import 'dart:io';

import 'package:flutter/gestures.dart' show TapGestureRecognizer;
import 'package:flutter/widgets.dart' as widgets show Table, TableRow, TableBorder, IntrinsicColumnWidth;
import 'package:markdown/markdown.dart' as md;
import 'package:shadcn_flutter/shadcn_flutter.dart';

/// Opens an http(s) [url] in the user's browser.
Future<void> openExternalUrl(String url) async {
  final uri = Uri.tryParse(url);
  if (uri == null || !(uri.scheme == 'http' || uri.scheme == 'https')) return;
  if (Platform.isWindows) {
    await Process.run('rundll32', ['url.dll,FileProtocolHandler', uri.toString()]);
  } else if (Platform.isMacOS) {
    await Process.run('open', [uri.toString()]);
  } else {
    await Process.run('xdg-open', [uri.toString()]);
  }
}

/// An assistant answer's Markdown (GitHub flavoured) as styled text:
/// headings, bold, italic, strikethrough, inline code, fenced code blocks
/// (with a copy button), bullet and numbered lists (nested), block quotes,
/// tables, links and rules. Text stays selectable, block by block.
class MarkdownView extends StatefulWidget {
  const MarkdownView({super.key, required this.data, this.fontSize = 11, this.onOpenLink = openExternalUrl});

  final String data;
  final double fontSize;

  /// Opens a clicked link (the browser by default).
  final Future<void> Function(String url) onOpenLink;

  @override
  State<MarkdownView> createState() => _MarkdownViewState();
}

class _MarkdownViewState extends State<MarkdownView> {
  /// The link recognizers of the last build; replaced on every build.
  final List<TapGestureRecognizer> _recognizers = [];

  @override
  void dispose() {
    _disposeRecognizers();
    super.dispose();
  }

  void _disposeRecognizers() {
    for (final r in _recognizers) {
      r.dispose();
    }
    _recognizers.clear();
  }

  @override
  Widget build(BuildContext context) {
    _disposeRecognizers();
    final nodes = md.Document(extensionSet: md.ExtensionSet.gitHubFlavored, encodeHtml: false).parse(widget.data);
    return _Renderer(this, Theme.of(context)).blocks(nodes);
  }
}

class _Renderer {
  _Renderer(this.state, this.theme);

  final _MarkdownViewState state;
  final ThemeData theme;

  double get size => state.widget.fontSize;
  TextStyle get base => TextStyle(fontSize: size, height: 1.4, color: theme.colorScheme.foreground);

  static const Map<String, double> _headingScale = {'h1': 1.45, 'h2': 1.3, 'h3': 1.15, 'h4': 1.05, 'h5': 1.0, 'h6': 1.0};

  Widget blocks(List<md.Node> nodes) {
    final children = <Widget>[];
    for (final n in nodes) {
      final w = block(n);
      if (w == null) continue;
      if (children.isNotEmpty) children.add(SizedBox(height: size * 0.6));
      children.add(w);
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: children);
  }

  Widget? block(md.Node node) {
    if (node is md.Text) return node.text.trim().isEmpty ? null : text([node], base);
    if (node is! md.Element) return null;
    final children = node.children ?? const <md.Node>[];
    switch (node.tag) {
      case 'p':
        return text(children, base);
      case 'h1' || 'h2' || 'h3' || 'h4' || 'h5' || 'h6':
        final style = base.copyWith(fontSize: size * _headingScale[node.tag]!, fontWeight: FontWeight.w700, height: 1.3);
        final heading = text(children, style);
        if (node.tag != 'h1' && node.tag != 'h2') return heading;
        return Container(
          padding: const EdgeInsets.only(bottom: 3),
          decoration: BoxDecoration(border: Border(bottom: BorderSide(color: theme.colorScheme.border))),
          child: heading,
        );
      case 'ul' || 'ol':
        return list(node);
      case 'blockquote':
        return Container(
          padding: const EdgeInsets.only(left: 8),
          decoration: BoxDecoration(border: Border(left: BorderSide(color: theme.colorScheme.primary.withValues(alpha: 0.6), width: 3))),
          child: DefaultTextStyle.merge(
            style: TextStyle(color: theme.colorScheme.mutedForeground),
            child: blocks(children),
          ),
        );
      case 'pre':
        final code = children.whereType<md.Element>().firstOrNull;
        final source = (code?.textContent ?? node.textContent).replaceFirst(RegExp(r'\n$'), '');
        final language = (code?.attributes['class'] ?? '').replaceFirst('language-', '');
        return CodeSnippet(
          key: const ValueKey('miniai_md_code'),
          constraints: const BoxConstraints(maxHeight: 240),
          code: SelectableText(source, style: TextStyle(fontSize: size - 1, fontFamily: 'monospace', height: 1.35)),
          actions: [
            if (language.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(right: 4, top: 6),
                child: Text(language, style: TextStyle(fontSize: size - 2, color: theme.colorScheme.mutedForeground)),
              ),
          ],
        );
      case 'hr':
        return Container(height: 1, color: theme.colorScheme.border);
      case 'table':
        return table(node);
      default:
        return text(children, base);
    }
  }

  Widget list(md.Element node) {
    final ordered = node.tag == 'ol';
    var n = int.tryParse(node.attributes['start'] ?? '') ?? 1;
    final items = <Widget>[];
    for (final li in (node.children ?? const <md.Node>[]).whereType<md.Element>()) {
      final marker = ordered ? '${n++}.' : '•';
      final content = li.children ?? const <md.Node>[];
      // A tight item holds inline nodes, a loose one paragraphs; nested
      // lists are blocks either way.
      final inline = <md.Node>[];
      final parts = <Widget>[];
      void flush() {
        if (inline.isEmpty) return;
        parts.add(text(List.of(inline), base));
        inline.clear();
      }

      for (final c in content) {
        if (c is md.Element && const {'p', 'ul', 'ol', 'pre', 'blockquote', 'table', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6'}.contains(c.tag)) {
          flush();
          final w = block(c);
          if (w != null) parts.add(w);
        } else {
          inline.add(c);
        }
      }
      flush();
      items.add(Padding(
        padding: EdgeInsets.only(top: items.isEmpty ? 0 : 2),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: ordered ? size * 1.8 : size * 1.2,
              child: Text(marker, style: base.copyWith(color: theme.colorScheme.mutedForeground)),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final (i, p) in parts.indexed) ...[if (i > 0) const SizedBox(height: 2), p],
                ],
              ),
            ),
          ],
        ),
      ));
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: items);
  }

  Widget table(md.Element node) {
    final rows = <(bool, List<md.Element>)>[];
    for (final section in (node.children ?? const <md.Node>[]).whereType<md.Element>()) {
      for (final tr in (section.children ?? const <md.Node>[]).whereType<md.Element>()) {
        rows.add((section.tag == 'thead', (tr.children ?? const <md.Node>[]).whereType<md.Element>().toList()));
      }
    }
    final columns = rows.fold<int>(0, (m, r) => r.$2.length > m ? r.$2.length : m);
    if (columns == 0) return const SizedBox.shrink();
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: widgets.Table(
        defaultColumnWidth: const widgets.IntrinsicColumnWidth(),
        border: widgets.TableBorder.all(color: theme.colorScheme.border),
        children: [
          for (final (head, cells) in rows)
            widgets.TableRow(
              decoration: head ? BoxDecoration(color: theme.colorScheme.muted.withValues(alpha: 0.5)) : null,
              children: [
                for (var i = 0; i < columns; i++)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                    child: i < cells.length
                        ? text(cells[i].children ?? const [], head ? base.copyWith(fontWeight: FontWeight.w700) : base)
                        : const SizedBox.shrink(),
                  ),
              ],
            ),
        ],
      ),
    );
  }

  /// Inline [nodes] as one selectable paragraph.
  Widget text(List<md.Node> nodes, TextStyle style) =>
      SelectableText.rich(TextSpan(style: style, children: [for (final n in nodes) ...inline(n, style)]));

  List<InlineSpan> inline(md.Node node, TextStyle style) {
    if (node is md.Text) return [TextSpan(text: _unescape(node.text))];
    if (node is! md.Element) return const [];
    final children = node.children ?? const <md.Node>[];
    List<InlineSpan> nested(TextStyle s) => [
          TextSpan(style: s, children: [for (final c in children) ...inline(c, s)]),
        ];
    switch (node.tag) {
      case 'strong':
        return nested(style.copyWith(fontWeight: FontWeight.w700));
      case 'em':
        return nested(style.copyWith(fontStyle: FontStyle.italic));
      case 'del':
        return nested(style.copyWith(decoration: TextDecoration.lineThrough));
      case 'code':
        return [
          TextSpan(
            text: _unescape(node.textContent),
            style: style.copyWith(
              fontFamily: 'monospace',
              fontSize: (style.fontSize ?? size) - 0.5,
              color: theme.colorScheme.primary,
              backgroundColor: theme.colorScheme.muted.withValues(alpha: 0.6),
            ),
          ),
        ];
      case 'a':
        final href = node.attributes['href'] ?? '';
        final recognizer = TapGestureRecognizer()..onTap = () => state.widget.onOpenLink(href);
        state._recognizers.add(recognizer);
        final link = style.copyWith(color: theme.colorScheme.primary, decoration: TextDecoration.underline);
        return [
          // The recognizer sits on the text itself: a tap hits the leaf span.
          TextSpan(text: _unescape(node.textContent), style: link, recognizer: recognizer, mouseCursor: SystemMouseCursors.click),
        ];
      case 'br':
        return const [TextSpan(text: '\n')];
      case 'img':
        return [TextSpan(text: '[${node.attributes['alt'] ?? 'image'}]', style: style.copyWith(color: theme.colorScheme.mutedForeground))];
      case 'input':
        // A task list checkbox.
        return [TextSpan(text: node.attributes['checked'] != null ? '☑ ' : '☐ ')];
      default:
        return [for (final c in children) ...inline(c, style)];
    }
  }

  /// The parser leaves HTML entities in text (`&amp;`, `&quot;`).
  static String _unescape(String s) => s.contains('&')
      ? s.replaceAll('&quot;', '"').replaceAll('&#39;', "'").replaceAll('&lt;', '<').replaceAll('&gt;', '>').replaceAll('&amp;', '&')
      : s;
}
