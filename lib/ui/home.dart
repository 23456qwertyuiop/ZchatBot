import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../core/models.dart';
import '../core/store.dart';
import 'common.dart';
import 'history_panel.dart';
import 'markdown.dart';
import 'scope.dart';
import 'settings_page.dart';

class Home extends StatefulWidget {
  const Home({super.key});

  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  final _focus = FocusNode();
  final List<Attachment> _pending = [];

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _pickAttachments() async {
    final files = await FilePicker.pickFiles();
    if (files.isEmpty) return;
    for (final f in files) {
      final bytes = await f.xFile.readAsBytes();
      final ext = (f.extension ?? '').toLowerCase();
      final imgMime = switch (ext) {
        'png' => 'image/png',
        'jpg' || 'jpeg' => 'image/jpeg',
        'webp' => 'image/webp',
        'gif' => 'image/gif',
        _ => null,
      };
      setState(() {
        _pending.add(Attachment(
          name: f.name,
          mimeType: imgMime ?? 'text/plain',
          data: imgMime != null ? base64Encode(bytes) : utf8.decode(bytes, allowMalformed: true),
        ));
      });
    }
  }

  void _send(AppStore store) {
    final text = _input.text.trim();
    if (text.isEmpty && _pending.isEmpty) return;
    if (!store.ready) {
      openSettings(context);
      return;
    }
    final attachments = List.of(_pending);
    _input.clear();
    setState(() => _pending.clear());
    store.send(text, attachments: attachments);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(
          _scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final store = Scope.of(context);
    final wide = MediaQuery.sizeOf(context).width >= 720;

    return Scaffold(
      body: SafeArea(
        child: wide
            ? Row(
                children: [
                  const SizedBox(
                    width: 348,
                    child: Padding(
                      padding: EdgeInsets.fromLTRB(12, 12, 0, 12),
                      child: HistoryPanel(),
                    ),
                  ),
                  Expanded(child: _chatPane(context, store, wide: true)),
                ],
              )
            : _chatPane(context, store, wide: false),
      ),
    );
  }

  Widget _chatPane(BuildContext context, AppStore store, {required bool wide}) {
    final conv = store.current;
    final title = (conv == null || conv.title.isEmpty) ? '新对话' : conv.title;
    final messages = conv?.messages ?? const <Message>[];
    final streaming = store.running != null && store.running == conv;

    return Column(
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: Row(
            children: [
              if (wide)
                Expanded(
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                  ),
                )
              else ...[
                FilledButton.tonalIcon(
                  onPressed: () => Navigator.of(context)
                      .push(slideRoute(const MobileHistoryPage(), fromLeft: true)),
                  icon: const Icon(Icons.menu, size: 18),
                  label: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 160),
                    child: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
                  ),
                ),
                const Spacer(),
              ],
              const SizedBox(width: 8),
              _ModelButton(store: store),
              if (conv != null) ...[
                const SizedBox(width: 4),
                IconButton.filledTonal(
                  icon: const Icon(Icons.add, size: 20),
                  onPressed: store.newChat,
                ),
              ],
            ],
          ),
        ),
        Expanded(
          child: messages.isEmpty
              ? Center(
                  child: store.ready
                      ? const SizedBox.shrink()
                      : FilledButton.tonal(
                          onPressed: () => openSettings(context),
                          child: const Text('配置 API'),
                        ),
                )
              : SelectionArea(
                  child: ListView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
                    itemCount: messages.length,
                    itemBuilder: (context, i) {
                      final m = messages[i];
                      final isLast = i == messages.length - 1;
                      return Center(
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 760),
                          child: _MessageBubble(
                            message: m,
                            streaming: streaming && isLast,
                            showActions: !streaming && isLast && m.role == Role.assistant,
                            onRetry: store.retry,
                          ),
                        ),
                      );
                    },
                  ),
                ),
        ),
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 792),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_pending.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Wrap(
                        spacing: 8,
                        runSpacing: 6,
                        children: [
                          for (var i = 0; i < _pending.length; i++)
                            InputChip(
                              avatar: Icon(
                                _pending[i].isImage ? Icons.image_outlined : Icons.description_outlined,
                                size: 16,
                              ),
                              label: Text(_pending[i].name, maxLines: 1, overflow: TextOverflow.ellipsis),
                              onDeleted: () => setState(() => _pending.removeAt(i)),
                            ),
                        ],
                      ),
                    ),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    spacing: 8,
                    children: [
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: SizedBox(
                          width: 40,
                          height: 40,
                          child: IconButton.filledTonal(
                            padding: EdgeInsets.zero,
                            icon: const Icon(Icons.open_in_new, size: 20),
                            onPressed: _pickAttachments,
                          ),
                        ),
                      ),
                      Expanded(
                        child: CallbackShortcuts(
                          bindings: wide
                              ? {
                                  const SingleActivator(LogicalKeyboardKey.enter): () {
                                    if (!streaming) _send(store);
                                  },
                                }
                              : const {},
                          child: TextField(
                            controller: _input,
                            focusNode: _focus,
                            minLines: 1,
                            maxLines: 6,
                            textInputAction: wide ? TextInputAction.none : TextInputAction.newline,
                            decoration: InputDecoration(
                              contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                              border: OutlineInputBorder(borderRadius: BorderRadius.circular(28)),
                            ),
                          ),
                        ),
                      ),
                      SizedBox(
                        width: 56,
                        height: 56,
                        child: IconButton.filled(
                          icon: Icon(streaming ? Icons.stop_rounded : Icons.arrow_upward),
                          onPressed: streaming ? store.stop : () => _send(store),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _ModelButton extends StatelessWidget {
  const _ModelButton({required this.store});
  final AppStore store;

  @override
  Widget build(BuildContext context) {
    final label = store.modelLabel ?? '选择模型';
    final providers = store.settings.providers.where((p) => p.models.isNotEmpty).toList();

    if (providers.isEmpty) {
      return ActionChip(
        label: Text(label),
        onPressed: () => openSettings(context),
      );
    }

    return MenuAnchor(
      builder: (context, controller, child) => ActionChip(
        label: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
        onPressed: () => controller.isOpen ? controller.close() : controller.open(),
      ),
      menuChildren: [
        for (final p in providers)
          for (final m in p.models)
            MenuItemButton(
              onPressed: () => store.selectModel(p, m),
              trailingIcon: store.settings.providerId == p.id && store.settings.model == m
                  ? const Icon(Icons.check, size: 18)
                  : null,
              child: Text('${p.name} · $m'),
            ),
        const Divider(height: 1),
        MenuItemButton(
          leadingIcon: const Icon(Icons.settings_outlined, size: 18),
          onPressed: () => openSettings(context),
          child: const Text('设置'),
        ),
      ],
    );
  }
}

class _MessageBubble extends StatefulWidget {
  const _MessageBubble({
    required this.message,
    required this.streaming,
    required this.showActions,
    required this.onRetry,
  });

  final Message message;
  final bool streaming;
  final bool showActions;
  final VoidCallback onRetry;

  @override
  State<_MessageBubble> createState() => _MessageBubbleState();
}

class _MessageBubbleState extends State<_MessageBubble> {
  bool _showReasoning = false;

  @override
  Widget build(BuildContext context) {
    final m = widget.message;
    final cs = Theme.of(context).colorScheme;

    if (m.role == Role.user) {
      return Align(
        alignment: Alignment.centerRight,
        child: Container(
          margin: const EdgeInsets.only(bottom: 16, left: 48),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
          decoration: BoxDecoration(
            color: cs.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(22),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            spacing: 8,
            children: [
              if (m.attachments.isNotEmpty)
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  alignment: WrapAlignment.end,
                  children: [
                    for (final a in m.attachments)
                      if (a.isImage)
                        ClipRRect(
                          borderRadius: BorderRadius.circular(12),
                          child: Image.memory(
                            base64Decode(a.data),
                            width: 180,
                            fit: BoxFit.cover,
                          ),
                        )
                      else
                        Chip(
                          avatar: const Icon(Icons.description_outlined, size: 16),
                          label: Text(a.name),
                        ),
                  ],
                ),
              if (m.content.isNotEmpty)
                Text(m.content, style: Theme.of(context).textTheme.bodyLarge),
            ],
          ),
        ),
      );
    }

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 10,
        children: [
          if (m.reasoning.isNotEmpty)
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ActionChip(
                  avatar: Icon(
                    _showReasoning ? Icons.expand_less : Icons.expand_more,
                    size: 16,
                  ),
                  label: const Text('思考过程'),
                  onPressed: () => setState(() => _showReasoning = !_showReasoning),
                ),
                if (_showReasoning)
                  Container(
                    margin: const EdgeInsets.only(top: 6),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: cs.surfaceContainerLow,
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Text(
                      m.reasoning,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: cs.onSurfaceVariant,
                            height: 1.5,
                          ),
                    ),
                  ),
              ],
            ),
          if (m.calls.isNotEmpty)
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: [
                for (final c in m.calls) _ToolPill(call: c),
              ],
            ),
          if (m.content.isNotEmpty)
            m.error
                ? Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: cs.errorContainer,
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Text(m.content, style: TextStyle(color: cs.onErrorContainer)),
                  )
                : MarkdownView(m.content)
          else if (widget.streaming && m.calls.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          if (widget.showActions && m.content.isNotEmpty)
            Row(
              children: [
                IconButton(
                  iconSize: 18,
                  color: cs.onSurfaceVariant,
                  icon: const Icon(Icons.content_copy_rounded),
                  onPressed: () => Clipboard.setData(ClipboardData(text: m.content)),
                ),
                IconButton(
                  iconSize: 18,
                  color: cs.onSurfaceVariant,
                  icon: const Icon(Icons.refresh_rounded),
                  onPressed: widget.onRetry,
                ),
              ],
            ),
        ],
      ),
    );
  }
}

class _ToolPill extends StatelessWidget {
  const _ToolPill({required this.call});
  final ToolCall call;

  @override
  Widget build(BuildContext context) {
    final done = call.result != null;
    return ActionChip(
      avatar: done
          ? const Icon(Icons.check, size: 16)
          : const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
      label: Text(call.name),
      onPressed: () => showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(call.name),
          content: SingleChildScrollView(
            child: SelectableText(
              '${call.args}\n\n${call.result ?? ''}'.trim(),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('关闭')),
          ],
        ),
      ),
    );
  }
}
