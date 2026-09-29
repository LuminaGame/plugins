import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show ChangeNotifier, Listenable;
import 'package:lumina_editor_api/lumina_editor_api.dart';

/// The workspace's real 3D models (`Props/*`), as every Lumina smoke uses.
Directory get testAssetsDir {
  final env = Platform.environment['LUMINA_TEST_ASSETS'];
  if (env != null && env.isNotEmpty) return Directory(env);
  return Directory('${Directory.current.path}/../test-assets');
}

/// Copies real barrel models into `<project>/contents/meshes/` and returns
/// their project-relative paths.
List<String> copyBarrels(Directory project) {
  final names = ['fuel_barrel_red.glb', 'dented_barrel.glb', 'empty_barrel.glb'];
  final out = <String>[];
  Directory('${project.path}/contents/meshes').createSync(recursive: true);
  for (final n in names) {
    final src = File('${testAssetsDir.path}/Props/Barrels/$n');
    if (!src.existsSync()) throw StateError('test asset missing: ${src.path}');
    src.copySync('${project.path}/contents/meshes/$n');
    out.add('contents/meshes/$n');
  }
  return out;
}

/// An [EditorLevelAccess] over a real level file: actors live in memory as
/// the editor keeps them, and [saveLevel] writes `metadata.actors` to the
/// project's `.lmas` exactly as Lumina Studio does — so tests assert on disk.
class FileLevel extends ChangeNotifier implements EditorLevelAccess {
  @override
  String? get undoTopLabel => null;

  @override
  bool undoIfTop(String label) => false;

  FileLevel(this.project, {this.activeLevelPath = 'contents/levels/L_Main.lmas'});

  final Directory project;
  @override
  final String activeLevelPath;
  final List<_Actor> _actors = [];
  final List<String> selected = [];
  final List<String> logs = [];
  final List<String> transactions = [];
  final List<String> openedAssets = [];
  int _next = 1;

  @override
  String get projectDirPath => project.path;
  @override
  Listenable get changes => this;
  @override
  List<EditorActorSnapshot> get actors => [for (final a in _actors) a.snapshot()];
  @override
  List<String> get selectedActorIds => List.unmodifiable(selected);

  @override
  Future<T> runTransaction<T>(String label, Future<T> Function() body) => body();

  @override
  Future<List<String>> addActors(List<EditorActorSpec> specs, {String? label}) async {
    transactions.add(label ?? 'add');
    final ids = <String>[];
    for (final s in specs) {
      final id = s.id ?? 'act_${_next++}';
      _actors.add(_Actor(
        id: id,
        name: s.name,
        type: s.type,
        parentId: s.parentId,
        location: List<double>.from(s.location),
        rotation: List<double>.from(s.rotation),
        scale: List<double>.from(s.scale),
        meshAssetPath: s.meshAssetPath,
        components: [
          for (var i = 0; i < s.components.length; i++)
            _Component(id: '${id}_c$i', type: s.components[i].type, name: s.components[i].name, properties: Map<String, dynamic>.from(s.components[i].properties)),
        ],
      ));
      ids.add(id);
    }
    notifyListeners();
    return ids;
  }

  @override
  void removeActors(Iterable<String> ids, {String? label}) {
    transactions.add(label ?? 'remove');
    final set = ids.toSet();
    bool gone(_Actor a) => set.contains(a.id) || (a.parentId != null && set.contains(a.parentId));
    _actors.removeWhere(gone);
    selected.removeWhere(set.contains);
    notifyListeners();
  }

  @override
  void setComponentProperty(String actorId, String componentType, String propertyId, Object? value, {String? label}) {
    transactions.add(label ?? 'set $propertyId');
    final a = _actors.firstWhere((a) => a.id == actorId);
    final c = a.components.firstWhere((c) => c.type == componentType);
    c.properties[propertyId] = value;
    notifyListeners();
  }

  @override
  void selectActors(Iterable<String> ids) {
    selected
      ..clear()
      ..addAll(ids);
    notifyListeners();
  }

  @override
  Future<void> saveLevel() async {
    final file = File('${project.path}/$activeLevelPath');
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(jsonEncode({
      'assetId': 'level_L_Main',
      'name': 'L_Main',
      'type': 'level',
      'relativePath': activeLevelPath,
      'rawPayload': null,
      'metadata': {'actors': [for (final a in _actors) a.toMap()]},
    }));
  }

  @override
  void openAssetEditor(String assetPath) => openedAssets.add(assetPath);

  @override
  void log(String message, {String level = 'info', String source = 'Plugin'}) => logs.add('[$level] $source: $message');
}

class _Component {
  final String id;
  final String type;
  final String name;
  final Map<String, dynamic> properties;
  _Component({required this.id, required this.type, required this.name, required this.properties});
  Map<String, dynamic> toMap() => {'id': id, 'type': type, 'name': name, 'enabled': true, 'properties': properties};
  EditorComponentSnapshot snapshot() => EditorComponentSnapshot(id: id, type: type, name: name, properties: Map.unmodifiable(properties));
}

class _Actor {
  final String id;
  String name;
  final String type;
  String? parentId;
  List<double> location;
  List<double> rotation;
  List<double> scale;
  String? meshAssetPath;
  final List<_Component> components;
  _Actor({
    required this.id,
    required this.name,
    required this.type,
    this.parentId,
    required this.location,
    required this.rotation,
    required this.scale,
    this.meshAssetPath,
    required this.components,
  });

  Map<String, dynamic> toMap() => {
        'id': id,
        'name': name,
        'type': type,
        'parentId': parentId,
        'location': location,
        'rotation': rotation,
        'scale': scale,
        'isVisible': true,
        'isLocked': false,
        'mobility': 'Movable',
        'meshAssetPath': meshAssetPath,
        'components': components.map((c) => c.toMap()).toList(),
      };

  EditorActorSnapshot snapshot() => EditorActorSnapshot(
        id: id,
        name: name,
        type: type,
        parentId: parentId,
        location: List.unmodifiable(location),
        rotation: List.unmodifiable(rotation),
        scale: List.unmodifiable(scale),
        meshAssetPath: meshAssetPath,
        components: [for (final c in components) c.snapshot()],
      );
}
