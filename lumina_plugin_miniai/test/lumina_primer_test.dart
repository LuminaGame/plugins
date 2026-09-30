// Every model MiniAI runs gets a short primer on how Lumina works and is
// told to read the editor's engine guide (get_lumina_guide) for a topic
// before working in an area it has not used; the local model gets a
// shorter one.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_plugin_miniai/lumina_plugin_miniai.dart';

void main() {
  test('the full primer: the guide tool, every topic, units and axes, the source of truth, compile, Maps & Modes', () {
    const p = LuminaPrimer.full;
    expect(p, contains('get_lumina_guide'));
    for (final topic in LuminaPrimer.topics) {
      expect(p, contains(topic), reason: topic);
    }
    expect(p, contains('centimetres'));
    expect(p, contains('Z is up'));
    expect(p, contains('+Y'));
    expect(p, contains('yaw 90 faces +X'));
    expect(p, contains('.lmas'));
    expect(p, contains('compile'));
    expect(p, contains('Maps & Modes'));
    expect(RegExp(r'material[^\n]*filament-materials').hasMatch(p), isTrue, reason: 'the material line points at the topic');
    expect(p.length, lessThanOrEqualTo(2400));
  });

  test('the compact primer for small local models', () {
    const p = LuminaPrimer.compact;
    expect(p, contains('get_lumina_guide'));
    expect(p, contains('cm'));
    expect(p, contains('Z up'));
    expect(p, contains('+Y'));
    expect(p.length, lessThanOrEqualTo(900));
  });

  test('the primer names exactly the topics the editor guide serves', () {
    // The editor's skill in the lumina checkout next to the plugins repo.
    final reference = Directory('${Directory.current.path}/../../lumina/lumina_ui/skills/lumina-engine/reference');
    if (!reference.existsSync()) {
      markTestSkipped('no lumina checkout next to plugins (${reference.path})');
      return;
    }
    final served = reference.listSync().whereType<File>().map((f) => f.uri.pathSegments.last.replaceAll('.md', '')).toSet();
    expect(LuminaPrimer.topics.toSet(), served);
  });

  test('the agent loop and Claude Code system prompts carry the primer; the local model gets the compact one', () {
    for (final mode in ApprovalMode.values) {
      final prompt = AgentLoop.systemPrompt(mode: mode);
      expect(prompt, contains(LuminaPrimer.full), reason: mode.name);
      expect(prompt, isNot(contains(LuminaPrimer.compact)));
    }
    final small = AgentLoop.systemPrompt(mode: ApprovalMode.ask, compactPrimer: true);
    expect(small, contains(LuminaPrimer.compact));
    expect(small, isNot(contains(LuminaPrimer.full)));
    expect(small, contains(AgentLoop.playTestRule));
    expect(ClaudeCodeAgent.systemPrompt, contains(LuminaPrimer.full));
  });
}
