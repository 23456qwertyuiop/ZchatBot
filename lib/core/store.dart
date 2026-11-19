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

  void newChat() => open(null);

  List<Conversation> filter(String query, {bool archived = false}) {
    final q = query.trim().toLowerCase();
    final base = conversations.where((c) => c.archived == archived);
    if (q.isEmpty) return base.toList();
    return base
        .where((c) =>
            c.title.toLowerCase().contains(q) ||
            c.messages.any((m) => m.content.toLowerCase().contains(q)))
        .toList();
  }

  int get archivedCount => conversations.where((c) => c.archived).length;

  // ------------------------------------------------------------------ chat

  String? get modelLabel => settings.provider == null ? null : settings.model;
  bool get ready => settings.provider != null && (settings.model ?? '').isNotEmpty;

  Future<void> send(String text, {List<Attachment> attachments = const []}) async {
    text = text.trim();
    if ((text.isEmpty && attachments.isEmpty) || running != null || !ready) return;
    final provisional = text.isNotEmpty ? _shortTitle(text) : _shortTitle(attachments.first.name);
    final c = current ?? Conversation(title: provisional);
    if (current == null) {
      conversations.insert(0, c);
      current = c;
    }
    c.messages.add(Message(Role.user, text)..attachments = List.of(attachments));
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

  void stop() {
    if (_abort?.isCompleted == false) _abort!.complete();
  }

  Future<void> _reply(Conversation c) async {
    final provider = settings.provider!;
    final model = settings.model!;
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
            system: systemPrompt(),
            history: c.messages.sublist(0, c.messages.length - 1),
            tools: useTools ? tools.map((t) => t.spec).toList() : const [],
            abort: _abort!.future,
          )) {
            turn = t;
            msg
              ..content = t.text
              ..reasoning = t.reasoning;
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

  String systemPrompt() {
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

  void selectModel(Provider p, String model) {
    settings
      ..providerId = p.id
      ..model = model;
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
