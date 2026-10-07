import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:lumina_editor_api/lumina_editor_api.dart';

import 'package:lumina_plugin_miniai/src/agent/agent_loop.dart';
import 'package:lumina_plugin_miniai/src/agent/approval.dart';
import 'package:lumina_plugin_miniai/src/agent/chat.dart';
import 'package:lumina_plugin_miniai/src/agent/chat_store.dart';
import 'package:lumina_plugin_miniai/src/agent/toolset_selector.dart';
import 'package:lumina_plugin_miniai/src/claude_code/claude_code_agent.dart';
import 'package:lumina_plugin_miniai/src/claude_code/claude_code_cli.dart';
import 'package:lumina_plugin_miniai/src/claude_code/claude_code_protocol.dart';
import 'package:lumina_plugin_miniai/src/context/editor_context.dart';
import 'package:lumina_plugin_miniai/src/context/selection_watcher.dart';
import 'package:lumina_plugin_miniai/src/llm/llm_types.dart';
import 'package:lumina_plugin_miniai/src/llm/sampling.dart';
import 'package:lumina_plugin_miniai/src/local/local_model_manager.dart';
import 'package:lumina_plugin_miniai/src/settings/miniai_project_settings.dart';
import 'package:lumina_plugin_miniai/src/settings/provider_settings.dart';

/// MiniAI's state for one editor session: the provider settings,
/// the current chat and the running turn.
class MiniAiController extends ChangeNotifier {
  MiniAiController({
    required this.storage,
    required this.mcp,
    this.transaction,
    this.projectName,
    Map<String, String>? environment,
    http.Client Function()? httpClient,
    HttpClient Function()? localHttpClient,
    LocalModelManager? local,
    ApprovalMode Function()? defaultMode,
    Map<String, Object?> Function()? projectSettings,
    this.level,
    this.projectRoot,
    ClaudeCodeStarter? claudeStarter,
    ClaudeCodeCli? claudeCli,
  }) : _defaultMode = defaultMode ?? (() => ApprovalMode.ask),
       _projectSettings = projectSettings ?? (() => const {}),
       settings = ProviderSettings(storage, environment: environment, httpClient: httpClient),
       local = local ?? LocalModelManager(storage: storage, environment: environment, httpClient: localHttpClient) {
    settings.addListener(notifyListeners);
    this.local.addListener(_localChanged);
    final projectDir = storage.projectDir;
    store = projectDir == null ? null : ChatStore(projectDir);
    claude = ClaudeCodeAgent(
      mcp: mcp,
      workingDirectory: projectRoot ?? projectDir?.path ?? Directory.current.path,
      configDir: projectDir,
      transaction: transaction,
      starter: claudeStarter,
      cli: claudeCli ?? ClaudeCodeCli(environmentOverride: environment),
    );
    selection = SelectionWatcher(mcp, level: level?.changes);
    mentions = MentionIndex(mcp);
    _bindChat(Chat(id: _newId(), mode: _defaultMode()));
  }

  /// The editor selection (the chip above the message box).
  late final SelectionWatcher selection;

  /// The project's content and actors for `@` mentions.
  late final MentionIndex mentions;

  /// The project attaches the editor selection to messages.
  bool get attachSelection => MiniAiProjectSettings.attachSelection(_projectSettings());

  /// What [text] carries: the selection (unless dropped or turned off) and
  /// the [picked] mentions still in the text. A slash command carries
  /// nothing.
  MessageContext contextFor(String text, List<MentionCandidate> picked) {
    if (text.startsWith('/')) return const MessageContext();
    final present = <MentionCandidate>[];
    for (final m in picked) {
      if (text.contains('@${m.name}') && !present.contains(m)) present.add(m);
    }
    return MessageContext(selection: attachSelection ? selection.attachable : null, mentions: present);
  }

  /// The project folder (Claude Code runs there).
  final String? projectRoot;

  /// The Claude Code provider: the chat's `claude` process.
  late final ClaudeCodeAgent claude;

  /// The commands the open chat's Claude Code session accepts (empty until
  /// [loadClaudeCommands]).
  List<ClaudeCommand> claudeCommands = const [];

