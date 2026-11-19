import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:material_ui/material_ui.dart';

import '../core/models.dart';
import '../core/presets.dart';
import '../core/store.dart';
import 'common.dart';
import 'scope.dart';

void openSettings(BuildContext context) {
  Navigator.of(context).push(slideRoute(const SettingsPage()));
}

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final store = Scope.of(context);
    final cs = Theme.of(context).colorScheme;
    final s = store.settings;

    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 680),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 48),
            children: [
              _sectionTitle(context, '快捷添加'),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final preset in _orderedPresets)
                    ActionChip(
                      label: Text(preset.name),
                      onPressed: () => _quickAdd(context, store, preset),
                    ),
                ],
              ),
              if (s.providers.isNotEmpty) ...[
                const SizedBox(height: 24),
                _sectionTitle(context, '模型服务'),
                const SizedBox(height: 8),
                for (final p in s.providers) ...[
                  _ProviderCard(provider: p),
                  const SizedBox(height: 10),
                ],
              ],
              const SizedBox(height: 20),
              _sectionTitle(context, '智能与记忆'),
              const SizedBox(height: 8),
              Container(
                decoration: BoxDecoration(
                  color: cs.surfaceContainerHigh,
                  borderRadius: BorderRadius.circular(20),
                ),
                clipBehavior: Clip.antiAlias,
                child: Column(
                  children: [
                    SwitchListTile(
                      title: const Text('跨对话记忆'),
                      value: s.memory,
                      onChanged: (v) {
                        s.memory = v;
                        store.saveSettings();
                      },
                    ),
                    Divider(height: 1, color: cs.outlineVariant),
                    SwitchListTile(
                      title: const Text('Agent 工具'),
                      value: s.agent,
                      onChanged: (v) {
                        s.agent = v;
                        store.saveSettings();
                      },
                    ),
                    Divider(height: 1, color: cs.outlineVariant),
                    SwitchListTile(
                      title: const Text('联网搜索'),
                      subtitle: const Text('允许模型调用 web_search 查询最新信息（需开启 Agent 工具）'),
                      value: s.webSearch,
                      onChanged: s.agent
                          ? (v) {
                              s.webSearch = v;
                              store.saveSettings();
                            }
                          : null,
                    ),
                    Divider(height: 1, color: cs.outlineVariant),
                    ListTile(
                      title: const Text('系统指令'),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () async {
                        final res = await promptText(
                          context,
                          title: '系统指令',
                          initial: s.instructions,
                          multiline: true,
                        );
                        if (res != null) {
                          s.instructions = res.trim();
                          store.saveSettings();
                        }
                      },
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),
              Row(
                children: [
                  _sectionTitle(context, '角色预设 (${s.prompts.length})'),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.add),
                    onPressed: () async {
                      final p = await _editPromptDialog(context, PromptPreset(name: '', content: ''), isNew: true);
                      if (p != null) {
                        s.prompts.add(p);
                        store.saveSettings();
                      }
                    },
                  ),
                ],
              ),
              if (s.prompts.isNotEmpty) ...[
                const SizedBox(height: 4),
                Container(
                  decoration: BoxDecoration(
                    color: cs.surfaceContainerHigh,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: Column(
                    children: [
                      for (var i = 0; i < s.prompts.length; i++) ...[
                        if (i > 0) Divider(height: 1, color: cs.outlineVariant),
                        ListTile(
                          title: Text(s.prompts[i].name),
                          subtitle: Text(
                            s.prompts[i].content,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          onTap: () async {
                            if (await _editPromptDialog(context, s.prompts[i]) != null) {
                              store.saveSettings();
                            }
                          },
                          trailing: IconButton(
                            icon: const Icon(Icons.close, size: 18),
                            onPressed: () async {
                              final p = s.prompts[i];
                              if (await confirm(context, '删除角色「${p.name}」？')) {
                                s.prompts.remove(p);
                                store.saveSettings();
                              }
                            },
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 20),
              _sectionTitle(context, '外观'),
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
                decoration: BoxDecoration(
                  color: cs.surfaceContainerHigh,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: double.infinity,
                      child: SegmentedButton<String>(
                        segments: const [
                          ButtonSegment(value: 'system', label: Text('跟随系统'), icon: Icon(Icons.brightness_auto_outlined)),
                          ButtonSegment(value: 'light', label: Text('浅色'), icon: Icon(Icons.light_mode_outlined)),
                          ButtonSegment(value: 'dark', label: Text('深色'), icon: Icon(Icons.dark_mode_outlined)),
                        ],
                        selected: {s.themeMode},
                        onSelectionChanged: (v) {
                          s.themeMode = v.first;
                          store.saveSettings();
                        },
                      ),
                    ),
                    const SizedBox(height: 16),
                    Text('主题色', style: Theme.of(context).textTheme.bodyLarge),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 12,
                      runSpacing: 12,
                      children: [
                        for (final c in themeSeeds)
                          InkWell(
                            customBorder: const CircleBorder(),
                            onTap: () {
                              s.seedColor = c;
                              store.saveSettings();
                            },
                            child: Container(
                              width: 36,
                              height: 36,
                              decoration: BoxDecoration(
                                color: Color(c),
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: s.seedColor == c ? cs.onSurface : Colors.transparent,
                                  width: 3,
                                ),
                              ),
                              child: s.seedColor == c
                                  ? const Icon(Icons.check, size: 18, color: Colors.white)
                                  : null,
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        Text('字体大小', style: Theme.of(context).textTheme.bodyLarge),
                        const Spacer(),
                        Text('${(s.textScale * 100).round()}%',
                            style: TextStyle(color: cs.onSurfaceVariant)),
                      ],
                    ),
                    Slider(
                      value: s.textScale,
                      min: 0.85,
                      max: 1.3,
                      divisions: 9,
                      label: '${(s.textScale * 100).round()}%',
                      onChanged: (v) {
                        s.textScale = v;
                        store.saveSettings();
                      },
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),
              Row(
                children: [
                  _sectionTitle(context, '记忆库 (${store.memories.length})'),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.add),
                    onPressed: () async {
                      final text = await promptText(context, title: '添加记忆');
                      if (text != null) store.addMemory(text);
                    },
                  ),
                  if (store.memories.isNotEmpty)
                    IconButton(
                      icon: const Icon(Icons.delete_sweep_outlined),
                      onPressed: () async {
                        if (await confirm(context, '清空全部记忆？')) {
                          store.clearMemories();
                        }
                      },
                    ),
                ],
              ),
              if (store.memories.isNotEmpty) ...[
                const SizedBox(height: 4),
                Container(
                  decoration: BoxDecoration(
                    color: cs.surfaceContainerHigh,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: Column(
                    children: [
                      for (var i = 0; i < store.memories.length; i++) ...[
                        if (i > 0) Divider(height: 1, color: cs.outlineVariant),
                        ListTile(
                          title: Text(store.memories[i].text),
                          trailing: IconButton(
                            icon: const Icon(Icons.close, size: 18),
                            onPressed: () => store.removeMemory(store.memories[i].id),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 20),
              _sectionTitle(context, '数据迁移'),
              const SizedBox(height: 8),
              Container(
                decoration: BoxDecoration(
                  color: cs.surfaceContainerHigh,
                  borderRadius: BorderRadius.circular(20),
                ),
                clipBehavior: Clip.antiAlias,
                child: Column(
                  children: [
                    ListTile(
                      leading: const Icon(Icons.upload_outlined),
                      title: const Text('导出全部数据'),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => _exportData(context, store),
                    ),
                    Divider(height: 1, color: cs.outlineVariant),
                    ListTile(
                      leading: const Icon(Icons.download_outlined),
                      title: const Text('导入数据'),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => _importData(context, store),
                    ),
                    if (store.totalTokensAll > 0) ...[
                      Divider(height: 1, color: cs.outlineVariant),
                      ListTile(
                        leading: const Icon(Icons.data_usage_outlined),
                        title: const Text('累计 Token'),
                        trailing: Text(
                          '↑${store.totalInputTokensAll}  ↓${store.totalOutputTokensAll}',
                          style: TextStyle(color: cs.onSurfaceVariant),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (store.conversations.isNotEmpty) ...[
                const SizedBox(height: 28),
                FilledButton.tonal(
                  style: FilledButton.styleFrom(
                    backgroundColor: cs.errorContainer,
                    foregroundColor: cs.onErrorContainer,
                    minimumSize: const Size.fromHeight(48),
                  ),
                  onPressed: () async {
                    if (await confirm(context, '清空全部对话？')) {
                      store.clearConversations();
                    }
                  },
                  child: const Text('清空全部对话'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _exportData(BuildContext context, AppStore store) async {
    final json = store.exportBackup();
    final bytes = Uint8List.fromList(utf8.encode(json));
    final date = DateTime.now().toIso8601String().substring(0, 10);
    await FilePicker.saveFile(
      fileName: 'zchatbot-backup-$date.json',
      bytes: bytes,
      mimeType: 'application/json',
    );
  }

  Future<void> _importData(BuildContext context, AppStore store) async {
    final files = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['json'],
    );
    if (files.isEmpty) return;
    try {
      final bytes = await files.first.xFile.readAsBytes();
      final raw = utf8.decode(bytes);
      store.importBackup(raw);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已导入 ${store.conversations.length} 条对话，${store.memories.length} 条记忆')),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('导入失败: $e')),
        );
      }
    }
  }

  static List<Preset> get _orderedPresets {
    final ds = presets.where((p) => p.name == 'DeepSeek');
    final rest = presets.where((p) => p.name != 'DeepSeek');
    return [...ds, ...rest];
  }

  Widget _sectionTitle(BuildContext context, String text) => Text(
        text,
        style: Theme.of(context).textTheme.titleSmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
              fontWeight: FontWeight.w600,
            ),
      );

  Future<void> _quickAdd(BuildContext context, AppStore store, Preset preset) async {
    final p = preset.create();
    if (preset.name == '自定义') {
      final edited = await _editProviderDialog(context, p, isNew: true);
      if (edited == null) return;
      store.settings.providers.add(edited);
      if (edited.models.isNotEmpty) {
        store.selectModel(edited, edited.models.first);
      } else {
        store.saveSettings();
      }
      return;
    }

    if (preset.name == 'Ollama') {
      store.settings.providers.add(p);
      store.selectModel(p, p.models.first);
      return;
    }

    final key = await promptText(context, title: '${preset.name} API Key');
    if (key == null || key.trim().isEmpty) return;
    p.apiKey = key.trim();
    store.settings.providers.add(p);
    if (p.models.isNotEmpty) {
      store.selectModel(p, p.models.first);
    } else {
      store.saveSettings();
    }
  }
}

class _ProviderCard extends StatefulWidget {
  const _ProviderCard({required this.provider});
  final Provider provider;

  @override
  State<_ProviderCard> createState() => _ProviderCardState();
}

class _ProviderCardState extends State<_ProviderCard> {
  bool _fetching = false;

  @override
  Widget build(BuildContext context) {
    final store = Scope.of(context);
    final cs = Theme.of(context).colorScheme;
    final p = widget.provider;
    final isCurrentProvider = store.settings.providerId == p.id;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  p.name,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                ),
              ),
              if (_fetching)
                const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else if (p.protocol == Protocol.openai)
                IconButton(
                  icon: const Icon(Icons.refresh, size: 20),
                  onPressed: () => _fetchModels(context, store, p),
                ),
              IconButton(
                icon: const Icon(Icons.add, size: 20),
                onPressed: () async {
                  final m = await promptText(context, title: '添加模型');
                  if (m != null && m.trim().isNotEmpty && !p.models.contains(m.trim())) {
                    p.models.add(m.trim());
                    store.selectModel(p, m.trim());
                  }
                },
              ),
              IconButton(
                icon: const Icon(Icons.edit_outlined, size: 20),
                onPressed: () async {
                  final updated = await _editProviderDialog(context, p);
                  if (updated != null) store.saveSettings();
                },
              ),
              IconButton(
                icon: const Icon(Icons.delete_outline, size: 20),
                onPressed: () async {
                  if (await confirm(context, '删除 ${p.name}？')) {
                    store.settings.providers.remove(p);
                    store.saveSettings();
                  }
                },
              ),
            ],
          ),
          if (p.models.isNotEmpty) ...[
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final m in p.models)
                  ChoiceChip(
                    label: Text(m),
                    selected: isCurrentProvider && store.settings.model == m,
                    onSelected: (_) => store.selectModel(p, m),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _fetchModels(BuildContext context, AppStore store, Provider p) async {
    setState(() => _fetching = true);
    try {
      final list = await store.llm.listModels(p);
      if (list.isNotEmpty) {
        p.models = list;
        store.saveSettings();
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      }
    } finally {
      if (mounted) setState(() => _fetching = false);
    }
  }
}

Future<Provider?> _editProviderDialog(BuildContext context, Provider p, {bool isNew = false}) {
  final nameCtrl = TextEditingController(text: p.name);
  final urlCtrl = TextEditingController(text: p.baseUrl);
  final keyCtrl = TextEditingController(text: p.apiKey);
  final modelsCtrl = TextEditingController(text: p.models.join(', '));
  var protocol = p.protocol;

  return showDialog<Provider>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: Text(isNew ? '添加服务' : p.name),
        content: SizedBox(
          width: 440,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              spacing: 12,
              children: [
                TextField(
                  controller: nameCtrl,
                  decoration: const InputDecoration(labelText: '名称'),
                ),
                SegmentedButton<Protocol>(
                  segments: const [
                    ButtonSegment(value: Protocol.openai, label: Text('OpenAI 兼容')),
                    ButtonSegment(value: Protocol.anthropic, label: Text('Anthropic')),
                  ],
                  selected: {protocol},
                  onSelectionChanged: (v) => setState(() => protocol = v.first),
                ),
                TextField(
                  controller: urlCtrl,
                  decoration: const InputDecoration(labelText: 'Base URL'),
                ),
                TextField(
                  controller: keyCtrl,
                  obscureText: true,
                  decoration: const InputDecoration(labelText: 'API Key'),
                ),
                TextField(
                  controller: modelsCtrl,
                  decoration: const InputDecoration(labelText: '模型 (逗号分隔)'),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
          FilledButton(
            onPressed: () {
              p
                ..name = nameCtrl.text.trim().isEmpty ? '自定义' : nameCtrl.text.trim()
                ..protocol = protocol
                ..baseUrl = urlCtrl.text.trim()
                ..apiKey = keyCtrl.text.trim()
                ..models = modelsCtrl.text
                    .split(',')
                    .map((s) => s.trim())
                    .where((s) => s.isNotEmpty)
                    .toList();
              Navigator.pop(context, p);
            },
            child: const Text('保存'),
          ),
        ],
      ),
    ),
  ).whenComplete(() {
    nameCtrl.dispose();
    urlCtrl.dispose();
    keyCtrl.dispose();
    modelsCtrl.dispose();
  });
}

Future<PromptPreset?> _editPromptDialog(BuildContext context, PromptPreset p, {bool isNew = false}) {
  final nameCtrl = TextEditingController(text: p.name);
  final contentCtrl = TextEditingController(text: p.content);
  return showDialog<PromptPreset>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(isNew ? '添加角色' : '编辑角色'),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            spacing: 12,
            children: [
              TextField(
                controller: nameCtrl,
                autofocus: isNew,
                decoration: const InputDecoration(labelText: '名称'),
              ),
              TextField(
                controller: contentCtrl,
                minLines: 5,
                maxLines: 14,
                decoration: InputDecoration(
                  labelText: '系统指令',
                  alignLabelWithHint: true,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(16)),
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
        FilledButton(
          onPressed: () {
            final name = nameCtrl.text.trim();
            if (name.isEmpty) return;
            p
              ..name = name
              ..content = contentCtrl.text.trim();
            Navigator.pop(context, p);
          },
          child: const Text('保存'),
        ),
      ],
    ),
  ).whenComplete(() {
    nameCtrl.dispose();
    contentCtrl.dispose();
  });
}
