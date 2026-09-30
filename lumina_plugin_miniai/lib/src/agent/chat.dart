import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:lumina_editor_api/lumina_editor_api.dart';

import '../llm/llm_types.dart';
import 'approval.dart';

enum ToolCallStatus { waitingApproval, waitingAnswer, running, done, failed, denied }

/// One thing shown in the conversation.
sealed class ChatItem {
  ChatItem();
}

class UserItem extends ChatItem {
  UserItem(this.text, {this.context});
  final String text;

  /// What went with it besides the text (`Context: Divider_Wall · Primitive,
  /// @fuel_barrel_red`); the model got the full block.
  final String? context;
}

class AssistantItem extends ChatItem {
  final StringBuffer text = StringBuffer();

  /// The model's reasoning, as it streamed (empty when the provider only
  /// says that it thinks, as Claude Code does by default).
  final StringBuffer thinking = StringBuffer();

  /// When the reasoning started; null when the model did not think.
  DateTime? thinkingStarted;

  /// How long it thought; null while it still thinks.
  Duration? thinkingTook;

  /// The model thought (text or not).
  bool get hasThinking => thinkingStarted != null || thinkingTook != null || thinking.isNotEmpty;

  /// The reasoning started and has not ended yet.
  bool get thinkingActive => thinkingStarted != null && thinkingTook == null;

  /// Adds streamed reasoning [text] (may be empty: the model thinks
  /// without sharing it).
  void addThinking(String text, {DateTime? now}) {
    if (thinkingTook != null) return;
    thinkingStarted ??= now ?? DateTime.now();
    thinking.write(text);
  }

  /// The reasoning ended (the answer or a tool call began, or the stream
  /// ended).
  void endThinking({DateTime? now}) {
    final started = thinkingStarted;
    if (started == null || thinkingTook != null) return;
    thinkingTook = (now ?? DateTime.now()).difference(started);
  }
}

class ToolCallItem extends ChatItem {
  ToolCallItem({required this.call, required this.risk});

  final LlmToolCall call;

  /// Null when the model named a tool that does not exist.
  final McpToolRisk? risk;
  ToolCallStatus status = ToolCallStatus.running;
  String result = '';
  Duration? elapsed;

  /// The images the result carried (screenshots), shown as thumbnails.
  List<ChatImage> images = const [];

  /// Set while [status] is [ToolCallStatus.waitingApproval].
  Completer<ApprovalAnswer>? approval;

  /// Set while [status] is [ToolCallStatus.waitingAnswer]: the model asked
  /// the user (Claude Code's AskUserQuestion); completes with the answers by
  /// question, or null when the user skipped.
  Completer<Map<String, String>?>? question;

  /// The user's answers to the questions, by question.
  Map<String, String>? answers;
}

/// One question of Claude Code's AskUserQuestion tool.
class UserQuestion {
  const UserQuestion({required this.question, required this.header, required this.options, this.multiSelect = false});

  final String question;

  /// A short label (a chip).
  final String header;
  final List<({String label, String description})> options;
  final bool multiSelect;

  /// The questions of an AskUserQuestion input (`{questions: [...]}`).
  static List<UserQuestion> listFrom(Object? input) => [
        for (final q in (input is Map ? input['questions'] as List? ?? const [] : const []))
          if (q is Map && q['question'] is String)
            UserQuestion(
              question: q['question'] as String,
              header: '${q['header'] ?? ''}',
              multiSelect: q['multiSelect'] == true,
              options: [
                for (final o in (q['options'] as List? ?? const []))
                  if (o is Map) (label: '${o['label'] ?? ''}', description: '${o['description'] ?? ''}'),
              ],
            ),
      ];
}

/// A note from MiniAI itself: stopped, a provider error, the round limit.
class NoteItem extends ChatItem {
  NoteItem(this.text, {this.isError = false});
  final String text;
  final bool isError;
}

/// One assistant turn: what "Undo this turn" can take back.
class TurnRecord {
  TurnRecord({
    required this.id,
    required this.label,
    required this.userItemIndex,
    this.sceneStep = false,
    this.fileWrites = 0,
    this.undone = false,
    this.untracked = 0,
    this.undoUnavailable,
    List<String>? planBlocked,
  }) : planBlocked = planBlocked ?? [];

  /// `<chatId>:<n>`; the tool caller is `miniai:<id>`.
  final String id;

  /// The turn's undo step label (`AI: <title>`).
  final String label;

