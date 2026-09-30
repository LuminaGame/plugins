import 'package:lumina_editor_api/lumina_editor_api.dart';

import '../llm/llm_types.dart';
import 'approval.dart';
import 'lumina_primer.dart';

/// Picks the few tool groups a request needs: a small model
/// cannot use 100+ tools, so it gets the groups its words point at, plus
/// `core`, at most [maxTools] tools, with short descriptions.
///
/// Requests may be in English, Turkish, Spanish, German or French. A
/// keyword ending in `*` is a stem that matches at a word start (`sahne*`:
/// sahneye, sahnede); any other keyword matches a whole word or phrase.
/// Matching folds Turkish case (`I`/`ı`, `İ`/`i`).
class ToolsetSelector {
  const ToolsetSelector({this.maxTools = 12, this.maxDescription = 160, this.disabledGroups = const {}});

  final int maxTools;
  final int maxDescription;

  /// Groups the project never gives the assistant; `core` is
  /// always kept.
  final Set<String> disabledGroups;

  bool _allowed(McpTool t) => t.groups.contains(McpToolGroups.core) || t.groups.intersection(disabledGroups).isEmpty;

  /// The groups offered when no keyword matches: enough to look around,
  /// place things and see the result.
  static const List<String> fallbackGroups = [McpToolGroups.level, McpToolGroups.asset, McpToolGroups.view];

  static const Map<String, List<String>> _keywords = {
    McpToolGroups.level: [
      'actor', 'actors', 'place', 'spawn', 'move', 'rotate', 'scale', 'delete', 'remove', 'level', 'scene', 'barrel', 'light', //
      'duplicate', 'rename', 'select', 'transform', 'outliner',
      // Turkish
      'sahne*', 'seviye*', 'ekle*', 'oluştur*', 'yerleştir*', 'koy*', 'yarat*', 'aktör*', 'nesne*', 'obje*', 'taşı*', 'döndür*', //
      'ölçekle*', 'büyüt*', 'küçült*', 'sil*', 'kaldır*', 'çoğalt*', 'kopyala*', 'seç*', 'ışık*', 'duvar*', 'küp*', 'varil*', //
      'adlandır*', 'konum*',
      // Spanish, German, French
      'escena*', 'nivel*', 'añad*', 'agreg*', 'crea*', 'coloca*', 'mueve*', 'mover', 'elimina*', 'borra*', //
      'szene*', 'hinzufüg*', 'füge*', 'erstell*', 'platzier*', 'verschieb*', 'lösch*', 'entfern*', //
      'scène*', 'niveau*', 'ajout*', 'crée*', 'créer', 'placer', 'déplace*', 'supprime*',
    ],
    McpToolGroups.asset: [
      'asset', 'assets', 'mesh', 'meshes', 'texture', 'import', 'content', 'folder',
      'varlık*', 'asset*', 'model*', 'mesh*', 'doku*', 'içe aktar*', 'içeri aktar*', 'klasör*', 'içerik*', 'dosya*', //
      'recurso*', 'modelo*', 'textura*', 'importa*', 'carpeta*', //
      'textur*', 'importier*', 'ordner*', 'inhalt*', //
      'ressource*', 'importe*', 'dossier*',
    ],
    McpToolGroups.material: [
      'material', 'shader', 'color', 'colour', 'roughness', 'metallic',
      'malzeme*', 'materyal*', 'renk*', 'rengi*', 'boya*', 'pürüzlü*', 'metalik*', 'kaplama*', //
      'material*', 'color*', 'farbe*', 'matériau*', 'couleur*',
    ],
    McpToolGroups.blueprint: [
      'blueprint', 'node', 'nodes', 'graph', 'event', 'variable', 'function', 'wire', 'pin',
      'blueprint*', 'düğüm*', 'grafik*', 'olay*', 'değişken*', 'fonksiyon*', 'işlev*', 'bağla*', //
      'nodo*', 'variable*', 'función*', 'evento*', 'knoten*', 'funktion*', 'ereignis*', 'nœud*', 'noeud*', 'fonction*', 'événement*',
    ],
    McpToolGroups.component: [
      'component', 'components', 'property', 'properties',
      'bileşen*', 'komponent*', 'özellik*', 'componente*', 'propiedad*', 'eigenschaft*', 'composant*', 'propriété*',
    ],
    McpToolGroups.pie: [
      'play', 'pie', 'run the game', 'simulate', 'playtest',
      'oyna*', 'oynat*', 'oyun*', 'test et*', 'çalıştır*', 'dene*', 'başlat*', 'simüle*', //
      'jugar', 'juega*', 'prueba*', 'ejecuta*', 'spiel*', 'starte*', 'teste*', 'jouer', 'joue*', 'lance*',
    ],
    McpToolGroups.view: [
      'camera', 'screenshot', 'view', 'viewport', 'look at', 'focus',
      'kamera*', 'ekran görüntü*', 'görüntü*', 'bak*', 'görünüm*', 'odakla*', //
      'cámara*', 'captura*', 'vista*', 'mira*', 'bildschirmfoto*', 'ansicht*', 'schau*', 'caméra*', 'capture*', 'vue', 'regarde*',
    ],
    McpToolGroups.log: [
      'log', 'error', 'errors', 'warning', 'output',
      'günlü*', 'hata*', 'uyarı*', 'çıktı*', 'registro*', 'error*', 'advertencia*', 'fehler*', 'warnung*', 'protokoll*', //
      'erreur*', 'journal*', 'avertissement*',
    ],
  };

