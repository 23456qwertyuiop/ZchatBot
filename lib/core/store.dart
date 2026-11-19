import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'llm.dart';
import 'models.dart';
import 'tools.dart';

/// The single source of truth. UI reads fields and calls methods; nothing else
/// mutates state. Persistence is plain JSON in SharedPreferences
/// (localStorage on web, NSUserDefaults on macOS, XML prefs on Android).
class AppStore extends ChangeNotifier {
  AppStore._(this._prefs, this.llm);

  static Future<AppStore> load({Llm? llm}) async {
    final prefs = await SharedPreferences.getInstance();
    final s = AppStore._(prefs, llm ?? Llm());
    final settings = prefs.getString('settings');
    if (settings != null) s.settings = Settings.fromJson(jsonDecode(settings));
    s.memories = [
      for (final m in jsonDecode(prefs.getString('memories') ?? '[]'))
        Memory.fromJson(Map<String, dynamic>.from(m))
    ];
    for (final id in prefs.getStringList('convs') ?? const <String>[]) {
      final raw = prefs.getString('conv_$id');
      if (raw != null) s.conversations.add(Conversation.fromJson(jsonDecode(raw)));
    }
    s.conversations.sort((a, b) => b.updated.compareTo(a.updated));
    return s;
  }

  final SharedPreferences _prefs;
  final Llm llm;

  Settings settings = Settings();
  List<Memory> memories = [];
  final List<Conversation> conversations = [];

  /// The open conversation; `null` is a fresh, unsaved chat.
  Conversation? current;

  /// The conversation currently receiving a reply, if any.
  Conversation? running;
  Completer<void>? _abort;

  static const maxSteps = 8;

  // ------------------------------------------------------------- navigation

  void open(Conversation? c) {
    current = c;
    notifyListeners();
  }

  void newChat() {
    pending = ChatParams();
    open(null);
  }

  /// Options for the next new chat (before it has a [Conversation]).
  ChatParams pending = ChatParams();

  /// Options of the open chat, or of the chat about to be created.
  ChatParams get params => current?.params ?? pending;

  /// Call after mutating [params].
  void saveParams() {
    final c = current;
    if (c != null) _save(c);
    notifyListeners();
  }

  PromptPreset? promptFor(ChatParams p) =>
      settings.prompts.where((x) => x.id == p.promptId).firstOrNull;

  void setPrompt(String? id) {
    params.promptId = id;
    saveParams();
  }

  /// Pinned chats first, then most recently updated.
  List<Conversation> filter(String query, {bool archived = false}) {
    final q = query.trim().toLowerCase();
    final base = conversations.where((c) => c.archived == archived).where((c) =>
        q.isEmpty ||
        c.title.toLowerCase().contains(q) ||
        c.messages.any((m) => m.content.toLowerCase().contains(q)));
    return [...base.where((c) => c.pinned), ...base.where((c) => !c.pinned)];
  }

  int get archivedCount => conversations.where((c) => c.archived).length;
  int get totalInputTokensAll => conversations.fold(0, (s, c) => s + c.totalInputTokens);
  int get totalOutputTokensAll => conversations.fold(0, (s, c) => s + c.totalOutputTokens);
  int get totalTokensAll => totalInputTokensAll + totalOutputTokensAll;

  // ------------------------------------------------------------------ chat

  /// The provider and model a chat uses: its own choice when still
  /// configured, otherwise the global default.
  (Provider, String)? modelFor(Conversation? c) {
    if (c != null && c.providerId != null) {
      final p = settings.providers.where((p) => p.id == c.providerId).firstOrNull;
      if (p != null && p.models.contains(c.model)) return (p, c.model!);
    }
    final p = settings.provider;
    final m = settings.model;
    if (p == null || m == null || m.isEmpty) return null;
    return (p, m);
  }

  String? get modelLabel => modelFor(current)?.$2;
  bool get ready => modelFor(current) != null;