  /// Why Claude Code could not start, for the panel.
  String? claudeError;
  bool _loadingCommands = false;

  /// The project's "Default mode for new chats".
  final ApprovalMode Function() _defaultMode;

  /// The project's AI Assistant settings, read per turn.
  final Map<String, Object?> Function() _projectSettings;

  /// The project's chats; null without a project (chats then
  /// stay in memory).
  late final ChatStore? store;

  /// The History rows, refreshed after every change.
  List<ChatSummary> summaries = const [];

  Future<void>? _saving;

  final PluginStorage storage;
  final EditorMcp mcp;
  final TurnTransaction? transaction;

  /// The open level: "Undo this turn" reads and pops its undo stack.
  final EditorLevelAccess? level;
  final String? projectName;
  final ProviderSettings settings;

  /// The local llama-server + MiniCPM5.
  final LocalModelManager local;

  /// The provider id of the local model.
  static const String localProviderId = 'miniai_local';

  String? _localUrl;

  late Chat chat;
  CancelToken? _cancel;

  /// The last turn ended with an error (the button turns destructive until
  /// the next send).
  bool lastTurnFailed = false;

  bool get running => chat.running;

  Future<void> load() async {
    await settings.load();
    // The project's preferred provider, for this session only.
    settings.useForSession(MiniAiProjectSettings.provider(_projectSettings()));
    await local.load();
    await refreshSummaries();
    // The chat that was open comes back when the project opens; else the
    // most recent one.
    final last = [...summaries]..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    if (last.isNotEmpty && chat.items.isEmpty && !running) {
      final open = (await _readSession())?['open'] as String?;
      final id = last.any((s) => s.id == open) ? open! : last.first.id;
      final restored = await store!.load(id);
      if (restored != null) _bindChat(restored);
      notifyListeners();
    }
  }

  Future<Map<String, Object?>?> _readSession() async {
    try {
      return await storage.readJson('session', project: true);
    } on FormatException {
      return null;
    }
  }

  /// Remembers the open chat for the next time the project opens.
  Future<void> _rememberOpen() async {
    if (store == null) return;
    await storage.writeJson('session', {'open': chat.items.isEmpty ? null : chat.id}, project: true);
  }

  Future<void> refreshSummaries() async {
    summaries = await store?.list() ?? const [];
    notifyListeners();
  }

  /// Writes the open chat (after a turn, Stop, a rename or a mode change).
  Future<void> saveChat() {
    final s = store;
    if (s == null || chat.items.isEmpty) return Future.value();
    final previous = _saving ?? Future<void>.value();
    final next = _saving = previous.then((_) => s.save(chat)).then((_) => _rememberOpen()).then((_) => refreshSummaries());
    return next;
  }

  /// Waits for the pending save (the project is closing).
  Future<void> flush() => _saving ?? Future<void>.value();

  /// A fresh, unsaved chat (saved with its first message).
  void newChat() {
    if (running) return;
    if (chat.items.isEmpty) {
      // Already new: it takes up the project's default mode.
      chat.gate.mode = _defaultMode();
      notifyListeners();
      return;
    }
    _bindChat(Chat(id: _newId(), mode: _defaultMode()));
    lastTurnFailed = false;
    notifyListeners();
  }

  /// Opens the stored chat [id].
  Future<void> openChat(String id) async {
    if (running || id == chat.id) return;
    final opened = await store?.load(id);
    if (opened == null) {
      await refreshSummaries();
      return;
    }
    _bindChat(opened);
    lastTurnFailed = false;
    notifyListeners();
    await _rememberOpen();
  }

  Future<void> renameChat(String id, String title) async {
    final name = title.trim();
    if (name.isEmpty) return;
    if (id == chat.id) {
      chat.title = name;
      chat.changed();
      if (chat.items.isNotEmpty) await saveChat();
      return;
    }
    await store?.rename(id, name);
    await refreshSummaries();
  }

