import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:lumina_editor_api/lumina_editor_api.dart';

import '../llm/llm_types.dart';
import '../llm/openai_compat_provider.dart';

/// What drives a provider.
enum ProviderKind {
  /// A `/v1/chat/completions` endpoint (the local model included).
  openaiCompat,

  /// The user's installed Claude Code CLI, headless.
  claudeCode,
}

/// One model endpoint the user set up.
@immutable
class ProviderConfig {
  const ProviderConfig({
    required this.id,
    required this.name,
    required this.baseUrl,
    required this.model,
    this.supportsTools = true,
    this.local = false,
    this.kind = ProviderKind.openaiCompat,
    this.command,
  });

  /// The Claude Code provider's id.
  static const String claudeCodeId = 'claude_code';

  final String id;
  final String name;

  /// e.g. `http://127.0.0.1:8080/v1`.
  final String baseUrl;
  final String model;
  final bool supportsTools;

  /// A model on this machine (smaller tool budget, fewer rounds).
  final bool local;
  final ProviderKind kind;

  /// Claude Code: the `claude` executable the user chose; null finds it.
  final String? command;

  bool get isClaudeCode => kind == ProviderKind.claudeCode;

  /// Claude Code may leave [model] empty: the CLI's default.
  bool get isUsable => isClaudeCode || model.isNotEmpty;

  /// What the panel shows for this provider.
  String get label => isClaudeCode ? 'Claude Code${model.isEmpty ? '' : ' ($model)'}' : model;

  factory ProviderConfig.fromJson(Map<String, Object?> json) => ProviderConfig(
        id: json['id'] as String,
        name: json['name'] as String? ?? json['id'] as String,
        baseUrl: json['baseUrl'] as String? ?? '',
        model: json['model'] as String? ?? '',
        supportsTools: json['supportsTools'] as bool? ?? true,
        local: json['local'] as bool? ?? false,
        kind: ProviderKind.values.where((k) => k.name == json['kind']).firstOrNull ?? ProviderKind.openaiCompat,
        command: json['command'] as String?,
      );

  Map<String, Object?> toJson() => {
        'id': id,
        'name': name,
        'baseUrl': baseUrl,
        'model': model,
        'supportsTools': supportsTools,
        'local': local,
        if (kind != ProviderKind.openaiCompat) 'kind': kind.name,
        'command': ?command,
      };

  /// Loopback endpoints are local models.
  static bool isLoopback(String baseUrl) {
    final host = Uri.tryParse(baseUrl)?.host ?? '';
    return host == '127.0.0.1' || host == 'localhost' || host == '::1';
  }
}

/// The user's providers and keys, in the plugin's user store:
/// `providers.json` (no secrets) and `credentials.json` (the keys, never
/// logged or shown in full). `OPENAI_API_KEY` wins for api.openai.com.
class ProviderSettings extends ChangeNotifier {
  ProviderSettings(this.storage, {Map<String, String>? environment, this.httpClient}) : _environment = environment ?? Platform.environment;

  /// The HTTP client providers use (tests pass a real one: the test binding
  /// fakes dart:io's).
  final http.Client Function()? httpClient;

  final PluginStorage storage;
  final Map<String, String> _environment;

  List<ProviderConfig> providers = [];
  String? selectedId;
  final Map<String, String> _keys = {};

  /// The provider this session uses instead of the saved choice (the
  /// project's preferred provider); never persisted.
  String? sessionProviderId;

  ProviderConfig? get selected =>
      providers.where((p) => p.id == sessionProviderId).firstOrNull ??
      providers.where((p) => p.id == selectedId).firstOrNull ??
      providers.firstOrNull;

  /// Uses [id] for this session when this user has it; returns whether it did.
  bool useForSession(String? id) {
    if (id == null || !providers.any((p) => p.id == id)) return false;
    sessionProviderId = id;
    notifyListeners();
    return true;
  }
  bool get isConfigured => selected?.isUsable ?? false;

  Future<void> load() async {
    final data = await storage.readJson('providers');
    providers = [for (final p in (data?['providers'] as List? ?? const [])) ProviderConfig.fromJson(Map<String, Object?>.from(p as Map))];
    selectedId = data?['selected'] as String?;
    final keys = await storage.readJson('credentials');
    _keys
      ..clear()
      ..addAll({for (final e in (keys ?? const {}).entries) e.key: '${e.value}'});
    notifyListeners();
  }

  /// Adds or replaces [config] and selects it; [apiKey] null keeps the
  /// stored key, empty removes it.
  Future<void> save(ProviderConfig config, {String? apiKey}) async {
    providers = [for (final p in providers) if (p.id != config.id) p, config];
    selectedId = config.id;
    // An explicit choice ends the project's session override.
    sessionProviderId = null;
    await storage.writeJson('providers', {'selected': selectedId, 'providers': [for (final p in providers) p.toJson()]});
    if (apiKey != null) {
      if (apiKey.isEmpty) {
        _keys.remove(config.id);
      } else {
        _keys[config.id] = apiKey;
      }
      await _writeKeys();
    }
    notifyListeners();
  }

  Future<void> _writeKeys() async {
    await storage.writeJson('credentials', Map<String, Object?>.from(_keys));
    // Only the user reads it; Windows profiles are private.
    if (!Platform.isWindows) {
      await Process.run('chmod', ['600', '${storage.userDir.path}/credentials.json']);
    }
  }

  /// The stored keys, masked: (provider id, `sk-…abcd`).
  List<(String, String)> get storedKeys => [for (final e in _keys.entries) (e.key, mask(e.value))];

  /// Where [config]'s key comes from: the environment variable's name,
  /// `stored`, or null.
  String? keySource(ProviderConfig config) {
    if (Uri.tryParse(config.baseUrl)?.host == 'api.openai.com' && (_environment['OPENAI_API_KEY'] ?? '').isNotEmpty) return 'OPENAI_API_KEY';
    return _keys.containsKey(config.id) ? 'stored' : null;
  }

  /// Deletes the stored key of [providerId].
  Future<void> removeKey(String providerId) async {
    if (_keys.remove(providerId) == null) return;
    await _writeKeys();
    notifyListeners();
  }

  /// The key for [config]: the environment first, then the stored one.
  String? keyFor(ProviderConfig config) {
    if (Uri.tryParse(config.baseUrl)?.host == 'api.openai.com') {
      final env = _environment['OPENAI_API_KEY'];
      if (env != null && env.isNotEmpty) return env;
    }
    return _keys[config.id];
  }

  bool hasKey(ProviderConfig config) => (keyFor(config) ?? '').isNotEmpty;

  /// The provider for [config].
  LlmProvider providerFor(ProviderConfig config) => OpenAiCompatProvider(
        name: config.id,
        baseUrl: config.baseUrl,
        apiKey: keyFor(config),
        client: httpClient,
        capabilities: LlmCapabilities(tools: config.supportsTools, maxContext: config.local ? 8192 : 128000),
      );

  /// `sk-…abcd` style, for display.
  static String mask(String key) => key.length <= 8 ? '••••' : '${key.substring(0, 3)}…${key.substring(key.length - 4)}';
}
