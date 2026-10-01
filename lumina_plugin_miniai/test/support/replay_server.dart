import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

/// A real local HTTP server that answers `POST /v1/chat/completions` with
/// recorded real SSE streams (test/fixtures/sse/*.txt), one per request in
/// [queue] order, and `GET /v1/models` with [models]. Requests are kept.
class ReplayServer {
  ReplayServer._(this._server);

  final HttpServer _server;
  final List<String> queue = [];
  final List<Map<String, Object?>> requests = [];
  List<String> models = const ['MiniCPM5-2B-Q4_K_M'];

  /// Status code and body for the next request instead of a fixture.
  (int, String)? nextError;

  /// Sends the fixture this slowly (bytes per write, pause), to test cancel.
  Duration? chunkDelay;

  String get baseUrl => 'http://127.0.0.1:${_server.port}/v1';

  static String fixture(String name) => File('test/fixtures/sse/$name.txt').readAsStringSync();

  static Future<ReplayServer> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final replay = ReplayServer._(server);
    server.listen(replay._handle);
    return replay;
  }

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    if (request.method == 'GET' && request.uri.path.endsWith('/models')) {
      response.headers.contentType = ContentType.json;
      response.write(jsonEncode({
        'object': 'list',
        'data': [for (final m in models) {'id': m, 'object': 'model'}],
      }));
      await response.close();
      return;
    }
    if (request.method == 'GET') {
      // Not a server-type probe target: like an OpenAI-compatible server
      // without llama.cpp's / Ollama's / vLLM's extra endpoints.
      response.statusCode = HttpStatus.notFound;
      await response.close();
      return;
    }
    final body = await utf8.decoder.bind(request).join();
    requests.add(jsonDecode(body) as Map<String, Object?>);
    final error = nextError;
    if (error != null) {
      nextError = null;
      response.statusCode = error.$1;
      response.headers.contentType = ContentType.json;
      response.write(error.$2);
      await response.close();
      return;
    }
    final name = queue.isEmpty ? 'text' : queue.removeAt(0);
    response.headers.contentType = ContentType('text', 'event-stream');
    // A queued `data: …` string is a stream body itself (a documented shape
    // no recorded server produced).
    final bytes = utf8.encode(name.startsWith('data:') ? name : fixture(name));
    final delay = chunkDelay;
    if (delay == null) {
      response.add(bytes);
    } else {
      response.bufferOutput = false;
      for (var i = 0; i < bytes.length; i += 200) {
        try {
          response.add(bytes.sublist(i, i + 200 > bytes.length ? bytes.length : i + 200));
          await response.flush();
        } catch (_) {
          return;
        }
        await Future<void>.delayed(delay);
      }
    }
    try {
      await response.close();
    } catch (_) {}
  }

  Future<void> close() => _server.close(force: true);
}

class _RealHttpOverrides extends HttpOverrides {}

/// A dart:io HTTP client that really connects (the Flutter test binding
/// answers every request of the default one with 400).
http.Client realHttpClient() => IOClient(HttpOverrides.runWithHttpOverrides(HttpClient.new, _RealHttpOverrides()));

/// The dart:io [HttpClient] behind [realHttpClient] (the downloader and the
/// local model manager use dart:io directly).
HttpClient realIoHttpClient() => HttpOverrides.runWithHttpOverrides(HttpClient.new, _RealHttpOverrides());
