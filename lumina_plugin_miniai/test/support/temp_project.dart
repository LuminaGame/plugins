import 'dart:convert';
import 'dart:io';

import 'package:lumina_editor_api/lumina_editor_api.dart';

import 'local_mcp.dart';

/// A real project folder in the system temp directory — assets as `.lmas`
/// files under `contents/`, a level file with its actors — and the host's
/// read tools (`list_assets`, `list_content_folders`, `list_actors`,
/// `get_selection`) answering from it, with the host's result shapes. The
/// selection is editor state: [selectedActors] and [selectedAssets].
class TempProject {
  TempProject(this.root) {
    void asset(String path, String type) => File('${root.path}/$path')
      ..createSync(recursive: true)
      ..writeAsStringSync(jsonEncode({'type': type, 'name': path.split('/').last.replaceAll('.lmas', '')}));
    asset('contents/meshes/fuel_barrel_red.lmas', 'filamesh');
    asset('contents/meshes/Divider_Wall.lmas', 'filamesh');
    asset('contents/Props/crate_wood.lmas', 'filamesh');
    asset('contents/materials/M_Brick.lmas', 'filamat');
    File(levelPath)
      ..createSync(recursive: true)
      ..writeAsStringSync(jsonEncode({
        'type': 'level',
        'actors': [
          {'id': 'actor_wall', 'name': 'Divider_Wall', 'type': 'Primitive', 'location': [120.0, 0.0, 0.0]},
          {'id': 'actor_light', 'name': 'Sun', 'type': 'DirectionalLight', 'location': [0.0, 0.0, 500.0]},
          {'id': 'actor_barrel', 'name': 'fuel_barrel_red_1', 'type': 'Mesh', 'location': [0.0, 250.0, 0.0]},
        ],
      }));
  }

  final Directory root;
  final List<String> selectedActors = [];
  final List<String> selectedAssets = [];

  String get levelPath => '${root.path}/contents/levels/L_Main.lmas';

  List<Map<String, Object?>> get actors =>
      [for (final a in (jsonDecode(File(levelPath).readAsStringSync()) as Map)['actors'] as List) Map<String, Object?>.from(a as Map)];

  /// Every `.lmas` under `contents/`, project-relative, `/`-separated.
  List<(String, String)> get assets => [
        for (final f in Directory('${root.path}/contents').listSync(recursive: true).whereType<File>())
          if (f.path.endsWith('.lmas'))
            (
              f.path.substring(root.path.length + 1).replaceAll(r'\', '/'),
              '${(jsonDecode(f.readAsStringSync()) as Map)['type']}',
            ),
      ]..sort((a, b) => a.$1.compareTo(b.$1));

  static String _name(String path) => path.split('/').last.replaceAll('.lmas', '');

  McpTool _tool(String name, McpToolHandler handler, Set<String> groups) =>
      McpTool(name: name, description: name, inputSchema: McpSchema.object({}), handler: handler, risk: McpToolRisk.readOnly, groups: groups);

  void register(LocalMcp mcp) {
    mcp
      ..registerTool(_tool('list_assets', (_) {
        final all = assets;
        return McpToolResult.json({
          'count': all.length,
          'assets': [for (final (path, type) in all) {'path': path, 'file_name': '${_name(path)}.lmas', 'type': type}],
        });
      }, {McpToolGroups.asset}))
      ..registerTool(_tool('list_content_folders', (_) {
        final dirs = [
          for (final d in Directory('${root.path}/contents').listSync(recursive: true).whereType<Directory>())
            d.path.substring(root.path.length + 1).replaceAll(r'\', '/'),
        ];
        Map<String, Object?> node(String path) => {
              'path': path,
              'name': path.split('/').last,
              'children': [for (final d in dirs..sort()) if (d.substring(0, d.lastIndexOf('/')) == path) node(d)],
            };
        return McpToolResult.json({'folders': [node('contents')]});
      }, {'content'}))
      ..registerTool(_tool('list_actors', (_) => McpToolResult.json({'count': actors.length, 'actors': actors}), {McpToolGroups.level}))
      ..registerTool(_tool('get_selection', (_) {
        final byId = {for (final a in actors) a['id']: a};
        final byPath = {for (final (p, t) in assets) p: t};
        return McpToolResult.json({
          'level': {
            'count': selectedActors.length,
            'primary_actor_id': selectedActors.lastOrNull,
            'actors': [
              for (final id in selectedActors)
                if (byId[id] case final a?) {...a, 'primary': id == selectedActors.last, 'components': const []},
            ],
          },
          'content_browser': {
            'current_folder': 'contents/meshes',
            'count': selectedAssets.length,
            'assets': [
              for (final p in selectedAssets) {'path': p, 'name': _name(p), 'type': byPath[p]},
            ],
          },
          'active_tab': {'index': 0, 'id': 'level', 'title': 'L_Main', 'kind': 'level', 'asset': null, 'selection': null},
        });
      }, {McpToolGroups.level, McpToolGroups.asset}));
  }
}