  /// Request words → the words host tool names use; `*` keys are stems.
  static const Map<String, List<String>> _synonyms = {
    'place': ['spawn', 'asset'],
    'put': ['spawn', 'asset'],
    'add': ['spawn', 'add'],
    'create': ['spawn', 'create'],
    'move': ['transform', 'set'],
    'rotate': ['transform', 'set'],
    'scale': ['transform', 'set'],
    'remove': ['delete'],
    'barrel': ['asset'],
    'barrels': ['asset'],
    'how': ['list', 'get'],
    'many': ['list'],
    'ekle*': ['spawn', 'add'],
    'oluştur*': ['spawn', 'create'],
    'yarat*': ['spawn', 'create'],
    'yerleştir*': ['spawn', 'asset'],
    'koy*': ['spawn', 'asset'],
    'küp*': ['spawn'],
    'varil*': ['asset'],
    'sil*': ['delete'],
    'kaldır*': ['delete', 'remove'],
    'taşı*': ['transform', 'set', 'move'],
    'döndür*': ['transform', 'set', 'rotate'],
    'ölçekle*': ['transform', 'set', 'scale'],
    'oyna*': ['play', 'start', 'pie'],
    'çalıştır*': ['play', 'start'],
    'başlat*': ['play', 'start'],
    'dene*': ['play', 'pie'],
    'ekran*': ['screenshot'],
    'görüntü*': ['screenshot', 'view'],
    'kamera*': ['camera'],
    'listele*': ['list'],
    'kaç': ['list', 'count'],
    'göster*': ['list', 'get'],
  };

  /// Words that ask for a change to the project.
  static const List<String> _changeWords = [
    'add', 'place', 'put', 'create', 'spawn', 'make', 'build', 'move', 'rotate', 'scale', 'delete', 'remove', 'rename', //
    'duplicate', 'set', 'change', 'paint', 'import', 'attach', 'generate', 'fix', 'write', 'edit', 'replace',
    'ekle*', 'oluştur*', 'yerleştir*', 'koy*', 'yap*', 'yarat*', 'taşı*', 'döndür*', 'ölçekle*', 'sil*', 'kaldır*', //
    'değiştir*', 'düzelt*', 'boya*', 'adlandır*', 'çoğalt*', 'kopyala*', 'içe aktar*', 'bağla*', 'ayarla*', 'yaz*', 'üret*', //
    'añad*', 'crea*', 'coloca*', 'elimina*', 'hinzufüg*', 'erstell*', 'platzier*', 'lösch*', 'ajout*', 'crée*', 'supprime*',
  ];

  /// [text] in lower case with Turkish dotted / dotless i folded to `i`.
  static String fold(String text) => text.toLowerCase().replaceAll('ı', 'i').replaceAll('̇', '');

  static final Map<String, RegExp> _patterns = {};

