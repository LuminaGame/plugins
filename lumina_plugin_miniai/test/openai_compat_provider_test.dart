// Parsing real MiniCPM5 (llama.cpp b11239) SSE streams.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_plugin_miniai/lumina_plugin_miniai.dart';

import 'support/replay_server.dart';

void main() {
  late ReplayServer server;
  late OpenAiCompatProvider provider;

  setUp(() async {
    server = await ReplayServer.start();
    provider = OpenAiCompatProvider(name: 'local', baseUrl: server.baseUrl);
  });
  tearDown(() => server.close());

  Future<List<LlmEvent>> run(String fixture, {List<LlmToolSpec> tools = const []}) {
    server.queue.add(fixture);
    return provider
        .stream(LlmRequest(model: 'MiniCPM5-2B-Q4_K_M', messages: const [LlmMessage.user('hi')], tools: tools), cancel: CancelToken())
        .toList();
  }

  test('text: reasoning deltas, then the answer, then Done(stop) and usage', () async {
    final events = await run('text');
    final thinking = events.whereType<ThinkingDelta>().map((e) => e.text).join();
    final text = events.whereType<TextDelta>().map((e) => e.text).join();
    expect(thinking, isNotEmpty);
    expect(text.trim(), '4');
    expect(events.indexWhere((e) => e is ThinkingDelta), lessThan(events.indexWhere((e) => e is TextDelta)));
    expect((events.last as Done).stopReason, 'stop');
    expect(events.whereType<Usage>(), isNotEmpty);
    expect(events.whereType<ToolCallEvent>(), isEmpty);
  });

  test('tool_call: one complete call with parseable arguments, Done(tool_calls)', () async {
    final events = await run('tool_call');
    final call = events.whereType<ToolCallEvent>().single.call;
    expect(call.name, 'probe.count');
    expect(jsonDecode(call.argumentsJson), isA<Map>());
    expect(call.id, isNotEmpty);
    expect((events.last as Done).stopReason, 'tool_calls');
  });

  test('two_tool_calls: two calls in order, their fragmented arguments joined', () async {
    final calls = (await run('two_tool_calls')).whereType<ToolCallEvent>().map((e) => e.call).toList();
    expect(calls, hasLength(2));
    final args = [for (final c in calls) jsonDecode(c.argumentsJson) as Map];
    expect(calls.map((c) => c.name), everyElement('spawn_actor_from_asset'));
    expect(args[0]['asset'], 'contents/meshes/fuel_barrel_red.lmas');
    expect((args[0]['location'] as List).first, 0);
    expect((args[1]['location'] as List).first, 300);
  });

  test('the request carries the model, stream, messages and function tools', () async {
    await run('tool_call', tools: const [
      LlmToolSpec(name: 'probe.count', description: 'Counts.', parameters: {'type': 'object', 'properties': {}}),
    ]);
    final body = server.requests.single;
    expect(body['model'], 'MiniCPM5-2B-Q4_K_M');
    expect(body['stream'], isTrue);
    expect(((body['tools'] as List).single as Map)['type'], 'function');
    expect((((body['tools'] as List).single as Map)['function'] as Map)['name'], 'probe.count');
  });

  test('a 401 is a permanent error with the server message; a 503 is retryable', () async {
    server.nextError = (401, jsonEncode({'error': {'message': 'Invalid API key'}}));
    final denied = (await run('text')).single as LlmError;
    expect(denied.retryable, isFalse);
    expect(denied.statusCode, 401);
    expect(denied.message, contains('Invalid API key'));
    server.nextError = (503, 'loading model');
    final busy = (await run('text')).single as LlmError;
    expect(busy.retryable, isTrue);
  });

  test('cancel ends the stream without a Done', () async {
    server.chunkDelay = const Duration(milliseconds: 40);
    server.queue.add('two_tool_calls');
    final cancel = CancelToken();
    final events = <LlmEvent>[];
    final done = provider
        .stream(const LlmRequest(model: 'm', messages: [LlmMessage.user('hi')]), cancel: cancel)
        .listen(events.add)
        .asFuture<void>();
    await Future<void>.delayed(const Duration(milliseconds: 150));
    cancel.cancel();
    await done.timeout(const Duration(seconds: 5));
    expect(events.whereType<Done>(), isEmpty);
    expect(events.whereType<ToolCallEvent>(), isEmpty, reason: 'no half-finished call is emitted');
  });

  test('listModels reads GET /models', () async {
    expect(await provider.listModels(), ['MiniCPM5-2B-Q4_K_M']);
  });
}
