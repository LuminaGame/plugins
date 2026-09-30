// A subprocess that replays a recorded Claude Code session
// (test/fixtures/claude_code/*.jsonl, from tool/record_claude_code.dart):
//
//   dart claude_code_replay.dart <fixture> <log> [the claude arguments…]
//
// `out` records are written to stdout as the CLI wrote them; at each `in`
// record it waits for the next line on stdin; at a `permission` record it
// writes `{"type": "__replay_permission", "request": …}` and waits for the
// answer line (the CLI would call the permission MCP tool there). Its
// arguments and every line it reads go to <log>, one JSON object per line.
// A `{"exit": n}` record exits with n once stdin closes (`"now": true`: at
// once, a CLI that dies mid-turn). A control response answers the request
// id of the control request it last read, as the CLI does.
//
// Pure dart:io.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> args) async {
  final fixture = File(args[0]);
  final log = File(args[1]).openWrite(mode: FileMode.append);
  log.writeln(jsonEncode({'args': args.sublist(2)}));
  await log.flush();
  final input = StreamIterator(stdin.transform(utf8.decoder).transform(const LineSplitter()));

  Future<String?> next() async {
    while (await input.moveNext()) {
      final line = input.current;
      if (line.trim().isEmpty) continue;
      log.writeln(jsonEncode({'stdin': line}));
      await log.flush();
      return line;
    }
    return null;
  }

  var code = 0;
  String? lastRequest;
  for (final raw in fixture.readAsLinesSync()) {
    if (raw.trim().isEmpty) continue;
    final record = Map<String, Object?>.from(jsonDecode(raw) as Map);
    if (record.containsKey('out')) {
      final out = Map<String, Object?>.from(record['out'] as Map);
      if (out['type'] == 'control_response' && lastRequest != null) {
        out['response'] = {...Map<String, Object?>.from(out['response'] as Map), 'request_id': lastRequest};
      }
      stdout.writeln(jsonEncode(out));
      await stdout.flush();
    } else if (record.containsKey('in')) {
      final line = await next();
      if (line == null) {
        await log.close();
        exit(0);
      }
      final message = jsonDecode(line);
      if (message is Map && message['type'] == 'control_request') lastRequest = '${message['request_id']}';
    } else if (record.containsKey('permission')) {
      stdout.writeln(jsonEncode({'type': '__replay_permission', 'request': record['permission']}));
      await stdout.flush();
      if (await next() == null) {
        await log.close();
        exit(0);
      }
    } else if (record.containsKey('exit')) {
      code = record['exit'] as int;
      if (record['now'] == true) {
        await log.close();
        exit(code);
      }
    }
  }
  // Like the CLI: wait for the input to close, then exit.
  while (await next() != null) {}
  await log.close();
  exit(code);
}
