import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// The server behind an OpenAI-compatible endpoint: it decides which
/// sampling fields a request may carry.
enum ServerBackend {
  llamaCpp('llama-server (llama.cpp)'),
  unslothStudio('Unsloth Studio'),
  vllm('vLLM'),
  ollama('Ollama'),
  lmStudio('LM Studio'),
  openRouter('OpenRouter'),
  openAi('OpenAI'),
  other('Other OpenAI-compatible');

  const ServerBackend(this.label);

  final String label;

  static ServerBackend? byName(Object? name) => values.where((b) => b.name == name).firstOrNull;

  /// A guess from the URL alone (known hosts and default ports).
  static ServerBackend guess(String baseUrl) {
    final uri = Uri.tryParse(baseUrl);
    final host = uri?.host ?? '';
    if (host == 'api.openai.com') return openAi;
    if (host == 'openrouter.ai' || host.endsWith('.openrouter.ai')) return openRouter;
    if (uri?.port == 11434) return ollama;
    if (uri?.port == 1234) return lmStudio;
    return other;
  }

  /// Servers that run open-weight models (the local-style defaults apply).
  bool get runsOpenModels => this != openAi && this != openRouter;
}

/// Finds the [ServerBackend] behind an endpoint with a few harmless GETs on
/// the server root.
class ServerBackendProbe {
  const ServerBackendProbe._();

  static Future<ServerBackend> detect(String baseUrl, {String? apiKey, http.Client Function()? client}) async {
    final known = ServerBackend.guess(baseUrl);
    if (known == ServerBackend.openAi || known == ServerBackend.openRouter) return known;
    var root = baseUrl.endsWith('/') ? baseUrl.substring(0, baseUrl.length - 1) : baseUrl;
    if (root.endsWith('/v1')) root = root.substring(0, root.length - 3);
    final c = (client ?? http.Client.new)();
    final headers = {if (apiKey != null && apiKey.isNotEmpty) 'authorization': 'Bearer $apiKey'};
    Future<http.Response?> get(String path) async {
      try {
        return await c.get(Uri.parse('$root$path'), headers: headers).timeout(const Duration(seconds: 5));
      } catch (_) {
        return null;
      }
    }

    Object? json(http.Response r) {
      try {
        return jsonDecode(r.body);
      } catch (_) {
        return null;
      }
    }

    bool unsloth(http.Response? r) => (r?.headers['server'] ?? '').toLowerCase().contains('unsloth');
    try {
      // All at once: an unreachable port costs its timeout only once.
      final [props, ollama, lmStudio, version] = await Future.wait([get('/props'), get('/api/version'), get('/api/v0/models'), get('/version')]);
      // Unsloth Studio answers /props like the llama-server it runs.
      if ([props, ollama, lmStudio, version].any(unsloth)) return ServerBackend.unslothStudio;
      if (props != null && props.statusCode == 200) {
        final body = json(props);
        if (body is Map && body.containsKey('default_generation_settings')) return ServerBackend.llamaCpp;
      }
      if (ollama != null && ollama.statusCode == 200 && json(ollama) is Map && (json(ollama) as Map)['version'] is String) {
        return ServerBackend.ollama;
      }
      if (lmStudio != null && lmStudio.statusCode == 200 && json(lmStudio) is Map) return ServerBackend.lmStudio;
      if (version != null && version.statusCode == 200 && json(version) is Map && (json(version) as Map)['version'] is String) {
        return ServerBackend.vllm;
      }
      return known;
    } finally {
      c.close();
    }
  }
}

/// One sampling field: its canonical (llama.cpp) name, the UI text and the
/// accepted range.
@immutable
class SamplingField {
  const SamplingField(this.name, this.label, this.help, {required this.min, required this.max, this.integer = false});

  final String name;
  final String label;
  final String help;
  final num min;
  final num max;
  final bool integer;

  bool accepts(num value) => value >= min && value <= max && (!integer || value == value.roundToDouble());
}

/// A provider's sampling settings: canonical llama.cpp-style names, unset
/// fields absent (the server's defaults apply).
@immutable
class SamplingSettings {
  const SamplingSettings([this.values = const {}]);

