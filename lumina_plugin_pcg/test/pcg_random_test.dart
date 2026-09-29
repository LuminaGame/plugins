import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_plugin_pcg/lumina_plugin_pcg.dart';

void main() {
  test('hash is deterministic, order-sensitive and non-negative', () {
    expect(PcgRandom.hash([1, 2, 3]), PcgRandom.hash([1, 2, 3]));
    expect(PcgRandom.hash([1, 2, 3]), isNot(PcgRandom.hash([3, 2, 1])));
    expect(PcgRandom.hash([7]), isNot(PcgRandom.hash([8])));
    for (final v in [0, 1, -1, 1 << 31, 123456789]) {
      expect(PcgRandom.hash([v, v]), greaterThanOrEqualTo(0));
    }
  });

  test('unit and range stay inside their bounds over many hashes', () {
    var min = 1.0;
    var max = 0.0;
    for (var i = 0; i < 5000; i++) {
      final u = PcgRandom.unit(PcgRandom.hash([42, i]));
      expect(u, inInclusiveRange(0.0, 1.0));
      if (u < min) min = u;
      if (u > max) max = u;
      expect(PcgRandom.range(PcgRandom.hash([i]), -5.0, 5.0), inInclusiveRange(-5.0, 5.0));
    }
    // 5000 samples: the stream really spreads over the unit interval.
    expect(min, lessThan(0.01));
    expect(max, greaterThan(0.99));
  });

  test('value noise is bounded, seeded and continuous', () {
    for (var i = 0; i < 400; i++) {
      final x = i * 0.137;
      final y = i * 0.311;
      final n = PcgRandom.valueNoise(x, y, 5);
      expect(n, inInclusiveRange(0.0, 1.0));
      expect(PcgRandom.valueNoise(x, y, 5), n, reason: 'same inputs, same noise');
      // Neighbouring samples 1/1000 of a cell apart differ by very little:
      // the noise is smooth, not white.
      expect((PcgRandom.valueNoise(x + 0.001, y, 5) - n).abs(), lessThan(0.02));
    }
    expect(PcgRandom.valueNoise(3.3, 4.4, 1), isNot(PcgRandom.valueNoise(3.3, 4.4, 2)), reason: 'the seed picks the lattice');
  });
}