  Future<void> send(String text, {List<Attachment> attachments = const [], String quote = ''}) async {
    text = text.trim();
    quote = quote.trim();
    if ((text.isEmpty && attachments.isEmpty && quote.isEmpty) || running != null || !ready) return;
    final provisional = text.isNotEmpty
        ? _shortTitle(text)
        : attachments.isNotEmpty
            ? _shortTitle(attachments.first.name)
            : _shortTitle(quote);
    final c = current ?? Conversation(title: provisional, params: pending);
    if (current == null) {
      final m = modelFor(null)!;
      c
        ..providerId = m.$1.id
        ..model = m.$2;
      conversations.insert(0, c);
      current = c;
      pending = ChatParams();
    }
    c.messages.add(Message(Role.user, text)
      ..attachments = List.of(attachments)
      ..quote = quote);
    await _reply(c);
  }

  /// Drops the last answer and asks again.
  Future<void> retry() async {
    final c = current;
    if (c == null || running != null || !ready) return;
    while (c.messages.isNotEmpty && c.messages.last.role == Role.assistant) {
      c.messages.removeLast();
    }
    if (c.messages.isEmpty) return;
    await _reply(c);
  }

  /// Replaces the text of a user message, drops everything after it and asks again.
  Future<void> editAndResend(Message m, String text) async {
    final c = current;
    if (c == null || running != null || !ready || m.role != Role.user) return;
    final i = c.messages.indexOf(m);
    if (i < 0) return;
    text = text.trim();
    if (text.isEmpty && m.attachments.isEmpty && m.quote.isEmpty) return;
    m
      ..content = text
      ..time = DateTime.now();
    c.messages.removeRange(i + 1, c.messages.length);
    await _reply(c);
  }

  /// Answers again from the user message that led to [m].
  Future<void> regenerate(Message m) async {
    final c = current;
    if (c == null || running != null || !ready) return;
    final i = c.messages.indexOf(m);
    if (i < 0) return;
    final userIdx = c.messages.sublist(0, i + 1).lastIndexWhere((x) => x.role == Role.user);
    if (userIdx < 0) return;
    c.messages.removeRange(userIdx + 1, c.messages.length);
    await _reply(c);
  }

  /// Copies the chat up to and including [m] into a new chat and opens it.
  Conversation? branch(Message m) {
    final c = current;
    if (c == null) return null;
    final i = c.messages.indexOf(m);
    if (i < 0) return null;
    final copy = Conversation(title: '${c.title} · 分支', params: c.params.copy())
      ..providerId = c.providerId
      ..model = c.model
      ..messages = [
        for (final x in c.messages.sublist(0, i + 1))
          Message.fromJson(jsonDecode(jsonEncode(x.toJson())))
      ];
    conversations.insert(0, copy);
    current = copy;
    _save(copy);
    _saveIndex();
    notifyListeners();
    return copy;
  }

  /// Turns a question and an answer (from model comparison) into a new chat.
  Conversation startFrom(String question, Message answer, Provider p, String model) {
    final c = Conversation(title: _shortTitle(question))
      ..providerId = p.id
      ..model = model
      ..messages = [Message(Role.user, question), answer];
    conversations.insert(0, c);
    current = c;
    _touch(c);
    return c;
  }

  void stop() {
    if (_abort?.isCompleted == false) _abort!.complete();
  }