  /// Where the turn starts in [Chat.items].
  final int userItemIndex;

  /// The turn left one step on the level undo stack.
  bool sceneStep;

  /// File-changing tool calls that succeeded (each left snapshots).
  int fileWrites;
  bool undone;

  /// Changes an external agent made with its own tools (Claude Code's
  /// Edit, Write, Bash): not on the undo stack, no snapshots.
  int untracked;

  /// Why this turn cannot be undone here at all (the editor could not
  /// attribute an external agent's calls to it); null when it can.
  String? undoUnavailable;

  /// In Plan mode: the tools the turn needed that the mode hides (the
  /// panel offers to switch to Ask).
  final List<String> planBlocked;

  String get caller => 'miniai:$id';

  Map<String, Object?> toJson() => {
        'id': id,
        'label': label,
        'userItem': userItemIndex,
        if (sceneStep) 'sceneStep': true,
        if (fileWrites > 0) 'fileWrites': fileWrites,
        if (undone) 'undone': true,
        if (untracked > 0) 'untracked': untracked,
        'undoUnavailable': ?undoUnavailable,
        if (planBlocked.isNotEmpty) 'planBlocked': planBlocked,
      };

  factory TurnRecord.fromJson(Map<String, Object?> j) => TurnRecord(
        id: '${j['id']}',
        label: '${j['label']}',
        userItemIndex: j['userItem'] as int? ?? 0,
        sceneStep: j['sceneStep'] == true,
        fileWrites: j['fileWrites'] as int? ?? 0,
        undone: j['undone'] == true,
        untracked: j['untracked'] as int? ?? 0,
        undoUnavailable: j['undoUnavailable'] as String?,
        planBlocked: [for (final t in (j['planBlocked'] as List? ?? const [])) '$t'],
      );
}

/// The user's answer on an approval card.
class ApprovalAnswer {
  const ApprovalAnswer.allow() : allowed = true, always = false, reason = null;
  const ApprovalAnswer.alwaysAllow() : allowed = true, always = true, reason = null;
  const ApprovalAnswer.deny([this.reason]) : allowed = false, always = false;

  final bool allowed;

  /// "Always allow in this chat".
  final bool always;
  final String? reason;
}

/// One conversation; it is stored with the project.
class Chat extends ChangeNotifier {
  Chat({required this.id, ApprovalMode mode = ApprovalMode.ask, DateTime? createdAt})
      : gate = ApprovalGate(mode: mode),
        createdAt = (createdAt ?? DateTime.now()).toUtc(),
        updatedAt = (createdAt ?? DateTime.now()).toUtc();

  static const String defaultTitle = 'New chat';

  final String id;
  String title = defaultTitle;
  final DateTime createdAt;
  DateTime updatedAt;
  bool pinned = false;

  /// The provider id and the model of the last turn.
  String? provider;
  String? model;
  final ApprovalGate gate;
  final List<ChatItem> items = [];

  /// What the model sees (the system prompt first).
  final List<LlmMessage> history = [];

  /// The assistant turns, oldest first.
  final List<TurnRecord> turns = [];

  bool running = false;
  Usage? lastUsage;

  /// Per-provider data kept with the chat (`claude_code`: the CLI's session
  /// id, model and cost), so the same provider can continue it.
  final Map<String, Object?> providerData = {};

  /// The tool calls waiting for the user.
  List<ToolCallItem> get pendingApprovals =>
      [for (final i in items) if (i is ToolCallItem && i.status == ToolCallStatus.waitingApproval) i];

  /// The questions waiting for the user's answer.
  List<ToolCallItem> get pendingQuestions =>
      [for (final i in items) if (i is ToolCallItem && i.status == ToolCallStatus.waitingAnswer) i];

  void changed() => notifyListeners();

  /// Answers [item]'s questions ([answers] by question; null skips them).
  void answerQuestions(ToolCallItem item, Map<String, String>? answers) {
    final pending = item.question;
    if (pending == null || pending.isCompleted) return;
    pending.complete(answers);
  }

  /// Answers [item]'s approval card.
  void answer(ToolCallItem item, ApprovalAnswer answer) {
    final pending = item.approval;
    if (pending == null || pending.isCompleted) return;
    if (answer.always) gate.alwaysAllow(item.call.name);
    pending.complete(answer);
  }

  /// Messages the user sent (the History's count).
  int get messageCount => items.whereType<UserItem>().length;

