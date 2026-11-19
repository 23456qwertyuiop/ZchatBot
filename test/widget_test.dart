import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:zchatbot/core/models.dart';
import 'package:zchatbot/core/presets.dart';
import 'package:zchatbot/core/store.dart';
import 'package:zchatbot/main.dart';

void main() {
  testWidgets('App boots cleanly', (tester) async {
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
}
