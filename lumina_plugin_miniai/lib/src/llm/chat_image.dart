import 'dart:convert';
import 'dart:typed_data';

/// An image a tool produced (a viewport screenshot, a PIE frame): shown in
/// its tool card and, for a model with vision, sent back as an image.
class ChatImage {
  ChatImage({required this.id, required this.mimeType, required this.bytes, this.data, this.width, this.height, this.source});

  /// The image from an MCP `image` content part (`data` + `mimeType`) or an
  /// Anthropic image block (`source.data` + `source.media_type`); null when
  /// [content] carries no base64 data.
  static ChatImage? fromContent(Map<Object?, Object?> content, {required String id, String? source}) {
    final nested = content['source'];
    final data = content['data'] ?? (nested is Map ? nested['data'] : null);
    if (data is! String || data.isEmpty) return null;
    final mime = content['mimeType'] ?? content['media_type'] ?? (nested is Map ? nested['media_type'] : null) ?? 'image/png';
    Uint8List raw;
    try {
      raw = base64Decode(data);
    } on FormatException {
      return null;
    }
    final (w, h) = dimensions(raw);
    return ChatImage(id: id, mimeType: '$mime', bytes: raw.length, data: data, width: w, height: h, source: source)
      .._decoded = raw;
  }

  final String id;
  final String mimeType;

  /// The encoded size.
  final int bytes;

  /// Base64 data; null when the chat no longer keeps it.
  String? data;
  final int? width;
  final int? height;

  /// The tool call it belongs to: `viewport_screenshot (call_1)`.
  final String? source;

  Uint8List? _decoded;

  bool get kept => data != null;

  /// The image bytes, or null when not kept.
  Uint8List? get decoded {
    final d = data;
    if (d == null) return null;
    return _decoded ??= base64Decode(d);
  }

  /// `data:image/png;base64,…`.
  String get dataUri => 'data:$mimeType;base64,$data';

  /// `image/png 1280×720, 245 KB`.
  String get describe => '$mimeType${width != null && height != null ? ' $width×$height' : ''}, ${(bytes / 1024).ceil()} KB';

  /// What a model without vision (or an older image) reads instead.
  String get placeholder => '[$describe produced by the tool; not shown to the model]';

  Map<String, Object?> toJson({bool withData = true}) => {
        'mime': mimeType,
        'bytes': bytes,
        'w': ?width,
        'h': ?height,
        'source': ?source,
        if (withData && data != null) 'data': data,
      };

  factory ChatImage.fromJson(String id, Map<String, Object?> j) => ChatImage(
        id: id,
        mimeType: j['mime'] as String? ?? 'image/png',
        bytes: j['bytes'] as int? ?? 0,
        data: j['data'] as String?,
        width: j['w'] as int?,
        height: j['h'] as int?,
        source: j['source'] as String?,
      );

  /// Width and height from a PNG, JPEG, GIF or WebP header; (null, null)
  /// for anything else.
  static (int?, int?) dimensions(Uint8List b) {
    int be16(int i) => (b[i] << 8) | b[i + 1];
    int be32(int i) => (b[i] << 24) | (b[i + 1] << 16) | (b[i + 2] << 8) | b[i + 3];
    int le16(int i) => b[i] | (b[i + 1] << 8);
    // PNG: IHDR right after the signature.
    if (b.length >= 24 && b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47) return (be32(16), be32(20));
    // GIF: logical screen size.
    if (b.length >= 10 && b[0] == 0x47 && b[1] == 0x49 && b[2] == 0x46) return (le16(6), le16(8));
    // WebP (VP8 / VP8L / VP8X).
    if (b.length >= 30 && b[0] == 0x52 && b[1] == 0x49 && b[8] == 0x57 && b[9] == 0x45) {
      final chunk = String.fromCharCodes(b.sublist(12, 16));
      if (chunk == 'VP8 ') return (le16(26) & 0x3FFF, le16(28) & 0x3FFF);
      if (chunk == 'VP8L') {
        final bits = b[21] | (b[22] << 8) | (b[23] << 16) | (b[24] << 24);
        return ((bits & 0x3FFF) + 1, ((bits >> 14) & 0x3FFF) + 1);
      }
      if (chunk == 'VP8X') return ((b[24] | (b[25] << 8) | (b[26] << 16)) + 1, (b[27] | (b[28] << 8) | (b[29] << 16)) + 1);
    }
    // JPEG: the first start-of-frame marker.
    if (b.length >= 4 && b[0] == 0xFF && b[1] == 0xD8) {
      var i = 2;
      while (i + 9 < b.length) {
        if (b[i] != 0xFF) {
          i++;
          continue;
        }
        final marker = b[i + 1];
        if (marker >= 0xC0 && marker <= 0xCF && marker != 0xC4 && marker != 0xC8 && marker != 0xCC) {
          return (be16(i + 7), be16(i + 5));
        }
        i += 2 + be16(i + 2);
      }
    }
    return (null, null);
  }
}

/// Which models read images.
abstract final class VisionModels {
  static final List<RegExp> _patterns = [
    RegExp(r'gpt-4o|gpt-4\.1|gpt-4-turbo|gpt-4-vision|gpt-5|chatgpt-4o'),
    RegExp(r'(^|[/:])o[134](-|$)'),
    RegExp(r'claude'),
    RegExp(r'gemini|gemma-?3'),
    RegExp(r'llava|bakllava|moondream|pixtral|mistral-small-3|mistral-medium'),
    RegExp(r'qwen[\d.]*-?vl|qvq|internvl|minicpm-?v|glm-4\.?\dv|cogvlm|idefics|smolvlm|phi-?[34](\.\d)?-vision'),
    RegExp(r'llama-?3\.2-?\d*b?-?vision|llama-?4|vision'),
    RegExp(r'grok-(2-vision|4)'),
  ];

  /// Whether [model] is known to read images (its name only).
  static bool guess(String model) {
    final m = model.toLowerCase();
    return _patterns.any((p) => p.hasMatch(m));
  }
}
