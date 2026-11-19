import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'models.dart';

/// A function the model may call. [parameters] is a JSON schema object.
class ToolSpec {
  const ToolSpec(this.name, this.description, this.parameters);
  final String name;
  final String description;
  final Map<String, dynamic> parameters;
}

/// The state of one streamed model reply. The same instance is re-emitted on
/// every chunk, so listeners can simply read it.
class LlmTurn {
  String _raw = '';
  String _reasoning = '';
  final calls = <ToolCall>[];
  int inputTokens = 0;
  int outputTokens = 0;

  /// Visible answer, with any inline `<think>` block split out.
  String get text {
    final (_, t) = _split();
    return t;
  }

  String get reasoning {
    final (r, _) = _split();
    return [_reasoning, r].where((s) => s.isNotEmpty).join('\n');
  }

  (String, String) _split() {
    final s = _raw.trimLeft();
    if (!s.startsWith('<think>')) return ('', _raw);
    final end = s.indexOf('</think>');
    if (end < 0) return (s.substring(7).trim(), '');
    return (s.substring(7, end).trim(), s.substring(end + 8).trimLeft());
  }
}

class LlmException implements Exception {
  LlmException(this.message, {this.status});
  final String message;
  final int? status;
  @override
  String toString() => status == null ? message : '[$status] $message';
}

/// Talks to OpenAI-compatible and Anthropic endpoints with streaming,
/// tool calling and cancellation. Works on web (fetch), Android and macOS.
class Llm {
  Llm([http.Client? client]) : _client = client ?? http.Client();
  final http.Client _client;

  Stream<LlmTurn> chat({
    required Provider provider,
    required String model,
    required String system,
    required List<Message> history,
    List<ToolSpec> tools = const [],
    Future<void>? abort,
  }) async* {
    final anthropic = provider.protocol == Protocol.anthropic;
    final base = _trim(provider.baseUrl);
    final uri = Uri.parse(anthropic ? '$base/messages' : '$base/chat/completions');
    final body = anthropic
        ? {
            'model': model,
            'max_tokens': 8192,
            'stream': true,
            if (system.isNotEmpty) 'system': system,
            'messages': _anthropicMessages(history),
            if (tools.isNotEmpty)
              'tools': [
                for (final t in tools)
                  {'name': t.name, 'description': t.description, 'input_schema': t.parameters}
              ],
          }
        : {
            'model': model,
            'stream': true,
            'stream_options': {'include_usage': true},
            'messages': _openaiMessages(system, history),
            if (tools.isNotEmpty)
              'tools': [
                for (final t in tools)
                  {
                    'type': 'function',
                    'function': {
                      'name': t.name,
                      'description': t.description,
                      'parameters': t.parameters,
                    }
                  }
              ],
          };

    final req = http.AbortableRequest('POST', uri, abortTrigger: abort)
      ..headers.addAll(_headers(provider))
      ..headers['content-type'] = 'application/json'
      ..body = jsonEncode(body);

    final turn = LlmTurn();
    try {
      final res = await _client.send(req);
      if (res.statusCode >= 400) {
        throw LlmException(_errorText(await res.stream.bytesToString()),
            status: res.statusCode);
      }
      // Some gateways ignore `stream` and answer with a single JSON body.
      if ((res.headers['content-type'] ?? '').contains('application/json')) {
        final j = jsonDecode(await res.stream.bytesToString());
        anthropic ? _anthropicFull(j, turn) : _openaiFull(j, turn);
        yield turn;
        return;
      }
      final builders = <int, ToolCall>{};
      final lines = res.stream.transform(utf8.decoder).transform(const LineSplitter());
      await for (final line in lines) {
        if (!line.startsWith('data:')) continue;
        final data = line.substring(5).trim();
        if (data.isEmpty) continue;
        if (data == '[DONE]') break;
        final Map<String, dynamic> j = jsonDecode(data);
        if (j['error'] != null) throw LlmException(_errorText(data));
        anthropic ? _anthropicChunk(j, turn, builders) : _openaiChunk(j, turn, builders);
        yield turn;
        if (j['type'] == 'message_stop') break;
      }
      turn.calls.addAll(builders.values.where((c) => c.name.isNotEmpty));
      yield turn;
    } on http.RequestAbortedException {
      turn.calls.clear();
      yield turn;
    }
  }

