// Every model MiniAI runs is told to let the game play 1.5 s before its
// first play-test screenshot (earlier frames can show the editor camera).
import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_plugin_miniai/lumina_plugin_miniai.dart';

void main() {
  test('the agent loop and Claude Code system prompts carry the 1.5 s play-test rule', () {
    expect(AgentLoop.playTestRule, contains('at least 1.5 s'));
    expect(AgentLoop.playTestRule, contains('"play_ms": 1500'));
    for (final mode in ApprovalMode.values) {
      expect(AgentLoop.systemPrompt(mode: mode), contains(AgentLoop.playTestRule));
    }
    expect(ClaudeCodeAgent.systemPrompt, contains(AgentLoop.playTestRule));
  });

  test('every system prompt says to think in any language and answer in the user\'s', () {
    expect(AgentLoop.languageRule, contains('think in whatever language'));
    expect(AgentLoop.languageRule, contains('language of their last message'));
    for (final mode in ApprovalMode.values) {
      expect(AgentLoop.systemPrompt(mode: mode), contains(AgentLoop.languageRule));
    }
    expect(ClaudeCodeAgent.systemPrompt, contains(AgentLoop.languageRule));
  });
}
