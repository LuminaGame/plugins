/// What every model MiniAI runs is told about how Lumina works: the
/// essentials of the editor's engine guide (`get_lumina_guide`, the
/// `lumina-engine` skill), and to read a topic before working in an area it
/// has not used yet.
abstract final class LuminaPrimer {
  /// The editor's read-only tool that serves the guide.
  static const String guideTool = 'get_lumina_guide';

  /// The guide's topics (the editor's `skills/lumina-engine/reference/`).
  static const List<String> topics = [
    'project-layout', 'levels-actors-transforms', 'blueprints', 'gameplay-framework', 'input', 'umg-widgets', //
    'meshes-materials', 'filament-materials', 'lights', 'camera-spring-arm', 'play-testing', 'save-games', 'pitfalls',
  ];

  /// For cloud models and Claude Code.
  static const String full = '''How Lumina works (the essentials; the full guide is the get_lumina_guide tool, if you have it):
- Before working in an area you have not used yet in this chat, call get_lumina_guide with its topic: project-layout, levels-actors-transforms, blueprints, gameplay-framework, input, umg-widgets, meshes-materials, filament-materials, lights, camera-spring-arm, play-testing, save-games, pitfalls. Without a topic it returns the overview.
- Units are centimetres and degrees, Z is up. A rotation is [x, y, z] degrees; index 2 is the yaw. At rotation 0 an actor faces +Y (right is +X); yaw 90 faces +X, yaw 180 faces -Y.
- The .lmas assets under contents/ and the .lmproject are the source of truth; the Dart in lib/ is generated from them. Change them only through the editor tools, never with file edits.
- Blueprints: read node ids and pin ids with list_blueprint_nodes / get_blueprint (never guess them); compile_blueprint with save true writes the asset and its Dart; Play runs the graphs as they are in the editor, a compile error stops Play.
- The player: the level needs a PlayerStart; the game mode and pawn come from Project Settings > Maps & Modes (set_project_settings, then apply_project_settings: until then a change is only staged). A GameMode Blueprint's graph does not run, only its class defaults.
- Input actions and keys live in Project Settings (edit_project_input, then apply_project_settings); only the possessed pawn's input events fire.
- Widgets: Create Widget with its class, Add to Viewport, keep the reference; find elements by their designer name (Get Element with class + element).
- Before writing or editing a material's source, read filament-materials; a mesh gets a material through its slot, a Blueprint materialOverride or Set Material, and compile_material needs save true.''';

  /// For the small local model (8 K context): a few lines.
  static const String compact =
      '''Lumina: cm, degrees, Z up; rotation [x, y, z], index 2 = yaw; yaw 0 faces +Y, yaw 90 faces +X. Assets (.lmas) are the source of truth: change them only with the editor tools. Read node and pin ids with list_blueprint_nodes / get_blueprint. Project Settings changes need apply_project_settings. Before working in an unfamiliar area call get_lumina_guide with a topic (blueprints, gameplay-framework, input, umg-widgets, meshes-materials, filament-materials, lights, camera-spring-arm, play-testing, pitfalls); without a topic it lists them.''';
}
