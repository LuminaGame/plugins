import 'dart:io';

import 'package:lumina/data/models/lumina_asset.dart';
import 'package:lumina_editor_api/lumina_editor_api.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';

import 'package:lumina_plugin_pcg/src/model/pcg_graph.dart';
import 'package:lumina_plugin_pcg/src/model/pcg_graph_asset.dart';
import 'package:lumina_plugin_pcg/src/volume/pcg_volume.dart';
import 'package:lumina_plugin_pcg/src/volume/pcg_volume_service.dart';
import 'package:lumina_plugin_pcg/src/ui/pcg_fields.dart';

/// The PCG Graph editor: a form-based node list, opened as a sub-editor tab
/// by the Content Browser through the plugin's asset type.
///
/// Why a form and not a canvas: the Blueprint graph canvas is a lumina_ui
/// internal (`views/blueprint/`), not part of `lumina_editor_api`, and a
/// plugin depends on the API only. The graph is still a real DAG (`nodes` +
/// `edges` in the `.lmas`); this editor shows it in evaluation order and
/// re-links it as one chain after add / remove / move — every node kind,
/// parameter and the persisted file are the same ones a canvas would edit.
class PcgGraphEditor extends StatefulWidget {
  final LuminaAsset asset;
  final EditorLevelAccess level;
  final PcgVolumeService service;

  const PcgGraphEditor({super.key, required this.asset, required this.level, required this.service});

  @override
  State<PcgGraphEditor> createState() => _PcgGraphEditorState();
}

class _PcgGraphEditorState extends State<PcgGraphEditor> {
  late PcgGraph _graph;
  late final String? _path = widget.asset.metadata[kAssetPathMetadataKey];
  bool _dirty = false;
  String? _status;
  late List<String> _meshChoices = _scanMeshes();

  @override
  void initState() {
    super.initState();
    _graph = PcgGraphAsset.fromAsset(widget.asset) ?? PcgGraph.starter(name: widget.asset.name);
  }

  /// Meshes under `contents/`: raw glTF/OBJ files and imported `FILAMESH`
  /// `.lmas` containers, project-relative, sorted.
  List<String> _scanMeshes() {
    final contents = Directory('${widget.level.projectDirPath}/contents');
    if (!contents.existsSync()) return const [];
    final out = <String>[];
    for (final f in contents.listSync(recursive: true, followLinks: false).whereType<File>()) {
      final lower = f.path.toLowerCase();
      if (lower.endsWith('.glb') || lower.endsWith('.gltf') || lower.endsWith('.obj')) {
        out.add(PcgGraphAsset.relative(widget.level.projectDirPath, f.path));
      } else if (lower.endsWith('.lmas')) {
        try {
          final head = String.fromCharCodes(f.readAsBytesSync().take(4096));
          if (head.contains('"type":"filamesh"') || head.contains('"type": "filamesh"')) {
            out.add(PcgGraphAsset.relative(widget.level.projectDirPath, f.path));
          }
        } catch (_) {}
      }
    }
    out.sort();
    return out;
  }

  void _mutate(void Function() edit) => setState(() {
        edit();
        _dirty = true;
      });

  Future<void> _save() async {
    final path = _path;
    if (path == null) {
      setState(() => _status = 'This asset has no path; the host did not set metadata.asset_path');
      return;
    }
    await PcgGraphAsset.save(_graph, path, assetId: widget.asset.assetId);
    if (!mounted) return;
    setState(() {
      _dirty = false;
      _status = 'Saved ${PcgGraphAsset.relative(widget.level.projectDirPath, path)}';
    });
    widget.level.log('Saved PCG Graph ${_graph.name} (${_graph.nodes.length} nodes)', source: PcgVolumeService.logSource);
  }

  Future<void> _generateUsers() async {
    final path = _path;
    if (path == null) return;
    if (_dirty) await _save();
    final relative = PcgGraphAsset.relative(widget.level.projectDirPath, path);
    var spawned = 0;
    var volumes = 0;
    for (final v in widget.service.volumes) {
      if (PcgVolumeSettings.of(v)?.graphPath != relative) continue;
      volumes++;
      final r = await widget.service.generate(v.id);
      spawned += r.spawned;
    }
    if (!mounted) return;
    setState(() => _status = volumes == 0 ? 'No PCG Volume uses this graph yet' : 'Generated $spawned instances in $volumes volume(s)');
  }

