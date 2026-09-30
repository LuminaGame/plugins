import 'package:lumina_editor_api/lumina_editor_api.dart';

/// How much MiniAI may do without asking.
enum ApprovalMode {
  /// Read-only: looks around (read + editor-state tools); mutating tools are
  /// not even offered.
  plan('Plan', 'Reads and looks around; changes nothing'),

  /// The default: reads freely, asks before every change.
  ask('Ask', 'Asks before every change'),

  /// Edits freely, asks before destructive or external actions.
  acceptEdits('Accept edits', 'Makes undoable edits; asks before deleting or reaching outside'),

  /// Runs everything (the round limit still applies).
  auto('Auto', 'Runs every tool without asking');

  const ApprovalMode(this.label, this.help);
  final String label;
  final String help;
}

/// What the gate says about one tool in one mode.
enum ApprovalDecision {
  /// Runs without asking.
  allow,

  /// Waits for the user.
  ask,

  /// Not offered to the model; a call to it is refused.
  hidden,
}

/// The approval table, plus the per-chat "always allow this tool".
class ApprovalGate {
  ApprovalGate({this.mode = ApprovalMode.ask});

  ApprovalMode mode;
  final Set<String> _alwaysAllowed = {};

  /// "Always allow in this chat" for [toolName].
  void alwaysAllow(String toolName) => _alwaysAllowed.add(toolName);

  bool isAlwaysAllowed(String toolName) => _alwaysAllowed.contains(toolName);

  /// The tools "always allowed in this chat" (saved with the chat).
  Set<String> get alwaysAllowed => Set.unmodifiable(_alwaysAllowed);

  static ApprovalDecision table(McpToolRisk risk, ApprovalMode mode) => switch (mode) {
        ApprovalMode.plan => risk <= McpToolRisk.editorState ? ApprovalDecision.allow : ApprovalDecision.hidden,
        ApprovalMode.ask => risk <= McpToolRisk.editorState ? ApprovalDecision.allow : ApprovalDecision.ask,
        ApprovalMode.acceptEdits => risk <= McpToolRisk.mutating ? ApprovalDecision.allow : ApprovalDecision.ask,
        ApprovalMode.auto => ApprovalDecision.allow,
      };

  ApprovalDecision decide(McpTool tool) => decideRisk(tool.name, tool.risk);

  /// The decision for a tool known by [name] and [risk] only (an external
  /// agent's own tools).
  ApprovalDecision decideRisk(String name, McpToolRisk risk) {
    final base = table(risk, mode);
    if (base == ApprovalDecision.ask && _alwaysAllowed.contains(name)) return ApprovalDecision.allow;
    return base;
  }
}