  Future<void> setPinned(String id, bool pinned) async {
    if (id == chat.id) {
      chat.pinned = pinned;
      if (chat.items.isNotEmpty) await saveChat();
      notifyListeners();
      return;
    }
    await store?.setPinned(id, pinned);
    await refreshSummaries();
  }

  /// Deletes [id]; deleting the open chat opens a new one.
  Future<void> deleteChat(String id) async {
    if (running && id == chat.id) return;
    await flush();
    await store?.delete(id);
    if (id == chat.id) _bindChat(Chat(id: _newId(), mode: _defaultMode()));
    await refreshSummaries();
  }

  Future<List<ChatSummary>> search(String query) async => await store?.search(query) ?? const [];

  /// A ready server becomes (and stays) the selected `local` provider.
  void _localChanged() {
    final url = local.baseUrl;
    if (url != null && url != _localUrl) {
      _localUrl = url;
      unawaited(settings.save(_localConfig(url)));
    }
    if (url == null) _localUrl = null;
    notifyListeners();
  }

  /// The local provider at [url]; the sampling the user set on it stays.
  ProviderConfig _localConfig(String url) => ProviderConfig(
        id: localProviderId,
        name: 'Local (${local.variant.label})',
        baseUrl: url,
        model: local.variant.id,
        local: true,
        backend: ServerBackend.llamaCpp,
        sampling: settings.providers.where((p) => p.id == localProviderId).firstOrNull?.sampling,
      );

  /// The local provider is selected and its server is not up.
  bool get needsLocalStart => settings.selected?.id == localProviderId && local.status != LocalModelStatus.ready;

  static String _newId() => DateTime.now().microsecondsSinceEpoch.toRadixString(36);

  bool _bound = false;

  void _bindChat(Chat next) {
    if (_bound && !identical(chat, next)) {
      // Another chat: its own Claude Code process, started on demand.
      unawaited(claude.close());
      claudeCommands = const [];
      claudeError = null;
    }
    if (_bound) chat.removeListener(notifyListeners);
    chat = next;
    _bound = true;
    chat.addListener(notifyListeners);
  }

  ApprovalMode get mode => chat.gate.mode;

  set mode(ApprovalMode value) {
    chat.gate.mode = value;
    notifyListeners();
    if (chat.items.isNotEmpty) unawaited(saveChat());
  }

  /// Sends [text] as a new turn; ignored while a turn runs or without a
  /// provider.
  Future<void> send(String text, {List<MentionCandidate> mentions = const [], MessageContext? context}) async {
    final config = settings.selected;
    if (text.trim().isEmpty || running || config == null || !config.isUsable) return;
    lastTurnFailed = false;
    final ctx = context ?? contextFor(text.trim(), mentions);
    selection.sent();
    if (config.isClaudeCode) return _sendClaude(config, text.trim(), ctx);
    if (needsLocalStart) {
      // Autostart: the server's port changes per start, so the provider is
      // re-read once it is ready.
      if (!local.autostart || !local.isInstalled()) return;
      await local.start();
      if (local.status != LocalModelStatus.ready) {
        lastTurnFailed = true;
        notifyListeners();
        return;
      }
      await settings.save(_localConfig(local.baseUrl!));
      return send(text, context: ctx);
    }
    final cancel = _cancel = CancelToken();
    final project = _projectSettings();
    final loop = AgentLoop(
      provider: settings.providerFor(config),
      model: config.model,
      mcp: mcp,
      transaction: transaction,
      projectName: projectName,
      maxRounds: MiniAiProjectSettings.maxRounds(project) ?? (config.local ? 6 : 25),
      selector: ToolsetSelector(maxTools: config.local ? 12 : 40, disabledGroups: MiniAiProjectSettings.disabledToolGroups(project)),
      projectNotes: MiniAiProjectSettings.projectNotes(project),
      // The local model gets the short primer, a tighter guide budget and smaller result cuts.
      compactPrimer: config.local,
      guideResultBudget: config.local ? 3500 : 16000,
      resultBudget: config.local ? 2500 : 4000,
      maxContextTokens: config.local ? local.contextSize : null,
      autoCompact: config.local ? local.autoCompact : true,
    );
    final before = chat.items.length;
    chat
      ..provider = config.id
      ..model = config.model;
    final turn = chat;
    await loop.run(turn, text.trim(), cancel: cancel, context: ctx);
    // Did the turn leave a level undo step?
    if (turn.turns.isNotEmpty) turn.turns.last.sceneStep = level != null && level!.undoTopLabel == turn.turns.last.label;
    lastTurnFailed = turn.items.skip(before).any((i) => i is NoteItem && i.isError);
    _cancel = null;
    turn.updatedAt = DateTime.now().toUtc();
    notifyListeners();
    if (identical(turn, chat)) await saveChat();
  }

