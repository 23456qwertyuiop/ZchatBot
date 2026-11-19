import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:zchatbot/core/models.dart';
import 'package:zchatbot/core/presets.dart';
import 'package:zchatbot/core/store.dart';
import 'package:zchatbot/main.dart';
import 'package:zchatbot/ui/home.dart';
import 'package:zchatbot/ui/markdown.dart';

void main() {
  testWidgets('App boots cleanly', (tester) async {
    Home.dropEnabled = false;
    SharedPreferences.setMockInitialValues({});
    final store = await AppStore.load();
    await tester.pumpWidget(ZchatApp(store: store));
    await tester.pumpAndSettle();

    expect(find.text('配置 API'), findsOneWidget);
  });

  test('Export and import backup round-trips all data', () async {
    SharedPreferences.setMockInitialValues({});
    final store = await AppStore.load();
    final ds = presets.firstWhere((p) => p.name == 'DeepSeek').create()..apiKey = 'sk-test';
    store.settings.providers.add(ds);
    store.selectModel(ds, ds.models.first);
    store.addMemory('喜欢用中文交流');
    final conv = Conversation(title: '测试对话')
      ..messages.add(Message(Role.user, '你好'));
    store.conversations.add(conv);

    final json = store.exportBackup();

    SharedPreferences.setMockInitialValues({});
    final restored = await AppStore.load();
    restored.importBackup(json);

    expect(restored.settings.providers.length, 1);
    expect(restored.settings.providers.first.apiKey, 'sk-test');
    expect(restored.settings.model, 'deepseek-chat');
    expect(restored.memories.single.text, '喜欢用中文交流');
    expect(restored.conversations.single.title, '测试对话');
    expect(restored.conversations.single.messages.single.content, '你好');
  });

  test('Pinned chats sort first and branching copies history', () async {
    SharedPreferences.setMockInitialValues({});
    final store = await AppStore.load();
    final a = Conversation(title: 'A')..messages.addAll([Message(Role.user, 'q1'), Message(Role.assistant, 'a1')]);
    final b = Conversation(title: 'B');
    store.conversations.addAll([a, b]);
    store.togglePin(b);
    expect(store.filter('').first, b);

    store.open(a);
    final copy = store.branch(a.messages.first)!;
    expect(copy.messages.single.content, 'q1');
    expect(store.current, copy);
    expect(a.messages.length, 2);
  });

  test('Markdown export includes quote, role and answer', () async {
    SharedPreferences.setMockInitialValues({});
    final store = await AppStore.load();
    final c = Conversation(title: '导出测试')
      ..params.promptId = store.settings.prompts.first.id
      ..messages.addAll([
        Message(Role.user, '解释一下')..quote = '被引用的文字',
        Message(Role.assistant, '这是回答'),
      ]);
    final md = store.exportMarkdown(c);
    expect(md, contains('# 导出测试'));
    expect(md, contains('> 被引用的文字'));
    expect(md, contains('角色：${store.settings.prompts.first.name}'));
    expect(md, contains('这是回答'));
  });

  test('New settings and chat params survive JSON round-trip', () {
    final s = Settings()
      ..themeMode = 'dark'
      ..seedColor = themeSeeds[2]
      ..textScale = 1.2
      ..webSearch = false;
    final r = Settings.fromJson(s.toJson());
    expect(r.themeMode, 'dark');
    expect(r.seedColor, themeSeeds[2]);
    expect(r.textScale, 1.2);
    expect(r.webSearch, false);
    expect(r.prompts.length, s.prompts.length);

    final c = Conversation(params: ChatParams(temperature: 0.3, maxTokens: 500, reasoning: 'high'))
      ..pinned = true
      ..messages.add(Message(Role.user, 'hi')..quote = 'q');
    final rc = Conversation.fromJson(c.toJson());
    expect(rc.pinned, true);
    expect(rc.params.temperature, 0.3);
    expect(rc.params.maxTokens, 500);
    expect(rc.params.reasoning, 'high');
    expect(rc.messages.single.quote, 'q');
    expect(rc.messages.single.time, isNotNull);
    expect(rc.messages.single.promptText, '> q\n\nhi');
  });

  test('Code highlighter keeps text intact', () {
    const code = 'final x = "hi"; // note\nreturn foo(42);';
    final spans = highlightCode(code, 'dart', false);
    expect(spans.map((s) => s.text).join(), code);
    expect(spans.any((s) => s.text == '// note' && s.style != null), isTrue);
  });
}
