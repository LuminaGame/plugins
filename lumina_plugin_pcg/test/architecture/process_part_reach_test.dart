import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_editor_api/testing.dart';

/// lumina_plugin_pcg runs inside the editor's process (its manifest declares no
/// `process_class` and no `"isolation": "process"`), so it has no process
/// part whose imports could be limited: nothing for a separate process to
/// reach. A process part added later starts its own allow-list here, as the
/// isolated plugins do.
void main() {
  test('lumina_plugin_pcg has no process part', () {
    expect(PluginProcessReach.processLibrariesOf(Directory.current), isEmpty);
    final manifest = File('lumina_plugin_pcg.lmplugin').readAsStringSync();
    expect(manifest, isNot(contains('"isolation": "process"')));
  });
}
