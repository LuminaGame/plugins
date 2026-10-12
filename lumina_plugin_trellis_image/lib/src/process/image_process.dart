import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:lumina_core/lumina_core.dart';
import 'package:lumina_plugin_process/lumina_plugin_process.dart';
import 'package:lumina_plugin_trellis_image/src/models/image_config.dart';

/// Owns native child processes and draft approval outside the editor process.
class TrellisImageProcess extends LuminaPluginProcess {
  @override
  String get pluginName => 'lumina_plugin_trellis_image';
  late PluginProcessContext context;
  late ImageConfig config;
  Process? _child;
  bool busy = false;
  bool cancelled = false;
  String status = 'Ready to create an image';
  String? error, draft, draftHash;
  Map<String, Object?>? result;
  int _revision = 0;
  Map<String, Object?> get snapshot => {
    'config': config.toJson(),
    'busy': busy,
    'cancellable': _child != null,
    'status': status,
    'error': error,
    'draft': draft,
    'draftId': draftHash,
    'result': result,
  };
  void emit() => context.emit('image.state', snapshot);

  @override
  Future<void> register(PluginProcessContext context) async {
    this.context = context;
    config = ImageConfig.fromJson(
      await context.storage.readJson('image') ?? {},
    );
    await _detectBinary();
    context.handle('image.state', (_) => snapshot);
    context.handle('image.configure', (args) async {
      if (busy) throw StateError('Wait for the current job to finish.');
      final next = ImageConfig.fromJson(args);
      if (next.root.trim().isEmpty || !RegExp(r'^\d+$').hasMatch(next.gpu)) {
        throw ArgumentError(
          'Choose a model folder and a numeric Vulkan GPU index.',
        );
      }
      config = next;
      await context.storage.writeJson('image', config.toJson());
      emit();
      return snapshot;
    });
    context.handle('image.install', (_) => _begin(_install));
    context.handle('image.generate', (args) {
      final request = ImageRequest.fromJson(args)..validate();
      return _begin(() => _generate(request), invalidateDraft: true);
    });
    context.registerMcpTool(
      McpTool(
        name: 'generate_image',
        title: 'Generate Qwen Image',
        description:
            'Generate or edit an image draft. Open Trellis Image Studio to review and approve it before 3D generation.',
        risk: McpToolRisk.external,
        groups: const {McpToolGroups.plugin},
        inputSchema: const {
          'type': 'object',
          'properties': {
            'prompt': {'type': 'string'},
            'reference': {'type': 'string'},
            'width': {'type': 'integer'},
            'height': {'type': 'integer'},
            'steps': {'type': 'integer'},
            'seed': {'type': 'integer'},
            'cloth': {
              'type': 'boolean',
              'description':
                  'The prompt names a garment: render it alone, hollow and in a worn shape (ghost mannequin), ready for 3D.',
            },
          },
          'required': ['prompt'],
        },
        handler: (args) {
          final request = ImageRequest.fromJson({
            for (final name in [
              'prompt',
              'reference',
              'width',
              'height',
              'steps',
              'seed',
              'cloth',
            ])
              name: args[name],
          })..validate();
          _begin(() => _generate(request), invalidateDraft: true);
          return McpToolResult.json(snapshot);
        },
      ),
    );
    // Approval is an explicit UI action. No MCP tool can approve a draft.
    context.handle('image.approve3d', (args) async {
      if (busy) throw StateError('A job is already running.');
      if (draft == null || args['draftId'] != draftHash) {
        throw StateError('Preview and approve the current image first.');
      }
      busy = true;
      error = null;
      emit();
      try {
        if (await _hash(draft!) != draftHash) {
          draft = null;
          draftHash = null;
          throw StateError(
            'The preview image changed. Generate and review a new image.',
          );
        }
      } catch (e) {
        busy = false;
        error = '$e';
        emit();
        rethrow;
      }
      status = 'Approved image: generating Trellis 3D';
      emit();
      return {'approvedImage': draft, 'draftId': draftHash};
    });
    context.handle('image.finish3d', (args) {
      if (args['draftId'] != draftHash) {
        throw StateError('This draft is no longer current.');
      }
      busy = false;
      error = args['error'] as String?;
      result = args['result'] is Map
          ? Map<String, Object?>.from(args['result'] as Map)
          : null;
      status = error == null
          ? '3D model ready. Review it, then save it to the project.'
          : '3D generation failed';
      emit();
      return snapshot;
    });
    // The reviewed mesh was saved into the project (the shell's Save).
    context.handle('image.saved3d', (args) {
      if (args['draftId'] != draftHash) {
        throw StateError('This draft is no longer current.');
      }
      result = {'asset_path': args['asset_path'], 'glb_path': args['glb_path']};
      status = '3D model saved to the project';
      emit();
      return snapshot;
    });
    context.handle('image.cancel', (_) async {
      if (_child != null) {
        cancelled = true;
        _child!.kill();
      }
      return snapshot;
    });
  }

