import 'package:flutter/foundation.dart';
import 'package:lumina_editor_api/lumina_editor_api.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' show LucideIcons;

import 'local/local_model_manager.dart';
import 'miniai_controller.dart';

/// The ✦ AI toolbar button's live state: active while the
/// chat panel is open; busy while a turn runs; a badge with the approvals
/// waiting; warning-toned without a provider, destructive after a failed
/// turn.
class MiniAiButtonState {
  MiniAiButtonState({required this.panelVisibility, this.controller}) {
    panelVisibility.addListener(_update);
    controller?.addListener(_update);
    _update();
  }

  /// `EditorPanels.visibility('miniai.chat')`.
  final ValueListenable<bool> panelVisibility;
  final MiniAiController? controller;

  final ValueNotifier<EditorButtonState> state = ValueNotifier(
    const EditorButtonState(icon: LucideIcons.sparkles, tooltip: 'AI Assistant (MiniAI)', label: 'AI'),
  );

  void _update() {
    final c = controller;
    final configured = c?.settings.isConfigured ?? false;
    final pending = c?.chat.pendingApprovals.length ?? 0;
    final local = c?.local;
    final crashed = local?.status == LocalModelStatus.crashed;
    final tone = crashed
        ? EditorTone.destructive
        : !configured
        ? EditorTone.warning
        : (c!.lastTurnFailed ? EditorTone.destructive : (pending > 0 ? EditorTone.primary : EditorTone.neutral));
    var next = state.value.copyWith(
      active: panelVisibility.value,
      busy: (c?.running ?? false) || (local?.isBusy ?? false),
      tone: tone,
      tooltip: crashed
          ? 'AI Assistant (MiniAI) — The local model stopped unexpectedly'
          : local?.status == LocalModelStatus.downloading
          ? 'AI Assistant (MiniAI) — Downloading ${local!.progressLabel ?? 'the local model'}'
          : local?.status == LocalModelStatus.starting
          ? 'AI Assistant (MiniAI) — Starting the local model'
          : !configured
          ? 'AI Assistant (MiniAI) — No model provider is set up yet'
          : pending > 0
          ? 'AI Assistant (MiniAI) — $pending tool call${pending == 1 ? '' : 's'} waiting for your approval'
          : 'AI Assistant (MiniAI) — ${c!.settings.selected!.model}',
    );
    next = pending > 0 ? next.copyWith(badge: '$pending') : next.withoutBadge;
    state.value = next;
  }

  void dispose() {
    panelVisibility.removeListener(_update);
    controller?.removeListener(_update);
  }
}