  static const String temperature = 'temperature';
  static const String topP = 'top_p';
  static const String topK = 'top_k';
  static const String minP = 'min_p';
  static const String repeatPenalty = 'repeat_penalty';
  static const String repeatLastN = 'repeat_last_n';
  static const String presencePenalty = 'presence_penalty';
  static const String frequencyPenalty = 'frequency_penalty';
  static const String dryMultiplier = 'dry_multiplier';
  static const String dryBase = 'dry_base';
  static const String dryAllowedLength = 'dry_allowed_length';
  static const String maxTokens = 'max_tokens';
  static const String seed = 'seed';

  /// Every field, in the order the dialog shows them.
  static const List<SamplingField> fields = [
    SamplingField(temperature, 'Temperature', 'Randomness. Lower is more focused; too low can loop.', min: 0, max: 2),
    SamplingField(topP, 'Top P', 'Keeps the most likely tokens up to this total probability.', min: 0, max: 1),
    SamplingField(topK, 'Top K', 'Keeps only this many most likely tokens (0 = off).', min: 0, max: 1000, integer: true),
    SamplingField(minP, 'Min P', 'Drops tokens less likely than this share of the best one.', min: 0, max: 1),
    SamplingField(repeatPenalty, 'Repeat penalty', 'Above 1 makes recently used tokens less likely (1 = off).', min: 1, max: 2),
    SamplingField(repeatLastN, 'Repeat window', 'How many recent tokens the penalties look at (llama.cpp, -1 = the whole context).',
        min: -1, max: 262144, integer: true),
    SamplingField(presencePenalty, 'Presence penalty', 'Penalises any token already used; curbs endless repetition (0 = off).', min: -2, max: 2),
    SamplingField(frequencyPenalty, 'Frequency penalty', 'Penalises tokens by how often they were used (0 = off).', min: -2, max: 2),
    SamplingField(dryMultiplier, 'DRY multiplier', 'Penalises repeated token sequences (0 = off). Can hurt code.', min: 0, max: 5),
    SamplingField(dryBase, 'DRY base', 'How fast the DRY penalty grows with the repeat length.', min: 1, max: 4),
    SamplingField(dryAllowedLength, 'DRY allowed length', 'Repeats up to this many tokens are not penalised.', min: 1, max: 100, integer: true),
    SamplingField(maxTokens, 'Max output tokens', 'The longest answer per request (empty = the server limit).', min: 1, max: 1000000, integer: true),
    SamplingField(seed, 'Seed', 'Fixed seed for repeatable answers (empty = random).', min: -1, max: 4294967295, integer: true),
  ];

  /// Set fields only.
  final Map<String, num> values;

  num? operator [](String name) => values[name];

  bool get isEmpty => values.isEmpty;

  /// [name] set to [value] (null unsets it).
  SamplingSettings withValue(String name, num? value) {
    final next = Map<String, num>.of(values);
    if (value == null) {
      next.remove(name);
    } else {
      next[name] = value;
    }
    return SamplingSettings(Map.unmodifiable(next));
  }

  /// The fields of [backend]'s request schema.
  static List<SamplingField> fieldsFor(ServerBackend backend) => [for (final f in fields) if (_wireName(backend, f.name, null) != null) f];

  /// The request name of [name] on [backend]; null when the server does not
  /// take it.
  static String? _wireName(ServerBackend backend, String name, String? model) {
    const standard = {temperature, topP, presencePenalty, frequencyPenalty, maxTokens, seed};
    switch (backend) {
      case ServerBackend.llamaCpp:
        return name;
      case ServerBackend.unslothStudio || ServerBackend.vllm || ServerBackend.openRouter:
        if (name == repeatPenalty) return 'repetition_penalty';
        return standard.contains(name) || name == topK || name == minP ? name : null;
      case ServerBackend.lmStudio:
        return standard.contains(name) || name == topK || name == repeatPenalty ? name : null;
      case ServerBackend.ollama || ServerBackend.other:
        return standard.contains(name) ? name : null;
      case ServerBackend.openAi:
        if (!standard.contains(name)) return null;
        if (name == maxTokens) return 'max_completion_tokens';
        if (model != null && isOpenAiReasoningModel(model) && name != seed) return null;
        return name;
    }
  }

  /// OpenAI models that reject temperature, top_p and the penalties.
  static bool isOpenAiReasoningModel(String model) {
    final m = model.toLowerCase();
    return RegExp(r'^(o\d|gpt-5)').hasMatch(m) && !m.contains('chat');
  }