  Object _begin(
    Future<void> Function() action, {
    bool invalidateDraft = false,
  }) {
    if (busy) throw StateError('A job is already running.');
    busy = true;
    cancelled = false;
    error = null;
    result = null;
    if (invalidateDraft) {
      draft = null;
      draftHash = null;
    }
    emit();
    unawaited(() async {
      try {
        await action();
      } catch (e, stack) {
        error = cancelled ? null : '$e';
        status = cancelled ? 'Cancelled' : 'Failed';
        if (!cancelled) context.log('$e\n$stack', level: 'error');
      } finally {
        busy = false;
        _child = null;
        emit();
      }
    }());
    return snapshot;
  }

  Future<void> _detectBinary() async {
    final installed = File('${config.root}/installed.json');
    if (config.binary.isEmpty && await installed.exists()) {
      final data = jsonDecode(await installed.readAsString()) as Map;
      config = ImageConfig(
        root: config.root,
        binary: data['binary'] as String,
        gpu: config.gpu,
      );
    }
  }

  Future<void> _install() async {
    if (!Platform.isWindows) {
      throw UnsupportedError(
        'Automatic install currently supports Windows Vulkan. Configure a local sd-cli on this platform.',
      );
    }
    final pluginDir = context.pluginDir;
    if (pluginDir == null) {
      throw StateError('Plugin installation folder is unavailable.');
    }
    status = 'Downloading runtime and models (about 11 GB)';
    emit();
    await _run('python', [
      '$pluginDir/resources/install_qwen.py',
      '--root',
      config.root,
    ]);
    await _detectBinary();
    await context.storage.writeJson('image', config.toJson());
    status = 'Installed Qwen Image 2.1 Q4_K_M';
  }

  Future<void> _run(String binary, List<String> args) async {
    final child = _child = await Process.start(
      binary,
      args,
      environment: {
        ...Platform.environment,
        'GGML_VK_VISIBLE_DEVICES': config.gpu,
        'CUDA_VISIBLE_DEVICES': '1',
      },
    );
    emit();
    final tail = <String>[];
    Future<void> listen(Stream<List<int>> stream) async {
      await for (final line
          in stream
              .transform(const Utf8Decoder(allowMalformed: true))
              .transform(const LineSplitter())) {
        if (tail.length == 20) tail.removeAt(0);
        final clean = line.replaceAll(RegExp(r'\x1B\[[0-?]*[ -/]*[@-~]'), '');
        tail.add(clean);
        status = clean;
        emit();
      }
    }

    final output = Future.wait([listen(child.stdout), listen(child.stderr)]);
    final code = await child.exitCode;
    await output;
    _child = null;
    if (cancelled) throw StateError('Cancelled');
    if (code != 0) {
      throw StateError('Process exited with code $code.\n${tail.join('\n')}');
    }
  }

  Future<void> _generate(ImageRequest request) async {
    for (final path in [
      config.binary,
      config.diffusion,
      config.encoder,
      config.vae,
    ]) {
      if (path.isEmpty || !await File(path).exists()) {
        throw StateError('Required executable/model is missing: $path');
      }
    }
    final directory = Directory(
      '${config.root}/outputs/${DateTime.now().microsecondsSinceEpoch}_${_revision++}',
    );
    await directory.create(recursive: true);
    String? reference;
    if (request.reference != null && request.reference!.isNotEmpty) {
      if (!await File(config.vision).exists()) {
        throw StateError(
          'Reference editing requires the vision encoder: ${config.vision}',
        );
      }
      reference = await _reference(request.reference!, directory.path);
    }
    final output = '${directory.path}/image.png';
    status = 'Generating Qwen image';
    emit();
    await _run(
      config.binary,
      request.arguments(config, output, resolvedReference: reference),
    );
    final file = File(output);
    if (!await file.exists() || await file.length() < 8) {
      throw StateError('Generation finished without an image.');
    }
    draftHash = await _hash(output);
    draft = output;
    status = 'Image ready. Review it before approving 3D generation.';
  }

  Future<String> _reference(String input, String outputDirectory) async {
    final project = context.project?.dir;
    final file = File(input).isAbsolute
        ? File(input)
        : File('${project ?? ''}/$input');
    final bytes = await file.readAsBytes();
    if (file.path.toLowerCase().endsWith('.lmas')) {
      final payload = await Isolate.run(() {
        final asset = LuminaAsset.fromBytes(bytes);
        if (asset.type != AssetType.texture || asset.rawPayload == null) {
          throw StateError(
            'Reference must be a texture asset with image bytes.',
          );
        }
        return asset.rawPayload!;
      });
      final extracted = File('$outputDirectory/reference.png');
      await extracted.writeAsBytes(payload);
      return extracted.path;
    }
    return file.path;
  }

  static Future<String> _hash(String path) async =>
      (await sha256.bind(File(path).openRead()).first).toString();

  @override
  Future<void> onShutdown() async {
    cancelled = true;
    final child = _child;
    child?.kill();
    if (child != null) {
      await child.exitCode.timeout(const Duration(seconds: 10));
    }
  }
}