  Future<void> _sendClaude(ProviderConfig config, String text, MessageContext context) async {
    final cancel = _cancel = CancelToken();
    final before = chat.items.length;
    chat
      ..provider = config.id
      ..model = config.model.isEmpty ? null : config.model;
    final turn = chat;
    claudeError = null;
    await claude.run(turn, text, model: config.model.isEmpty ? null : config.model, command: config.command, cancel: cancel, context: context);
    if (turn.turns.isNotEmpty) turn.turns.last.sceneStep = level != null && level!.undoTopLabel == turn.turns.last.label;
    lastTurnFailed = turn.items.skip(before).any((i) => i is NoteItem && i.isError);
    _cancel = null;
    turn.updatedAt = DateTime.now().toUtc();
    _refreshCommandsFromInit();
    notifyListeners();
    if (identical(turn, chat)) await saveChat();
  }

  /// The selected provider is Claude Code.
  bool get usesClaudeCode => settings.selected?.isClaudeCode ?? false;

  /// Starts the open chat's Claude Code process (no model call) and reads
  /// the commands it accepts.
  Future<void> loadClaudeCommands() async {
    final config = settings.selected;
    if (config == null || !config.isClaudeCode || _loadingCommands) return;
    _loadingCommands = true;
    try {
      await claude.ensureSession(chat, model: config.model.isEmpty ? null : config.model, command: config.command);
      claudeError = null;
      _refreshCommandsFromInit();
    } on Object catch (e) {
      claudeError = '$e';
    } finally {
      _loadingCommands = false;
      notifyListeners();
    }
  }

  /// Terminal-only commands, until `system/init` names them.
  static const Set<String> _terminalOnly = {'doctor', 'color', 'focus', 'reload-plugins'};

  void _refreshCommandsFromInit() {
    final session = claude.session;
    final reported = session?.capabilities?.commands ?? const <ClaudeCommand>[];
    if (reported.isEmpty) return;
    final init = session?.init;
    final terminal = init == null ? _terminalOnly : init.terminalCommands.toSet();
    final accepted = init?.slashCommands.toSet();
    claudeCommands = [
      for (final c in reported)
        if (!c.name.startsWith('__') && !terminal.contains(c.name) && (accepted == null || accepted.contains(c.name))) c,
    ];
  }

  /// Answers a Claude Code permission request (MiniAI's `permission_prompt`
  /// MCP tool).
  Future<Map<String, Object?>> answerPermission(Map<String, Object?> request) => claude.permission(request);

  /// `Claude Code · <model> · session <id>` for the panel.
  String? get claudeState {
    final config = settings.selected;
    if (config == null || !config.isClaudeCode) return null;
    final data = chat.providerData[ClaudeCodeAgent.providerKey];
    final session = claude.session;
    final model = session?.init?.model ?? (data is Map ? data['model'] as String? : null) ?? (config.model.isEmpty ? 'default model' : config.model);
    final id = session?.sessionId ?? (data is Map ? data['sessionId'] as String? : null);
    return ['Claude Code', model, if (id != null) 'session ${id.length > 8 ? id.substring(0, 8) : id}'].join(' · ');
  }

  /// The session's cost, turns and time from the last result.
  String? get claudeUsage {
    final data = chat.providerData[ClaudeCodeAgent.providerKey];
    if (data is! Map || data['costUsd'] == null) return null;
    final cost = (data['costUsd'] as num).toDouble();
    final turns = data['turns'] as int?;
    final ms = data['durationMs'] as int?;
    return [
      '\$${cost.toStringAsFixed(cost < 1 ? 4 : 2)} this session',
      if (turns != null) '$turns turn${turns == 1 ? '' : 's'}',
      if (ms != null) '${(ms / 1000).toStringAsFixed(1)} s',
    ].join(' · ');
  }