  Future<void> _reply(Conversation c) async {
    final (provider, model) = modelFor(c)!;
    final firstReply = c.messages.where((m) => m.role == Role.user).length == 1;
    running = c;
    _abort = Completer<void>();
    _touch(c);

    final tools = _activeTools();
    var useTools = tools.isNotEmpty;
    try {
      for (var step = 0; step < maxSteps; step++) {
        final msg = Message(Role.assistant);
        c.messages.add(msg);
        LlmTurn? turn;
        try {
          await for (final t in llm.chat(
            provider: provider,
            model: model,
            system: systemPrompt(c),
            history: c.messages.sublist(0, c.messages.length - 1),
            tools: useTools ? tools.map((t) => t.spec).toList() : const [],
            params: c.params,
            abort: _abort!.future,
          )) {
            turn = t;
            msg
              ..content = t.text
              ..reasoning = t.reasoning
              ..signature = t.signature
              ..inputTokens = t.inputTokens
              ..outputTokens = t.outputTokens;
            notifyListeners();
          }
        } on LlmException catch (e) {
          // Many models reject tools; fall back to plain chat once.
          final toolIssue = RegExp('tool|function', caseSensitive: false).hasMatch(e.message);
          if (useTools && e.status == 400 && toolIssue && msg.content.isEmpty) {
            c.messages.remove(msg);
            useTools = false;
            step--;
            continue;
          }
          rethrow;
        }
        if (_abort!.isCompleted || turn == null || turn.calls.isEmpty) break;

        msg.calls = turn.calls;
        notifyListeners();
        for (final call in msg.calls) {
          call.result = await _runTool(tools, call);
          notifyListeners();
        }
      }
    } catch (e) {
      final last = c.messages.last;
      if (last.role == Role.assistant && last.calls.isEmpty) {
        last
          ..error = true
          ..content = [last.content, '$e'].where((s) => s.isNotEmpty).join('\n\n');
      }
    } finally {
      c.messages.removeWhere((m) =>
          m.role == Role.assistant && m.content.isEmpty && m.calls.isEmpty && m.reasoning.isEmpty);
      running = null;
      _abort = null;
      _touch(c);
    }
    if (firstReply && c.messages.any((m) => m.role == Role.assistant && !m.error)) {
      unawaited(_nameConversation(c, provider, model));
    }
  }

  List<Tool> _activeTools() {
    if (!settings.agent) return const [];
    return buildTools(this).where((t) => settings.memory || !t.needsMemory).toList();
  }

  Future<String> _runTool(List<Tool> tools, ToolCall call) async {
    final tool = tools.where((t) => t.spec.name == call.name).firstOrNull;
    if (tool == null) return 'Unknown tool ${call.name}.';
    try {
      final args = call.args.trim().isEmpty ? <String, dynamic>{} : jsonDecode(call.args);
      return await tool.run(Map<String, dynamic>.from(args as Map));
    } catch (e) {
      return 'Error: $e';
    }
  }

  Future<void> _nameConversation(Conversation c, Provider p, String model) async {
    try {
      final transcript = c.messages
          .where((m) => !m.error && m.content.isNotEmpty)
          .take(2)
          .map((m) => '${m.role.name}: ${m.content}')
          .join('\n');
      LlmTurn? last;
      await for (final t in llm.chat(
        provider: p,
        model: model,
        system: 'Write a title of at most 6 words (or 12 Chinese characters) for this '
            'conversation, in its language. Reply with the title only, no quotes or punctuation.',
        history: [Message(Role.user, transcript)],
      )) {
        last = t;
      }
      final title = (last?.text ?? '').trim().split('\n').first.replaceAll(RegExp(r'''^["'“《]+|["'”》。.]+$'''), '');
      if (title.isNotEmpty && title.length <= 40) rename(c, title);
    } catch (_) {
      // Keep the provisional title.
    }
  }

  static String _shortTitle(String text) {
    final line = text.split('\n').first.trim();
    return line.length > 24 ? '${line.substring(0, 24)}…' : line;
  }

  // ---------------------------------------------------------------- memory

