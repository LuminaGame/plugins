import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_editor_api/lumina_editor_api.dart';
import 'package:lumina_plugin_miniai/src/local/vllm_manager.dart';
import 'package:lumina_plugin_miniai/src/settings/provider_settings.dart';
import 'package:lumina_plugin_miniai/src/vllm_section.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';

void main() {
  testWidgets('Gemma runtime controls display persisted settings and installation failures', (tester) async {
    final root = Directory.systemTemp.createTempSync('vllm_widget_');
    addTearDown(() => root.deleteSync(recursive: true));
    final storage = PluginStorage(userDir: root);
    final providers = ProviderSettings(storage);
    final manager = VllmManager(storage, providers);
    addTearDown(manager.dispose); addTearDown(providers.dispose);
    await tester.pumpWidget(ShadcnApp(home: Scaffold(child: VllmSection(manager: manager))));
    expect(find.byKey(const ValueKey('miniai_vllm_install')), findsOneWidget);
    expect(find.byKey(const ValueKey('miniai_vllm_start')), findsOneWidget);
    expect(find.byKey(const ValueKey('miniai_vllm_connect')), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('miniai_vllm_endpoint')), 'http://10.5.10.3:8098/v1');
    manager.failed = true;
    manager.status = 'The runtime release could not be downloaded';
    manager.notifyListeners();
    await tester.pump();
    expect(find.text(manager.status), findsOneWidget);
    expect(find.text('Gemma 4 E4B · vllm.cpp'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}