  /// Whether [turn] can be taken back now, and why not.
  (bool, String) canUndoTurn(TurnRecord turn) {
    if (turn.undone) return (false, 'This turn was undone');
    if (turn.undoUnavailable != null) return (false, turn.undoUnavailable!);
    if (running) return (false, 'Wait for the running turn to finish');
    if (turn.sceneStep && level?.undoTopLabel != turn.label) {
      return (false, 'Newer changes are on top of this turn in Edit ▸ Undo; undo them first');
    }
    const untracked = "Claude Code's own file edits (Edit, Write, Bash) are not tracked here";
    if (!turn.sceneStep && turn.fileWrites == 0) return (false, turn.untracked > 0 ? untracked : 'This turn changed nothing');
    return (
      true,
      "Undo this turn's ${[if (turn.sceneStep) 'level changes', if (turn.fileWrites > 0) 'file changes'].join(' and ')}"
          "${turn.untracked > 0 ? ' ($untracked)' : ''}",
    );
  }

  /// Takes back [turnId]: its level undo step (only while it is the newest)
  /// and every file snapshot its calls took, newest first.
  Future<void> undoTurn(String turnId) async {
    final turn = chat.turns.where((t) => t.id == turnId).firstOrNull;
    if (turn == null || !canUndoTurn(turn).$1) return;
    var scene = 0;
    var files = 0;
    final problems = <String>[];
    if (turn.sceneStep) {
      if (level?.undoIfTop(turn.label) ?? false) {
        scene = 1;
      } else {
        problems.add('the level step is no longer the newest');
      }
    }
    if (turn.fileWrites > 0) {
      try {
        files = await _restoreFiles(turn);
      } on Object catch (e) {
        problems.add('restoring files failed: $e');
      }
    }
    turn.undone = scene > 0 || files > 0;
    final done = [if (scene > 0) '1 scene step', if (files > 0) '$files file${files == 1 ? '' : 's'} restored'];
    chat.items.add(NoteItem(
      done.isEmpty ? 'Nothing was undone: ${problems.join('; ')}.' : 'Undone: ${done.join(', ')}.${problems.isEmpty ? '' : ' (${problems.join('; ')})'}',
      isError: problems.isNotEmpty,
    ));
    chat.updatedAt = DateTime.now().toUtc();
    chat.changed();
    await saveChat();
  }

  /// Restores the snapshots [turn]'s calls took, newest first; returns how
  /// many files changed back.
  Future<int> _restoreFiles(TurnRecord turn) async {
    final history = await mcp.callTool(_fsHistory, {'caller': turn.caller, 'limit': 500}, caller: '${turn.caller}:undo');
    if (history.isError) throw StateError(history.content.map((c) => c['text']).join(' '));
    final data = jsonDecode('${history.content.first['text']}');
    final snapshots = [for (final s in (data is Map ? (data['snapshots'] as List? ?? const []) : data as List)) Map<String, Object?>.from(s as Map)];
    final paths = <String>{};
    for (final s in snapshots) {
      final r = await mcp.callTool(_fsRestore, {'snapshot_id': s['id']}, caller: '${turn.caller}:undo');
      if (r.isError) throw StateError('${s['path']}: ${r.content.map((c) => c['text']).join(' ')}');
      paths.add('${s['path']}');
    }
    return paths.length;
  }

  static const String _fsHistory = 'fs_history';
  static const String _fsRestore = 'fs_restore';

  /// Stops the running turn.
  void stop() => _cancel?.cancel();

  @override
  void dispose() {
    stop();
    selection.dispose();
    unawaited(claude.close());
    settings.removeListener(notifyListeners);
    local.removeListener(_localChanged);
    local.dispose();
    chat.removeListener(notifyListeners);
    super.dispose();
  }
}