  Future<List<String>> listModels(Provider p) async {
    final res = await _client.get(Uri.parse('${_trim(p.baseUrl)}/models'),
        headers: _headers(p));
    if (res.statusCode >= 400) {
      throw LlmException(_errorText(utf8.decode(res.bodyBytes)), status: res.statusCode);
    }
    final j = jsonDecode(utf8.decode(res.bodyBytes));
    final ids = [for (final m in (j['data'] as List? ?? const [])) m['id'] as String];
    return ids..sort();
  }

  // ---------------------------------------------------------------- helpers

  static String _trim(String url) => url.trim().replaceAll(RegExp(r'/+$'), '');

  static Map<String, String> _headers(Provider p) =>
      p.protocol == Protocol.anthropic
          ? {
              'x-api-key': p.apiKey,
              'anthropic-version': '2023-06-01',
              'anthropic-dangerous-direct-browser-access': 'true',
            }
          : {if (p.apiKey.isNotEmpty) 'authorization': 'Bearer ${p.apiKey}'};

  static String _errorText(String body) {
    try {
      final j = jsonDecode(body);
      final e = j['error'] ?? j;
      if (e is String) return e;
      return (e['message'] ?? e['msg'] ?? body).toString();
    } catch (_) {
      return body.length > 300 ? '${body.substring(0, 300)}…' : body;
    }
  }

  static List<Map<String, dynamic>> _openaiMessages(String system, List<Message> history) {
    final out = <Map<String, dynamic>>[
      if (system.isNotEmpty) {'role': 'system', 'content': system},
    ];
    for (final m in history) {
      if (m.error) continue;
      if (m.role == Role.user) {
        if (m.attachments.isEmpty) {
          out.add({'role': 'user', 'content': m.content});
        } else {
          out.add({
            'role': 'user',
            'content': [
              for (final a in m.attachments)
                if (a.isImage)
                  {
                    'type': 'image_url',
                    'image_url': {'url': 'data:${a.mimeType};base64,${a.data}'},
                  }
                else
                  {'type': 'text', 'text': '[附件: ${a.name}]\n${a.data}'},
              if (m.content.isNotEmpty) {'type': 'text', 'text': m.content},
            ],
          });
        }
      } else if (m.calls.isEmpty) {
        if (m.content.isNotEmpty) out.add({'role': 'assistant', 'content': m.content});
      } else {
        out.add({
          'role': 'assistant',
          'content': m.content,
          'tool_calls': [
            for (final c in m.calls)
              {
                'id': c.id,
                'type': 'function',
                'function': {'name': c.name, 'arguments': c.args.isEmpty ? '{}' : c.args},
              }
          ],
        });
        for (final c in m.calls) {
          out.add({'role': 'tool', 'tool_call_id': c.id, 'content': c.result ?? ''});
        }
      }
    }
    return out;
  }

  static List<Map<String, dynamic>> _anthropicMessages(List<Message> history) {
    final out = <Map<String, dynamic>>[];
    void add(String role, Map<String, dynamic> block) {
      if (out.isNotEmpty && out.last['role'] == role) {
        (out.last['content'] as List).add(block);
      } else {
        out.add({'role': role, 'content': [block]});
      }
    }

    for (final m in history) {
      if (m.error) continue;
      if (m.role == Role.user) {
        for (final a in m.attachments) {
          if (a.isImage) {
            add('user', {
              'type': 'image',
              'source': {'type': 'base64', 'media_type': a.mimeType, 'data': a.data},
            });
          } else {
            add('user', {'type': 'text', 'text': '[附件: ${a.name}]\n${a.data}'});
          }
        }
        if (m.content.isNotEmpty) add('user', {'type': 'text', 'text': m.content});
        continue;
      }
      if (m.content.isNotEmpty) add('assistant', {'type': 'text', 'text': m.content});
      for (final c in m.calls) {
        add('assistant', {'type': 'tool_use', 'id': c.id, 'name': c.name, 'input': _json(c.args)});
      }
      for (final c in m.calls) {
        add('user', {'type': 'tool_result', 'tool_use_id': c.id, 'content': c.result ?? ''});
      }
    }
    return out;
  }

