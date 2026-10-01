// Sampling settings: what each server type gets in the request body, the
// defaults per model family, the saved format and the server-type probe.
// Real local HTTP servers (the replay server with recorded streams, and
// servers answering the probe paths the way each server does).
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_editor_api/lumina_editor_api.dart';
import 'package:lumina_plugin_miniai/lumina_plugin_miniai.dart';

import 'support/replay_server.dart';

/// Every field set.
const SamplingSettings _all = SamplingSettings({
  SamplingSettings.temperature: 0.6,
  SamplingSettings.topP: 0.95,
  SamplingSettings.topK: 20,
  SamplingSettings.minP: 0.0,
  SamplingSettings.repeatPenalty: 1.05,
  SamplingSettings.repeatLastN: 256,
  SamplingSettings.presencePenalty: 1.5,
  SamplingSettings.frequencyPenalty: 0.1,
  SamplingSettings.dryMultiplier: 0.8,
  SamplingSettings.dryBase: 1.75,
  SamplingSettings.dryAllowedLength: 2,
  SamplingSettings.maxTokens: 4096,
  SamplingSettings.seed: 7,
});

const Set<String> _base = {'model', 'stream', 'stream_options', 'messages'};

void main() {
  group('request body per server type (replay server)', () {
    late ReplayServer server;
    setUp(() async => server = await ReplayServer.start());
    tearDown(() => server.close());

    Future<Map<String, Object?>> sent(ServerBackend backend, {String model = 'm', SamplingSettings sampling = _all}) async {
      server.queue.add('text');
      final provider = OpenAiCompatProvider(name: 't', baseUrl: server.baseUrl, backend: backend, sampling: sampling, client: realHttpClient);
      await provider.stream(LlmRequest(model: model, messages: const [LlmMessage.user('hi')]), cancel: CancelToken()).toList();
      return server.requests.last;
    }

    Set<String> fields(Map<String, Object?> body) => body.keys.toSet().difference(_base);

    test('llama-server gets every field under its own names', () async {
      final body = await sent(ServerBackend.llamaCpp);
      expect(fields(body), {
        'temperature', 'top_p', 'top_k', 'min_p', 'repeat_penalty', 'repeat_last_n', 'presence_penalty', 'frequency_penalty', //
        'dry_multiplier', 'dry_base', 'dry_allowed_length', 'max_tokens', 'seed',
      });
      expect(body['repeat_penalty'], 1.05);
      expect(body['top_k'], 20);
    });

    test('Unsloth Studio, vLLM and OpenRouter get repetition_penalty, top_k, min_p, and no llama.cpp-only fields', () async {
      for (final backend in [ServerBackend.unslothStudio, ServerBackend.vllm, ServerBackend.openRouter]) {
        final body = await sent(backend);
        expect(fields(body), {
          'temperature', 'top_p', 'top_k', 'min_p', 'repetition_penalty', 'presence_penalty', 'frequency_penalty', 'max_tokens', 'seed',
        }, reason: backend.name);
        expect(body['repetition_penalty'], 1.05);
      }
    });

    test('LM Studio gets repeat_penalty and top_k but not min_p', () async {
      expect(fields(await sent(ServerBackend.lmStudio)), {
        'temperature', 'top_p', 'top_k', 'repeat_penalty', 'presence_penalty', 'frequency_penalty', 'max_tokens', 'seed',
      });
    });

    test('Ollama and other servers get the standard fields only', () async {
      for (final backend in [ServerBackend.ollama, ServerBackend.other]) {
        expect(fields(await sent(backend)), {'temperature', 'top_p', 'presence_penalty', 'frequency_penalty', 'max_tokens', 'seed'});
      }
    });

    test('OpenAI gets exactly its own fields, max_completion_tokens; reasoning models no sampling', () async {
      final body = await sent(ServerBackend.openAi, model: 'gpt-4o');
      expect(fields(body), {'temperature', 'top_p', 'presence_penalty', 'frequency_penalty', 'max_completion_tokens', 'seed'});
      expect(body['max_completion_tokens'], 4096);
      for (final model in ['o3-mini', 'o1', 'gpt-5', 'gpt-5-mini']) {
        expect(fields(await sent(ServerBackend.openAi, model: model)), {'max_completion_tokens', 'seed'}, reason: model);
      }
      expect(fields(await sent(ServerBackend.openAi, model: 'gpt-5-chat-latest')), contains('temperature'));
    });

    test('unset fields are absent; an explicit request temperature wins', () async {
      final body = await sent(ServerBackend.llamaCpp, sampling: const SamplingSettings({SamplingSettings.temperature: 0.6}));
      expect(fields(body), {'temperature'});
      expect(fields(await sent(ServerBackend.llamaCpp, sampling: const SamplingSettings())), isEmpty);
      server.queue.add('text');
      await OpenAiCompatProvider(name: 't', baseUrl: server.baseUrl, backend: ServerBackend.llamaCpp, sampling: _all, client: realHttpClient)
          .stream(const LlmRequest(model: 'm', messages: [LlmMessage.user('hi')], temperature: 0.2), cancel: CancelToken())
          .toList();
      expect(server.requests.last['temperature'], 0.2);
    });
  });

  group('defaults', () {
    test('Ornith (Qwen3.5) on Unsloth Studio: 0.6 / 0.95 / 20 / 0 with presence penalty 1.5', () {
      final (d, source) = SamplingDefaults.withSource('s-batman/Ornith-1.0-35B-NVFP4-MTP-GGUF:ornith-1.0-35b-NVFP4-MTP', ServerBackend.unslothStudio);
      expect(d.values, {'temperature': 0.6, 'top_p': 0.95, 'top_k': 20, 'min_p': 0.0, 'presence_penalty': 1.5});
      expect(source, contains('Ornith'));
      expect(d.toBody(ServerBackend.unslothStudio, model: 'x'), {'temperature': 0.6, 'top_p': 0.95, 'top_k': 20, 'min_p': 0.0, 'presence_penalty': 1.5});
    });

    test('MiniCPM5 on llama-server: 1.0 / 0.95 / min_p 0 / repeat penalty 1.05', () {
      expect(SamplingDefaults.forModel('MiniCPM5-2B-Q4_K_M', ServerBackend.llamaCpp).values,
          {'temperature': 1.0, 'top_p': 0.95, 'min_p': 0.0, 'repeat_penalty': 1.05});
    });

    test('a cloud model on OpenAI keeps the provider defaults; an unknown open model gets anti-repetition settings', () {
      expect(SamplingDefaults.forModel('gpt-4o', ServerBackend.openAi).isEmpty, isTrue);
      expect(SamplingDefaults.forModel('some-model', ServerBackend.llamaCpp)[SamplingSettings.repeatPenalty], 1.05);
      expect(SamplingDefaults.forModel('Qwen3.5-35B-A3B-Instruct', ServerBackend.vllm)[SamplingSettings.topP], 0.8);
      expect(SamplingDefaults.forModel('gemma-4-12B-it', ServerBackend.lmStudio)[SamplingSettings.topK], 64);
    });
  });

  group('saved with the provider config', () {
    late Directory temp;
    setUp(() async => temp = await Directory.systemTemp.createTemp('miniai_sampling_'));
    tearDown(() => temp.delete(recursive: true));

    PluginStorage storage() => PluginStorage(userDir: Directory('${temp.path}/user'), projectDir: Directory('${temp.path}/project'));

    test('backend and sampling round-trip; no key in providers.json, no sampling in credentials.json', () async {
      final settings = ProviderSettings(storage(), environment: const {});
      const sampling = SamplingSettings({SamplingSettings.temperature: 0.5, SamplingSettings.repeatLastN: 128});
      await settings.save(
        const ProviderConfig(id: 'ornith', name: 'Ornith', baseUrl: 'http://10.0.0.2:8888/v1', model: 'ornith', backend: ServerBackend.unslothStudio, sampling: sampling),
        apiKey: 'sk-sampling-0123456789',
      );
      final again = ProviderSettings(storage(), environment: const {});
      await again.load();
      final config = again.providers.single;
      expect(config.backend, ServerBackend.unslothStudio);
      expect(config.sampling, sampling);
      expect(config.effectiveSampling, sampling);
      final providers = File('${temp.path}/user/providers.json').readAsStringSync();
      expect(providers, isNot(contains('sk-sampling')));
      expect(File('${temp.path}/user/credentials.json').readAsStringSync(), isNot(contains('temperature')));
      expect(((jsonDecode(providers) as Map)['providers'] as List).single, containsPair('sampling', {'temperature': 0.5, 'repeat_last_n': 128}));
    });

    test('a config saved before sampling existed loads with a guessed server type and the defaults', () async {
      Directory('${temp.path}/user').createSync(recursive: true);
      File('${temp.path}/user/providers.json').writeAsStringSync(jsonEncode({
        'selected': 'local_model',
        'providers': [
          {'id': 'local_model', 'name': 'Local model', 'baseUrl': 'http://10.5.10.3:8888/v1', 'model': 'Ornith-1.0-35B', 'supportsTools': true, 'local': false, 'vision': true},
        ],
      }));
      final settings = ProviderSettings(storage(), environment: const {});
      await settings.load();
      final config = settings.selected!;
      expect(config.backend, isNull);
      expect(config.effectiveBackend, ServerBackend.other);
      expect(config.effectiveSampling[SamplingSettings.presencePenalty], 1.5);
      expect(ServerBackend.guess('http://127.0.0.1:11434/v1'), ServerBackend.ollama);
      expect(ServerBackend.guess('https://api.openai.com/v1'), ServerBackend.openAi);
    });

    test('updateSampling changes one provider and keeps the selection', () async {
      final settings = ProviderSettings(storage(), environment: const {});
      await settings.save(const ProviderConfig(id: 'a', name: 'A', baseUrl: 'http://127.0.0.1:1/v1', model: 'MiniCPM5-2B-Q4_K_M'));
      await settings.save(const ProviderConfig(id: 'b', name: 'B', baseUrl: 'http://127.0.0.1:2/v1', model: 'x'));
      await settings.updateSampling('a', const SamplingSettings({SamplingSettings.temperature: 0.3}), backend: ServerBackend.llamaCpp);
      expect(settings.selected!.id, 'b');
      final again = ProviderSettings(storage(), environment: const {});
      await again.load();
      final a = again.providers.firstWhere((p) => p.id == 'a');
      expect(a.sampling![SamplingSettings.temperature], 0.3);
      expect(a.backend, ServerBackend.llamaCpp);
    });
  });

  group('server type probe (real local servers)', () {
    /// A server that answers [routes] (path → (status, headers, body)) and
    /// 404 with [serverHeader] for the rest.
    Future<HttpServer> serve(Map<String, (int, String)> routes, {String? serverHeader}) async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        final route = routes[request.uri.path];
        request.response.headers.set('server', serverHeader ?? 'test');
        request.response.statusCode = route?.$1 ?? 404;
        request.response.headers.contentType = ContentType.json;
        request.response.write(route?.$2 ?? '{"detail":"Not Found"}');
        await request.response.close();
      });
      return server;
    }

    Future<ServerBackend> detect(HttpServer s) => ServerBackendProbe.detect('http://127.0.0.1:${s.port}/v1', client: realHttpClient);

    test('Unsloth Studio (its server header; it also answers /props), llama-server, Ollama, LM Studio, vLLM, other', () async {
      final cases = <ServerBackend, HttpServer>{
        // The shape of the user's server (Unsloth Studio v0.1.900-beta).
        ServerBackend.unslothStudio: await serve({
          '/props': (200, '{"default_generation_settings":{"params":{}},"build_info":"unsloth-studio/v0.1.900-beta"}'),
          '/version': (200, '{"version":"v0.1.900-beta"}'),
        }, serverHeader: 'unsloth-studio'),
        ServerBackend.llamaCpp: await serve({'/props': (200, '{"default_generation_settings":{"params":{}},"build_info":"b11239-66e665c42"}')}),
        ServerBackend.ollama: await serve({'/api/version': (200, '{"version":"0.12.3"}')}),
        ServerBackend.lmStudio: await serve({'/api/v0/models': (200, '{"object":"list","data":[]}')}),
        ServerBackend.vllm: await serve({'/version': (200, '{"version":"0.11.0"}')}, serverHeader: 'uvicorn'),
        ServerBackend.other: await serve({}),
      };
      try {
        for (final e in cases.entries) {
          expect(await detect(e.value), e.key, reason: e.key.name);
        }
      } finally {
        for (final s in cases.values) {
          await s.close(force: true);
        }
      }
    });

    test('OpenAI and OpenRouter by host, without a request', () async {
      expect(await ServerBackendProbe.detect('https://api.openai.com/v1', client: () => throw StateError('no request')), ServerBackend.openAi);
      expect(await ServerBackendProbe.detect('https://openrouter.ai/api/v1', client: () => throw StateError('no request')), ServerBackend.openRouter);
    });
  });
}