  static RegExp _pattern(String keyword) => _patterns.putIfAbsent(keyword, () {
        final stem = keyword.endsWith('*');
        final word = fold(stem ? keyword.substring(0, keyword.length - 1) : keyword);
        return RegExp('(?<![\\p{L}\\p{N}])${RegExp.escape(word)}${stem ? '' : '(?![\\p{L}\\p{N}])'}', unicode: true);
      });

  static bool _matches(String folded, List<String> keywords) => keywords.any((k) => _pattern(k).hasMatch(folded));

  /// The groups [message] needs; [fallbackGroups] when nothing matches.
  Set<String> groupsFor(String message) {
    final text = fold(message);
    final groups = <String>{};
    for (final e in _keywords.entries) {
      if (disabledGroups.contains(e.key)) continue;
      if (_matches(text, e.value)) groups.add(e.key);
    }
    if (groups.isEmpty) groups.addAll(fallbackGroups.where((g) => !disabledGroups.contains(g)));
    return groups;
  }

  /// Whether [message] asks to change the project (add, place, delete, …).
  static bool asksForChanges(String message) => _matches(fold(message), _changeWords);

  /// The words of [message] plus the tool-name words they stand for.
  static Set<String> _words(String message) {
    final words = fold(message).split(RegExp(r'[^\p{L}\p{N}]+', unicode: true)).where((w) => w.length > 2 || w == 'kaç').toSet();
    for (final w in List.of(words)) {
      for (final e in _synonyms.entries) {
        final stem = e.key.endsWith('*');
        final key = fold(stem ? e.key.substring(0, e.key.length - 1) : e.key);
        if (stem ? w.startsWith(key) : w == key) words.addAll(e.value);
      }
    }
    return words;
  }

  /// [tools] ordered by how many of their name's words the request uses
  /// (a stable sort: ties keep their order).
  static List<McpTool> _byScore(List<McpTool> tools, String message) {
    final words = _words(message);
    int score(McpTool t) => t.name.toLowerCase().split(RegExp(r'[_.]')).where(words.contains).length;
    final indexed = [for (var i = 0; i < tools.length; i++) (i, tools[i], score(tools[i]))];
    indexed.sort((a, b) => b.$3 != a.$3 ? b.$3.compareTo(a.$3) : a.$1.compareTo(b.$1));
    return [for (final e in indexed) e.$2];
  }

  /// The tools to offer for [message] in [gate]'s mode, as [LlmToolSpec]s:
  /// the engine guide (`get_lumina_guide`) always first, then the groups' tools (read-only before changes, so a truncated list
  /// keeps the ones that look before they act… and the mutating ones the
  /// request asked for), then `core`, capped at [maxTools].
  List<McpTool> select(List<McpTool> all, String message, ApprovalGate gate) {
    final groups = groupsFor(message);
    final offered = [for (final t in all) if (gate.decide(t) != ApprovalDecision.hidden && _allowed(t)) t];
    final guide = [for (final t in offered) if (t.name == LuminaPrimer.guideTool) t];
    final inGroups = [for (final t in offered) if (t.groups.intersection(groups).isNotEmpty && !guide.contains(t)) t];
    final core = [
      for (final t in offered)
        if (t.groups.contains(McpToolGroups.core) && !inGroups.contains(t) && !guide.contains(t)) t,
    ];
    return [...guide, ..._byScore(inGroups, message), ...core].take(maxTools).toList();
  }

  /// The tools of [message]'s groups that [gate]'s mode hides (Plan mode's
  /// changes), best matches first.
  List<McpTool> hiddenFor(List<McpTool> all, String message, ApprovalGate gate) {
    final groups = groupsFor(message);
    return _byScore([
      for (final t in all)
        if (gate.decide(t) == ApprovalDecision.hidden && _allowed(t) && t.groups.intersection(groups).isNotEmpty) t,
    ], message);
  }

  LlmToolSpec specOf(McpTool tool) => LlmToolSpec(
        name: tool.name,
        description: tool.description.length <= maxDescription ? tool.description : '${tool.description.substring(0, maxDescription - 1)}…',
        parameters: tool.inputSchema,
      );
}
