import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:material_ui/material_ui.dart';

import '../core/models.dart';
import '../core/store.dart';
import 'common.dart';
import 'scope.dart';
import 'settings_page.dart';

/// Matches the history panel in `m3e-canvas.json`:
/// - `surfaceContainerHigh` rounded container (`radius 28`)
/// - Pill list items (`对话1 ... chevron_right`)
/// - Bottom bar with tonal settings iconButton + filled searchBar (`搜索`)
class HistoryPanel extends StatefulWidget {
  const HistoryPanel({super.key, this.onPicked});
  final VoidCallback? onPicked;

  @override
  State<HistoryPanel> createState() => _HistoryPanelState();
}

class _HistoryPanelState extends State<HistoryPanel> {
  final _searchCtrl = TextEditingController();
  String _query = '';
  bool _showArchived = false;

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final store = Scope.of(context);
    final cs = Theme.of(context).colorScheme;
    final archivedCount = store.archivedCount;
    if (_showArchived && archivedCount == 0) _showArchived = false;
    final list = store.filter(_query, archived: _showArchived);

    return Container(
      decoration: BoxDecoration(
        color: cs.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(28),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          if (_showArchived)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
              child: Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.arrow_back, size: 20),
                    onPressed: () => setState(() => _showArchived = false),
                  ),
                  const SizedBox(width: 4),
                  Text(
                    '已归档',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
                  ),
                ],
              ),
            ),
          Expanded(
            child: ListView.separated(
              padding: const EdgeInsets.fromLTRB(12, 16, 12, 12),
              itemCount: list.length + (!_showArchived && archivedCount > 0 ? 1 : 0),
              separatorBuilder: (_, _) => const SizedBox(height: 6),
              itemBuilder: (context, i) {
                if (i == list.length) {
                  return Material(
                    color: Colors.transparent,
                    shape: const StadiumBorder(),
                    clipBehavior: Clip.antiAlias,
                    child: InkWell(
                      onTap: () => setState(() => _showArchived = true),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
                        child: Row(
                          children: [
                            Icon(Icons.archive_outlined, size: 18, color: cs.onSurfaceVariant),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                '已归档 ($archivedCount)',
                                style: TextStyle(color: cs.onSurfaceVariant, fontWeight: FontWeight.w500),
                              ),
                            ),
                            Icon(Icons.chevron_right, size: 18, color: cs.onSurfaceVariant),
                          ],
                        ),
                      ),
                    ),
                  );
                }
                final c = list[i];
                final selected = store.current == c;
                return _ConversationTile(
                  conversation: c,
                  selected: selected,
                  onTap: () {
                    store.open(c);
                    widget.onPicked?.call();
                  },
                );
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
            child: Row(
              spacing: 8,
              children: [
                SizedBox(
                  width: 56,
                  height: 56,
                  child: IconButton.filledTonal(
                    icon: const Icon(Icons.settings_outlined),
                    onPressed: () => openSettings(context),
                  ),
                ),
                Expanded(
                  child: SizedBox(
                    height: 56,
                    child: SearchBar(
                      controller: _searchCtrl,
                      hintText: '搜索',
                      elevation: const WidgetStatePropertyAll(0),
                      backgroundColor: WidgetStatePropertyAll(cs.surfaceContainerHighest),
                      leading: const Padding(
                        padding: EdgeInsets.only(left: 6),
                        child: Icon(Icons.search, size: 20),
                      ),
                      trailing: [
                        if (_query.isNotEmpty)
                          IconButton(
                            icon: const Icon(Icons.close, size: 18),
                            onPressed: () {
                              _searchCtrl.clear();
                              setState(() => _query = '');
                            },
                          )
                        else
                          IconButton(
                            icon: const Icon(Icons.add, size: 20),
                            onPressed: () {
                              store.newChat();
                              widget.onPicked?.call();
                            },
                          ),
                      ],
                      onChanged: (v) => setState(() => _query = v),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ConversationTile extends StatelessWidget {
  const _ConversationTile({
    required this.conversation,
    required this.selected,
    required this.onTap,
  });

  final Conversation conversation;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final store = Scope.read(context);
    final cs = Theme.of(context).colorScheme;
    final title = conversation.title.isEmpty ? '新对话' : conversation.title;

    return Dismissible(
      key: ValueKey(conversation.id),
      direction: DismissDirection.endToStart,
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 20),
        decoration: BoxDecoration(
          color: cs.errorContainer,
          borderRadius: BorderRadius.circular(28),
        ),
        child: Icon(Icons.delete_outline, color: cs.onErrorContainer),
      ),
      onDismissed: (_) => store.delete(conversation),
      child: Material(
        color: selected ? cs.secondaryContainer : cs.surfaceContainerHighest.withValues(alpha: 0.65),
        shape: const StadiumBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          onLongPress: () => _rename(context, store),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 6, 6, 6),
            child: Row(
              children: [
                if (conversation.pinned)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: Icon(
                      Icons.push_pin,
                      size: 14,
                      color: selected ? cs.onSecondaryContainer : cs.primary,
                    ),
                  ),
                Expanded(
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                      color: selected ? cs.onSecondaryContainer : cs.onSurface,
                    ),
                  ),
                ),
                PopupMenuButton<String>(
                  padding: EdgeInsets.zero,
                  icon: Icon(
                    Icons.more_horiz,
                    size: 20,
                    color: selected ? cs.onSecondaryContainer : cs.onSurfaceVariant,
                  ),
                  onSelected: (v) {
                    switch (v) {
                      case 'rename':
                        _rename(context, store);
                      case 'pin':
                        store.togglePin(conversation);
                      case 'export':
                        _export(store);
                      case 'archive':
                        store.toggleArchive(conversation);
                      case 'delete':
                        store.delete(conversation);
                    }
                  },
                  itemBuilder: (_) => [
                    PopupMenuItem(
                      value: 'pin',
                      child: Text(conversation.pinned ? '取消置顶' : '置顶'),
                    ),
                    const PopupMenuItem(value: 'rename', child: Text('重命名')),
                    const PopupMenuItem(value: 'export', child: Text('导出 Markdown')),
                    PopupMenuItem(
                      value: 'archive',
                      child: Text(conversation.archived ? '取消归档' : '归档'),
                    ),
                    PopupMenuItem(
                      value: 'delete',
                      child: Text('删除', style: TextStyle(color: cs.error)),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _export(AppStore store) async {
    final name = (conversation.title.isEmpty ? '对话' : conversation.title)
        .replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    await FilePicker.saveFile(
      fileName: '$name.md',
      bytes: Uint8List.fromList(utf8.encode(store.exportMarkdown(conversation))),
      mimeType: 'text/markdown',
    );
  }

  Future<void> _rename(BuildContext context, dynamic store) async {
    final name = await promptText(
      context,
      title: '重命名',
      initial: conversation.title,
    );
    if (name != null && name.trim().isNotEmpty) {
      store.rename(conversation, name);
    }
  }
}

/// Mobile full-screen history frame (`al7p929s` in `m3e-canvas.json`).
class MobileHistoryPage extends StatelessWidget {
  const MobileHistoryPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: HistoryPanel(
            onPicked: () => Navigator.of(context).pop(),
          ),
        ),
      ),
    );
  }
}
