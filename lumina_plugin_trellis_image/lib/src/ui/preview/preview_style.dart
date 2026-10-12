import 'package:lumina_editor_api/lumina_editor_api.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';

/// The editor theme's panel tokens (sidebar, card, card header, border,
/// foreground, muted foreground), with the shadcn theme as the fallback
/// outside the editor.
class PreviewStyle {
  const PreviewStyle({
    required this.sidebar,
    required this.card,
    required this.cardHeader,
    required this.border,
    required this.background,
    required this.foreground,
    required this.muted,
    required this.destructive,
  });

  final Color sidebar,
      card,
      cardHeader,
      border,
      background,
      foreground,
      muted,
      destructive;

  factory PreviewStyle.of(BuildContext context, EditorThemeAccess? theme) {
    final c = Theme.of(context).colorScheme;
    Color token(String name, Color fallback) {
      if (theme == null) return fallback;
      try {
        return theme.color(name);
      } on ArgumentError {
        return fallback;
      }
    }

    return PreviewStyle(
      sidebar: token('sidebar', c.card),
      card: token('card', c.card),
      cardHeader: token('cardHeader', c.muted),
      border: token('border', c.border),
      background: token('background', c.background),
      foreground: token('foreground', c.foreground),
      muted: token('mutedForeground', c.mutedForeground),
      destructive: c.destructive,
    );
  }

  /// A section header (11–12 px semi-bold).
  Widget header(String text) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Text(
      text,
      style: TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w600,
        color: foreground,
      ),
    ),
  );

  /// A label / value row (10 px).
  Widget row(String label, String value, {Key? key}) => Padding(
    padding: const EdgeInsets.only(bottom: 3),
    child: Row(
      children: [
        Expanded(
          child: Text(label, style: TextStyle(fontSize: 10, color: muted)),
        ),
        Text(
          value,
          key: key,
          style: TextStyle(fontSize: 10, color: foreground),
        ),
      ],
    ),
  );

  /// A bordered card section.
  Widget section(List<Widget> children) => Container(
    margin: const EdgeInsets.only(bottom: 10),
    padding: const EdgeInsets.all(10),
    decoration: BoxDecoration(
      color: card,
      border: Border.all(color: border),
      borderRadius: BorderRadius.circular(6),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: children,
    ),
  );
}