  /// The tool images, oldest first.
  List<ChatImage> get images => [for (final i in items) if (i is ToolCallItem) ...i.images];

  /// How many images keep their pixels in the chat file (the newest).
  static const int keptImages = 12;

  int _imageSeq = 0;

  /// A new image id, unique in this chat.
  String newImageId() => 'img${++_imageSeq}';

  // ── storage ──────────────────────────────────

  static const int formatVersion = 1;

  Map<String, Object?> toJson() {
    final all = images;
    final keep = all.length <= keptImages ? all.toSet() : all.sublist(all.length - keptImages).toSet();
    return {
      'id': id,
      'title': title,
      'version': formatVersion,
      'createdAt': createdAt.toIso8601String(),
      'updatedAt': updatedAt.toIso8601String(),
      'pinned': pinned,
      'settings': {
        'provider': provider,
        'model': model,
        'mode': gate.mode.name,
        'alwaysAllowed': gate.alwaysAllowed.toList()..sort(),
      },
      if (lastUsage != null) 'usage': {'in': lastUsage!.promptTokens, 'out': lastUsage!.completionTokens},
      'messages': [for (final m in history) _messageJson(m)],
      'items': [for (final i in items) _itemJson(i)],
      if (turns.isNotEmpty) 'turns': [for (final t in turns) t.toJson()],
      if (providerData.isNotEmpty) 'providerData': providerData,
      if (all.isNotEmpty) 'images': {for (final i in all) i.id: i.toJson(withData: keep.contains(i))},
    };
  }

  static Object? _args(String json) {
    try {
      return jsonDecode(json);
    } on FormatException {
      return json;
    }
  }

  static String _argsText(Object? args) => args is String ? args : jsonEncode(args ?? const {});

  static Map<String, Object?> _messageJson(LlmMessage m) => switch (m.role) {
        LlmRole.tool => {
            'role': 'tool',
            'callId': m.toolCallId,
            'name': m.toolName,
            'content': m.content,
            if (m.images.isNotEmpty) 'images': [for (final i in m.images) i.id],
          },
        LlmRole.assistant => {
            'role': 'assistant',
            'content': [
              if (m.content.isNotEmpty) {'type': 'text', 'text': m.content},
              for (final c in m.toolCalls) {'type': 'tool_call', 'id': c.id, 'name': c.name, 'args': _args(c.argumentsJson)},
            ],
          },
        _ => {
            'role': m.role.name,
            'content': [
              {'type': 'text', 'text': m.content},
            ],
          },
      };

  static String _text(Object? content) => [
        for (final c in (content as List? ?? const []))
          if (c is Map && c['type'] == 'text') '${c['text']}',
      ].join();

  static List<ChatImage> _imagesFrom(Object? ids, Map<String, ChatImage> images) => [
        for (final id in (ids as List? ?? const [])) ?images['$id'],
      ];

  static LlmMessage _messageFrom(Map<String, Object?> j, Map<String, ChatImage> images) {
    final content = j['content'];
    switch (j['role']) {
      case 'system':
        return LlmMessage.system(_text(content));
      case 'user':
        return LlmMessage.user(_text(content));
      case 'assistant':
        return LlmMessage.assistant(_text(content), toolCalls: [
          for (final c in (content as List? ?? const []))
            if (c is Map && c['type'] == 'tool_call') LlmToolCall(id: '${c['id']}', name: '${c['name']}', argumentsJson: _argsText(c['args'])),
        ]);
      case 'tool':
        return LlmMessage.toolResult(
          toolCallId: '${j['callId']}',
          toolName: '${j['name']}',
          content: '${content ?? ''}',
          images: _imagesFrom(j['images'], images),
        );
      default:
        throw FormatException('unknown message role ${j['role']}');
    }
  }

  static Map<String, Object?> _itemJson(ChatItem i) => switch (i) {
        UserItem() => {'kind': 'user', 'text': i.text, 'context': ?i.context},
        AssistantItem() => {
            'kind': 'assistant',
            'text': i.text.toString(),
            if (i.thinking.isNotEmpty) 'thinking': i.thinking.toString(),
            if (i.thinkingTook != null) 'thinkingMs': i.thinkingTook!.inMilliseconds,
          },
        ToolCallItem() => {
            'kind': 'tool',
            'callId': i.call.id,
            'name': i.call.name,
            'args': _args(i.call.argumentsJson),
            'risk': i.risk?.name,
            'status': i.status.name,
            'result': i.result,
            if (i.elapsed != null) 'ms': i.elapsed!.inMilliseconds,
            if (i.images.isNotEmpty) 'images': [for (final image in i.images) image.id],
            'answers': ?i.answers,
          },
        NoteItem() => {'kind': 'note', 'text': i.text, if (i.isError) 'isError': true},
      };

