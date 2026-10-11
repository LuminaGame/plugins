import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_editor_api/lumina_editor_api.dart';
import 'package:lumina_editor_api/testing.dart';
import 'package:lumina_plugin_trellis_image/lumina_plugin_trellis_image.dart';
import 'package:lumina_plugin_trellis_image/src/models/image_config.dart';

void main() {
  late LoopbackHost host;
  late TrellisImageProcess process;
  late Future<int> exit;
  setUp(() async {
    host = await LoopbackHost.start(settings: const {});
    process = TrellisImageProcess();
    exit = runPluginProcessMain(
      host.launch('lumina_plugin_trellis_image'),
      process,
    );
    await host.contributions;
  });
  tearDown(() async {
    await host.call(PluginMethods.shutdown);
    await exit;
    await host.close();
  });
  test('rejects approval without a current image draft', () async {
    await expectLater(
      host.channel.call('image.approve3d', {'draftId': 'old'}),
      throwsA(isA<PluginRemoteError>()),
    );
    expect(process.busy, isFalse);
    expect(process.draft, isNull);
  });
  test('invalid prompt does not consume or start a job', () async {
    await expectLater(
      host.channel.call('image.generate', {'prompt': ' '}),
      throwsA(isA<PluginRemoteError>()),
    );
    expect(process.busy, isFalse);
  });
  test(
    'missing executable produces visible error and process remains available',
    () async {
      await host.channel.call('image.configure', {
        'root': host.root.path,
        'binary': '${host.root.path}/missing-sd-cli',
      });
      final finished = host.channel
          .events('image.state')
          .firstWhere(
            (event) =>
                event.data is Map && (event.data as Map)['busy'] == false,
          );
      await host.channel.call('image.generate', {'prompt': 'A ceramic pot'});
      final event = await finished.timeout(const Duration(seconds: 10));
      expect((event.data as Map)['error'], contains('missing'));
      final state = await host.channel.call('image.state') as Map;
      expect(state['draft'], isNull);
      expect(state['busy'], isFalse);
    },
  );
  test(
    'request validates resolution and preserves reference arguments without shell parsing',
    () {
      final config = ImageConfig(root: host.root.path);
      final request = ImageRequest(
        prompt: 'A pot; keep its handle',
        reference: 'ref',
      );
      final args = request.arguments(
        config,
        '${host.root.path}/out.png',
        resolvedReference: '${host.root.path}/reference image.png',
      );
      expect(args[args.indexOf('-p') + 1], request.prompt);
      expect(
        args[args.indexOf('--ref-image') + 1],
        endsWith('reference image.png'),
      );
      expect(
        () => const ImageRequest(prompt: 'pot', width: 301).validate(),
        throwsArgumentError,
      );
    },
  );
  test(
    'real Qwen generation produces a reviewable image without calling 3D',
    () async {
      final root = Platform.environment['LUMINA_QWEN_IMAGE_ROOT'];
      if (root == null) return;
      await host.channel.call('image.configure', {
        'root': root,
        'binary': '$root/runtime/sd-cli.exe',
        'gpu': '0',
      });
      final finished = host.channel
          .events('image.state')
          .firstWhere(
            (event) =>
                event.data is Map && (event.data as Map)['busy'] == false,
          );
      await host.channel.call('image.generate', {
        'prompt':
            'A red ceramic teapot, isolated on plain white background, product photograph',
        'width': 512,
        'height': 512,
        'steps': 20,
        'seed': 42,
      });
      final event = await finished.timeout(const Duration(minutes: 15));
      final state = event.data as Map;
      expect(state['error'], isNull, reason: '${state['error']}');
      expect(await File(state['draft'] as String).exists(), isTrue);
      expect(state['draftId'], isNotEmpty);
      expect(state['result'], isNull);
      final image = File(state['draft'] as String);
      final original = await image.readAsBytes();
      await image.writeAsBytes([0], mode: FileMode.append);
      final invalid = host.channel
          .events('image.state')
          .firstWhere((e) => e.data is Map && (e.data as Map)['busy'] == false);
      await expectLater(
        host.channel.call('image.approve3d', {'draftId': state['draftId']}),
        throwsA(isA<PluginRemoteError>()),
      );
      expect(((await invalid).data as Map)['error'], contains('changed'));
      await image.writeAsBytes(original);
    },
    skip: Platform.environment['LUMINA_QWEN_IMAGE_ROOT'] == null,
    timeout: const Timeout(Duration(minutes: 20)),
  );
}
