import 'dart:convert';

/// The node kinds a PCG Graph is built from.
enum PcgNodeType {
  /// `Get Landscape Data` / volume bounds: the surface the graph samples —
  /// the level's landscape where the volume overlaps one, else the volume's
  /// floor (`surface` param: `auto` | `landscape` | `floor`).
  getSurfaceData('Get Surface Data'),

  /// `Surface Sampler`: a jittered grid of points over the volume's footprint,
  /// projected onto the surface. `cellSize` cm between points, `looseness`
  /// `[0, 1]` random offset within the cell, `maxSlopeDegrees` rejection.
  surfaceSampler('Surface Sampler'),

  /// `Transform Points`: random rotation (`rotationMin`/`rotationMax`, degrees
  /// about X Y Z), scale (`scaleMin`/`scaleMax`, `uniformScale`) and offset
  /// (`offsetMin`/`offsetMax`, cm) per point.
  transformPoints('Transform Points'),

  /// `Density Noise`: writes smooth value noise into each point's density;
  /// `noiseScale` cm is one lattice cell.
  densityNoise('Density Noise'),

  /// `Density Filter`: keeps points whose density lies in
  /// `[minDensity, maxDensity]`.
  densityFilter('Density Filter'),

  /// `Difference`: drops points within `radius` cm (in XY) of an existing,
  /// hand-placed actor of one of `actorTypes` — nothing spawns inside a
  /// building or on the player start.
  difference('Difference'),

  /// `Static Mesh Spawner`: turns points into mesh instances; `meshes` is a
  /// list of `{path, weight}` picked per point by weight.
  staticMeshSpawner('Static Mesh Spawner');

  const PcgNodeType(this.label);

  /// The name the editor shows.
  final String label;

  static PcgNodeType parse(String name) =>
      PcgNodeType.values.firstWhere((t) => t.name == name, orElse: () => throw FormatException('Unknown PCG node type "$name"'));

  /// The parameters a fresh node of this type starts with.
  Map<String, dynamic> defaultParams() {
    switch (this) {
      case PcgNodeType.getSurfaceData:
        return {'surface': 'auto'};
      case PcgNodeType.surfaceSampler:
        return {'cellSize': 200.0, 'looseness': 0.5, 'maxSlopeDegrees': 45.0};
      case PcgNodeType.transformPoints:
        return {
          'rotationMin': [0.0, 0.0, 0.0],
          'rotationMax': [0.0, 0.0, 360.0],
          'scaleMin': 0.8,
          'scaleMax': 1.2,
          'uniformScale': true,
          'offsetMin': [0.0, 0.0, 0.0],
          'offsetMax': [0.0, 0.0, 0.0],
        };
      case PcgNodeType.densityNoise:
        return {'noiseScale': 800.0};
      case PcgNodeType.densityFilter:
        return {'minDensity': 0.4, 'maxDensity': 1.0};
      case PcgNodeType.difference:
        return {
          'radius': 300.0,
          'actorTypes': ['StaticMesh', 'Mesh', 'SkeletalMesh', 'Pawn', 'PlayerStart', 'Primitive'],
        };
      case PcgNodeType.staticMeshSpawner:
        return {'meshes': <Map<String, dynamic>>[]};
    }
  }
}

/// A weighted mesh entry of a Static Mesh Spawner.
class PcgMeshEntry {
  /// Project-relative path (`contents/meshes/barrel.glb` or an `.lmas`).
  final String path;
  final double weight;

  const PcgMeshEntry({required this.path, this.weight = 1.0});

  Map<String, dynamic> toJson() => {'path': path, 'weight': weight};

  factory PcgMeshEntry.fromJson(Map<String, dynamic> json) => PcgMeshEntry(
        path: json['path'] as String? ?? '',
        weight: (json['weight'] as num?)?.toDouble() ?? 1.0,
      );
}

/// One node of a PCG Graph: a type and its parameters.
class PcgNode {
  final String id;
  final PcgNodeType type;
  final Map<String, dynamic> params;

  PcgNode({required this.id, required this.type, Map<String, dynamic>? params})
      : params = params ?? type.defaultParams();

  double number(String key, double fallback) {
    final v = params[key];
    return v is num ? v.toDouble() : fallback;
  }

  bool flag(String key, bool fallback) {
    final v = params[key];
    return v is bool ? v : fallback;
  }

  String text(String key, String fallback) {
    final v = params[key];
    return v is String ? v : fallback;
  }

  List<double> vector3(String key, List<double> fallback) {
    final v = params[key];
    if (v is List && v.length >= 3 && v.every((e) => e is num)) {
      return [for (var i = 0; i < 3; i++) (v[i] as num).toDouble()];
    }
    return fallback;
  }

  List<String> strings(String key, List<String> fallback) {
    final v = params[key];
    if (v is List) return v.map((e) => e.toString()).toList();
    return fallback;
  }

  List<PcgMeshEntry> get meshes {
    final v = params['meshes'];
    if (v is! List) return const [];
    return [
      for (final e in v)
        if (e is Map) PcgMeshEntry.fromJson(Map<String, dynamic>.from(e)),
    ];
  }

  PcgNode copyWith({Map<String, dynamic>? params}) => PcgNode(id: id, type: type, params: params ?? Map<String, dynamic>.from(this.params));

  Map<String, dynamic> toJson() => {'id': id, 'type': type.name, 'params': params};