  static ChatItem _itemFrom(Map<String, Object?> j, Map<String, ChatImage> images) {
    switch (j['kind']) {
      case 'user':
        return UserItem('${j['text']}', context: j['context'] as String?);
      case 'assistant':
        return AssistantItem()
          ..text.write(j['text'] ?? '')
          ..thinking.write(j['thinking'] ?? '')
          ..thinkingTook = j['thinkingMs'] is int ? Duration(milliseconds: j['thinkingMs'] as int) : null;
      case 'tool':
        final risk = McpToolRisk.values.where((r) => r.name == j['risk']).firstOrNull;
        final item = ToolCallItem(call: LlmToolCall(id: '${j['callId']}', name: '${j['name']}', argumentsJson: _argsText(j['args'])), risk: risk);
        var status = ToolCallStatus.values.where((s) => s.name == j['status']).firstOrNull ?? ToolCallStatus.failed;
        var result = '${j['result'] ?? ''}';
        // A card the editor closed on never finished.
        if (status == ToolCallStatus.waitingApproval || status == ToolCallStatus.waitingAnswer || status == ToolCallStatus.running) {
          status = ToolCallStatus.failed;
          result = result.isEmpty ? 'Interrupted: the chat was closed before this call finished.' : result;
        }
        item
          ..status = status
          ..result = result
          ..elapsed = j['ms'] is int ? Duration(milliseconds: j['ms'] as int) : null
          ..images = _imagesFrom(j['images'], images)
          ..answers = j['answers'] is Map ? {for (final e in (j['answers'] as Map).entries) '${e.key}': '${e.value}'} : null;
        return item;
      case 'note':
        return NoteItem('${j['text']}', isError: j['isError'] == true);
      default:
        throw FormatException('unknown item kind ${j['kind']}');
    }
  }

  /// A chat read back from [toJson]; throws [FormatException] when [json]
  /// is not a chat.
  factory Chat.fromJson(Map<String, Object?> json) {
    final id = json['id'];
    if (id is! String || id.isEmpty) throw const FormatException('a chat needs an id');
    final settings = Map<String, Object?>.from(json['settings'] as Map? ?? const {});
    final mode = ApprovalMode.values.where((m) => m.name == settings['mode']).firstOrNull ?? ApprovalMode.ask;
    final chat = Chat(id: id, mode: mode, createdAt: DateTime.tryParse('${json['createdAt']}'))
      ..title = json['title'] as String? ?? defaultTitle
      ..pinned = json['pinned'] == true
      ..provider = settings['provider'] as String?
      ..model = settings['model'] as String?;
    chat.updatedAt = DateTime.tryParse('${json['updatedAt']}')?.toUtc() ?? chat.createdAt;
    for (final t in (settings['alwaysAllowed'] as List? ?? const [])) {
      chat.gate.alwaysAllow('$t');
    }
    final usage = json['usage'];
    if (usage is Map) chat.lastUsage = Usage(promptTokens: usage['in'] as int? ?? 0, completionTokens: usage['out'] as int? ?? 0);
    final images = <String, ChatImage>{
      for (final e in (json['images'] as Map? ?? const {}).entries) '${e.key}': ChatImage.fromJson('${e.key}', Map<String, Object?>.from(e.value as Map)),
    };
    for (final id in images.keys) {
      final n = int.tryParse(id.replaceFirst('img', '')) ?? 0;
      if (n > chat._imageSeq) chat._imageSeq = n;
    }
    for (final m in (json['messages'] as List? ?? const [])) {
      chat.history.add(_messageFrom(Map<String, Object?>.from(m as Map), images));
    }
    for (final i in (json['items'] as List? ?? const [])) {
      chat.items.add(_itemFrom(Map<String, Object?>.from(i as Map), images));
    }
    for (final t in (json['turns'] as List? ?? const [])) {
      chat.turns.add(TurnRecord.fromJson(Map<String, Object?>.from(t as Map)));
    }
    final data = json['providerData'];
    if (data is Map) chat.providerData.addAll(Map<String, Object?>.from(data));
    return chat;
  }
}
