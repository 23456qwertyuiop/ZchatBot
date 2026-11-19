import 'package:material_ui/material_ui.dart';

import '../core/models.dart';
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

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final store = Scope.of(context);
    final cs = Theme.of(context).colorScheme;
    final list = store.filter(_query);

    return Container(
      decoration: BoxDecoration(
        color: cs.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(28),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          Expanded(
            child: ListView.separated(
              padding: const EdgeInsets.fromLTRB(12, 16, 12, 12),
              itemCount: list.length,
              separatorBuilder: (_, _) => const SizedBox(height: 6),
              itemBuilder: (context, i) {
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
          onLongPress: () async {
            final name = await promptText(
              context,
              title: '重命名',
              initial: conversation.title,
            );
            if (name != null && name.trim().isNotEmpty) {
              store.rename(conversation, name);
            }
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
            child: Row(
              children: [
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
                Icon(
                  Icons.chevron_right,
                  size: 20,
                  color: selected ? cs.onSecondaryContainer : cs.onSurfaceVariant,
                ),
              ],
            ),
          ),
        ),
      ),
    );
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
