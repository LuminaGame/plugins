import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_editor_api/lumina_editor_api.dart';
import 'package:lumina_plugin_pcg/lumina_plugin_pcg.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';

import 'test_support.dart';

void main() {
  late Directory project;
  late FileLevel level;
  late PcgVolumeService service;

  setUp(() async {
    project = Directory.systemTemp.createTempSync('pcg_widgets_');
    final barrels = copyBarrels(project);
    level = FileLevel(project);
    service = PcgVolumeService(level);
    final g = PcgGraph.starter(name: 'Barrels', meshes: [PcgMeshEntry(path: barrels.first)]);
    g.nodeById('sampler')!.params['cellSize'] = 500.0;
    await PcgGraphAsset.save(g, '${project.path}/contents/pcg/Barrels.lmas');
  });
  tearDown(() => project.deleteSync(recursive: true));

  Widget app(Widget child) => ShadcnApp(theme: ThemeData(colorScheme: ColorSchemes.darkZinc, radius: 0.5), home: Scaffold(child: child));

  testWidgets('PcgVolumeDetails: Generate places instances, the count updates, Cleanup empties it, edits go through setProperty', (tester) async {
    tester.view.physicalSize = const Size(900, 700);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    final id = await service.placeVolume(location: [0.0, 0.0, 0.0], graphPath: 'contents/pcg/Barrels.lmas', seed: 8);
    final sets = <String>[];
    Widget details() => ListenableBuilder(
          listenable: level,
          builder: (context, _) => PcgVolumeDetails(
            target: DetailsTarget(
              target: level.actors.firstWhere((a) => a.id == id),
              setProperty: (name, value) {
                sets.add('$name=$value');
                final dot = name.indexOf('.');
                level.setComponentProperty(id, name.substring(0, dot), name.substring(dot + 1), value);
              },
            ),
            level: level,
            service: service,
          ),
        );
    await tester.pumpWidget(app(details()));
    await tester.pump();
    expect(find.text('0'), findsOneWidget);
    expect(find.text('Generate'), findsOneWidget);

    await tester.tap(find.byKey(const Key('pcg_generate_button')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    final n = service.generatedBy(id).length;
    expect(n, greaterThan(0));
    expect(find.byKey(const Key('pcg_instance_count')), findsOneWidget);
    expect((tester.widget(find.byKey(const Key('pcg_instance_count'))) as Text).data, '$n');
    expect((tester.widget(find.byKey(const Key('pcg_status'))) as Text).data, contains('Generated $n instances'));

    await tester.enterText(find.byKey(const Key('pcg_seed_field')), '123');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(sets, contains('${PcgTypes.component}.${PcgTypes.propSeed}=123'));
    expect(PcgVolumeSettings.of(level.actors.firstWhere((a) => a.id == id))!.seed, 123);

    await tester.tap(find.byKey(const Key('pcg_cleanup_button')));
    await tester.pump();
    expect(service.generatedBy(id), isEmpty);
    expect((tester.widget(find.byKey(const Key('pcg_instance_count'))) as Text).data, '0');

    await tester.tap(find.byKey(const Key('pcg_edit_graph_button')));
    await tester.pump();
    expect(level.openedAssets, ['contents/pcg/Barrels.lmas']);
  });

  testWidgets('PcgGraphEditor: lists the chain, removes a node, saves the .lmas, and generates the volumes using it', (tester) async {
    // Tall enough for the whole chain: the node list is a ListView, which
    // does not build the cards below its viewport.
    tester.view.physicalSize = const Size(1000, 1800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    final path = '${project.path}/contents/pcg/Barrels.lmas';
    final id = await service.placeVolume(location: [0.0, 0.0, 0.0], graphPath: 'contents/pcg/Barrels.lmas', seed: 8);
    await tester.pumpWidget(app(PcgGraphEditor(asset: loadPcgGraphAssetForEditor(path), level: level, service: service)));
    await tester.pump();
    for (final t in PcgNodeType.values) {
      expect(find.text(t.label), findsOneWidget, reason: 'every starter node is listed');
    }
    expect(find.byKey(const Key('pcg_mesh_spawner_0')), findsOneWidget);

    await tester.tap(find.byKey(const Key('pcg_remove_filter')));
    await tester.pump();
    expect(find.text(PcgNodeType.densityFilter.label), findsNothing);
    await tester.tap(find.byKey(const Key('pcg_graph_save_button')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    final saved = PcgGraphAsset.load(path)!;
    expect(saved.nodes.map((n) => n.id), isNot(contains('filter')));
    expect(saved.edges, hasLength(saved.nodes.length - 1), reason: 're-linked as a chain');
    expect(saved.topologicalOrder().last.type, PcgNodeType.staticMeshSpawner);

    await tester.tap(find.byKey(const Key('pcg_graph_generate_button')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(service.generatedBy(id), isNotEmpty);
    expect((tester.widget(find.byKey(const Key('pcg_graph_status'))) as Text).data, contains('in 1 volume(s)'));
  });
}
