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

/// A reusable system prompt ("role"), e.g. translator or code reviewer.
class PromptPreset {
  PromptPreset({String? id, required this.name, required this.content}) : id = id ?? newId();
  final String id;
  String name;
  String content;

  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'content': content};
  factory PromptPreset.fromJson(Map<String, dynamic> j) =>
      PromptPreset(id: j['id'], name: j['name'] ?? '', content: j['content'] ?? '');

  static List<PromptPreset> defaults() => [
        PromptPreset(
          name: '翻译',
          content: '你是专业译者。用户发来中文就译成地道的英文，发来其他语言就译成流畅的中文。'
              '只输出译文，保留原有格式，不做解释。',
        ),
        PromptPreset(
          name: '代码审查',
          content: '你是资深工程师。审查用户给出的代码：先指出会导致错误的问题，再给出可读性和性能改进建议，'
              '每条都说明原因并给出修改后的代码片段。',
        ),
        PromptPreset(
          name: '润色',
          content: '你是文字编辑。在不改变原意的前提下润色用户给出的文字，使其通顺、准确、简洁。'
              '先给出润色后的全文，再简要列出主要改动。',
        ),
      ];
}

/// Theme seed colours offered in settings. `null` keeps the default purple.
const themeSeeds = <int>[0xFF6750A4, 0xFFE91E63, 0xFF1E88E5, 0xFF2E7D32, 0xFFEF6C00, 0xFF00897B];

class Settings {
  List<Provider> providers = [];
  String? providerId;
  String? model;
  bool memory = true;
  bool agent = true;
  bool webSearch = true;
  String instructions = '';
  List<PromptPreset> prompts = PromptPreset.defaults();

  /// 'system' | 'light' | 'dark'
  String themeMode = 'system';
  int seedColor = themeSeeds.first;
  double textScale = 1.0;

  Provider? get provider =>
      providers.where((p) => p.id == providerId).firstOrNull;

  Map<String, dynamic> toJson() => {
        'providers': providers.map((p) => p.toJson()).toList(),
        'providerId': providerId,
        'model': model,
        'memory': memory,
        'agent': agent,
        'instructions': instructions,
        'webSearch': webSearch,
        'prompts': prompts.map((p) => p.toJson()).toList(),
        'themeMode': themeMode,
        'seedColor': seedColor,
        'textScale': textScale,
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
    ..instructions = j['instructions'] ?? ''
    ..webSearch = j['webSearch'] ?? true
    ..prompts = j['prompts'] is List
        ? [
            for (final p in j['prompts'] as List)
              PromptPreset.fromJson(Map<String, dynamic>.from(p as Map))
          ]
        : PromptPreset.defaults()
    ..themeMode = j['themeMode'] ?? 'system'
    ..seedColor = j['seedColor'] ?? themeSeeds.first
    ..textScale = (j['textScale'] as num?)?.toDouble() ?? 1.0;
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
  Message(this.role, [this.content = '']) : time = DateTime.now();
  final Role role;
  String content;
  String reasoning = '';

  /// Anthropic extended-thinking signature; must be sent back with tool turns.
  String signature = '';

  /// When the message was created; null for messages saved by older versions.
  DateTime? time;
  List<ToolCall> calls = [];
  List<Attachment> attachments = [];

  /// Text the user selected from earlier messages and quoted in this turn.
  String quote = '';
  bool error = false;
  int inputTokens = 0;
  int outputTokens = 0;

  /// What the model sees for a user turn: the quote (as a Markdown
  /// blockquote) followed by the user's own text.
  String get promptText {
    if (quote.isEmpty) return content;
    final q = quote.trim().split('\n').map((l) => '> $l').join('\n');
    return content.isEmpty ? q : '$q\n\n$content';
  }

  Map<String, dynamic> toJson() => {
        'role': role.name,
        'content': content,
        if (reasoning.isNotEmpty) 'reasoning': reasoning,
        if (signature.isNotEmpty) 'signature': signature,
        if (time != null) 'time': time!.millisecondsSinceEpoch,
        if (calls.isNotEmpty) 'calls': calls.map((c) => c.toJson()).toList(),
        if (attachments.isNotEmpty) 'attachments': attachments.map((a) => a.toJson()).toList(),
        if (quote.isNotEmpty) 'quote': quote,
        if (error) 'error': true,
        if (inputTokens > 0) 'inputTokens': inputTokens,
        if (outputTokens > 0) 'outputTokens': outputTokens,
      };

  factory Message.fromJson(Map<String, dynamic> j) =>
      Message(Role.values.byName(j['role']), j['content'] ?? '')
        ..reasoning = j['reasoning'] ?? ''
        ..signature = j['signature'] ?? ''
        ..time = j['time'] is int ? DateTime.fromMillisecondsSinceEpoch(j['time']) : null
        ..calls = [
          for (final c in (j['calls'] as List? ?? const []))
            ToolCall.fromJson(Map<String, dynamic>.from(c))
        ]
        ..attachments = [
          for (final a in (j['attachments'] as List? ?? const []))
            Attachment.fromJson(Map<String, dynamic>.from(a))
        ]
        ..quote = j['quote'] ?? ''
        ..error = j['error'] ?? false
        ..inputTokens = j['inputTokens'] ?? 0
        ..outputTokens = j['outputTokens'] ?? 0;
}

/// Per-conversation generation options. `null` fields mean "provider default".
class ChatParams {
  ChatParams({this.promptId, this.temperature, this.maxTokens, this.reasoning});

