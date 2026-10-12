import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_editor_api/lumina_editor_api.dart';
import 'package:lumina_editor_api/testing.dart';
import 'package:lumina_plugin_trellis_image/lumina_plugin_trellis_image.dart';
import 'package:lumina_plugin_trellis_image/src/shell/image_client.dart';
import 'package:lumina_plugin_trellis_image/src/ui/image_workspace.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';

void main() {
  testWidgets('shows native configuration and forbids 3D without an image', (
    tester,
  ) async {
    late LoopbackHost host;
    late Future<int> exit;
    late ImageClient client;
    await tester.runAsync(() async {
      host = await LoopbackHost.start(settings: const {});
      exit = runPluginProcessMain(
        host.launch('lumina_plugin_trellis_image'),
        TrellisImageProcess(),
      );
      await host.contributions;
      client = ImageClient(host.channel);
      await client.call('image.state');
    });
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ShadcnApp(
        theme: ThemeData(colorScheme: ColorSchemes.darkZinc),
        home: Scaffold(child: ImageWorkspace(client: client)),
      ),
    );
    await tester.pump();
    expect(find.text('Qwen Image 2.1 · Q4_K_M'), findsOneWidget);
    final approve = tester.widget<PrimaryButton>(
      find.byKey(const Key('qwen_approve_3d')),
    );
    expect(approve.onPressed, isNull);
    expect(find.text('sd-cli executable'), findsOneWidget);
    // Is cloth starts off and toggles on a tap.
    Checkbox cloth() => tester.widget(find.byKey(const Key('qwen_is_cloth')));
    expect(cloth().state, CheckboxState.unchecked);
    await tester.tap(find.byKey(const Key('qwen_is_cloth')));
    await tester.pump();
    expect(cloth().state, CheckboxState.checked);
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() async {
      client.dispose();
      await host.call(PluginMethods.shutdown);
      await exit;
      await host.close();
    });
  });
}
