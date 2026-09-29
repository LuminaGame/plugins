import 'dart:io';

import 'package:lumina/data/models/landscape_data.dart';
import 'package:lumina/data/models/lumina_asset.dart';
import 'package:lumina_editor_api/lumina_editor_api.dart';

/// The surface a PCG Volume samples: height and slope at a stored-space
/// (cm, Z up) XY position.
abstract class PcgSurface {
  /// Height (stored Z, cm) at ([x], [y]), or null when the surface has no
  /// sample there.
  double? heightAt(double x, double y);

  /// Slope in degrees off vertical at ([x], [y]); 0 where unknown.
  double slopeAt(double x, double y) => 0.0;

  String get describe;
}

/// A flat floor at [z] (cm): the bottom face of a PCG Volume.
class PcgFloorSurface extends PcgSurface {
  final double z;
  PcgFloorSurface(this.z);

  @override
  double? heightAt(double x, double y) => z;

  @override
  String get describe => 'volume floor at z=${z.toStringAsFixed(1)} cm';
}

/// A placed Landscape actor's heightmap.
///
/// `LandscapeData` is authored in metres, Y up, centred on its origin; the
/// actor is stored in cm, Z up. A stored point `(x, y)` maps to terrain
/// `worldX = (x − Lx) / (100·Sx)`, `worldZ = −(y − Ly) / (100·Sy)` (the
/// Z-up → Y-up rule `(x, y, z) → (x, z, −y)`, see `LuminaAxes`), and the
/// sampled height comes back as `Lz + h·100·Sz`.
class PcgLandscapeSurface extends PcgSurface {
  final EditorActorSnapshot actor;
  final LandscapeData data;

  PcgLandscapeSurface({required this.actor, required this.data});

  double get _sx => actor.scale.isNotEmpty && actor.scale[0] != 0 ? actor.scale[0] : 1.0;
  double get _sy => actor.scale.length > 1 && actor.scale[1] != 0 ? actor.scale[1] : 1.0;
  double get _sz => actor.scale.length > 2 && actor.scale[2] != 0 ? actor.scale[2] : 1.0;

  (double, double) _terrainMetres(double x, double y) {
    final lx = (x - actor.location[0]) / (100.0 * _sx);
    final lz = -(y - actor.location[1]) / (100.0 * _sy);
    return (lx, lz);
  }

  /// True when the stored XY lies over the terrain footprint.
  bool contains(double x, double y) {
    final (lx, lz) = _terrainMetres(x, y);
    return data.contains(lx, lz);
  }

  @override
  double? heightAt(double x, double y) {
    final (lx, lz) = _terrainMetres(x, y);
    if (!data.contains(lx, lz)) return null;
    return actor.location[2] + data.sampleHeight(lx, lz) * 100.0 * _sz;
  }

  @override
  double slopeAt(double x, double y) {
    final (lx, lz) = _terrainMetres(x, y);
    if (!data.contains(lx, lz)) return 0.0;
    return data.sampleSlopeDegrees(lx, lz);
  }

  @override
  String get describe => 'landscape "${actor.name}" (${data.gridResolution}², ${data.worldSize} m)';

  /// Loads the terrain of a `Landscape` actor from its `.lmas`; null when the
  /// actor has no readable landscape asset.
  static PcgLandscapeSurface? fromActor(EditorActorSnapshot actor) {
    if (actor.type != 'Landscape') return null;
    final path = actor.meshAssetPath;
    if (path == null || path.isEmpty) return null;
    final file = File(path);
    if (!file.existsSync()) return null;
    try {
      var bytes = file.readAsBytesSync();
      if (path.toLowerCase().endsWith('.lmas')) {
        final payload = LuminaAsset.fromBytes(bytes).rawPayload;
        if (payload == null || payload.isEmpty) return null;
        bytes = payload;
      }
      return PcgLandscapeSurface(actor: actor, data: LandscapeData.fromBytes(bytes));
    } catch (_) {
      return null;
    }
  }
}

/// Landscapes first, then the floor: the surface a volume samples where no
/// landscape covers a point (Get Landscape Data falls back to the volume
/// when there is no landscape).
class PcgCompositeSurface extends PcgSurface {
  final List<PcgLandscapeSurface> landscapes;
  final PcgFloorSurface? floor;

  PcgCompositeSurface({required this.landscapes, this.floor});

  PcgLandscapeSurface? landscapeAt(double x, double y) {
    for (final l in landscapes) {
      if (l.contains(x, y)) return l;
    }
    return null;
  }

  @override
  double? heightAt(double x, double y) => landscapeAt(x, y)?.heightAt(x, y) ?? floor?.heightAt(x, y);

  @override
  double slopeAt(double x, double y) => landscapeAt(x, y)?.slopeAt(x, y) ?? 0.0;

  @override
  String get describe => landscapes.isEmpty
      ? (floor?.describe ?? 'no surface')
      : '${landscapes.map((l) => l.describe).join(', ')}${floor != null ? ' + ${floor!.describe}' : ''}';
}
