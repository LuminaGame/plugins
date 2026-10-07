import 'dart:async';

import 'package:lumina_plugin_miniai/src/llm/chat_image.dart';

export 'chat_image.dart';

/// The provider-neutral conversation MiniAI keeps; each
/// provider converts it to and from its own API.

enum LlmRole { system, user, assistant, tool }

/// One tool call the model made.
class LlmToolCall {
  const LlmToolCall({required this.id, required this.name, required this.argumentsJson});

  final String id;
  final String name;

  /// The arguments exactly as the model wrote them (JSON text).
  final String argumentsJson;

  Map<String, Object?> toJson() => {'id': id, 'name': name, 'arguments': argumentsJson};
}

class LlmMessage {
  const LlmMessage.system(this.content)
      : role = LlmRole.system,
        toolCalls = const [],
        toolCallId = null,
        toolName = null,
        images = const [];
  const LlmMessage.user(this.content)
      : role = LlmRole.user,
        toolCalls = const [],
        toolCallId = null,
        toolName = null,
        images = const [];
  const LlmMessage.assistant(this.content, {this.toolCalls = const []})
      : role = LlmRole.assistant,
        toolCallId = null,
        toolName = null,
        images = const [];
  const LlmMessage.toolResult({required String this.toolCallId, required String this.toolName, required this.content, this.images = const []})
      : role = LlmRole.tool,
        toolCalls = const [];

  final LlmRole role;
  final String content;
  final List<LlmToolCall> toolCalls;

  /// For [LlmRole.tool]: the call it answers.
  final String? toolCallId;
  final String? toolName;

  /// For [LlmRole.tool]: the images the tool returned.
  final List<ChatImage> images;
}

/// A tool offered to the model: an MCP tool's name, description and input
/// schema.
class LlmToolSpec {
  const LlmToolSpec({required this.name, required this.description, required this.parameters});

  final String name;
  final String description;

  /// A JSON Schema object.
  final Map<String, Object?> parameters;
}

class LlmRequest {
  const LlmRequest({required this.model, required this.messages, this.tools = const [], this.temperature, this.maxTokens});

  final String model;
  final List<LlmMessage> messages;
  final List<LlmToolSpec> tools;
  final double? temperature;
  final int? maxTokens;
}

class LlmCapabilities {
  const LlmCapabilities({this.tools = true, this.streaming = true, this.vision = false, this.maxContext = 16384});

  final bool tools;
  final bool streaming;
  final bool vision;
  final int maxContext;
}

/// What a provider streams.
sealed class LlmEvent {
  const LlmEvent();
}

class TextDelta extends LlmEvent {
  const TextDelta(this.text);
  final String text;
}

class ThinkingDelta extends LlmEvent {
  const ThinkingDelta(this.text);
  final String text;
}

/// A complete tool call (its argument fragments already joined).
class ToolCallEvent extends LlmEvent {
  const ToolCallEvent(this.call);
  final LlmToolCall call;
}

class Usage extends LlmEvent {
  const Usage({required this.promptTokens, required this.completionTokens});
  final int promptTokens;
  final int completionTokens;
}

/// The stream ended normally: `stop`, `tool_calls`, `length`, …
class Done extends LlmEvent {
  const Done(this.stopReason);
  final String stopReason;
}

class LlmError extends LlmEvent {
  const LlmError(this.message, {required this.retryable, this.statusCode});
  final String message;

  /// 429, 5xx and network failures may succeed later; 4xx will not.
  final bool retryable;
  final int? statusCode;
}

/// Cancels a running [LlmProvider.stream] or agent turn.
class CancelToken {
  final Completer<void> _cancelled = Completer<void>();

  bool get isCancelled => _cancelled.isCompleted;
  Future<void> get whenCancelled => _cancelled.future;

  void cancel() {
    if (!_cancelled.isCompleted) _cancelled.complete();
  }
}

abstract class LlmProvider {
  /// `openai_compat:<name>`, "local", …
  String get id;
  LlmCapabilities get capabilities;
  Future<List<String>> listModels();
  Stream<LlmEvent> stream(LlmRequest request, {required CancelToken cancel});
}