  /// Id of a [PromptPreset] used as this chat's role.
  String? promptId;
  double? temperature;
  int? maxTokens;

  /// Thinking effort: 'low' | 'medium' | 'high'.
  String? reasoning;

  ChatParams copy() => ChatParams.fromJson(toJson());

  Map<String, dynamic> toJson() => {
        if (promptId != null) 'promptId': promptId,
        if (temperature != null) 'temperature': temperature,
        if (maxTokens != null) 'maxTokens': maxTokens,
        if (reasoning != null) 'reasoning': reasoning,
      };

  factory ChatParams.fromJson(Map<String, dynamic> j) => ChatParams(
        promptId: j['promptId'],
        temperature: (j['temperature'] as num?)?.toDouble(),
        maxTokens: j['maxTokens'],
        reasoning: j['reasoning'],
      );
}

class Conversation {
  Conversation({
    String? id,
    this.title = '',
    DateTime? updated,
    this.archived = false,
    this.pinned = false,
    ChatParams? params,
  })  : id = id ?? newId(),
        updated = updated ?? DateTime.now(),
        params = params ?? ChatParams();
  final String id;
  String title;
  DateTime updated;
  bool archived;
  bool pinned;
  ChatParams params;

  /// Model chosen for this chat; falls back to the global default when unset
  /// or no longer available.
  String? providerId;
  String? model;
  List<Message> messages = [];

  int get totalInputTokens => messages.fold(0, (s, m) => s + m.inputTokens);
  int get totalOutputTokens => messages.fold(0, (s, m) => s + m.outputTokens);
  int get totalTokens => totalInputTokens + totalOutputTokens;

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'updated': updated.millisecondsSinceEpoch,
        if (archived) 'archived': true,
        if (pinned) 'pinned': true,
        if (providerId != null) 'providerId': providerId,
        if (model != null) 'model': model,
        'params': params.toJson(),
        'messages': messages.map((m) => m.toJson()).toList(),
      };

  factory Conversation.fromJson(Map<String, dynamic> j) => Conversation(
        id: j['id'],
        title: j['title'] ?? '',
        updated: DateTime.fromMillisecondsSinceEpoch(j['updated'] ?? 0),
        archived: j['archived'] ?? false,
        pinned: j['pinned'] ?? false,
        params: j['params'] is Map ? ChatParams.fromJson(Map<String, dynamic>.from(j['params'] as Map)) : null,
      )
        ..providerId = j['providerId']
        ..model = j['model']
        ..messages = [
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
