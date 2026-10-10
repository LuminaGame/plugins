import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_plugin_miniai/src/llm/llm_types.dart';
import 'package:lumina_plugin_miniai/src/llm/openai_compat_provider.dart';
import 'package:lumina_plugin_miniai/src/llm/sampling.dart';
import 'package:lumina_plugin_miniai/src/local/vllm_manager.dart';

void main() {
  final endpoint = Platform.environment['LUMINA_VLLM_TEST_URL'];
  test(
    'native Gemma streams text and a structured tool call through the Mini AI provider',
    () async {
      final provider = OpenAiCompatProvider(
        name: 'Gemma',
        baseUrl: endpoint!,
        backend: ServerBackend.vllmCpp,
      );
      expect(await provider.listModels(), contains(VllmManager.modelId));
      final text = await provider
          .stream(
            const LlmRequest(
              model: VllmManager.modelId,
              messages: [LlmMessage.user('Reply with the word READY.')],
              temperature: 0,
              maxTokens: 8,
            ),
            cancel: CancelToken(),
          )
          .toList();
      expect(text.whereType<LlmError>(), isEmpty);
      expect(
        text.whereType<TextDelta>().map((e) => e.text).join(),
        contains('READY'),
      );
      final tool = await provider
          .stream(
            const LlmRequest(
              model: VllmManager.modelId,
              messages: [LlmMessage.user('Call get_editor_status now.')],
              tools: [
                LlmToolSpec(
                  name: 'get_editor_status',
                  description: 'Read current editor status.',
                  parameters: {'type': 'object', 'properties': {}},
                ),
              ],
              temperature: 0,
              maxTokens: 64,
            ),
            cancel: CancelToken(),
          )
          .toList();
      expect(tool.whereType<LlmError>(), isEmpty);
      expect(
        tool.whereType<ToolCallEvent>().single.call.name,
        'get_editor_status',
      );
      expect(tool.whereType<ToolCallEvent>().single.call.argumentsJson, '{}');
    },
    skip: endpoint == null
        ? 'Set LUMINA_VLLM_TEST_URL to a real Gemma vllm.cpp endpoint.'
        : false,
    timeout: const Timeout(Duration(minutes: 4)),
  );
}