  String systemPrompt([Conversation? chat]) {
    final role = promptFor(chat?.params ?? params);
    final now = DateTime.now();
    final off = now.timeZoneOffset;
    final tz = 'UTC${off.isNegative ? '-' : '+'}${off.inHours.abs().toString().padLeft(2, '0')}:'
        '${(off.inMinutes.abs() % 60).toString().padLeft(2, '0')}';
    final b = StringBuffer()
      ..writeln('You are ZchatBot, a helpful assistant. Reply in the user\'s language. '
          'Use Markdown when it helps.')
      ..writeln('Current time: ${now.toString().substring(0, 16)} ($tz).');
    if (settings.instructions.trim().isNotEmpty) {
      b
        ..writeln('\n# User instructions')
        ..writeln(settings.instructions.trim());
    }
    if (role != null && role.content.trim().isNotEmpty) {
      b
        ..writeln('\n# Role for this chat: ${role.name}')
        ..writeln(role.content.trim());
    }
    if (settings.agent && settings.webSearch) {
      b.writeln('\nCall `web_search` for recent events or facts you are unsure about, '
          'then `read_url` for details. Cite the URLs you used.');
    }
    if (settings.memory) {
      b.writeln('\n# Memory about the user (persists across chats)');
      if (memories.isEmpty) b.writeln('(empty)');
      for (final m in memories) {
        b.writeln('- [${m.id}] ${m.text}');
      }
      final recent = conversations.where((c) => c != current).take(10);
      if (recent.isNotEmpty) {
        b.writeln('\n# Recent conversations');
        for (final c in recent) {
          b.writeln('- ${c.title} (${c.updated.toString().substring(0, 10)})');
        }
      }
      b.writeln('\nUse memory naturally; never recite it unless asked.');
      if (settings.agent) {
        b.writeln('Call `remember` when the user shares lasting information about '
            'themselves or asks you to remember something; skip trivia and secrets. '
            'Call `forget` to delete wrong or unwanted memories. Call `search_chats` '
            'when the user refers to an earlier conversation.');
      }
    }
    return b.toString();
  }

  Memory? addMemory(String text) {
    text = text.trim();
    if (text.isEmpty) return null;
    final existing = memories.where((m) => m.text == text).firstOrNull;
    if (existing != null) return existing;
    final m = Memory(text);
    memories.add(m);
    _saveMemories();
    return m;
  }

  bool removeMemory(String id) {
    final before = memories.length;
    memories.removeWhere((m) => m.id == id);
    _saveMemories();
    return memories.length < before;
  }

  void clearMemories() {
    memories.clear();
    _saveMemories();
  }

  String searchHistory(String query) {
    final words = query.toLowerCase().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
    if (words.isEmpty) return 'Empty query.';
    final hits = <String>[];
    for (final c in conversations) {
      if (c == current) continue;
      for (final m in c.messages) {
        final t = m.content.toLowerCase();
        if (words.any(t.contains)) {
          final i = words.map(t.indexOf).where((i) => i >= 0).reduce((a, b) => a < b ? a : b);
          final start = (i - 120).clamp(0, m.content.length);
          final end = (i + 280).clamp(0, m.content.length);
          hits.add('[${c.title} · ${c.updated.toString().substring(0, 10)} · ${m.role.name}] '
              '${m.content.substring(start, end).replaceAll('\n', ' ')}');
          if (hits.length >= 12) return hits.join('\n');
        }
      }
    }
    return hits.isEmpty ? 'No matches.' : hits.join('\n');
  }

  void _saveMemories() {
    _prefs.setString('memories', jsonEncode(memories.map((m) => m.toJson()).toList()));
    notifyListeners();
  }

  // --------------------------------------------------------- conversations

  void rename(Conversation c, String title) {
    title = title.trim();
    if (title.isEmpty) return;
    c.title = title;
    _save(c);
    notifyListeners();
  }

  void togglePin(Conversation c) {
    c.pinned = !c.pinned;
    _save(c);
    notifyListeners();
  }

  /// Renders a chat as Markdown for sharing.
  String exportMarkdown(Conversation c) {
    String fmt(DateTime? t) => t == null ? '' : t.toString().substring(0, 16);
    final m = modelFor(c);
    final b = StringBuffer()
      ..writeln('# ${c.title.isEmpty ? '新对话' : c.title}')
      ..writeln()
      ..writeln('> ${[if (m != null) '${m.$1.name} · ${m.$2}', fmt(c.updated)].join(' · ')}')
      ..writeln();
    final role = promptFor(c.params);
    if (role != null) b..writeln('> 角色：${role.name}')..writeln();
    for (final x in c.messages) {
      if (x.role == Role.user) {
        b..writeln('## 🧑 用户  ${fmt(x.time)}')..writeln();
        if (x.quote.isNotEmpty) {
          b..writeln(x.quote.trim().split('\n').map((l) => '> $l').join('\n'))..writeln();
        }
        for (final a in x.attachments) {
          b.writeln('📎 ${a.name}');
        }
        if (x.attachments.isNotEmpty) b.writeln();
        if (x.content.isNotEmpty) b..writeln(x.content)..writeln();
      } else {
        if (x.content.isEmpty && x.calls.isEmpty) continue;
        b..writeln('## 🤖 助手  ${fmt(x.time)}')..writeln();
        if (x.reasoning.isNotEmpty) {
          b
            ..writeln('<details><summary>思考过程</summary>')
            ..writeln()
            ..writeln(x.reasoning)
            ..writeln()
            ..writeln('</details>')
            ..writeln();
        }
        for (final call in x.calls) {
          b.writeln('> 🔧 `${call.name}` ${call.args}');
        }
        if (x.calls.isNotEmpty) b.writeln();
        if (x.content.isNotEmpty) b..writeln(x.content)..writeln();
      }
    }
    return b.toString();
  }

