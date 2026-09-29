import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';

/// Cancels a running [Downloader.fetch]; the partial file stays for resuming.
class DownloadCancel {
  bool _cancelled = false;
  bool get cancelled => _cancelled;
  void cancel() => _cancelled = true;
}

class DownloadCancelled implements Exception {
  const DownloadCancelled();
  @override
  String toString() => 'Download cancelled';
}

/// Streams a URL into a file: `<target>.part` first, resumed with
/// an HTTP Range request when a part exists, then checked against the pinned
/// size and SHA-256 and renamed into place.
class Downloader {
  Downloader({HttpClient Function()? httpClient}) : _httpClient = httpClient ?? HttpClient.new;

  final HttpClient Function() _httpClient;

  /// Downloads [url] to [target]. [onProgress] gets (received, total).
  /// Throws [DownloadCancelled] after [cancel], or an [HttpException] /
  /// [FileSystemException]-style error naming what failed.
  Future<void> fetch(
    Uri url,
    File target, {
    required String sha256,
    int? size,
    void Function(int received, int total)? onProgress,
    DownloadCancel? cancel,
  }) async {
    await target.parent.create(recursive: true);
    final part = File('${target.path}.part');
    var have = await part.exists() ? await part.length() : 0;
    if (size != null && have > size) {
      await part.delete();
      have = 0;
    }
    final client = _httpClient();
    try {
      if (size == null || have < size) {
        final request = await client.getUrl(url);
        request.followRedirects = true;
        request.maxRedirects = 10;
        if (have > 0) request.headers.set(HttpHeaders.rangeHeader, 'bytes=$have-');
        final response = await request.close();
        if (response.statusCode == 200) {
          have = 0; // The server ignored the range: start over.
        } else if (response.statusCode == 206) {
          // Resuming.
        } else if (response.statusCode == 416 && size != null && have == size) {
          await response.drain<void>();
        } else {
          await response.drain<void>();
          throw HttpException('GET $url answered ${response.statusCode}', uri: url);
        }
        if (response.statusCode != 416) {
          final total = size ?? (response.contentLength < 0 ? 0 : have + response.contentLength);
          final sink = part.openWrite(mode: have == 0 ? FileMode.write : FileMode.append);
          var received = have;
          onProgress?.call(received, total);
          try {
            await for (final chunk in response) {
              if (cancel?.cancelled ?? false) throw const DownloadCancelled();
              sink.add(chunk);
              received += chunk.length;
              onProgress?.call(received, total);
            }
          } finally {
            await sink.flush();
            await sink.close();
          }
          if (cancel?.cancelled ?? false) throw const DownloadCancelled();
        }
      }
    } finally {
      client.close(force: true);
    }

    final length = await part.length();
    if (size != null && length != size) {
      await part.delete();
      throw FormatException('${target.path}: expected $size bytes, got $length');
    }
    final actual = (await sha256Of(part)).toLowerCase();
    if (actual != sha256.toLowerCase()) {
      await part.delete();
      throw FormatException('${target.path}: SHA-256 mismatch (expected $sha256, got $actual)');
    }
    if (await target.exists()) await target.delete();
    await part.rename(target.path);
  }

  /// The SHA-256 of [file], streamed.
  static Future<String> sha256Of(File file) async => (await sha256.bind(file.openRead()).first).toString();
}