  /// The request fields for [backend] and [model]; unsupported fields are
  /// left out.
  Map<String, Object?> toBody(ServerBackend backend, {required String model}) => {
        for (final e in values.entries) ?_wireName(backend, e.key, model): e.value,
      };

  Map<String, Object?> toJson() => Map<String, Object?>.of(values);

  factory SamplingSettings.fromJson(Map<String, Object?> json) => SamplingSettings(Map.unmodifiable({
        for (final f in fields)
          if (json[f.name] case final num v) f.name: f.integer ? v.round() : v,
      }));

  @override
  bool operator ==(Object other) =>
      other is SamplingSettings && other.values.length == values.length && values.entries.every((e) => other.values[e.key] == e.value);

  @override
  int get hashCode => Object.hashAllUnordered(values.entries.map((e) => Object.hash(e.key, e.value)));

  @override
  String toString() => 'SamplingSettings($values)';
}

/// The recommended settings per model family: what the model's vendor
/// recommends, with the repetition control it suggests against loops.
class SamplingDefaults {
  const SamplingDefaults._();

  /// The defaults for [model] on [backend] and where they come from.
  static (SamplingSettings, String) withSource(String model, ServerBackend backend) {
    final m = model.toLowerCase();
    const s = SamplingSettings.new;
    if (m.contains('minicpm')) {
      return (
        s(const {SamplingSettings.temperature: 1.0, SamplingSettings.topP: 0.95, SamplingSettings.minP: 0.0, SamplingSettings.repeatPenalty: 1.05}),
        'MiniCPM5 model card (repeat penalty 1.05 against repetition, min_p 0)',
      );
    }
    final qwen = m.contains('qwen') || m.contains('qwq') || m.contains('ornith');
    if (qwen && m.contains('coder')) {
      return (
        s(const {SamplingSettings.temperature: 0.7, SamplingSettings.topP: 0.8, SamplingSettings.topK: 20, SamplingSettings.minP: 0.0, SamplingSettings.repeatPenalty: 1.05}),
        'Qwen3-Coder model card',
      );
    }
    if (qwen && m.contains('instruct')) {
      return (
        s(const {SamplingSettings.temperature: 0.7, SamplingSettings.topP: 0.8, SamplingSettings.topK: 20, SamplingSettings.minP: 0.0, SamplingSettings.presencePenalty: 1.5}),
        'Qwen3.5 model card, instruct mode (presence penalty against endless repetition)',
      );
    }
    if (qwen) {
      return (
        s(const {SamplingSettings.temperature: 0.6, SamplingSettings.topP: 0.95, SamplingSettings.topK: 20, SamplingSettings.minP: 0.0, SamplingSettings.presencePenalty: 1.5}),
        '${m.contains('ornith') ? 'Ornith-1.0 (Qwen3.5) model card' : 'Qwen3.5 model card'}, thinking mode, with presence penalty 1.5 against endless repetition',
      );
    }
    if (m.contains('gemma')) {
      return (
        s(const {SamplingSettings.temperature: 1.0, SamplingSettings.topP: 0.95, SamplingSettings.topK: 64, SamplingSettings.minP: 0.0}),
        'Gemma model card',
      );
    }
    if (m.contains('gpt-oss')) {
      return (s(const {SamplingSettings.temperature: 1.0, SamplingSettings.topP: 1.0}), 'gpt-oss model card');
    }
    if (m.contains('deepseek')) {
      return (s(const {SamplingSettings.temperature: 0.6, SamplingSettings.topP: 0.95}), 'DeepSeek-R1 model card');
    }
    if (RegExp(r'(mistral|ministral|devstral|magistral)').hasMatch(m)) {
      return (s(const {SamplingSettings.temperature: 0.15}), 'Mistral model card');
    }
    if (m.contains('llama')) {
      return (s(const {SamplingSettings.temperature: 0.6, SamplingSettings.topP: 0.9}), 'Llama 3 generation config');
    }
    if (!backend.runsOpenModels) return (const SamplingSettings(), '${backend.label} defaults');
    return (
      s(const {SamplingSettings.temperature: 0.7, SamplingSettings.topP: 0.95, SamplingSettings.topK: 40, SamplingSettings.minP: 0.05, SamplingSettings.repeatPenalty: 1.05}),
      'general settings against repetition (unknown model family)',
    );
  }

  static SamplingSettings forModel(String model, ServerBackend backend) => withSource(model, backend).$1;
}
