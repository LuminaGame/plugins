/// What [RepetitionGuard] found.
class RepetitionHit {
  const RepetitionHit({required this.copies, required this.period, required this.cut});

  /// How many times the block (or line) appeared.
  final int copies;

  /// The block's length in characters (0 for a repeated line).
  final int period;

  /// How many trailing characters to drop to keep one copy (0 for a
  /// repeated line).
  final int cut;
}

/// Watches streamed text for a model that repeats itself:
///
/// * the tail is one block of at least [minPeriod] characters repeated,
///   either [minCopies] times over at least [minSpan] characters, or
///   [shortCopies] times;
/// * among the last [lineWindow] non-empty lines, one line of at least
///   [minLine] characters appears [lineCopies] times.
///
/// Code repeats short lines (`),`, `}`) and Markdown tables `---`, so the
/// blocks and lines that count are long.
class RepetitionGuard {
  RepetitionGuard({
    this.minPeriod = 8,
    this.minCopies = 5,
    this.minSpan = 500,
    this.shortCopies = 16,
    this.minLine = 40,
    this.lineCopies = 10,
    this.lineWindow = 60,
    this.window = 6000,
    this.checkEvery = 48,
  });

  final int minPeriod;
  final int minCopies;
  final int minSpan;
  final int shortCopies;
  final int minLine;
  final int lineCopies;
  final int lineWindow;

  /// Only the newest [window] characters are kept and checked.
  final int window;

  /// Checks run after this many new characters.
  final int checkEvery;

  String _text = '';
  int _pending = 0;

  /// Adds [delta]; returns a hit once the text repeats.
  RepetitionHit? add(String delta) {
    _text += delta;
    if (_text.length > window * 2) _text = _text.substring(_text.length - window);
    _pending += delta.length;
    if (_pending < checkEvery) return null;
    _pending = 0;
    return check();
  }

  /// Checks the text now.
  RepetitionHit? check() => _tail() ?? _lines();

  RepetitionHit? _tail() {
    final text = _text.length > window ? _text.substring(_text.length - window) : _text;
    final n = text.length;
    if (n < minPeriod * minCopies) return null;
    // z[p] over the reversed text: how far the text, read backwards from
    // its end, matches itself shifted by p, i.e. the length of the periodic
    // tail with period p (minus one period).
    final r = text.codeUnits.reversed.toList(growable: false);
    final z = List<int>.filled(n, 0);
    var l = 0, rr = 0;
    for (var i = 1; i < n; i++) {
      if (i < rr) z[i] = (rr - i) < z[i - l] ? (rr - i) : z[i - l];
      while (i + z[i] < n && r[z[i]] == r[i + z[i]]) {
        z[i]++;
      }
      if (i + z[i] > rr) {
        l = i;
        rr = i + z[i];
      }
    }
    for (var p = minPeriod; p * minCopies <= n; p++) {
      final span = z[p] + p;
      final copies = span ~/ p;
      if ((copies >= minCopies && span >= minSpan) || copies >= shortCopies) {
        // A block that is itself a shorter repeat (`abab`) reports its
        // smallest period, found first.
        if (_blank(text.substring(n - p))) continue;
        return RepetitionHit(copies: copies, period: p, cut: span - p);
      }
    }
    return null;
  }

  /// Whitespace or punctuation only (a long rule of `-` or spaces).
  static bool _blank(String block) => !RegExp(r'[\p{L}\p{N}]', unicode: true).hasMatch(block);

  RepetitionHit? _lines() {
    final lines = [
      for (final line in _text.split('\n'))
        if (line.trim().isNotEmpty) line.trim(),
    ];
    final recent = lines.length > lineWindow ? lines.sublist(lines.length - lineWindow) : lines;
    final counts = <String, int>{};
    for (final line in recent) {
      if (line.length < minLine || _blank(line)) continue;
      final c = counts[line] = (counts[line] ?? 0) + 1;
      if (c >= lineCopies) return RepetitionHit(copies: c, period: 0, cut: 0);
    }
    return null;
  }
}