  void toggleArchive(Conversation c) {
    c.archived = !c.archived;
    if (c.archived && current == c) current = null;
    _save(c);
    notifyListeners();
  }

  void delete(Conversation c) {
    if (running == c) stop();
    conversations.remove(c);
    if (current == c) current = null;
    _prefs.remove('conv_${c.id}');
    _saveIndex();
    notifyListeners();
  }

  void clearConversations() {
    stop();
    for (final c in conversations) {
      _prefs.remove('conv_${c.id}');
    }
    conversations.clear();
    current = null;
    _saveIndex();
    notifyListeners();
  }

  void _touch(Conversation c) {
    c.updated = DateTime.now();
    conversations
      ..remove(c)
      ..insert(0, c);
    _save(c);
    _saveIndex();
    notifyListeners();
  }

  void _save(Conversation c) => _prefs.setString('conv_${c.id}', jsonEncode(c.toJson()));
  void _saveIndex() => _prefs.setStringList('convs', conversations.map((c) => c.id).toList());

  // -------------------------------------------------------------- settings

  /// Call after mutating [settings] or any [Provider].
  void saveSettings() {
    final s = settings;
    // Keep the selected model valid.
    if (s.provider == null || !(s.provider!.models.contains(s.model))) {
      final p = s.provider?.models.isNotEmpty == true
          ? s.provider
          : s.providers.where((p) => p.models.isNotEmpty).firstOrNull ?? s.provider;
      s.providerId = p?.id;
      s.model = p?.models.contains(s.model) == true ? s.model : p?.models.firstOrNull;
    }
    _prefs.setString('settings', jsonEncode(s.toJson()));
    notifyListeners();
  }

  /// Sets the global default and, when a chat is open, that chat's model.
  void selectModel(Provider p, String model) {
    settings
      ..providerId = p.id
      ..model = model;
    final c = current;
    if (c != null) {
      c
        ..providerId = p.id
        ..model = model;
      _save(c);
    }
    saveSettings();
  }

  // ------------------------------------------------------- export / import

  String exportBackup() => const JsonEncoder.withIndent('  ').convert({
        'version': 1,
        'exportedAt': DateTime.now().millisecondsSinceEpoch,
        'settings': settings.toJson(),
        'memories': memories.map((m) => m.toJson()).toList(),
        'conversations': conversations.map((c) => c.toJson()).toList(),
      });

  void importBackup(String raw) {
    final decoded = jsonDecode(raw);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('无效的备份文件');
    }
    stop();
    for (final c in conversations) {
      _prefs.remove('conv_${c.id}');
    }

    if (decoded['settings'] is Map) {
      settings = Settings.fromJson(Map<String, dynamic>.from(decoded['settings'] as Map));
    }
    memories = [
      for (final m in (decoded['memories'] as List? ?? const []))
        Memory.fromJson(Map<String, dynamic>.from(m as Map))
    ];
    conversations
      ..clear()
      ..addAll([
        for (final c in (decoded['conversations'] as List? ?? const []))
          Conversation.fromJson(Map<String, dynamic>.from(c as Map))
      ])
      ..sort((a, b) => b.updated.compareTo(a.updated));

    current = conversations.firstOrNull;
    for (final c in conversations) {
      _save(c);
    }
    _saveIndex();
    _prefs.setString('memories', jsonEncode(memories.map((m) => m.toJson()).toList()));
    saveSettings();
  }
}
