// Tool-result images: what an OpenAI-compatible model gets (pixels or a
// placeholder), which models read images, and how a chat keeps them.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_editor_api/lumina_editor_api.dart';
import 'package:lumina_plugin_miniai/lumina_plugin_miniai.dart';

import 'support/local_mcp.dart';
import 'support/png.dart';
import 'support/replay_server.dart';

void main() {
  late Uint8List png;

  setUpAll(() async => png = await renderPng(64, 48));

  ChatImage image(String id, String source) =>
      ChatImage.fromContent(McpContent.image(png), id: id, source: source)!;

  List<LlmMessage> round(String callId, List<ChatImage> images, {String text = 'Took a screenshot.'}) => [
        LlmMessage.assistant('', toolCalls: [LlmToolCall(id: callId, name: 'viewport_screenshot', argumentsJson: '{}')]),
        LlmMessage.toolResult(toolCallId: callId, toolName: 'viewport_screenshot', content: text, images: images),
      ];

  OpenAiCompatProvider provider({required bool vision}) =>
      OpenAiCompatProvider(name: 't', baseUrl: 'http://127.0.0.1:9/v1', capabilities: LlmCapabilities(vision: vision));

  test('a real PNG from MCP content: its size and dimensions', () {
    final i = image('img1', 'viewport_screenshot (call_1)');
    expect((i.width, i.height), (64, 48));
    expect(i.bytes, png.length);
    expect(i.mimeType, 'image/png');
    expect(i.describe, startsWith('image/png 64×48, '));
    expect(i.decoded, png);
  });

  test('vision: the tool message points below, and a user message carries the captioned image_url', () {
    final body = provider(vision: true).requestBody(LlmRequest(model: 'gpt-4o', messages: [
      const LlmMessage.system('sys'),
      const LlmMessage.user('Look at the level'),
      ...round('call_1', [image('img1', 'viewport_screenshot (call_1)')]),
    ]));
    final messages = (body['messages'] as List).cast<Map>();
    expect(messages.map((m) => m['role']), ['system', 'user', 'assistant', 'tool', 'user']);
    expect(messages[3]['content'], 'Took a screenshot.\n[image 1: attached below]');
    final parts = (messages[4]['content'] as List).cast<Map>();
    expect(parts[0], {'type': 'text', 'text': 'Image 1 from viewport_screenshot (call_1):'});
    expect(parts[1]['type'], 'image_url');
    final url = (parts[1]['image_url'] as Map)['url'] as String;
    expect(url, startsWith('data:image/png;base64,'));
    expect(base64Decode(url.substring('data:image/png;base64,'.length)), png);
  });

  test('only the newest two images are pixels; the oldest is a placeholder', () {
    final body = provider(vision: true).requestBody(LlmRequest(model: 'gpt-4o', messages: [
      const LlmMessage.user('Take three screenshots'),
      ...round('call_1', [image('img1', 'viewport_screenshot (call_1)')]),
      ...round('call_2', [image('img2', 'viewport_screenshot (call_2)')]),
      ...round('call_3', [image('img3', 'viewport_screenshot (call_3)')]),
    ]));
    final messages = (body['messages'] as List).cast<Map>();
    final tools = messages.where((m) => m['role'] == 'tool').toList();
    expect(tools[0]['content'], contains('image/png 64×48'));
    expect(tools[0]['content'], contains('not shown to the model'));
    expect(tools[1]['content'], endsWith('[image 1: attached below]'));
    expect(tools[2]['content'], endsWith('[image 1: attached below]'));
    final urls = [
      for (final m in messages)
        if (m['content'] is List)
          for (final p in (m['content'] as List).cast<Map>())
            if (p['type'] == 'image_url') p,
    ];
    expect(urls, hasLength(2));
    // Every tool message is answered before the images' user message.
    final last = messages.lastIndexWhere((m) => m['role'] == 'tool');
    expect(messages[last + 1]['role'], 'user');
  });

  test('without vision no pixels go out, only the placeholder', () {
    final body = provider(vision: false).requestBody(LlmRequest(model: 'MiniCPM5-2B-Q4_K_M', messages: [
      const LlmMessage.user('Look'),
      ...round('call_1', [image('img1', 'viewport_screenshot (call_1)')], text: ''),
    ]));
    final encoded = jsonEncode(body);
    expect(encoded, isNot(contains('image_url')));
    expect(encoded, isNot(contains('base64')));
    final tool = (body['messages'] as List).cast<Map>().firstWhere((m) => m['role'] == 'tool');
    expect(tool['content'], matches(RegExp(r'^\[image/png 64×48, \d+ KB produced by the tool; not shown to the model\]$')));
  });

  test('which models read images, and the per-provider override', () {
    for (final m in ['gpt-4o-mini', 'claude-sonnet-4-5', 'gemini-2.5-flash', 'llava-1.6', 'Qwen2.5-VL-7B', 'MiniCPM-V-2_6', 'gemma3:12b', 'o3-mini']) {
      expect(VisionModels.guess(m), isTrue, reason: m);
    }
    for (final m in ['MiniCPM5-2B-Q4_K_M', 'llama-3.1-8b', 'gpt-3.5-turbo', 'qwen2.5-coder-7b']) {
      expect(VisionModels.guess(m), isFalse, reason: m);
    }
    const auto = ProviderConfig(id: 'a', name: 'A', baseUrl: 'http://x/v1', model: 'gpt-4o');
    expect(auto.acceptsImages, isTrue);
    const off = ProviderConfig(id: 'a', name: 'A', baseUrl: 'http://x/v1', model: 'gpt-4o', vision: false);
    expect(off.acceptsImages, isFalse);
    const on = ProviderConfig(id: 'l', name: 'L', baseUrl: 'http://x/v1', model: 'MiniCPM5-2B-Q4_K_M', vision: true);
    expect(on.acceptsImages, isTrue);
    expect(ProviderConfig.fromJson(off.toJson()).vision, isFalse);
    expect(ProviderConfig.fromJson(auto.toJson()).vision, isNull);
    expect(auto.toJson().containsKey('vision'), isFalse);
  });

  test('a provider built from the settings reads images only when the model does', () async {
    final temp = Directory.systemTemp.createTempSync('miniai_vision_');
    addTearDown(() => temp.deleteSync(recursive: true));
    final settings = ProviderSettings(PluginStorage(userDir: temp), environment: const {});
    expect(settings.providerFor(const ProviderConfig(id: 'a', name: 'A', baseUrl: 'http://x/v1', model: 'gpt-4o')).capabilities.vision, isTrue);
    expect(settings.providerFor(const ProviderConfig(id: 'l', name: 'L', baseUrl: 'http://x/v1', model: 'MiniCPM5-2B-Q4_K_M')).capabilities.vision, isFalse);
  });

  group('agent loop', () {
    late ReplayServer server;
    late LocalMcp mcp;

    setUp(() async {
      server = await ReplayServer.start();
      mcp = LocalMcp()
        ..registerTool(McpTool(
          name: 'probe.count',
          description: 'Counts the actors and shows the viewport.',
          inputSchema: McpSchema.object({}),
          handler: (_) => McpToolResult([McpContent.text('{"count": 5}'), McpContent.image(png)]),
          risk: McpToolRisk.readOnly,
          groups: {McpToolGroups.level},
        ));
    });
    tearDown(() => server.close());

    test('a tool image lands on the card and, for a vision model, in the next request', () async {
      server.queue.addAll(['tool_call', 'tool_result_answer']);
      final chat = Chat(id: 'v1');
      await AgentLoop(
        provider: OpenAiCompatProvider(name: 'v', baseUrl: server.baseUrl, capabilities: const LlmCapabilities(vision: true)),
        model: 'MiniCPM5-2B-Q4_K_M',
        mcp: mcp,
      ).run(chat, 'How many actors are in the level? Use the tool.');
      final card = chat.items.whereType<ToolCallItem>().single;
      expect(card.images, hasLength(1));
      expect(card.images.single.decoded, png);
      expect(card.result, '{"count": 5}');
      expect(card.result, isNot(contains('[image]')));
      final second = (server.requests[1]['messages'] as List).cast<Map>();
      final tool = second.lastWhere((m) => m['role'] == 'tool');
      expect(tool['content'], '{"count": 5}\n[image 1: attached below]');
      final images = second.last;
      expect(images['role'], 'user');
      expect(jsonEncode(images['content']), contains('data:image/png;base64,'));
      expect(jsonEncode(images['content']), contains('Image 1 from probe.count (${card.call.id}):'));
    });

    test('a text-only model gets the placeholder', () async {
      server.queue.addAll(['tool_call', 'tool_result_answer']);
      final chat = Chat(id: 'v2');
      await AgentLoop(provider: OpenAiCompatProvider(name: 'v', baseUrl: server.baseUrl), model: 'MiniCPM5-2B-Q4_K_M', mcp: mcp)
          .run(chat, 'How many actors are in the level? Use the tool.');
      final encoded = jsonEncode(server.requests[1]);
      expect(encoded, isNot(contains('image_url')));
      expect(encoded, contains('not shown to the model'));
    });
  });

  test('a chat keeps the newest 12 images with pixels; older ones keep their size', () async {
    final temp = Directory.systemTemp.createTempSync('miniai_images_');
    addTearDown(() => temp.deleteSync(recursive: true));
    final chat = Chat(id: 'imgs');
    chat.items.add(UserItem('Take 14 screenshots'));
    for (var n = 1; n <= 14; n++) {
      final i = image(chat.newImageId(), 'viewport_screenshot (call_$n)');
      final call = LlmToolCall(id: 'call_$n', name: 'viewport_screenshot', argumentsJson: '{}');
      chat.items.add(ToolCallItem(call: call, risk: McpToolRisk.readOnly)
        ..status = ToolCallStatus.done
        ..images = [i]);
      chat.history.add(LlmMessage.toolResult(toolCallId: call.id, toolName: call.name, content: '', images: [i]));
    }
    final store = ChatStore(temp);
    await store.save(chat);
    final loaded = (await store.load('imgs'))!;
    final cards = loaded.items.whereType<ToolCallItem>().toList();
    expect(cards, hasLength(14));
    expect(cards.take(2).map((c) => c.images.single.kept), [false, false]);
    expect(cards.skip(2).every((c) => c.images.single.kept), isTrue);
    expect(cards.first.images.single.width, 64);
    expect(cards.last.images.single.decoded, png);
    expect(identical(loaded.history.last.images.single, cards.last.images.single), isTrue, reason: 'one image, shared');
    expect(loaded.newImageId(), 'img15');
  });

  test('Claude Code tool results: image blocks become images, not "[image]" text', () {
    final data = base64Encode(png);
    final line = jsonEncode({
      'type': 'user',
      'message': {
        'role': 'user',
        'content': [
          {
            'type': 'tool_result',
            'tool_use_id': 'toolu_1',
            'content': [
              {'type': 'text', 'text': 'Viewport 64×48'},
              {
                'type': 'image',
                'source': {'type': 'base64', 'media_type': 'image/png', 'data': data},
              },
            ],
          },
        ],
      },
      'parent_tool_use_id': null,
    });
    final result = ClaudeCodeProtocol.parse(line) as ClaudeToolResult;
    expect(result.text, 'Viewport 64×48');
    expect(result.images, hasLength(1));
    final i = ChatImage.fromContent(result.images.single, id: 'img1')!;
    expect((i.width, i.height), (64, 48));
    expect(i.mimeType, 'image/png');
  });
}
