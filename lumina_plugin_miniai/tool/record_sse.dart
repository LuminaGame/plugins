// Records real `/v1/chat/completions` SSE streams from a running
// OpenAI-compatible server into test/fixtures/sse/ (the agent loop fixtures).
//
//   dart run tool/record_sse.dart http://127.0.0.1:8080/v1 <model>
//
// Pure dart:io: runs without Flutter.
import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> args) async {
  final baseUrl = args.isNotEmpty ? args[0] : 'http://127.0.0.1:8080/v1';
  final model = args.length > 1 ? args[1] : 'MiniCPM5-2B-Q4_K_M';
  final out = Directory('test/fixtures/sse')..createSync(recursive: true);

  const countActors = {
    'type': 'function',
    'function': {
      'name': 'probe.count',
      'description': 'Counts the actors in the open level.',
      'parameters': {'type': 'object', 'properties': <String, Object?>{}, 'additionalProperties': false},
    },
  };
  const spawn = {
    'type': 'function',
    'function': {
      'name': 'spawn_actor_from_asset',
      'description': 'Places a mesh asset in the open level as a new actor.',
      'parameters': {
        'type': 'object',
        'properties': {
          'asset': {'type': 'string', 'description': 'The asset path, e.g. "contents/meshes/barrel.lmas"'},
          'location': {
            'type': 'array',
            'description': '[x, y, z] in centimetres, Z up',
            'items': {'type': 'number'},
          },
        },
        'required': ['asset'],
        'additionalProperties': false,
      },
    },
  };

  final cases = <String, Map<String, Object?>>{
    'text': {
      'messages': [
        {'role': 'user', 'content': 'What is 2+2? Answer with the number only.'},
      ],
    },
    'tool_call': {
      'messages': [
        {'role': 'system', 'content': 'You are MiniAI inside the Lumina game editor. Use the tools to answer.'},
        {'role': 'user', 'content': 'How many actors are in the level? Use the tool.'},
      ],
      'tools': [countActors],
    },
    'tool_result_answer': {
      'messages': [
        {'role': 'system', 'content': 'You are MiniAI inside the Lumina game editor. Use the tools to answer.'},
        {'role': 'user', 'content': 'How many actors are in the level? Use the tool.'},
        {
          'role': 'assistant',
          'content': '',
          'tool_calls': [
            {
              'id': 'call_1',
              'type': 'function',
              'function': {'name': 'probe.count', 'arguments': '{}'},
            },
          ],
        },
        {'role': 'tool', 'tool_call_id': 'call_1', 'name': 'probe.count', 'content': '{"count": 5}'},
      ],
      'tools': [countActors],
    },
    'two_tool_calls': {
      'messages': [
        {'role': 'system', 'content': 'You are MiniAI inside the Lumina game editor. Use the tools. Make every call the request needs in one response.'},
        {
          'role': 'user',
          'content': 'Place the asset contents/meshes/fuel_barrel_red.lmas twice: once at [0, 0, 0] and once at [300, 0, 0].',
        },
      ],
      'tools': [spawn],
    },
  };

  final client = HttpClient();
  for (final entry in cases.entries) {
    final body = {'model': model, 'stream': true, 'stream_options': {'include_usage': true}, 'temperature': 0, ...entry.value};
    final request = await client.postUrl(Uri.parse('$baseUrl/chat/completions'));
    request.headers.contentType = ContentType.json;
    request.write(jsonEncode(body));
    final response = await request.close();
    final bytes = await response.fold<List<int>>([], (a, b) => a..addAll(b));
    File('${out.path}/${entry.key}.txt').writeAsBytesSync(bytes);
    File('${out.path}/${entry.key}.request.json').writeAsStringSync(const JsonEncoder.withIndent('  ').convert(body));
    stdout.writeln('${entry.key}: HTTP ${response.statusCode}, ${bytes.length} bytes');
  }
  client.close();
}