  static Map<String, dynamic> _json(String s) {
    try {
      final v = jsonDecode(s.isEmpty ? '{}' : s);
      return v is Map<String, dynamic> ? v : {};
    } catch (_) {
      return {};
    }
  }

  static void _openaiChunk(Map<String, dynamic> j, LlmTurn t, Map<int, ToolCall> b) {
    final u = j['usage'];
    if (u is Map) {
      if (u['prompt_tokens'] is int) t.inputTokens = u['prompt_tokens'];
      if (u['completion_tokens'] is int) t.outputTokens = u['completion_tokens'];
    }
    final choices = j['choices'] as List?;
    if (choices == null || choices.isEmpty) return;
    final delta = (choices[0]['delta'] ?? const {}) as Map;
    if (delta['content'] is String) t._raw += delta['content'];
    final r = delta['reasoning_content'] ?? delta['reasoning'];
    if (r is String) t._reasoning += r;
    final tcs = delta['tool_calls'] as List? ?? const [];
    for (var i = 0; i < tcs.length; i++) {
      final tc = tcs[i] as Map;
      final idx = (tc['index'] as int?) ?? b.length + i;
      final call = b.putIfAbsent(idx, () => ToolCall(id: tc['id'] ?? newId(), name: ''));
      final fn = (tc['function'] ?? const {}) as Map;
      if ((fn['name'] ?? '').toString().isNotEmpty) call.name = fn['name'];
      if (fn['arguments'] is String) call.args += fn['arguments'];
      if (fn['arguments'] is Map) call.args = jsonEncode(fn['arguments']);
    }
  }

  static void _openaiFull(Map<String, dynamic> j, LlmTurn t) {
    final u = j['usage'];
    if (u is Map) {
      if (u['prompt_tokens'] is int) t.inputTokens = u['prompt_tokens'];
      if (u['completion_tokens'] is int) t.outputTokens = u['completion_tokens'];
    }
    final msg = (j['choices'] as List).first['message'] as Map;
    t._raw = msg['content'] ?? '';
    t._reasoning = msg['reasoning_content'] ?? '';
    for (final tc in (msg['tool_calls'] as List? ?? const [])) {
      t.calls.add(ToolCall(
          id: tc['id'] ?? newId(),
          name: tc['function']['name'],
          args: tc['function']['arguments'] ?? '{}'));
    }
  }

  static void _anthropicChunk(Map<String, dynamic> j, LlmTurn t, Map<int, ToolCall> b) {
    switch (j['type']) {
      case 'message_start':
        final u = (j['message'] as Map?)?['usage'];
        if (u is Map && u['input_tokens'] is int) t.inputTokens = u['input_tokens'];
      case 'message_delta':
        final u = j['usage'];
        if (u is Map && u['output_tokens'] is int) t.outputTokens = u['output_tokens'];
      case 'content_block_start':
        final cb = j['content_block'] as Map;
        if (cb['type'] == 'tool_use') {
          b[j['index']] = ToolCall(id: cb['id'], name: cb['name']);
        }
      case 'content_block_delta':
        final d = j['delta'] as Map;
        switch (d['type']) {
          case 'text_delta':
            t._raw += d['text'];
          case 'thinking_delta':
            t._reasoning += d['thinking'];
          case 'input_json_delta':
            b[j['index']]?.args += d['partial_json'];
        }
    }
  }

  static void _anthropicFull(Map<String, dynamic> j, LlmTurn t) {
    final u = j['usage'];
    if (u is Map) {
      if (u['input_tokens'] is int) t.inputTokens = u['input_tokens'];
      if (u['output_tokens'] is int) t.outputTokens = u['output_tokens'];
    }
    for (final c in (j['content'] as List? ?? const [])) {
      if (c['type'] == 'text') t._raw += c['text'];
      if (c['type'] == 'tool_use') {
        t.calls.add(ToolCall(id: c['id'], name: c['name'], args: jsonEncode(c['input'])));
      }
    }
  }
}
