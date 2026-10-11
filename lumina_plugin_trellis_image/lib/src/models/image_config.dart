import 'dart:io';

class ImageConfig {
  const ImageConfig({required this.root, this.binary = '', this.gpu = '0'});
  final String root;
  final String binary;
  final String gpu;
  String get diffusion => '$root/models/qwen-image-2.1-Q4_K_M.gguf';
  String get encoder => '$root/models/Qwen3-VL-8B-Instruct-UD-Q4_K_XL.gguf';
  String get vae => '$root/models/qwen_image_2.1_vae_bf16.safetensors';
  String get vision => '$root/models/mmproj-F16.gguf';
  Map<String, Object?> toJson() => {'root': root, 'binary': binary, 'gpu': gpu};
  factory ImageConfig.fromJson(Map<String, Object?> json) => ImageConfig(
    root: json['root'] as String? ?? defaultRoot,
    binary: json['binary'] as String? ?? '',
    gpu: json['gpu'] as String? ?? '0',
  );
  static String get defaultRoot {
    if (Platform.isWindows) {
      return '${Platform.environment['LOCALAPPDATA']}/Lumina/qwen_image';
    }
    if (Platform.isMacOS) {
      return '${Platform.environment['HOME']}/Library/Application Support/Lumina/qwen_image';
    }
    return '${Platform.environment['XDG_DATA_HOME'] ?? '${Platform.environment['HOME']}/.local/share'}/lumina/qwen_image';
  }
}

class ImageRequest {
  const ImageRequest({
    required this.prompt,
    this.reference,
    this.width = 1024,
    this.height = 1024,
    this.steps = 20,
    this.seed = 42,
  });
  final String prompt;
  final String? reference;
  final int width, height, steps, seed;
  factory ImageRequest.fromJson(Map<String, Object?> json) => ImageRequest(
    prompt: json['prompt'] as String? ?? '',
    reference: json['reference'] as String?,
    width: (json['width'] as num?)?.toInt() ?? 1024,
    height: (json['height'] as num?)?.toInt() ?? 1024,
    steps: (json['steps'] as num?)?.toInt() ?? 20,
    seed: (json['seed'] as num?)?.toInt() ?? 42,
  );
  void validate() {
    if (prompt.trim().isEmpty) throw ArgumentError('Enter an image prompt.');
    if (width < 256 ||
        width > 2048 ||
        width % 64 != 0 ||
        height < 256 ||
        height > 2048 ||
        height % 64 != 0) {
      throw ArgumentError(
        'Image dimensions must be multiples of 64 between 256 and 2048.',
      );
    }
    if (steps < 1 || steps > 100) {
      throw ArgumentError('Steps must be between 1 and 100.');
    }
  }

  List<String> arguments(
    ImageConfig config,
    String output, {
    String? resolvedReference,
  }) {
    validate();
    return [
      '--diffusion-model',
      config.diffusion,
      '--vae',
      config.vae,
      '--llm',
      config.encoder,
      '-p',
      prompt,
      '--steps',
      '$steps',
      '--cfg-scale',
      '6',
      '--sampling-method',
      'euler',
      '-W',
      '$width',
      '-H',
      '$height',
      '--seed',
      '$seed',
      '--diffusion-fa',
      '--offload-to-cpu',
      '--clip-on-cpu',
      '--vae-on-cpu',
      if (resolvedReference != null) ...[
        '--llm_vision',
        config.vision,
        '--ref-image',
        resolvedReference,
      ],
      '-o',
      output,
    ];
  }
}
