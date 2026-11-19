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
      if (store.settings.webSearch)
        Tool(
          ToolSpec(
            'web_search',
            'Search the web for up-to-date information. Returns titles, URLs and '
                'snippets; call read_url on a result to read the full page.',
            _schema({'query': 'Search keywords'}),
          ),
          (a) async => webSearch('${a['query'] ?? ''}'),
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

/// DuckDuckGo's HTML endpoint: no API key needed. Blocked by CORS on web.
Future<String> webSearch(String query) async {
  query = query.trim();
  if (query.isEmpty) return 'Empty query.';
  final uri = Uri.https('html.duckduckgo.com', '/html/', {'q': query});
  final res = await http.get(uri, headers: {
    'user-agent': 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 '
        '(KHTML, like Gecko) Chrome/120.0 Safari/537.36',
  }).timeout(const Duration(seconds: 20));
  if (res.statusCode >= 400) return 'HTTP ${res.statusCode}';
  final html = utf8.decode(res.bodyBytes, allowMalformed: true);
  String clean(String s) => s
      .replaceAll(RegExp(r'<[^>]+>'), '')
      .replaceAll('&amp;', '&')
      .replaceAll('&quot;', '"')
      .replaceAll('&#x27;', "'")
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  final links = RegExp(r'<a[^>]*class="result__a"[^>]*href="([^"]+)"[^>]*>([\s\S]*?)</a>').allMatches(html).toList();
  final snippets = RegExp(r'class="result__snippet"[^>]*>([\s\S]*?)</a>').allMatches(html).toList();
  final out = <String>[];
  for (var i = 0; i < links.length && out.length < 8; i++) {
    var href = links[i].group(1)!.replaceAll('&amp;', '&');
    if (href.startsWith('//')) href = 'https:$href';
    final target = Uri.tryParse(href)?.queryParameters['uddg'];
    final url = target ?? href;
    if (url.contains('duckduckgo.com/y.js')) continue; // ads
    final snippet = i < snippets.length ? clean(snippets[i].group(1)!) : '';
    out.add('${out.length + 1}. ${clean(links[i].group(2)!)}\n   $url\n   $snippet');
  }
  return out.isEmpty ? 'No results.' : out.join('\n');
}
