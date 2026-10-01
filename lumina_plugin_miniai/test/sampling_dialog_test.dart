// Model provider…'s "Advanced / Sampling" section: collapsed by default,
// the model's defaults for the server type, edits saved with the provider,
// Reset to defaults, invalid values block Save. Real temp plugin storage.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_editor_api/lumina_editor_api.dart';
import 'package:lumina_plugin_miniai/lumina_plugin_miniai.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';

import 'support/replay_server.dart';

const String _ornith = 's-batman/Ornith-1.0-35B-NVFP4-MTP-GGUF:ornith-1.0-35b-NVFP4-MTP';

void main() {
  late Directory temp;
  late ReplayServer server;
  late ProviderSettings settings;

  setUp(() async {
    temp = Directory.systemTemp.createTempSync('miniai_sampling_dialog_');
    server = await ReplayServer.start();
    settings = ProviderSettings(PluginStorage(userDir: Directory('${temp.path}/user')), environment: const {}, httpClient: realHttpClient);
  });

  tearDown(() async {
    await server.close();
    temp.deleteSync(recursive: true);
  });

  Future<void> drive(WidgetTester tester, bool Function() done) async {
    for (var i = 0; i < 200 && !done(); i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(done(), isTrue);
  }

  Future<void> open(WidgetTester tester) async {
    tester.view.physicalSize = const Size(900, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ShadcnApp(
      home: Scaffold(
        child: Builder(
          builder: (context) => PrimaryButton(key: const ValueKey('open'), onPressed: () => showProviderDialog(context, settings), child: const Text('open')),
        ),
      ),
    ));
    await tester.tap(find.byKey(const ValueKey('open')));
    await tester.pumpAndSettle();
  }

  String field(WidgetTester tester, String name) => tester.widget<TextField>(find.byKey(ValueKey('miniai_sampling_$name'))).controller!.text;

  Map<String, Object?> saved() =>
      (((jsonDecode(File('${temp.path}/user/providers.json').readAsStringSync()) as Map)['providers'] as List).single as Map).cast<String, Object?>();

  Future<void> save(WidgetTester tester) async {
    await tester.ensureVisible(find.byKey(const ValueKey('miniai_provider_save')));
    await tester.tap(find.byKey(const ValueKey('miniai_provider_save')));
    await drive(tester, () => find.byKey(const ValueKey('miniai_provider_save')).evaluate().isEmpty);
    await tester.pumpAndSettle();
  }

  testWidgets('collapsed by default; the Ornith defaults for Unsloth Studio; an edit is saved; Reset saves no sampling', (tester) async {
    await tester.runAsync(() => settings.save(ProviderConfig(id: 'ornith', name: 'Ornith', baseUrl: server.baseUrl, model: _ornith, backend: ServerBackend.unslothStudio)));
    await open(tester);
    expect(find.byKey(const ValueKey('miniai_sampling_toggle')), findsOneWidget);
    expect(find.byKey(const ValueKey('miniai_sampling_temperature')), findsNothing, reason: 'collapsed');

    await tester.ensureVisible(find.byKey(const ValueKey('miniai_sampling_toggle')));
    await tester.tap(find.byKey(const ValueKey('miniai_sampling_toggle')));
    await tester.pumpAndSettle();
    expect(field(tester, 'temperature'), '0.6');
    expect(field(tester, 'top_p'), '0.95');
    expect(field(tester, 'top_k'), '20');
    expect(field(tester, 'min_p'), '0.0');
    expect(field(tester, 'presence_penalty'), '1.5');
    expect(field(tester, 'repeat_penalty'), '', reason: 'unset: the server default');
    expect(find.byKey(const ValueKey('miniai_sampling_repeat_last_n')), findsNothing, reason: 'Unsloth Studio does not take it');
    expect(find.byKey(const ValueKey('miniai_sampling_dry_multiplier')), findsNothing);
    expect(find.text('Unsloth Studio'), findsOneWidget);
    expect(find.textContaining('Ornith-1.0 (Qwen3.5) model card'), findsOneWidget);
    expect(find.textContaining('Penalises any token already used'), findsOneWidget, reason: 'help per field');

    await tester.enterText(find.byKey(const ValueKey('miniai_sampling_temperature')), '0.4');
    await tester.enterText(find.byKey(const ValueKey('miniai_sampling_repeat_penalty')), '1.1');
    await tester.pump();
    await save(tester);
    expect(saved()['sampling'], {'temperature': 0.4, 'top_p': 0.95, 'top_k': 20, 'min_p': 0.0, 'presence_penalty': 1.5, 'repeat_penalty': 1.1});
    expect(saved()['backend'], 'unslothStudio');

    await open(tester);
    await tester.ensureVisible(find.byKey(const ValueKey('miniai_sampling_toggle')));
    await tester.tap(find.byKey(const ValueKey('miniai_sampling_toggle')));
    await tester.pumpAndSettle();
    expect(field(tester, 'temperature'), '0.4');
    await tester.ensureVisible(find.byKey(const ValueKey('miniai_sampling_reset')));
    await tester.tap(find.byKey(const ValueKey('miniai_sampling_reset')));
    await tester.pump();
    expect(field(tester, 'temperature'), '0.6');
    expect(field(tester, 'repeat_penalty'), '');
    await save(tester);
    expect(saved().containsKey('sampling'), isFalse, reason: 'the defaults are followed, not copied');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('an out-of-range value shows why and disables Save; the server type can be changed', (tester) async {
    await tester.runAsync(() => settings.save(ProviderConfig(id: 'ornith', name: 'Ornith', baseUrl: server.baseUrl, model: _ornith, backend: ServerBackend.unslothStudio)));
    await open(tester);
    await tester.ensureVisible(find.byKey(const ValueKey('miniai_sampling_toggle')));
    await tester.tap(find.byKey(const ValueKey('miniai_sampling_toggle')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('miniai_sampling_temperature')), '5');
    await tester.pump();
    expect(find.byKey(const ValueKey('miniai_sampling_temperature_error')), findsOneWidget);
    expect(tester.widget<PrimaryButton>(find.byKey(const ValueKey('miniai_provider_save'))).onPressed, isNull);
    await tester.enterText(find.byKey(const ValueKey('miniai_sampling_temperature')), '0.7');
    await tester.pump();
    expect(tester.widget<PrimaryButton>(find.byKey(const ValueKey('miniai_provider_save'))).onPressed, isNotNull);

    // llama-server takes the llama.cpp-only fields.
    await tester.tap(find.byKey(const ValueKey('miniai_sampling_backend')));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.tap(find.byKey(const ValueKey('miniai_sampling_backend_llamaCpp')));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(find.byKey(const ValueKey('miniai_sampling_repeat_last_n')), findsOneWidget);
    expect(find.byKey(const ValueKey('miniai_sampling_dry_multiplier')), findsOneWidget);
    await save(tester);
    expect(saved()['backend'], 'llamaCpp');
    expect((saved()['sampling'] as Map)['temperature'], 0.7);
    await tester.pumpWidget(const SizedBox());
    // The editor is a desktop app: Select opens a popover there (a drawer on
    // the test's default mobile platform).
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));
}
