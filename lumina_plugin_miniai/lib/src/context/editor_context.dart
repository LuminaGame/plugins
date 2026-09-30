import 'dart:convert';

/// The editor's current selection, from the host's `get_selection` tool,
/// reduced to what a model needs.
class EditorSelection {
  const EditorSelection({this.actors = const [], this.primaryActorId, this.assets = const [], this.folder, this.activeTab});

  /// Reads a `get_selection` answer.
  factory EditorSelection.fromJson(Map<String, Object?> json) {
    final level = json['level'] is Map ? Map<String, Object?>.from(json['level'] as Map) : const <String, Object?>{};
    final browser = json['content_browser'] is Map ? Map<String, Object?>.from(json['content_browser'] as Map) : const <String, Object?>{};
    final tab = json['active_tab'] is Map ? Map<String, Object?>.from(json['active_tab'] as Map) : null;
    return EditorSelection(
      actors: [
        for (final a in (level['actors'] as List? ?? const []))
          if (a is Map)
            {
              'id': a['id'],
              'name': a['name'],
              'type': a['type'],
              if (a['location'] != null) 'location': a['location'],
              if (a['mesh_asset_path'] != null) 'mesh': a['mesh_asset_path'],
              if (a['blueprint'] is Map) 'blueprint': (a['blueprint'] as Map)['path'],
            },
      ],
      primaryActorId: level['primary_actor_id'] as String?,
      assets: [
        for (final a in (browser['assets'] as List? ?? const []))
          if (a is Map) {'path': a['path'], 'name': a['name'], 'type': a['type']},
      ],
      folder: browser['current_folder'] as String?,
      activeTab: tab == null
          ? null
          : {
              'title': tab['title'],
              'kind': tab['kind'],
              if (tab['asset'] is Map) 'asset': (tab['asset'] as Map)['path'],
              if (tab['selection'] is Map) 'selection': tab['selection'],
            },
    );
  }

  /// Most actors and assets the model gets.
  static const int maxItems = 10;

  /// `{id, name, type, location, …}` per selected actor, in selection order.
  final List<Map<String, Object?>> actors;
  final String? primaryActorId;

  /// `{path, name, type}` per selected Content Browser asset.
  final List<Map<String, Object?>> assets;

  /// The Content Browser's current folder.
  final String? folder;
  final Map<String, Object?>? activeTab;

  /// Nothing selected (no chip).
  bool get isEmpty => actors.isEmpty && assets.isEmpty;

  /// The chip's text: `Divider_Wall · Primitive`, `3 actors`,
  /// `fuel_barrel_red · filamesh`, `2 assets`; null when nothing is selected.
  String? get label {
    String one(Map<String, Object?> m) => '${m['name']} · ${m['type']}';
    final parts = [
      if (actors.length == 1) one(actors.single) else if (actors.length > 1) '${actors.length} actors',
      if (assets.length == 1) one(assets.single) else if (assets.length > 1) '${assets.length} assets',
    ];
    return parts.isEmpty ? null : parts.join(', ');
  }

  /// What the model gets: no components, no properties, at most
  /// [maxItems] actors and assets.
  Map<String, Object?> toContextJson() => {
        if (actors.isNotEmpty)
          'level': {
            'primary_actor_id': ?primaryActorId,
            'selected_actors': actors.take(maxItems).toList(),
            if (actors.length > maxItems) 'more_actors': actors.length - maxItems,
          },
        if (assets.isNotEmpty || folder != null)
          'content_browser': {
            'current_folder': ?folder,
            if (assets.isNotEmpty) 'selected_assets': assets.take(maxItems).toList(),
            if (assets.length > maxItems) 'more_assets': assets.length - maxItems,
          },
        'active_tab': ?activeTab,
      };

  /// Equal for the same selection (a poll that found no change).
  String get signature => jsonEncode(toContextJson());
}

enum MentionKind { asset, folder, actor }

/// Something an `@` mention can name: a Content Browser asset or folder, or
/// a level actor.
class MentionCandidate {
  const MentionCandidate({required this.kind, required this.name, this.path, this.id, this.type});

  final MentionKind kind;

  /// What `@` inserts.
  final String name;

  /// Assets and folders: the project-relative path.
  final String? path;

  /// Actors: the actor id.
  final String? id;

  /// The asset type (`filamesh`) or actor type (`Primitive`).
  final String? type;

  /// The reference the model gets.
  Map<String, Object?> toJson() => {
        'kind': kind.name,
        'name': name,
        'path': ?path,
        'id': ?id,
        'type': ?type,
      };

  @override
  bool operator ==(Object other) => other is MentionCandidate && other.kind == kind && other.path == path && other.id == id && other.name == name;

  @override
  int get hashCode => Object.hash(kind, path, id, name);
}

/// What one message carries besides its text: the selection (unless the
/// user dropped it) and the mentions still in the text.
class MessageContext {
  const MessageContext({this.selection, this.mentions = const []});

  final EditorSelection? selection;
  final List<MentionCandidate> mentions;

  bool get isEmpty => (selection == null || selection!.isEmpty) && mentions.isEmpty;

  /// The JSON object the model reads; null when there is nothing to attach.
  String? get json {
    if (isEmpty) return null;
    return jsonEncode({
      if (selection != null && !selection!.isEmpty) 'selection': selection!.toContextJson(),
      if (mentions.isNotEmpty) 'mentions': [for (final m in mentions) m.toJson()],
    });
  }

  /// [text] with the context block before it (OpenAI-compatible models).
  String messageFor(String text) {
    final data = json;
    return data == null ? text : '<editor_context>\n$data\n</editor_context>\n\n$text';
  }

  /// The line under the user's bubble: `Context: Divider_Wall · Primitive, @fuel_barrel_red`.
  String? get displayLine {
    if (isEmpty) return null;
    return 'Context: ${[
      if (selection?.label != null) selection!.label!,
      for (final m in mentions) '@${m.name}',
    ].join(', ')}';
  }
}
