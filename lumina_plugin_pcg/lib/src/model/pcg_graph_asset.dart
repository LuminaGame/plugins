import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:lumina_core/lumina_core.dart';
import 'package:lumina_editor_api/lumina_editor_api.dart';

import 'package:lumina_plugin_pcg/src/model/pcg_graph.dart';

/// The `.lmas` container of a PCG Graph.
///
/// A graph is a plugin asset: an `.lmas` of `AssetType.unknown` whose
/// `metadata.custom_type` is [customTypeId] and whose `raw_payload` is the
/// graph's JSON. The Content Browser lists it like any asset and opens it
/// with the editor registered for [customTypeId].
abstract final class PcgGraphAsset {
  static const String customTypeId = 'pcg.graph';

  /// Where new graphs go, relative to the project.
  static const String defaultFolder = 'contents/pcg';

  static LuminaAsset toAsset(PcgGraph graph, {String? assetId}) => LuminaAsset(
        assetId: assetId ?? 'pcg_${graph.name}',
        name: graph.name,
        type: AssetType.unknown,
        rawPayload: Uint8List.fromList(utf8.encode(graph.toJsonString())),
        metadata: {
          kCustomAssetTypeKey: customTypeId,
          'node_count': graph.nodes.length.toString(),
        },
      );

  /// True when [asset] is a PCG Graph.
  static bool isGraph(LuminaAsset asset) => asset.metadata[kCustomAssetTypeKey] == customTypeId;

  /// The graph inside [asset], or null when it is not one / has no payload.
  static PcgGraph? fromAsset(LuminaAsset asset) {
    if (!isGraph(asset)) return null;
    final payload = asset.rawPayload;
    if (payload == null || payload.isEmpty) return null;
    return PcgGraph.fromJsonString(utf8.decode(payload));
  }

  /// Writes [graph] to [absolutePath] (creating folders).
  static Future<void> save(PcgGraph graph, String absolutePath, {String? assetId}) async {
    final file = File(absolutePath);
    file.parent.createSync(recursive: true);
    file.writeAsBytesSync(toAsset(graph, assetId: assetId).toProtoBufferBytes());
  }

  /// Reads the graph at [absolutePath]; null when the file is missing or not
  /// a PCG Graph.
  static PcgGraph? load(String absolutePath) {
    final file = File(absolutePath);
    if (!file.existsSync()) return null;
    try {
      return fromAsset(LuminaAsset.fromBytes(file.readAsBytesSync()));
    } catch (_) {
      return null;
    }
  }

  /// Resolves a project-relative or absolute path against [projectDirPath].
  static String absolute(String projectDirPath, String path) => path.startsWith('/') ? path : '$projectDirPath/$path';

  /// Project-relative form of [absolutePath] when it lies under
  /// [projectDirPath]; the input otherwise.
  static String relative(String projectDirPath, String absolutePath) {
    // '/' on every host: Windows listings join below the project with '\'
    // and references are stored '/'-separated.
    final path = absolutePath.replaceAll(r'\', '/');
    final prefix = '${projectDirPath.replaceAll(r'\', '/')}/';
    return path.startsWith(prefix) ? path.substring(prefix.length) : path;
  }

  /// Every PCG Graph `.lmas` under `<project>/contents/`, as project-relative
  /// paths, sorted. A real directory scan, like the Content Browser's.
  static List<String> scan(String projectDirPath) {
    final contents = Directory('$projectDirPath/contents');
    if (!contents.existsSync()) return const [];
    final out = <String>[];
    for (final entity in contents.listSync(recursive: true, followLinks: false)) {
      if (entity is! File || !entity.path.endsWith('.lmas')) continue;
      try {
        final bytes = entity.readAsBytesSync();
        // Cheap pre-check before parsing: the custom type id is literal in
        // the JSON header of every PCG graph container.
        if (!_containsAscii(bytes, customTypeId)) continue;
        if (isGraph(LuminaAsset.fromBytes(bytes))) out.add(relative(projectDirPath, entity.path));
      } catch (_) {}
    }
    out.sort();
    return out;
  }

  static bool _containsAscii(Uint8List bytes, String needle) {
    final n = needle.codeUnits;
    outer:
    for (var i = 0; i + n.length <= bytes.length; i++) {
      for (var j = 0; j < n.length; j++) {
        if (bytes[i + j] != n[j]) continue outer;
      }
      return true;
    }
    return false;
  }
}
