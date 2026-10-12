/// A mesh's numbers as Trellis reports them (`trellis.inspect`, the
/// `before` / `after` of `trellis.simplify`).
class MeshStats {
  const MeshStats({
    required this.triangles,
    required this.vertices,
    required this.fileBytes,
    required this.sizeCm,
    this.hasVertexColors = false,
  });

  final int triangles;
  final int vertices;
  final int fileBytes;

  /// The bounds' extent in centimetres (x, y, z; the GLB is in metres).
  final List<double> sizeCm;
  final bool hasVertexColors;

  factory MeshStats.fromJson(Map<String, Object?> json) {
    List<double> vec(Object? v) => v is List && v.length >= 3
        ? [for (final e in v.take(3)) (e as num).toDouble()]
        : const [0, 0, 0];
    final lo = vec(json['bounds_min']), hi = vec(json['bounds_max']);
    return MeshStats(
      triangles: (json['triangles'] as num?)?.toInt() ?? 0,
      vertices: (json['vertices'] as num?)?.toInt() ?? 0,
      fileBytes: (json['file_bytes'] as num?)?.toInt() ?? 0,
      sizeCm: [for (var i = 0; i < 3; i++) (hi[i] - lo[i]) * 100.0],
      hasVertexColors: json['has_vertex_colors'] == true,
    );
  }

  static String count(int n) => n >= 1000000
      ? '${(n / 1000000).toStringAsFixed(2)} M'
      : n >= 1000
      ? '${(n / 1000).toStringAsFixed(1)} k'
      : '$n';

  static String bytes(int n) => n >= 1 << 20
      ? '${(n / (1 << 20)).toStringAsFixed(1)} MB'
      : '${(n / 1024).toStringAsFixed(1)} KB';

  String get sizeLabel => sizeCm.map((v) => v.toStringAsFixed(1)).join(' × ');
}

/// A simplified copy of the generated mesh.
class MeshSimplification {
  const MeshSimplification({
    required this.glbPath,
    required this.before,
    required this.after,
    required this.targetTriangles,
    required this.durationMs,
  });

  final String glbPath;
  final MeshStats before;
  final MeshStats after;
  final int targetTriangles;
  final int durationMs;

  factory MeshSimplification.fromJson(Map<String, Object?> json) {
    Map<String, Object?> map(Object? v) =>
        v is Map ? v.cast<String, Object?>() : const {};
    return MeshSimplification(
      glbPath: json['glb_path'] as String? ?? '',
      before: MeshStats.fromJson(map(json['before'])),
      after: MeshStats.fromJson(map(json['after'])),
      targetTriangles: (json['target_triangles'] as num?)?.toInt() ?? 0,
      durationMs: (json['duration_ms'] as num?)?.toInt() ?? 0,
    );
  }
}

/// The generated mesh under review: it lives in the Trellis plugin's temp
/// folder until it is saved to the project or discarded.
class MeshPreview {
  MeshPreview({required this.sourcePath, required this.stats});

  /// The mesh Trellis generated (kept for Revert).
  final String sourcePath;
  final MeshStats stats;

  /// The applied simplification, if any.
  MeshSimplification? simplified;

  /// The project asset it was saved as.
  String? savedAssetPath;

  /// The mesh shown and saved: the simplified copy when there is one.
  String get shownPath => simplified?.glbPath ?? sourcePath;
  MeshStats get shownStats => simplified?.after ?? stats;
}
