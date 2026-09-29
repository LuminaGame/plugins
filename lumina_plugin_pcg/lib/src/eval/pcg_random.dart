import 'dart:math' as math;

/// Deterministic hashing and random streams for PCG.
///
/// Every random decision in a graph evaluation derives from the volume's
/// seed plus stable integers (a grid cell, a node index), never from
/// evaluation order, so the same graph + seed + level produce the same
/// instances on every machine.
abstract final class PcgRandom {
  /// Mixes [values] into one 32-bit hash (a `murmur3`-style finaliser over
  /// a running state).
  static int hash(List<int> values) {
    var h = 0x9E3779B9;
    for (final v in values) {
      var k = (v & 0xFFFFFFFF) * 0xCC9E2D51 & 0xFFFFFFFF;
      k = ((k << 15) | (k >> 17)) & 0xFFFFFFFF;
      k = k * 0x1B873593 & 0xFFFFFFFF;
      h ^= k;
      h = ((h << 13) | (h >> 19)) & 0xFFFFFFFF;
      h = (h * 5 + 0xE6546B64) & 0xFFFFFFFF;
    }
    h ^= h >> 16;
    h = h * 0x85EBCA6B & 0xFFFFFFFF;
    h ^= h >> 13;
    h = h * 0xC2B2AE35 & 0xFFFFFFFF;
    h ^= h >> 16;
    return h & 0x7FFFFFFF;
  }

  /// A uniform double in `[0, 1)` from a hash.
  static double unit(int hash) => (hash & 0xFFFFFF) / 16777216.0;

  /// A uniform double in `[min, max]` from a hash.
  static double range(int hash, double min, double max) => min + unit(hash) * (max - min);

  /// A `dart:math` random stream seeded from [values]: for the few places a
  /// stream reads better than per-decision hashing (mesh choice per point).
  static math.Random stream(List<int> values) => math.Random(hash(values));

  /// Smooth value noise in `[0, 1]` over a 2D domain, with [seed] selecting
  /// the lattice. Cosine-interpolated lattice hashes: cheap and, unlike
  /// `dart:math` per-call randomness, identical for identical inputs.
  static double valueNoise(double x, double y, int seed) {
    final x0 = x.floor();
    final y0 = y.floor();
    final fx = x - x0;
    final fy = y - y0;
    double lattice(int ix, int iy) => unit(hash([seed, ix, iy]));
    double smooth(double t) => (1 - math.cos(t * math.pi)) * 0.5;
    final sx = smooth(fx);
    final sy = smooth(fy);
    final a = lattice(x0, y0);
    final b = lattice(x0 + 1, y0);
    final c = lattice(x0, y0 + 1);
    final d = lattice(x0 + 1, y0 + 1);
    final top = a + (b - a) * sx;
    final bottom = c + (d - c) * sx;
    return top + (bottom - top) * sy;
  }
}
