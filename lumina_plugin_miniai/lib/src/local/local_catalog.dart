import 'dart:io';

import 'package:flutter/foundation.dart';

/// One file MiniAI downloads, pinned by size and SHA-256.
@immutable
class PinnedFile {
  const PinnedFile({required this.name, required this.url, required this.size, required this.sha256});

  final String name;
  final String url;
  final int size;
  final String sha256;
}

/// The llama.cpp build MiniAI runs: b11239 carries the MiniCPM5 tool-call
/// parser (`--jinja`). Vulkan on Windows and Linux (the CUDA 12.4 build may
/// lack Blackwell kernels), Metal on macOS.
class LlamaBuild {
  const LlamaBuild._();

  static const String tag = 'b11239';
  static const String _base = 'https://github.com/ggml-org/llama.cpp/releases/download/$tag';

  static const PinnedFile windows = PinnedFile(
    name: 'llama-$tag-bin-win-vulkan-x64.zip',
    url: '$_base/llama-$tag-bin-win-vulkan-x64.zip',
    size: 33063921,
    sha256: '5c69d4446426743786a3be414ec16a7451e3e9e978575b80adfc43e44bd0e9be',
  );
  static const PinnedFile linux = PinnedFile(
    name: 'llama-$tag-bin-ubuntu-vulkan-x64.tar.gz',
    url: '$_base/llama-$tag-bin-ubuntu-vulkan-x64.tar.gz',
    size: 31351900,
    sha256: 'f0282a115219facf2948305d675acd065baab7260663b06c80b4167c38054d37',
  );
  static const PinnedFile macos = PinnedFile(
    name: 'llama-$tag-bin-macos-arm64.tar.gz',
    url: '$_base/llama-$tag-bin-macos-arm64.tar.gz',
    size: 11760944,
    sha256: '8d75e5e60150cfa83f47ef91bfc4b3f1c6cf8173ca3954bd107ddcb942d8b8ea',
  );

  /// The archive for this platform.
  static PinnedFile get current => Platform.isWindows ? windows : (Platform.isMacOS ? macos : linux);

  static String get serverExecutable => Platform.isWindows ? 'llama-server.exe' : 'llama-server';
}

/// A MiniCPM5 GGUF.
@immutable
class ModelVariant {
  const ModelVariant({required this.id, required this.label, required this.file, this.limited = false});

  /// The file name without `.gguf`; also the server's `--alias`.
  final String id;
  final String label;
  final PinnedFile file;

  /// The 1B model: tool calls are less reliable.
  final bool limited;

  static const String _hf = 'https://huggingface.co/openbmb';

  static const ModelVariant minicpm5_2bQ4 = ModelVariant(
    id: 'MiniCPM5-2B-Q4_K_M',
    label: 'MiniCPM5 2B (Q4_K_M)',
    file: PinnedFile(
      name: 'MiniCPM5-2B-Q4_K_M.gguf',
      url: '$_hf/MiniCPM5-2B-GGUF/resolve/main/MiniCPM5-2B-Q4_K_M.gguf',
      size: 1561318368,
      sha256: 'ec2d5801640099e97d8d7e8003ad4d81f336e757811f03a26173dddf386602fd',
    ),
  );
  static const ModelVariant minicpm5_2bQ8 = ModelVariant(
    id: 'MiniCPM5-2B-Q8_0',
    label: 'MiniCPM5 2B (Q8_0)',
    file: PinnedFile(
      name: 'MiniCPM5-2B-Q8_0.gguf',
      url: '$_hf/MiniCPM5-2B-GGUF/resolve/main/MiniCPM5-2B-Q8_0.gguf',
      size: 2679710688,
      sha256: 'c5415f8989bf88a8288f1b55a3cc371af53c07b0faa220a63bd7a990cfaba078',
    ),
  );
  static const ModelVariant minicpm5_1bQ4 = ModelVariant(
    id: 'MiniCPM5-1B-Q4_K_M',
    label: 'MiniCPM5 1B (Q4_K_M, limited)',
    limited: true,
    file: PinnedFile(
      name: 'MiniCPM5-1B-Q4_K_M.gguf',
      url: '$_hf/MiniCPM5-1B-GGUF/resolve/main/MiniCPM5-1B-Q4_K_M.gguf',
      size: 688065920,
      sha256: '81b64d05a23b17b34c475f42b3e72fbde62d4b92cc34541f7a8031d0752deafa',
    ),
  );

  static const List<ModelVariant> all = [minicpm5_2bQ4, minicpm5_2bQ8, minicpm5_1bQ4];
  static const ModelVariant defaultVariant = minicpm5_2bQ4;

  static ModelVariant byId(String? id) => all.where((v) => v.id == id).firstOrNull ?? defaultVariant;
}

/// `1.5 GB` / `33 MB`.
String formatBytes(int bytes) {
  if (bytes >= 1000000000) return '${(bytes / 1e9).toStringAsFixed(1)} GB';
  if (bytes >= 1000000) return '${(bytes / 1e6).toStringAsFixed(0)} MB';
  return '${(bytes / 1e3).toStringAsFixed(0)} KB';
}
