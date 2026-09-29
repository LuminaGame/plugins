import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';

/// `tool/pack_plugin.dart` on a real temp copy of this
/// plugin (sources copied from the package root, plus the build outputs, IDE
/// folders, logs and secrets a developer's folder holds), its zip read back
/// with package:archive (CRCs verified).
void main() {
  late Directory tempRoot;
  late Directory copy;
  final pluginRoot = Directory.current; // flutter test runs in the package root

  setUp(() {
    tempRoot = Directory.systemTemp.createTempSync('pcg_pack_test_');
    copy = Directory('${tempRoot.path}/lumina_plugin_pcg')..createSync();
    // The tracked sources: everything but the generated folders.
    for (final entity in pluginRoot.listSync(recursive: true, followLinks: false)) {
      final rel = entity.path.substring(pluginRoot.path.length + 1).replaceAll(r'\', '/');
      if (RegExp(r'^(build|\.dart_tool|\.git|\.idea)(/|$)').hasMatch(rel)) continue;
      if (entity is Directory) {
        Directory('${copy.path}/$rel').createSync(recursive: true);
      } else if (entity is File) {
        File('${copy.path}/$rel')
          ..parent.createSync(recursive: true)
          ..writeAsBytesSync(entity.readAsBytesSync());
      }
    }
  });
  tearDown(() {
    if (tempRoot.existsSync()) tempRoot.deleteSync(recursive: true);
  });

  void write(String rel, [String contents = 'x']) => File('${copy.path}/$rel')
    ..parent.createSync(recursive: true)
    ..writeAsStringSync(contents);

  /// Runs this plugin's script (resolved in the real package) on [dir].
  Future<ProcessResult> pack(Directory dir, [List<String> args = const []]) => Process.run(
        'dart',
        ['tool/pack_plugin.dart', dir.path, ...args],
        workingDirectory: pluginRoot.path,
        runInShell: Platform.isWindows,
      );

  File zipOf(Directory dir, [String version = '0.1.0']) => File('${dir.path}/build/pack/lumina_plugin_pcg-$version.zip');

  Set<String> names(File zip) =>
      {for (final e in ZipDecoder().decodeBytes(zip.readAsBytesSync(), verify: true)) if (e.isFile) e.name};

  void setVersion(String file, String from, String to) {
    final f = File('${copy.path}/$file');
    f.writeAsStringSync(f.readAsStringSync().replaceFirst(from, to));
  }

  test('packs under the single top lumina_plugin_pcg/ without build outputs, IDE folders, logs and secrets',
      () async {
    write('build/lib/app.dill');
    write('build/pack/old.zip');
    write('.dart_tool/package_config.json', '{}');
    write('.dart_tool/flutter_build/x.bin');
    write('.idea/workspace.xml');
    write('debug.log');
    write('.env', 'KEY=1');
    write('credentials.json', '{}');
    final res = await pack(copy);
    expect(res.exitCode, 0, reason: '${res.stdout}\n${res.stderr}');

    final zip = zipOf(copy);
    final all = names(zip);
    expect(all.every((n) => n.startsWith('lumina_plugin_pcg/')), isTrue);
    expect(all, containsAll([
      'lumina_plugin_pcg/lib/lumina_plugin_pcg.dart',
      'lumina_plugin_pcg/pubspec.yaml',
      'lumina_plugin_pcg/lumina_plugin_pcg.lmplugin',
      'lumina_plugin_pcg/LICENSE',
      'lumina_plugin_pcg/CHANGELOG.md',
      'lumina_plugin_pcg/tool/pack_plugin.dart',
    ]));
    for (final left in ['/build/', '/.dart_tool/', '/.idea/', 'debug.log', '.env', 'credentials.json']) {
      expect(all.where((n) => n.contains(left)), isEmpty, reason: left);
    }

    final out = res.stdout as String;
    expect(out, contains(zip.path.replaceAll('/', Platform.pathSeparator)));
    expect(out, contains('${all.length} files'));
    expect(out, contains('build/ (2 files)'));
    expect(out, contains('.dart_tool/ (2 files)'));
    expect(out, contains('.idea/ (1 file)'));
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('.gitignore and .pubignore patterns are honored', () async {
    File('${copy.path}/.gitignore').writeAsStringSync('secret/\n', mode: FileMode.append);
    write('secret/token.json', '{}');
    write('lib/.pubignore', '*.bak.txt\n');
    write('lib/notes.bak.txt');
    write('lib/notes.txt');
    final res = await pack(copy);
    expect(res.exitCode, 0, reason: '${res.stdout}\n${res.stderr}');
    final all = names(zipOf(copy));
    expect(all, isNot(contains('lumina_plugin_pcg/secret/token.json')));
    expect(all, isNot(contains('lumina_plugin_pcg/lib/notes.bak.txt')));
    expect(all, contains('lumina_plugin_pcg/lib/notes.txt'));
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('a version mismatch names both versions and both files', () async {
    setVersion('lumina_plugin_pcg.lmplugin', '"version": "0.1.0"', '"version": "0.2.0"');
    final res = await pack(copy);
    expect(res.exitCode, isNot(0));
    final err = res.stderr as String;
    expect(err, allOf(contains('lumina_plugin_pcg.lmplugin'), contains('0.2.0'), contains('pubspec.yaml'), contains('0.1.0')));
    expect(zipOf(copy, '0.2.0').existsSync(), isFalse);
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('a missing LICENSE names the license field', () async {
    File('${copy.path}/LICENSE').deleteSync();
    final res = await pack(copy);
    expect(res.exitCode, isNot(0));
    expect(res.stderr as String, contains('"license"'));
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('a disallowed file is named; --skip-disallowed packs without it, with a warning', () async {
    write('tool/helper.exe', 'MZ');
    var res = await pack(copy);
    expect(res.exitCode, isNot(0));
    expect(res.stderr as String, contains('tool/helper.exe'));
    expect(zipOf(copy).existsSync(), isFalse);

    res = await pack(copy, ['--skip-disallowed']);
    expect(res.exitCode, 0, reason: '${res.stdout}\n${res.stderr}');
    expect(res.stderr as String, allOf(contains('Warning'), contains('tool/helper.exe')));
    expect(names(zipOf(copy)), isNot(contains('lumina_plugin_pcg/tool/helper.exe')));
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('--dry-run writes nothing and lists the files', () async {
    final res = await pack(copy, ['--dry-run']);
    expect(res.exitCode, 0, reason: '${res.stdout}\n${res.stderr}');
    expect(res.stdout as String, contains('lumina_plugin_pcg/lib/lumina_plugin_pcg.dart'));
    expect(Directory('${copy.path}/build/pack').existsSync(), isFalse);
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('two packs of unchanged sources are byte-identical', () async {
    final out = Directory('${tempRoot.path}/dist');
    var res = await pack(copy, ['--out', out.path]);
    expect(res.exitCode, 0, reason: '${res.stdout}\n${res.stderr}');
    final zip = File('${out.path}/lumina_plugin_pcg-0.1.0.zip');
    final first = zip.readAsBytesSync();
    // A later mtime must not change the bytes.
    File('${copy.path}/README.md').setLastModifiedSync(DateTime.now().add(const Duration(minutes: 5)));
    res = await pack(copy, ['--out', out.path]);
    expect(res.exitCode, 0, reason: '${res.stdout}\n${res.stderr}');
    expect(zip.readAsBytesSync(), first);
    expect(out.listSync().map((e) => e.uri.pathSegments.last), ['lumina_plugin_pcg-0.1.0.zip'],
        reason: 'no .tmp left behind');
  }, timeout: const Timeout(Duration(minutes: 2)));
}
