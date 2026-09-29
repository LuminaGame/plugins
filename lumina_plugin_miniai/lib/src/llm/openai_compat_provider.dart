import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'llm_types.dart';

/// Any `/v1/chat/completions` server: a local `llama-server`
/// with MiniCPM5, Ollama, LM Studio, vLLM, OpenRouter, OpenAI.
class OpenAiCompatProvider implements LlmProvider {
  OpenAiCompatProvider({
    required this.name,
    required String baseUrl,
    this.apiKey,
    this.extraHeaders = const {},
    this.capabilities = const LlmCapabilities(),
    http.Client Function()? client,
  })  : baseUrl = baseUrl.endsWith('/') ? baseUrl.substring(0, baseUrl.length - 1) : baseUrl,
        _client = client ?? http.Client.new;

  final String name;

  /// e.g. `http://127.0.0.1:8080/v1`.
  final String baseUrl;
  final String? apiKey;
  final Map<String, String> extraHeaders;
  final http.Client Function() _client;

  @override
  final LlmCapabilities capabilities;

  @override
  String get id => 'openai_compat:$name';

  Map<String, String> get _headers => {
        'content-type': 'application/json',
        if (apiKey != null && apiKey!.isNotEmpty) 'authorization': 'Bearer $apiKey',
        ...extraHeaders,
      };

  @override
  Future<List<String>> listModels() async {
    final client = _client();
    try {
      final response = await client.get(Uri.parse('$baseUrl/models'), headers: _headers).timeout(const Duration(seconds: 15));
      if (response.statusCode != 200) {
        throw StateError('GET $baseUrl/models: ${response.statusCode} ${_serverMessage(response.body)}');
      }
      final json = jsonDecode(response.body);
      final data = json is Map ? json['data'] : null;
      return [for (final m in (data is List ? data : const [])) if (m is Map && m['id'] is String) m['id'] as String];
    } finally {
      client.close();
    }
  }

  /// The request body (public for tests and logging).
  Map<String, Object?> requestBody(LlmRequest request) => {
        'model': request.model,
        'stream': true,
        'stream_options': {'include_usage': true},
        'messages': [for (final m in request.messages) _message(m)],
        if (request.tools.isNotEmpty)
          'tools': [
            for (final t in request.tools)
              {
                'type': 'function',
                'function': {'name': t.name, 'description': t.description, 'parameters': t.parameters},
              },
          ],
        'temperature': ?request.temperature,
        'max_tokens': ?request.maxTokens,
      };

  static Map<String, Object?> _message(LlmMessage m) => switch (m.role) {
        LlmRole.system => {'role': 'system', 'content': m.content},
        LlmRole.user => {'role': 'user', 'content': m.content},
        LlmRole.assistant => {
            'role': 'assistant',
            'content': m.content,
            if (m.toolCalls.isNotEmpty)
              'tool_calls': [
                for (final c in m.toolCalls)
                  {
                    'id': c.id,
                    'type': 'function',
                    'function': {'name': c.name, 'arguments': c.argumentsJson},
                  },
              ],
          },
        LlmRole.tool => {'role': 'tool', 'tool_call_id': m.toolCallId, 'name': m.toolName, 'content': m.content},
      };

  @override
  Stream<LlmEvent> stream(LlmRequest request, {required CancelToken cancel}) async* {
    final client = _client();
    unawaited(cancel.whenCancelled.then((_) => client.close()));
    try {
      final httpRequest = http.Request('POST', Uri.parse('$baseUrl/chat/completions'))
        ..headers.addAll({..._headers, 'accept': 'text/event-stream'})
        ..body = jsonEncode(requestBody(request));
      final http.StreamedResponse response;
      try {
        response = await client.send(httpRequest);
      } catch (e) {
        if (cancel.isCancelled) return;
        yield LlmError('Cannot reach $baseUrl: $e', retryable: true);
        return;
      }
      if (response.statusCode != 200) {
        final body = await response.stream.bytesToString();
        yield LlmError(
          '${response.statusCode} from $baseUrl: ${_serverMessage(body)}',
          retryable: response.statusCode == 429 || response.statusCode >= 500,
          statusCode: response.statusCode,
        );
        return;
      }
      final calls = <int, _PartialCall>{};
      String? finish;
      final lines = response.stream.transform(utf8.decoder).transform(const LineSplitter());
      await for (final line in lines) {
        if (cancel.isCancelled) return;
        if (!line.startsWith('data:')) continue;
        final data = line.substring(5).trim();
        if (data == '[DONE]') break;
        if (data.isEmpty) continue;
        final Object? chunk;
        try {
          chunk = jsonDecode(data);
        } on FormatException {
          continue;
        }
        if (chunk is! Map) continue;
        final usage = chunk['usage'];
        if (usage is Map) {
          yield Usage(
            promptTokens: (usage['prompt_tokens'] as num?)?.toInt() ?? 0,
            completionTokens: (usage['completion_tokens'] as num?)?.toInt() ?? 0,
          );
        }
        final choices = chunk['choices'];
        if (choices is! List || choices.isEmpty) continue;
        final choice = choices.first as Map;
        final delta = choice['delta'];
        if (delta is Map) {
          final reasoning = delta['reasoning_content'];
          if (reasoning is String && reasoning.isNotEmpty) yield ThinkingDelta(reasoning);
          final content = delta['content'];
          if (content is String && content.isNotEmpty) yield TextDelta(content);
          final toolCalls = delta['tool_calls'];
          if (toolCalls is List) {
            for (final raw in toolCalls) {
              if (raw is! Map) continue;
              final index = (raw['index'] as num?)?.toInt() ?? calls.length;
              final partial = calls.putIfAbsent(index, _PartialCall.new);
              if (raw['id'] is String) partial.id = raw['id'] as String;
              final fn = raw['function'];
              if (fn is Map) {
                if (fn['name'] is String) partial.name += fn['name'] as String;
                if (fn['arguments'] is String) partial.arguments.write(fn['arguments'] as String);
              }
            }
          }
        }
        final reason = choice['finish_reason'];
        if (reason is String) finish = reason;
      }
      final ordered = calls.keys.toList()..sort();
      for (final i in ordered) {
        final c = calls[i]!;
        yield ToolCallEvent(LlmToolCall(
          id: c.id ?? 'call_$i',
          name: c.name,
          argumentsJson: c.arguments.isEmpty ? '{}' : c.arguments.toString(),
        ));
      }
      yield Done(finish ?? (calls.isEmpty ? 'stop' : 'tool_calls'));
    } catch (e) {
      if (cancel.isCancelled) return;
      yield LlmError('Stream from $baseUrl failed: $e', retryable: true);
    } finally {
      client.close();
    }
  }

  static String _serverMessage(String body) {
    try {
      final json = jsonDecode(body);
      if (json is Map) {
        final error = json['error'];
        if (error is Map && error['message'] is String) return error['message'] as String;
        if (error is String) return error;
      }
    } catch (_) {}
    return body.length > 300 ? '${body.substring(0, 300)}…' : body;
  }
}

class _PartialCall {
  String? id;
  String name = '';
  final StringBuffer arguments = StringBuffer();
}
