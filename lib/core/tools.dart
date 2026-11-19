import 'dart:convert';

import 'package:http/http.dart' as http;

import 'llm.dart';
import 'store.dart';

/// An agent capability: what the model sees ([spec]) and what runs ([run]).
/// To add a tool, add one entry to [buildTools].
class Tool {
  const Tool(this.spec, this.run, {this.needsMemory = false});
  final ToolSpec spec;
  final Future<String> Function(Map<String, dynamic> args) run;
  final bool needsMemory;
}

Map<String, dynamic> _schema(Map<String, String> props) => {
      'type': 'object',
      'properties': {
        for (final e in props.entries) e.key: {'type': 'string', 'description': e.value}
      },
      'required': props.keys.toList(),
    };

List<Tool> buildTools(AppStore store) => [
      Tool(
        const ToolSpec(
          'remember',
          'Save a durable fact about the user (preferences, background, goals, '
              'or anything they ask you to remember) to long-term memory shared '
              'across all chats. Write it as a short standalone sentence.',
          {
            'type': 'object',
            'properties': {
              'fact': {'type': 'string', 'description': 'The fact to remember'}
            },
            'required': ['fact'],
          },
        ),
        (a) async {
          final m = store.addMemory('${a['fact'] ?? ''}');
          return m == null ? 'Nothing saved.' : 'Saved as ${m.id}.';
        },
        needsMemory: true,
      ),
      Tool(
        ToolSpec(
          'forget',
          'Delete a memory by its id when it is wrong, outdated, or the user asks to forget it.',
          _schema({'id': 'Memory id'}),
        ),
        (a) async => store.removeMemory('${a['id']}') ? 'Deleted.' : 'No such memory.',
        needsMemory: true,
      ),
      Tool(
        ToolSpec(
          'search_chats',
          'Full-text search over the user\'s previous conversations. Use when they '
              'refer to something discussed before.',
          _schema({'query': 'Keywords'}),
        ),
        (a) async => store.searchHistory('${a['query'] ?? ''}'),
        needsMemory: true,
      ),
      Tool(
        ToolSpec(
          'read_url',
          'Fetch a web page and return its readable text.',
          _schema({'url': 'Absolute http(s) URL'}),
        ),
        (a) async => readUrl('${a['url']}'),
      ),
    ];

Future<String> readUrl(String url) async {
  final uri = Uri.tryParse(url);
  if (uri == null || !uri.hasScheme) return 'Invalid URL.';
  final res = await http.get(uri).timeout(const Duration(seconds: 20));
  if (res.statusCode >= 400) return 'HTTP ${res.statusCode}';
  var text = utf8.decode(res.bodyBytes, allowMalformed: true);
  if ((res.headers['content-type'] ?? '').contains('html')) {
    text = text
        .replaceAll(RegExp(r'<(script|style|noscript|svg)[\s\S]*?</\1>', caseSensitive: false), ' ')
        .replaceAll(RegExp(r'<[^>]+>'), ' ')
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }
  return text.length > 8000 ? '${text.substring(0, 8000)}…' : text;
}
