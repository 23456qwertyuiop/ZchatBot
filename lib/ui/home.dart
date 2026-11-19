import 'dart:async';
import 'dart:convert';

import 'package:cross_file/cross_file.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pasteboard/pasteboard.dart';

import '../core/models.dart';
import '../core/store.dart';
import 'common.dart';
import 'compare_page.dart';
import 'history_panel.dart';
import 'markdown.dart';
import 'scope.dart';
import 'settings_page.dart';
import 'voice.dart';

class Home extends StatefulWidget {
  const Home({super.key});

  /// Native drag-and-drop; widget tests turn it off (no native bridge there).
  static bool dropEnabled = true;

  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  final _focus = FocusNode();
  final _dictation = Dictation();
  final List<Attachment> _pending = [];

  /// Text currently selected inside the message list.
  String _selection = '';

  /// Text quoted into the next message.
  String _quote = '';

  /// Whether the list is scrolled to (near) the end; new output follows only then.
  bool _atBottom = true;

  /// A file is being dragged over the window.
  bool _dragging = false;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    _dictation.addListener(_rebuild);
    Speaker.instance.addListener(_rebuild);
  }

  @override
  void dispose() {
    Speaker.instance.removeListener(_rebuild);
    _dictation
      ..removeListener(_rebuild)
      ..dispose();
    _input.dispose();
    _scroll.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _rebuild() {
    if (mounted) setState(() {});
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    final p = _scroll.position;
    final atBottom = p.pixels >= p.maxScrollExtent - 80;
    if (atBottom != _atBottom) setState(() => _atBottom = atBottom);
  }

  void _scrollToBottom({bool animate = true}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      final end = _scroll.position.maxScrollExtent;
      if (animate) {
        _scroll.animateTo(end, duration: const Duration(milliseconds: 220), curve: Curves.easeOut);
      } else {
        _scroll.jumpTo(end);
      }
    });
  }

  void _toast(String text) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text), duration: const Duration(seconds: 2)));
  }

  // ----------------------------------------------------------- attachments

  static String? _imageMime(String name, Uint8List bytes) {
    final ext = name.contains('.') ? name.split('.').last.toLowerCase() : '';
    final byExt = switch (ext) {
      'png' => 'image/png',
      'jpg' || 'jpeg' => 'image/jpeg',
      'webp' => 'image/webp',
      'gif' => 'image/gif',
      _ => null,
    };
    if (byExt != null) return byExt;
    if (bytes.length > 4 && bytes[0] == 0x89 && bytes[1] == 0x50) return 'image/png';
    if (bytes.length > 3 && bytes[0] == 0xFF && bytes[1] == 0xD8) return 'image/jpeg';
    return null;
  }

  void _addFile(String name, Uint8List bytes) {
    final mime = _imageMime(name, bytes);
    setState(() {
      _pending.add(Attachment(
        name: name,
        mimeType: mime ?? 'text/plain',
        data: mime != null ? base64Encode(bytes) : utf8.decode(bytes, allowMalformed: true),
      ));
    });
  }

  Future<void> _pickAttachments() async {
    final files = await FilePicker.pickFiles();
    if (files.isEmpty) return;
    for (final f in files) {
      _addFile(f.name, await f.xFile.readAsBytes());
    }
  }

  /// Cmd/Ctrl+V: files or an image on the clipboard become attachments,
  /// anything else is pasted as text as usual.
  Future<void> _paste() async {
    try {
      final files = await Pasteboard.files();
      final local = files.where((f) => !f.startsWith('content://')).toList();
      if (local.isNotEmpty) {
        for (final path in local) {
          _addFile(path.split(RegExp(r'[/\\]')).last, await XFile(path).readAsBytes());
        }
        return;
      }
      final image = await Pasteboard.image;
      if (image != null && image.isNotEmpty) {
        final stamp = DateTime.now().toString().substring(11, 19).replaceAll(':', '');
        _addFile('粘贴图片-$stamp.png', image);
        return;
      }
    } catch (_) {
      // Plugin unavailable on this platform: fall back to text.
    }
    final ctx = _focus.context;
    if (ctx != null && ctx.mounted) {
      Actions.maybeInvoke(ctx, const PasteTextIntent(SelectionChangedCause.keyboard));
    }
  }

  Future<void> _onDrop(DropDoneDetails d) async {
    setState(() => _dragging = false);
    final files = d.files.where((f) => f is! DropItemDirectory).toList();
    for (final f in files) {
      try {
        _addFile(f.name, await f.readAsBytes());
      } catch (_) {
        _toast('无法读取 ${f.name}');
      }
    }
    final text = d.rawText;
    if (files.isEmpty && text != null && text.isNotEmpty) _insertText(text);
  }

  void _insertText(String text) {
    final v = _input.value;
    final sel = v.selection.isValid ? v.selection : TextSelection.collapsed(offset: v.text.length);
    _input.value = v.copyWith(
      text: v.text.replaceRange(sel.start, sel.end, text),
      selection: TextSelection.collapsed(offset: sel.start + text.length),
    );
  }

  // ----------------------------------------------------------------- voice

  Future<void> _toggleDictation() async {
    if (_dictation.listening) {
      await _dictation.stop();
      return;
    }
    final base = _input.text.isEmpty || _input.text.endsWith(' ') ? _input.text : '${_input.text} ';
    final err = await _dictation.start((t) {
      _input.value = TextEditingValue(
        text: base + t,
        selection: TextSelection.collapsed(offset: (base + t).length),
      );
    });
    if (err != null && mounted) _toast(err);
  }

  // ------------------------------------------------------------------ send

  void _send(AppStore store) {
    final text = _input.text.trim();
    if (text.isEmpty && _pending.isEmpty && _quote.isEmpty) return;
    if (!store.ready) {
      openSettings(context);
      return;
    }
    if (_dictation.listening) _dictation.stop();
    final attachments = List.of(_pending);
    final quote = _quote;
    _input.clear();
    setState(() {
      _pending.clear();
      _quote = '';
      _atBottom = true;
    });
    store.send(text, attachments: attachments, quote: quote);
    _scrollToBottom();
  }

  Future<void> _edit(AppStore store, Message m) async {
    final text = await promptText(context, title: '编辑并重新发送', initial: m.content, multiline: true);
    if (text == null) return;
    setState(() => _atBottom = true);
    store.editAndResend(m, text);
    _scrollToBottom();
  }

  void _regenerate(AppStore store, Message m) {
    setState(() => _atBottom = true);
    store.regenerate(m);
    _scrollToBottom();
  }

  void _branch(AppStore store, Message m) {
    if (store.branch(m) != null) _toast('已创建分支对话');
  }

  Future<void> _exportMarkdown(AppStore store, Conversation c) async {
    final name = (c.title.isEmpty ? '对话' : c.title).replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    await FilePicker.saveFile(
      fileName: '$name.md',
      bytes: Uint8List.fromList(utf8.encode(store.exportMarkdown(c))),
      mimeType: 'text/markdown',
    );
  }

  void _quoteSelection(SelectableRegionState region) {
    final text = _selection.trim();
    region.hideToolbar();
    if (text.isEmpty) return;
    setState(() => _quote = text);
    _focus.requestFocus();
  }

  Widget _selectionMenu(BuildContext context, SelectableRegionState region) {
    final items = [
      ContextMenuButtonItem(
        label: '引用',
        onPressed: () => _quoteSelection(region),
      ),
      ...region.contextMenuButtonItems,
    ];
    return AdaptiveTextSelectionToolbar.buttonItems(
      anchors: region.contextMenuAnchors,
      buttonItems: items,
    );
  }

  // ----------------------------------------------------------------- build

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
    final cs = Theme.of(context).colorScheme;
    final conv = store.current;
    final title = (conv == null || conv.title.isEmpty) ? '新对话' : conv.title;
    final messages = conv?.messages ?? const <Message>[];
    final streaming = store.running != null && store.running == conv;
    final busy = store.running != null;
    final role = store.promptFor(store.params);
    final touch = switch (Theme.of(context).platform) {
      TargetPlatform.android || TargetPlatform.iOS => true,
      _ => false,
    };

    if (streaming && _atBottom) _scrollToBottom(animate: false);

    final pane = Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: Row(
            children: [
              if (wide)
                Expanded(
                  child: Row(
                    children: [
                      if (conv?.pinned == true)
                        Padding(
                          padding: const EdgeInsets.only(right: 6),
                          child: Icon(Icons.push_pin, size: 18, color: cs.primary),
                        ),
                      Flexible(
                        child: Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                                fontWeight: FontWeight.w700,
                              ),
                        ),
                      ),
                      if (role != null) ...[
                        const SizedBox(width: 10),
                        InputChip(
                          avatar: const Icon(Icons.theater_comedy_outlined, size: 16),
                          label: Text(role.name),
                          onDeleted: () => store.setPrompt(null),
                        ),
                      ],
                    ],
                  ),
                )
              else ...[
                FilledButton.tonalIcon(
                  onPressed: () => Navigator.of(context)
                      .push(slideRoute(const MobileHistoryPage(), fromLeft: true)),
                  icon: const Icon(Icons.menu, size: 18),
                  label: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 140),
                    child: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
                  ),
                ),
                const Spacer(),
              ],
              const SizedBox(width: 8),
              if (wide && conv != null && conv.totalTokens > 0) ...[
                Tooltip(
                  message: '输入 ${conv.totalInputTokens} · 输出 ${conv.totalOutputTokens}',
                  child: Text(
                    '${_fmtTokens(conv.totalTokens)} tok',
                    style: Theme.of(context).textTheme.labelMedium?.copyWith(
                          color: cs.onSurfaceVariant,
                        ),
                  ),
                ),
                const SizedBox(width: 8),
              ],
              _ModelButton(store: store, maxWidth: wide ? 180 : 96),
              _MoreMenu(
                store: store,
                onParams: () => _editParams(context, store),
                onCompare: () => Navigator.of(context).push(slideRoute(const ComparePage())),
                onExport: conv == null ? null : () => _exportMarkdown(store, conv),
              ),
              if (conv != null)
                IconButton.filledTonal(
                  icon: const Icon(Icons.add, size: 20),
                  onPressed: store.newChat,
                ),
            ],
          ),
        ),
        Expanded(
          child: messages.isEmpty
              ? Center(
                  child: store.ready
                      ? _RolePicker(store: store)
                      : FilledButton.tonal(
                          onPressed: () => openSettings(context),
                          child: const Text('配置 API'),
                        ),
                )
              : Stack(
                  children: [
                    SelectionArea(
                      onSelectionChanged: (c) => _selection = c?.plainText ?? '',
                      contextMenuBuilder: _selectionMenu,
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
                                pinActions: touch || (!streaming && isLast && m.role == Role.assistant),
                                busy: busy,
                                speaking: Speaker.instance.speaking == m,
                                onCopy: () {
                                  Clipboard.setData(ClipboardData(text: m.content));
                                  _toast('已复制');
                                },
                                onEdit: () => _edit(store, m),
                                onRegenerate: () => _regenerate(store, m),
                                onBranch: () => _branch(store, m),
                                onSpeak: () => Speaker.instance.toggle(m),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                    if (!_atBottom)
                      Positioned(
                        right: 0,
                        left: 0,
                        bottom: 12,
                        child: Center(
                          child: FloatingActionButton.small(
                            heroTag: null,
                            elevation: 2,
                            onPressed: () {
                              setState(() => _atBottom = true);
                              _scrollToBottom();
                            },
                            child: const Icon(Icons.arrow_downward_rounded),
                          ),
                        ),
                      ),
                  ],
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
                  if (_quote.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: _QuotePreview(
                        text: _quote,
                        onClose: () => setState(() => _quote = ''),
                      ),
                    ),
                  if (_pending.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Wrap(
                        spacing: 8,
                        runSpacing: 6,
                        children: [
                          for (var i = 0; i < _pending.length; i++)
                            InputChip(
                              avatar: _pending[i].isImage
                                  ? ClipRRect(
                                      borderRadius: BorderRadius.circular(4),
                                      child: Image.memory(base64Decode(_pending[i].data),
                                          width: 20, height: 20, fit: BoxFit.cover),
                                    )
                                  : const Icon(Icons.description_outlined, size: 16),
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
                      Expanded(
                        child: Container(
                          constraints: const BoxConstraints(minHeight: 56),
                          decoration: BoxDecoration(
                            border: Border.all(color: cs.outline),
                            borderRadius: BorderRadius.circular(28),
                          ),
                          padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            spacing: 8,
                            children: [
                              Padding(
                                padding: const EdgeInsets.only(bottom: 1),
                                child: SizedBox(
                                  width: 40,
                                  height: 40,
                                  child: IconButton.filledTonal(
                                    padding: EdgeInsets.zero,
                                    icon: const Icon(Icons.attach_file_rounded, size: 20),
                                    onPressed: _pickAttachments,
                                  ),
                                ),
                              ),
                              Expanded(
                                child: CallbackShortcuts(
                                  bindings: {
                                    if (wide)
                                      const SingleActivator(LogicalKeyboardKey.enter): () {
                                        if (!streaming) _send(store);
                                      },
                                    SingleActivator(
                                      LogicalKeyboardKey.keyV,
                                      meta: defaultTargetPlatform == TargetPlatform.macOS,
                                      control: defaultTargetPlatform != TargetPlatform.macOS,
                                    ): () => unawaited(_paste()),
                                  },
                                  child: TextField(
                                    controller: _input,
                                    focusNode: _focus,
                                    minLines: 1,
                                    maxLines: 6,
                                    textInputAction: wide ? TextInputAction.none : TextInputAction.newline,
                                    decoration: InputDecoration(
                                      isDense: true,
                                      hintText: _dictation.listening ? '正在聆听…' : null,
                                      border: InputBorder.none,
                                      enabledBorder: InputBorder.none,
                                      focusedBorder: InputBorder.none,
                                      contentPadding: const EdgeInsets.symmetric(vertical: 10),
                                    ),
                                  ),
                                ),
                              ),
                              Padding(
                                padding: const EdgeInsets.only(bottom: 1),
                                child: SizedBox(
                                  width: 40,
                                  height: 40,
                                  child: _dictation.listening
                                      ? IconButton.filled(
                                          padding: EdgeInsets.zero,
                                          icon: const Icon(Icons.mic, size: 20),
                                          onPressed: _toggleDictation,
                                        )
                                      : IconButton(
                                          padding: EdgeInsets.zero,
                                          icon: const Icon(Icons.mic_none_rounded, size: 20),
                                          onPressed: _toggleDictation,
                                        ),
                                ),
                              ),
                            ],
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

    if (!Home.dropEnabled) return pane;
    return DropTarget(
      onDragEntered: (_) => setState(() => _dragging = true),
      onDragExited: (_) => setState(() => _dragging = false),
      onDragDone: (d) => unawaited(_onDrop(d)),
      child: Stack(
        children: [
          pane,
          if (_dragging)
            Positioned.fill(
              child: IgnorePointer(
                child: Container(
                  margin: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: cs.primaryContainer.withValues(alpha: 0.85),
                    borderRadius: BorderRadius.circular(28),
                    border: Border.all(color: cs.primary, width: 2),
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    '松开以添加附件',
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(color: cs.onPrimaryContainer),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _editParams(BuildContext context, AppStore store) async {
    final p = store.params;
    double? temperature = p.temperature;
    var reasoning = p.reasoning ?? '';
    final maxCtrl = TextEditingController(text: p.maxTokens?.toString() ?? '');
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: Text(store.current == null ? '新对话参数' : '本对话参数'),
          content: SizedBox(
            width: 420,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('自定义温度'),
                    subtitle: Text(temperature == null
                        ? '使用模型默认值'
                        : '${temperature!.toStringAsFixed(1)}（越高越有创造性）'),
                    value: temperature != null,
                    onChanged: (v) => setState(() => temperature = v ? 0.7 : null),
                  ),
                  if (temperature != null)
                    Slider(
                      value: temperature!,
                      min: 0,
                      max: 2,
                      divisions: 20,
                      label: temperature!.toStringAsFixed(1),
                      onChanged: (v) => setState(() => temperature = v),
                    ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: maxCtrl,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    decoration: const InputDecoration(
                      labelText: '最大输出 Token',
                      hintText: '留空使用默认值',
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text('思考强度', style: Theme.of(context).textTheme.titleSmall),
                  const SizedBox(height: 8),
                  SegmentedButton<String>(
                    showSelectedIcon: false,
                    segments: const [
                      ButtonSegment(value: '', label: Text('默认')),
                      ButtonSegment(value: 'low', label: Text('低')),
                      ButtonSegment(value: 'medium', label: Text('中')),
                      ButtonSegment(value: 'high', label: Text('高')),
                    ],
                    selected: {reasoning},
                    onSelectionChanged: (v) => setState(() => reasoning = v.first),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '仅支持推理模型（如 o 系列、Claude 扩展思考）；其他模型可能报错。',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => setState(() {
                temperature = null;
                reasoning = '';
                maxCtrl.clear();
              }),
              child: const Text('重置'),
            ),
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('保存')),
          ],
        ),
      ),
    );
    final max = int.tryParse(maxCtrl.text.trim());
    maxCtrl.dispose();
    if (saved != true) return;
    p
      ..temperature = temperature
      ..maxTokens = (max != null && max > 0) ? max : null
      ..reasoning = reasoning.isEmpty ? null : reasoning;
    store.saveParams();
  }
}

/// Role presets offered on an empty chat.
class _RolePicker extends StatelessWidget {
  const _RolePicker({required this.store});
  final AppStore store;

  @override
  Widget build(BuildContext context) {
    final prompts = store.settings.prompts;
    if (prompts.isEmpty) return const SizedBox.shrink();
    final selected = store.params.promptId;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 520),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          spacing: 12,
          children: [
            Text(
              '选择一个角色开始（可选）',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
            Wrap(
              alignment: WrapAlignment.center,
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final p in prompts)
                  ChoiceChip(
                    label: Text(p.name),
                    selected: selected == p.id,
                    onSelected: (v) => store.setPrompt(v ? p.id : null),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _MoreMenu extends StatelessWidget {
  const _MoreMenu({
    required this.store,
    required this.onParams,
    required this.onCompare,
    required this.onExport,
  });

  final AppStore store;
  final VoidCallback onParams;
  final VoidCallback onCompare;
  final VoidCallback? onExport;

  @override
  Widget build(BuildContext context) {
    final conv = store.current;
    final selected = store.params.promptId;
    return MenuAnchor(
      builder: (context, controller, _) => IconButton(
        icon: const Icon(Icons.more_vert),
        onPressed: () => controller.isOpen ? controller.close() : controller.open(),
      ),
      menuChildren: [
        SubmenuButton(
          leadingIcon: const Icon(Icons.theater_comedy_outlined, size: 18),
          menuChildren: [
            MenuItemButton(
              onPressed: () => store.setPrompt(null),
              trailingIcon: selected == null ? const Icon(Icons.check, size: 18) : null,
              child: const Text('无'),
            ),
            for (final p in store.settings.prompts)
              MenuItemButton(
                onPressed: () => store.setPrompt(p.id),
                trailingIcon: selected == p.id ? const Icon(Icons.check, size: 18) : null,
                child: Text(p.name),
              ),
            const Divider(height: 1),
            MenuItemButton(
              onPressed: () => openSettings(context),
              child: const Text('管理角色…'),
            ),
          ],
          child: const Text('角色'),
        ),
        MenuItemButton(
          leadingIcon: const Icon(Icons.tune, size: 18),
          onPressed: onParams,
          child: const Text('生成参数…'),
        ),
        MenuItemButton(
          leadingIcon: const Icon(Icons.compare_arrows, size: 18),
          onPressed: onCompare,
          child: const Text('模型对比'),
        ),
        if (conv != null) ...[
          const Divider(height: 1),
          MenuItemButton(
            leadingIcon: Icon(conv.pinned ? Icons.push_pin : Icons.push_pin_outlined, size: 18),
            onPressed: () => store.togglePin(conv),
            child: Text(conv.pinned ? '取消置顶' : '置顶'),
          ),
          MenuItemButton(
            leadingIcon: const Icon(Icons.file_download_outlined, size: 18),
            onPressed: onExport,
            child: const Text('导出 Markdown'),
          ),
        ],
      ],
    );
  }
}

class _ModelButton extends StatelessWidget {
  const _ModelButton({required this.store, required this.maxWidth});
  final AppStore store;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    final label = store.modelLabel ?? '选择模型';
    final providers = store.settings.providers.where((p) => p.models.isNotEmpty).toList();
    final active = store.modelFor(store.current);

    if (providers.isEmpty) {
      return ActionChip(
        label: Text(label),
        onPressed: () => openSettings(context),
      );
    }

    return MenuAnchor(
      builder: (context, controller, child) => ActionChip(
        label: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxWidth),
          child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
        ),
        onPressed: () => controller.isOpen ? controller.close() : controller.open(),
      ),
      menuChildren: [
        for (final p in providers)
          for (final m in p.models)
            MenuItemButton(
              onPressed: () => store.selectModel(p, m),
              trailingIcon: active?.$1.id == p.id && active?.$2 == m
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
    required this.pinActions,
    required this.busy,
    required this.speaking,
    required this.onCopy,
    required this.onEdit,
    required this.onRegenerate,
    required this.onBranch,
    required this.onSpeak,
  });

  final Message message;
  final bool streaming;

  /// Keep the action row visible (touch devices, latest answer) instead of on hover only.
  final bool pinActions;

  /// A reply is being generated somewhere; editing actions are disabled.
  final bool busy;
  final bool speaking;
  final VoidCallback onCopy;
  final VoidCallback onEdit;
  final VoidCallback onRegenerate;
  final VoidCallback onBranch;
  final VoidCallback onSpeak;

  @override
  State<_MessageBubble> createState() => _MessageBubbleState();
}

class _MessageBubbleState extends State<_MessageBubble> {
  bool _showReasoning = false;
  bool _hover = false;

  Widget _actions(BuildContext context, {required bool user}) {
    final m = widget.message;
    final cs = Theme.of(context).colorScheme;
    final small = Theme.of(context).textTheme.labelSmall?.copyWith(color: cs.onSurfaceVariant);
    Widget btn(IconData icon, String tip, VoidCallback? onPressed) => IconButton(
          tooltip: tip,
          iconSize: 18,
          visualDensity: VisualDensity.compact,
          color: cs.onSurfaceVariant,
          icon: Icon(icon),
          onPressed: onPressed,
        );
    final time = m.time == null ? null : Text(_fmtTime(m.time!), style: small);
    final children = user
        ? [
            ?time,
            btn(Icons.content_copy_rounded, '复制', widget.onCopy),
            btn(Icons.edit_outlined, '编辑并重新发送', widget.busy ? null : widget.onEdit),
            btn(Icons.call_split_rounded, '从这里分支', widget.busy ? null : widget.onBranch),
          ]
        : [
            btn(Icons.content_copy_rounded, '复制', widget.onCopy),
            btn(Icons.refresh_rounded, '重新生成', widget.busy ? null : widget.onRegenerate),
            btn(widget.speaking ? Icons.stop_circle_outlined : Icons.volume_up_outlined,
                widget.speaking ? '停止朗读' : '朗读', widget.onSpeak),
            btn(Icons.call_split_rounded, '从这里分支', widget.busy ? null : widget.onBranch),
            if (m.inputTokens + m.outputTokens > 0) ...[
              const SizedBox(width: 6),
              Text('↑${m.inputTokens} ↓${m.outputTokens}', style: small),
            ],
            if (time != null) ...[const SizedBox(width: 8), time],
          ];
    return Visibility(
      visible: widget.pinActions || _hover,
      maintainSize: true,
      maintainAnimation: true,
      maintainState: true,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: children,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final m = widget.message;
    final cs = Theme.of(context).colorScheme;

    final Widget body;
    if (m.role == Role.user) {
      body = Align(
        alignment: Alignment.centerRight,
        child: Padding(
          padding: const EdgeInsets.only(bottom: 10, left: 48),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            spacing: 2,
            children: [
              Container(
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
                    if (m.quote.isNotEmpty) _QuoteBlock(text: m.quote),
                    if (m.content.isNotEmpty)
                      Text(m.content, style: Theme.of(context).textTheme.bodyLarge),
                  ],
                ),
              ),
              _actions(context, user: true),
            ],
          ),
        ),
      );
    } else {
      body = Container(
        width: double.infinity,
        margin: const EdgeInsets.only(bottom: 14),
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
            if (!widget.streaming && m.content.isNotEmpty && !m.error) _actions(context, user: false),
            if (!widget.streaming && m.error)
              TextButton.icon(
                onPressed: widget.busy ? null : widget.onRegenerate,
                icon: const Icon(Icons.refresh_rounded, size: 18),
                label: const Text('重试'),
              ),
          ],
        ),
      );
    }

    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: body,
    );
  }
}

String _fmtTokens(int n) => n >= 1000 ? '${(n / 1000).toStringAsFixed(1)}k' : '$n';

String _fmtTime(DateTime t) {
  final now = DateTime.now();
  String two(int n) => n.toString().padLeft(2, '0');
  final hm = '${two(t.hour)}:${two(t.minute)}';
  if (t.year == now.year && t.month == now.month && t.day == now.day) return hm;
  if (t.year == now.year) return '${two(t.month)}-${two(t.day)} $hm';
  return '${t.year}-${two(t.month)}-${two(t.day)} $hm';
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

/// The quote waiting above the input box, with a button to drop it.
class _QuotePreview extends StatelessWidget {
  const _QuotePreview({required this.text, required this.onClose});
  final String text;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 8, 4, 8),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2, right: 8),
            child: Icon(Icons.format_quote_rounded, size: 18, color: cs.primary),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                text,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
              ),
            ),
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            iconSize: 18,
            color: cs.onSurfaceVariant,
            icon: const Icon(Icons.close_rounded),
            onPressed: onClose,
          ),
        ],
      ),
    );
  }
}

/// A quote shown inside a sent user message.
class _QuoteBlock extends StatelessWidget {
  const _QuoteBlock({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.only(left: 10),
      decoration: BoxDecoration(
        border: Border(left: BorderSide(color: cs.outline, width: 3)),
      ),
      child: Text(
        text,
        maxLines: 4,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
      ),
    );
  }
}