  @override
  Widget build(BuildContext context) {
    final ordered = _graph.topologicalOrder();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          child: Row(
            children: [
              const Icon(LucideIcons.workflow, size: 14),
              const SizedBox(width: 6),
              Text('PCG GRAPH · ${_graph.name}', style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600)),
              if (_dirty) const Padding(padding: EdgeInsets.only(left: 6), child: Text('•', style: TextStyle(fontSize: 14))),
              const Spacer(),
              _AddNodeSelect(onAdd: (type) => _mutate(() {
                    _graph.nodes.add(PcgNode(id: _graph.freshNodeId(type), type: type));
                    _graph.relinkAsChain();
                  })),
              const SizedBox(width: 6),
              OutlineButton(
                key: const Key('pcg_graph_generate_button'),
                size: ButtonSize.small,
                onPressed: _generateUsers,
                child: const Text('Generate volumes'),
              ),
              const SizedBox(width: 6),
              PrimaryButton(
                key: const Key('pcg_graph_save_button'),
                size: ButtonSize.small,
                onPressed: _save,
                child: const Text('Save'),
              ),
            ],
          ),
        ),
        if (_status != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Text(_status!, key: const Key('pcg_graph_status'), style: const TextStyle(fontSize: 10)).muted(),
          ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(10),
            children: [
              for (var i = 0; i < ordered.length; i++) _nodeCard(ordered[i], i, ordered.length),
              if (ordered.isEmpty) const Text('Empty graph: add a Get Surface Data node, then a Surface Sampler and a Static Mesh Spawner.').muted(),
            ],
          ),
        ),
      ],
    );
  }

  Widget _nodeCard(PcgNode node, int index, int count) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Card(
        key: Key('pcg_node_${node.id}'),
        padding: const EdgeInsets.all(8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Text('${index + 1}.', style: const TextStyle(fontSize: 10)).muted(),
                const SizedBox(width: 6),
                Text(node.type.label, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600)),
                const SizedBox(width: 6),
                Text(node.id, style: const TextStyle(fontSize: 10)).muted(),
                const Spacer(),
                GhostButton(
                  size: ButtonSize.small,
                  onPressed: index == 0 ? null : () => _move(node, -1),
                  child: const Icon(LucideIcons.chevronUp, size: 12),
                ),
                GhostButton(
                  size: ButtonSize.small,
                  onPressed: index == count - 1 ? null : () => _move(node, 1),
                  child: const Icon(LucideIcons.chevronDown, size: 12),
                ),
                GhostButton(
                  key: Key('pcg_remove_${node.id}'),
                  size: ButtonSize.small,
                  onPressed: () => _mutate(() {
                    _graph.nodes.removeWhere((n) => n.id == node.id);
                    _graph.relinkAsChain();
                  }),
                  child: const Icon(LucideIcons.x, size: 12),
                ),
              ],
            ),
            const SizedBox(height: 4),
            ..._paramRows(node),
          ],
        ),
      ),
    );
  }

  void _move(PcgNode node, int delta) => _mutate(() {
        final order = _graph.topologicalOrder();
        final i = order.indexWhere((n) => n.id == node.id);
        final j = (i + delta).clamp(0, order.length - 1);
        final moved = order.removeAt(i);
        order.insert(j, moved);
        _graph.nodes
          ..clear()
          ..addAll(order);
        _graph.relinkAsChain();
      });

  void _setParam(PcgNode node, String key, Object? value) => _mutate(() => node.params[key] = value);

  List<Widget> _paramRows(PcgNode node) {
    final rows = <Widget>[];
    for (final entry in node.params.entries) {
      final key = entry.key;
      final value = entry.value;
      if (key == 'meshes') {
        rows.add(_meshList(node));
      } else if (value is bool) {
        rows.add(PcgFieldRow(
          label: key,
          child: Align(
            alignment: Alignment.centerLeft,
            child: Checkbox(
              state: value ? CheckboxState.checked : CheckboxState.unchecked,
              onChanged: (s) => _setParam(node, key, s == CheckboxState.checked),
            ),
          ),
        ));
      } else if (value is num) {
        rows.add(PcgFieldRow(
          label: key,
          child: PcgNumberField(
            fieldKey: Key('pcg_param_${node.id}_$key'),
            value: value.toDouble(),
            fractionDigits: 2,
            onCommit: (v) => _setParam(node, key, v),
          ),
        ));
      } else if (value is List && value.length == 3 && value.every((e) => e is num)) {
        rows.add(PcgFieldRow(
          label: key,
          child: PcgVector3Field(
            value: [for (final e in value) (e as num).toDouble()],
            onCommit: (v) => _setParam(node, key, v),
          ),
        ));
      } else if (key == 'surface') {
        rows.add(PcgFieldRow(
          label: key,
          child: Select<String>(
            value: value as String? ?? 'auto',
            onChanged: (v) => _setParam(node, key, v ?? 'auto'),
            itemBuilder: (context, v) => Text(v, style: const TextStyle(fontSize: 10)),
            popup: SelectPopup(
              items: SelectItemList(
                children: [
                  for (final s in const ['auto', 'landscape', 'floor']) SelectItemButton(value: s, child: Text(s, style: const TextStyle(fontSize: 10))),
                ],
              ),
            ).call,
          ),
        ));
      } else if (value is List) {
        rows.add(PcgFieldRow(
          label: key,
          child: _TextCommit(
            text: value.join(', '),
            onCommit: (t) => _setParam(node, key, [for (final s in t.split(',')) if (s.trim().isNotEmpty) s.trim()]),
          ),
        ));
      } else {
        rows.add(PcgFieldRow(
          label: key,
          child: _TextCommit(text: value?.toString() ?? '', onCommit: (t) => _setParam(node, key, t)),
        ));
      }
    }
    return rows;
  }

  Widget _meshList(PcgNode node) {
    final meshes = node.meshes;
    void write(List<PcgMeshEntry> next) => _setParam(node, 'meshes', next.map((m) => m.toJson()).toList());
    final unused = _meshChoices.where((m) => !meshes.any((e) => e.path == m)).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < meshes.length; i++)
          PcgFieldRow(
            label: i == 0 ? 'meshes' : '',
            child: Row(
              children: [
                Expanded(child: Text(meshes[i].path, key: Key('pcg_mesh_${node.id}_$i'), style: const TextStyle(fontSize: 10), overflow: TextOverflow.ellipsis)),
                const SizedBox(width: 4),
                SizedBox(
                  width: 56,
                  child: PcgNumberField(
                    value: meshes[i].weight,
                    onCommit: (w) {
                      final next = List<PcgMeshEntry>.from(meshes);
                      next[i] = PcgMeshEntry(path: meshes[i].path, weight: w);
                      write(next);
                    },
                  ),
                ),
                GhostButton(
                  size: ButtonSize.small,
                  onPressed: () => write([for (var j = 0; j < meshes.length; j++) if (j != i) meshes[j]]),
                  child: const Icon(LucideIcons.x, size: 12),
                ),
              ],
            ),
          ),
        PcgFieldRow(
          label: meshes.isEmpty ? 'meshes' : '',
          child: Row(
            children: [
              Expanded(
                child: unused.isEmpty
                    ? Text(_meshChoices.isEmpty ? 'No meshes under contents/ (import a .glb first)' : 'All meshes added', style: const TextStyle(fontSize: 10)).muted()
                    : Select<String>(
                        key: Key('pcg_add_mesh_${node.id}'),
                        value: null,
                        placeholder: const Text('Add mesh…', style: TextStyle(fontSize: 10)),
                        onChanged: (v) {
                          if (v != null) write([...meshes, PcgMeshEntry(path: v)]);
                        },
                        itemBuilder: (context, v) => Text(v, style: const TextStyle(fontSize: 10)),
                        popup: SelectPopup(
                          items: SelectItemList(
                            children: [for (final m in unused) SelectItemButton(value: m, child: Text(m, style: const TextStyle(fontSize: 10)))],
                          ),
                        ).call,
                      ),
              ),
              const SizedBox(width: 4),
              GhostButton(
                size: ButtonSize.small,
                onPressed: () => setState(() => _meshChoices = _scanMeshes()),
                child: const Icon(LucideIcons.refreshCw, size: 12),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _AddNodeSelect extends StatelessWidget {
  final ValueChanged<PcgNodeType> onAdd;
  const _AddNodeSelect({required this.onAdd});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 180,
      child: Select<PcgNodeType>(
        key: const Key('pcg_add_node_select'),
        value: null,
        placeholder: const Text('Add node…', style: TextStyle(fontSize: 10)),
        onChanged: (v) {
          if (v != null) onAdd(v);
        },
        itemBuilder: (context, v) => Text(v.label, style: const TextStyle(fontSize: 10)),
        popup: SelectPopup(
          items: SelectItemList(
            children: [for (final t in PcgNodeType.values) SelectItemButton(value: t, child: Text(t.label, style: const TextStyle(fontSize: 10)))],
          ),
        ).call,
      ),
    );
  }
}

class _TextCommit extends StatefulWidget {
  final String text;
  final ValueChanged<String> onCommit;
  const _TextCommit({required this.text, required this.onCommit});

  @override
  State<_TextCommit> createState() => _TextCommitState();
}

class _TextCommitState extends State<_TextCommit> {
  late final TextEditingController _controller = TextEditingController(text: widget.text);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: _controller,
      style: const TextStyle(fontSize: 10),
      onSubmitted: widget.onCommit,
    );
  }
}