  factory PcgNode.fromJson(Map<String, dynamic> json) => PcgNode(
        id: json['id'] as String,
        type: PcgNodeType.parse(json['type'] as String),
        params: json['params'] is Map ? Map<String, dynamic>.from(json['params'] as Map) : null,
      );
}

/// A directed edge: [from]'s output feeds [to]'s input.
class PcgEdge {
  final String from;
  final String to;
  const PcgEdge(this.from, this.to);

  Map<String, dynamic> toJson() => {'from': from, 'to': to};
  factory PcgEdge.fromJson(Map<String, dynamic> json) => PcgEdge(json['from'] as String, json['to'] as String);

  @override
  bool operator ==(Object other) => other is PcgEdge && other.from == from && other.to == to;
  @override
  int get hashCode => Object.hash(from, to);
}

/// A PCG Graph: a DAG of [PcgNode]s. Data (surface, points, instances)
/// flows along [edges]; every Static Mesh Spawner's output is what a
/// volume spawns.
class PcgGraph {
  static const int formatVersion = 1;

  final String name;
  final List<PcgNode> nodes;
  final List<PcgEdge> edges;

  /// The graph owns growable copies of [nodes] and [edges] (a caller may
  /// pass `const` lists; the editor adds, removes and relinks in place).
  PcgGraph({required this.name, List<PcgNode>? nodes, List<PcgEdge>? edges})
      : nodes = [...?nodes],
        edges = [...?edges];

  /// The example graph a new asset starts with: surface → sampler → noise →
  /// filter → difference → transform → spawner, with [meshes] (may be empty;
  /// the editor fills them in).
  factory PcgGraph.starter({required String name, List<PcgMeshEntry> meshes = const []}) {
    final chain = [
      PcgNode(id: 'surface', type: PcgNodeType.getSurfaceData),
      PcgNode(id: 'sampler', type: PcgNodeType.surfaceSampler),
      PcgNode(id: 'noise', type: PcgNodeType.densityNoise),
      PcgNode(id: 'filter', type: PcgNodeType.densityFilter),
      PcgNode(id: 'difference', type: PcgNodeType.difference),
      PcgNode(id: 'transform', type: PcgNodeType.transformPoints),
      PcgNode(
        id: 'spawner',
        type: PcgNodeType.staticMeshSpawner,
        params: {'meshes': meshes.map((m) => m.toJson()).toList()},
      ),
    ];
    return PcgGraph(name: name, nodes: chain, edges: [
      for (var i = 0; i + 1 < chain.length; i++) PcgEdge(chain[i].id, chain[i + 1].id),
    ]);
  }

  PcgNode? nodeById(String id) {
    for (final n in nodes) {
      if (n.id == id) return n;
    }
    return null;
  }

  List<String> inputsOf(String id) => [for (final e in edges) if (e.to == id) e.from];

  /// Nodes in dependency order (Kahn), ties broken by list order.
  /// Throws [StateError] on a cycle.
  List<PcgNode> topologicalOrder() {
    final indegree = {for (final n in nodes) n.id: 0};
    for (final e in edges) {
      if (indegree.containsKey(e.to) && indegree.containsKey(e.from)) indegree[e.to] = indegree[e.to]! + 1;
    }
    final ready = [for (final n in nodes) if (indegree[n.id] == 0) n];
    final out = <PcgNode>[];
    while (ready.isNotEmpty) {
      final n = ready.removeAt(0);
      out.add(n);
      for (final e in edges) {
        if (e.from != n.id || !indegree.containsKey(e.to)) continue;
        indegree[e.to] = indegree[e.to]! - 1;
        if (indegree[e.to] == 0) ready.add(nodeById(e.to)!);
      }
    }
    if (out.length != nodes.length) throw StateError('PCG graph "$name" has a cycle');
    return out;
  }

  /// A fresh id for a new node of [type] (`sampler_2` when `sampler` exists).
  String freshNodeId(PcgNodeType type) {
    final base = type.name.replaceAll('getSurfaceData', 'surface').replaceAll('staticMeshSpawner', 'spawner');
    if (nodeById(base) == null) return base;
    var i = 2;
    while (nodeById('${base}_$i') != null) {
      i++;
    }
    return '${base}_$i';
  }

  /// Re-wires the graph as one chain in the order of [nodes]: what the
  /// form-based editor does after an add / remove / reorder.
  void relinkAsChain() {
    edges
      ..clear()
      ..addAll([for (var i = 0; i + 1 < nodes.length; i++) PcgEdge(nodes[i].id, nodes[i + 1].id)]);
  }

  Map<String, dynamic> toJson() => {
        'version': formatVersion,
        'name': name,
        'nodes': nodes.map((n) => n.toJson()).toList(),
        'edges': edges.map((e) => e.toJson()).toList(),
      };

  factory PcgGraph.fromJson(Map<String, dynamic> json) {
    final version = json['version'];
    if (version is int && version > formatVersion) {
      throw FormatException('PCG graph version $version is newer than this plugin ($formatVersion)');
    }
    return PcgGraph(
      name: json['name'] as String? ?? 'PCG Graph',
      nodes: [for (final n in (json['nodes'] as List? ?? const [])) PcgNode.fromJson(Map<String, dynamic>.from(n as Map))],
      edges: [for (final e in (json['edges'] as List? ?? const [])) PcgEdge.fromJson(Map<String, dynamic>.from(e as Map))],
    );
  }

  String toJsonString() => const JsonEncoder.withIndent('  ').convert(toJson());
  factory PcgGraph.fromJsonString(String source) => PcgGraph.fromJson(Map<String, dynamic>.from(jsonDecode(source) as Map));
}
