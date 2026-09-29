/// One point flowing through a PCG graph: a candidate placement.
///
/// Positions are in the level's stored space — centimetres, **Z up** — the
/// same numbers the Details panel shows for the instances the point becomes.
/// [density] is the point's weight in `[0, 1]` (the Density Filter reads it,
/// the Density Noise node writes it), [seed] a stable per-point hash the
/// random nodes derive their decisions from, and [slopeDegrees] the surface
/// slope under the point (0 on a volume floor).
class PcgPoint {
  final double x;
  final double y;
  final double z;
  final List<double> rotation;
  final List<double> scale;
  final double density;
  final int seed;
  final double slopeDegrees;

  const PcgPoint({
    required this.x,
    required this.y,
    required this.z,
    this.rotation = const [0.0, 0.0, 0.0],
    this.scale = const [1.0, 1.0, 1.0],
    this.density = 1.0,
    required this.seed,
    this.slopeDegrees = 0.0,
  });

  PcgPoint copyWith({
    double? x,
    double? y,
    double? z,
    List<double>? rotation,
    List<double>? scale,
    double? density,
    int? seed,
    double? slopeDegrees,
  }) {
    return PcgPoint(
      x: x ?? this.x,
      y: y ?? this.y,
      z: z ?? this.z,
      rotation: rotation ?? this.rotation,
      scale: scale ?? this.scale,
      density: density ?? this.density,
      seed: seed ?? this.seed,
      slopeDegrees: slopeDegrees ?? this.slopeDegrees,
    );
  }

  @override
  String toString() => 'PcgPoint($x, $y, $z, density: $density, seed: $seed)';
}

/// A mesh placement a Static Mesh Spawner produced: what becomes one
/// `StaticMesh` actor in the level.
class PcgInstance {
  /// Project-relative mesh path (`contents/meshes/barrel.glb`).
  final String meshPath;
  final List<double> location;
  final List<double> rotation;
  final List<double> scale;
  final int seed;

  const PcgInstance({
    required this.meshPath,
    required this.location,
    required this.rotation,
    required this.scale,
    required this.seed,
  });

  @override
  String toString() => 'PcgInstance($meshPath @ $location)';
}
