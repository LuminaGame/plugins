import 'package:lumina_editor_api/lumina_editor_api.dart';

import '../llm/llm_types.dart';
import 'approval.dart';

/// Picks the few tool groups a request needs: a small model
/// cannot use 100+ tools, so it gets the groups its words point at, plus
/// `core`, at most [maxTools] tools, with short descriptions.
class ToolsetSelector {
  const ToolsetSelector({this.maxTools = 12, this.maxDescription = 160, this.disabledGroups = const {}});

  final int maxTools;
  final int maxDescription;

  /// Groups the project never gives the assistant; `core` is
  /// always kept.
  final Set<String> disabledGroups;

  bool _allowed(McpTool t) => t.groups.contains(McpToolGroups.core) || t.groups.intersection(disabledGroups).isEmpty;

  static const Map<String, List<String>> _keywords = {
    McpToolGroups.level: ['actor', 'actors', 'place', 'spawn', 'move', 'rotate', 'scale', 'delete', 'remove', 'level', 'scene', 'barrel', 'light', 'duplicate', 'rename', 'select', 'transform', 'outliner'],
    McpToolGroups.asset: ['asset', 'assets', 'mesh', 'meshes', 'texture', 'import', 'content', 'folder'],
    McpToolGroups.material: ['material', 'shader', 'color', 'colour', 'roughness', 'metallic'],
    McpToolGroups.blueprint: ['blueprint', 'node', 'nodes', 'graph', 'event', 'variable', 'function', 'wire', 'pin'],
    McpToolGroups.component: ['component', 'components', 'property', 'properties'],
    McpToolGroups.pie: ['play', 'pie', 'run the game', 'simulate'],
    McpToolGroups.view: ['camera', 'screenshot', 'view', 'viewport', 'look at', 'focus'],
    McpToolGroups.log: ['log', 'error', 'errors', 'warning', 'output'],
  };

  /// Request words → the words host tool names use.
  static const Map<String, List<String>> _synonyms = {
    'place': ['spawn', 'asset'],
    'put': ['spawn', 'asset'],
    'add': ['spawn', 'add'],
    'create': ['spawn', 'create'],
    'move': ['transform', 'set'],
    'rotate': ['transform', 'set'],
    'scale': ['transform', 'set'],
    'remove': ['delete'],
    'barrel': ['asset'],
    'barrels': ['asset'],
    'how': ['list', 'get'],
    'many': ['list'],
  };

  /// The groups [message] needs; `level` when nothing matches.
  Set<String> groupsFor(String message) {
    final text = message.toLowerCase();
    final groups = <String>{};
    for (final e in _keywords.entries) {
      if (disabledGroups.contains(e.key)) continue;
      if (e.value.any((w) => RegExp('\\b${RegExp.escape(w)}\\b').hasMatch(text))) groups.add(e.key);
    }
    if (groups.isEmpty && !disabledGroups.contains(McpToolGroups.level)) groups.add(McpToolGroups.level);
    return groups;
  }

  /// The tools to offer for [message] in [gate]'s mode, as [LlmToolSpec]s:
  /// the groups' tools first (read-only before changes, so a truncated list
  /// keeps the ones that look before they act… and the mutating ones the
  /// request asked for), then `core`, capped at [maxTools].
  List<McpTool> select(List<McpTool> all, String message, ApprovalGate gate) {
    final groups = groupsFor(message);
    final offered = [for (final t in all) if (gate.decide(t) != ApprovalDecision.hidden && _allowed(t)) t];
    final inGroups = [for (final t in offered) if (t.groups.intersection(groups).isNotEmpty) t];
    final core = [for (final t in offered) if (t.groups.contains(McpToolGroups.core) && !inGroups.contains(t)) t];
    // Prefer the tools whose names share a word (or a synonym) with the
    // request.
    final words = message.toLowerCase().split(RegExp(r'[^a-z0-9]+')).where((w) => w.length > 2).toSet();
    for (final w in List.of(words)) {
      words.addAll(_synonyms[w] ?? const []);
    }
    int score(McpTool t) => t.name.toLowerCase().split(RegExp(r'[_.]')).where(words.contains).length;
    inGroups.sort((a, b) => score(b).compareTo(score(a)));
    return [...inGroups, ...core].take(maxTools).toList();
  }

  LlmToolSpec specOf(McpTool tool) => LlmToolSpec(
        name: tool.name,
        description: tool.description.length <= maxDescription ? tool.description : '${tool.description.substring(0, maxDescription - 1)}…',
        parameters: tool.inputSchema,
      );
}
