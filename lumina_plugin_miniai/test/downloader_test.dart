// The resumable, verified downloader against a real local HTTP
// server serving a real asset (Range support, a 302 hop like GitHub's CDN).
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_plugin_miniai/lumina_plugin_miniai.dart';

import 'support/replay_server.dart';

class _RangeServer {
  _RangeServer(this.bytes);

  final Uint8List bytes;
  late HttpServer _server;
  final List<String?> ranges = [];

  Uri get url => Uri.parse('http://127.0.0.1:${_server.port}/redirect/fuel_barrel_red.glb');

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen((request) async {
      final response = request.response;
      if (request.uri.path.startsWith('/redirect/')) {
        response.statusCode = HttpStatus.found;
        response.headers.set(HttpHeaders.locationHeader, '/files/${request.uri.pathSegments.last}');
        await response.close();
        return;
      }
      final range = request.headers.value(HttpHeaders.rangeHeader);
      ranges.add(range);
      var start = 0;
      if (range != null) {
        start = int.parse(RegExp(r'bytes=(\d+)-').firstMatch(range)!.group(1)!);
        response.statusCode = HttpStatus.partialContent;
        response.headers.set(HttpHeaders.contentRangeHeader, 'bytes $start-${bytes.length - 1}/${bytes.length}');
      }
      response.contentLength = bytes.length - start;
      try {
        // Small chunks with a pause, so a cancel lands half-way.
        for (var i = start; i < bytes.length; i += 4096) {
          response.add(bytes.sublist(i, i + 4096 > bytes.length ? bytes.length : i + 4096));
          await response.flush();
          await Future<void>.delayed(const Duration(milliseconds: 15));
        }
        await response.close();
      } catch (_) {}
    });
  }

  Future<void> close() => _server.close(force: true);
}

void main() {
  final source = File('${Directory.current.parent.path}/test-assets/Props/Barrels/fuel_barrel_red.glb');
  late Directory temp;
  late _RangeServer server;
  late String sha;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('miniai_dl_');
    server = _RangeServer(await source.readAsBytes());
    await server.start();
    sha = await Downloader.sha256Of(source);
  });

  tearDown(() async {
    await server.close();
    await temp.delete(recursive: true);
  });

  test('a full download equals the source, is verified and leaves no part', () async {
    final target = File('${temp.path}/models/barrel.glb');
    final progress = <int>[];
    await Downloader(httpClient: realIoHttpClient).fetch(server.url, target, sha256: sha, size: server.bytes.length, onProgress: (r, _) => progress.add(r));
    expect(await target.readAsBytes(), server.bytes);
    expect(File('${target.path}.part').existsSync(), isFalse);
    for (var i = 1; i < progress.length; i++) {
      expect(progress[i], greaterThanOrEqualTo(progress[i - 1]));
    }
    expect(progress.last, server.bytes.length);
  });

  test('a cancelled download keeps its part and resumes with a Range request', () async {
    final target = File('${temp.path}/barrel.glb');
    final cancel = DownloadCancel();
    await expectLater(
      Downloader(httpClient: realIoHttpClient).fetch(
        server.url,
        target,
        sha256: sha,
        size: server.bytes.length,
        cancel: cancel,
        onProgress: (r, _) {
          if (r >= 10000) cancel.cancel();
        },
      ),
      throwsA(isA<DownloadCancelled>()),
    );
    final part = File('${target.path}.part');
    final have = part.lengthSync();
    expect(have, inInclusiveRange(10000, server.bytes.length - 1));
    expect(target.existsSync(), isFalse);

    await Downloader(httpClient: realIoHttpClient).fetch(server.url, target, sha256: sha, size: server.bytes.length);
    expect(server.ranges.last, 'bytes=$have-');
    expect(await target.readAsBytes(), server.bytes);
    expect(part.existsSync(), isFalse);
  });

  test('a wrong SHA-256 fails naming both hashes and deletes the part', () async {
    final target = File('${temp.path}/barrel.glb');
    const wrong = '0000000000000000000000000000000000000000000000000000000000000000';
    await expectLater(
      Downloader(httpClient: realIoHttpClient).fetch(server.url, target, sha256: wrong, size: server.bytes.length),
      throwsA(isA<FormatException>().having((e) => e.message, 'message', allOf(contains(wrong), contains(sha)))),
    );
    expect(File('${target.path}.part').existsSync(), isFalse);
    expect(target.existsSync(), isFalse);
  });
}
