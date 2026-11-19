/// Plain data types. Everything is JSON-serialisable so storage stays trivial.
library;

import 'dart:math';

final _rand = Random();
String newId() =>
    DateTime.now().microsecondsSinceEpoch.toRadixString(36) +
    _rand.nextInt(1 << 20).toRadixString(36);

enum Protocol { openai, anthropic }

/// One configured AI vendor (OpenAI-compatible or Anthropic).
class Provider {
  Provider({
    required this.id,
    required this.name,
    required this.protocol,
    required this.baseUrl,
    this.apiKey = '',
    List<String>? models,
  }) : models = models ?? [];

  final String id;
  String name;
  Protocol protocol;
  String baseUrl;
  String apiKey;
  List<String> models;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'protocol': protocol.name,
        'baseUrl': baseUrl,
        'apiKey': apiKey,
        'models': models,
      };

  factory Provider.fromJson(Map<String, dynamic> j) => Provider(
        id: j['id'],
        name: j['name'],
        protocol: Protocol.values.byName(j['protocol'] ?? 'openai'),
        baseUrl: j['baseUrl'],
        apiKey: j['apiKey'] ?? '',
        models: List<String>.from(j['models'] ?? const []),
      );
}

class Settings {
  List<Provider> providers = [];
  String? providerId;
  String? model;
  bool memory = true;
  bool agent = true;
  String instructions = '';

  Provider? get provider =>
      providers.where((p) => p.id == providerId).firstOrNull;

  Map<String, dynamic> toJson() => {
        'providers': providers.map((p) => p.toJson()).toList(),
        'providerId': providerId,
        'model': model,
        'memory': memory,
        'agent': agent,
        'instructions': instructions,
      };

  static Settings fromJson(Map<String, dynamic> j) => Settings()
    ..providers = [
      for (final p in (j['providers'] as List? ?? const []))
        Provider.fromJson(Map<String, dynamic>.from(p))
    ]
    ..providerId = j['providerId']
    ..model = j['model']
    ..memory = j['memory'] ?? true
    ..agent = j['agent'] ?? true
    ..instructions = j['instructions'] ?? '';
}

class ToolCall {
  ToolCall({required this.id, required this.name, this.args = '', this.result});
  final String id;
  String name;
  String args;
  String? result;

  Map<String, dynamic> toJson() =>
      {'id': id, 'name': name, 'args': args, 'result': result};
  factory ToolCall.fromJson(Map<String, dynamic> j) => ToolCall(
      id: j['id'], name: j['name'], args: j['args'] ?? '', result: j['result']);
}

enum Role { user, assistant }

class Attachment {
  Attachment({required this.name, required this.mimeType, required this.data});
  final String name;
  final String mimeType;
  final String data;

  bool get isImage => mimeType.startsWith('image/');

  Map<String, dynamic> toJson() => {
        'name': name,
        'mimeType': mimeType,
        'data': data,
      };

  factory Attachment.fromJson(Map<String, dynamic> j) => Attachment(
        name: j['name'] ?? '',
        mimeType: j['mimeType'] ?? 'text/plain',
        data: j['data'] ?? '',
      );
}

/// A single bubble. An assistant turn that used tools is stored as several
/// assistant messages: each one carries the calls it made and their results.
class Message {
  Message(this.role, [this.content = '']);
  final Role role;
  String content;
  String reasoning = '';
  List<ToolCall> calls = [];
  List<Attachment> attachments = [];
  bool error = false;
  int inputTokens = 0;
  int outputTokens = 0;

  Map<String, dynamic> toJson() => {
        'role': role.name,
        'content': content,
        if (reasoning.isNotEmpty) 'reasoning': reasoning,
        if (calls.isNotEmpty) 'calls': calls.map((c) => c.toJson()).toList(),
        if (attachments.isNotEmpty) 'attachments': attachments.map((a) => a.toJson()).toList(),
        if (error) 'error': true,
        if (inputTokens > 0) 'inputTokens': inputTokens,
        if (outputTokens > 0) 'outputTokens': outputTokens,
      };

  factory Message.fromJson(Map<String, dynamic> j) =>
      Message(Role.values.byName(j['role']), j['content'] ?? '')
        ..reasoning = j['reasoning'] ?? ''
        ..calls = [
          for (final c in (j['calls'] as List? ?? const []))
            ToolCall.fromJson(Map<String, dynamic>.from(c))
        ]
        ..attachments = [
          for (final a in (j['attachments'] as List? ?? const []))
            Attachment.fromJson(Map<String, dynamic>.from(a))
        ]
        ..error = j['error'] ?? false
        ..inputTokens = j['inputTokens'] ?? 0
        ..outputTokens = j['outputTokens'] ?? 0;
}

class Conversation {
  Conversation({String? id, this.title = '', DateTime? updated, this.archived = false})
      : id = id ?? newId(),
        updated = updated ?? DateTime.now();
  final String id;
  String title;
  DateTime updated;
  bool archived;
  List<Message> messages = [];

  int get totalInputTokens => messages.fold(0, (s, m) => s + m.inputTokens);
  int get totalOutputTokens => messages.fold(0, (s, m) => s + m.outputTokens);
  int get totalTokens => totalInputTokens + totalOutputTokens;

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'updated': updated.millisecondsSinceEpoch,
        if (archived) 'archived': true,
        'messages': messages.map((m) => m.toJson()).toList(),
      };

  factory Conversation.fromJson(Map<String, dynamic> j) => Conversation(
        id: j['id'],
        title: j['title'] ?? '',
        updated: DateTime.fromMillisecondsSinceEpoch(j['updated'] ?? 0),
        archived: j['archived'] ?? false,
      )..messages = [
          for (final m in (j['messages'] as List? ?? const []))
            Message.fromJson(Map<String, dynamic>.from(m))
        ];
}

/// A long-term fact about the user, shared across all conversations.
class Memory {
  Memory(this.text, {String? id, DateTime? created})
      : id = id ?? newId(),
        created = created ?? DateTime.now();
  final String id;
  String text;
  final DateTime created;

  Map<String, dynamic> toJson() =>
      {'id': id, 'text': text, 'created': created.millisecondsSinceEpoch};
  factory Memory.fromJson(Map<String, dynamic> j) => Memory(j['text'],
      id: j['id'],
      created: DateTime.fromMillisecondsSinceEpoch(j['created'] ?? 0));
}
