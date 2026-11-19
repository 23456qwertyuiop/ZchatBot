import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../core/models.dart';
import '../core/store.dart';
import 'markdown.dart';
import 'scope.dart';

/// Sends one question to several models and shows the answers side by side.
class ComparePage extends StatefulWidget {
  const ComparePage({super.key});

  @override
  State<ComparePage> createState() => _ComparePageState();
}

class _Slot {
  _Slot(this.provider, this.model);
  Provider provider;
  String model;
  Message answer = Message(Role.assistant);
  bool running = false;
  Completer<void>? abort;
}

class _ComparePageState extends State<ComparePage> {
  final _input = TextEditingController();
  final _pages = PageController(viewportFraction: 0.92);
  final List<_Slot> _slots = [];
  String _question = '';

  List<(Provider, String)> _all(AppStore store) => [
        for (final p in store.settings.providers)
          for (final m in p.models) (p, m),
      ];

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_slots.isNotEmpty) return;
    final store = Scope.read(context);
    final all = _all(store);
    final first = store.modelFor(store.current);
    if (first != null) _slots.add(_Slot(first.$1, first.$2));
    final other = all.where((x) => first == null || x.$1 != first.$1 || x.$2 != first.$2).firstOrNull;
    if (other != null) _slots.add(_Slot(other.$1, other.$2));
  }

  @override
  void dispose() {
    for (final s in _slots) {
      s.abort?.complete();
    }
    _input.dispose();
    _pages.dispose();
    super.dispose();
  }

  bool get _busy => _slots.any((s) => s.running);

  void _run(AppStore store) {
    final q = _input.text.trim();
    if (q.isEmpty || _busy || _slots.isEmpty) return;
    setState(() => _question = q);
    for (final s in _slots) {
      _ask(store, s, q);
    }
  }

  Future<void> _ask(AppStore store, _Slot s, String q) async {
    final answer = Message(Role.assistant);
    setState(() {
      s
        ..answer = answer
        ..running = true
        ..abort = Completer<void>();
    });
    try {
      await for (final t in store.llm.chat(
        provider: s.provider,
        model: s.model,
        system: store.systemPrompt(),
        history: [Message(Role.user, q)],
        abort: s.abort!.future,
      )) {
        if (!mounted) return;
        setState(() {
          answer
            ..content = t.text
            ..reasoning = t.reasoning
            ..inputTokens = t.inputTokens
            ..outputTokens = t.outputTokens;
        });
      }
    } catch (e) {
      answer
        ..error = true
        ..content = '$e';
    } finally {
      if (mounted) setState(() => s.running = false);
    }
  }

  void _stop() {
    for (final s in _slots) {
      if (s.abort?.isCompleted == false) s.abort!.complete();
    }
  }

  void _continueWith(AppStore store, _Slot s) {
    store.startFrom(_question, s.answer, s.provider, s.model);
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final store = Scope.of(context);
    final all = _all(store);
    final wide = MediaQuery.sizeOf(context).width >= 720;

    final columns = [
      for (var i = 0; i < _slots.length; i++)
        _SlotView(
          slot: _slots[i],
          options: all,
          canRemove: _slots.length > 1 && !_busy,
          canContinue: _question.isNotEmpty && !_slots[i].running && _slots[i].answer.content.isNotEmpty && !_slots[i].answer.error,
          onModel: (x) => setState(() {
            _slots[i]
              ..provider = x.$1
              ..model = x.$2;
          }),
          onRemove: () => setState(() => _slots.removeAt(i)),
          onContinue: () => _continueWith(store, _slots[i]),
        ),
    ];

    return Scaffold(
      appBar: AppBar(
        title: const Text('模型对比'),
        actions: [
          if (_slots.length < 4 && all.isNotEmpty && !_busy)
            TextButton.icon(
              onPressed: () => setState(() => _slots.add(_Slot(all.first.$1, all.first.$2))),
              icon: const Icon(Icons.add, size: 18),
              label: const Text('添加模型'),
            ),
          const SizedBox(width: 8),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: all.isEmpty
                  ? const Center(child: Text('请先在设置中添加模型'))
                  : wide
                      ? Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            spacing: 12,
                            children: [for (final c in columns) Expanded(child: c)],
                          ),
                        )
                      : PageView(
                          controller: _pages,
                          children: [
                            for (final c in columns)
                              Padding(padding: const EdgeInsets.symmetric(horizontal: 6), child: c),
                          ],
                        ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              child: Row(
                spacing: 8,
                children: [
                  Expanded(
                    child: TextField(
                      controller: _input,
                      minLines: 1,
                      maxLines: 5,
                      decoration: const InputDecoration(
                        hintText: '输入问题，同时发送给以上模型',
                        contentPadding: EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                      ),
                      onSubmitted: (_) => _run(store),
                    ),
                  ),
                  SizedBox(
                    width: 56,
                    height: 56,
                    child: IconButton.filled(
                      icon: Icon(_busy ? Icons.stop_rounded : Icons.arrow_upward),
                      onPressed: _busy ? _stop : () => _run(store),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SlotView extends StatelessWidget {
  const _SlotView({
    required this.slot,
    required this.options,
    required this.canRemove,
    required this.canContinue,
    required this.onModel,
    required this.onRemove,
    required this.onContinue,
  });

  final _Slot slot;
  final List<(Provider, String)> options;
  final bool canRemove;
  final bool canContinue;
  final ValueChanged<(Provider, String)> onModel;
  final VoidCallback onRemove;
  final VoidCallback onContinue;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final a = slot.answer;
    return Container(
      decoration: BoxDecoration(
        color: cs.surfaceContainerLow,
        borderRadius: BorderRadius.circular(20),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 4, 4),
            child: Row(
              children: [
                Expanded(
                  child: MenuAnchor(
                    builder: (context, controller, _) => ActionChip(
                      label: Text('${slot.provider.name} · ${slot.model}',
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                      onPressed: slot.running
                          ? null
                          : () => controller.isOpen ? controller.close() : controller.open(),
                    ),
                    menuChildren: [
                      for (final o in options)
                        MenuItemButton(
                          onPressed: () => onModel(o),
                          child: Text('${o.$1.name} · ${o.$2}'),
                        ),
                    ],
                  ),
                ),
                if (canContinue)
                  IconButton(
                    tooltip: '用此回答继续对话',
                    icon: const Icon(Icons.forum_outlined, size: 20),
                    onPressed: onContinue,
                  ),
                if (canRemove)
                  IconButton(
                    icon: const Icon(Icons.close, size: 20),
                    onPressed: onRemove,
                  ),
              ],
            ),
          ),
          Expanded(
            child: SelectionArea(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                children: [
                  if (a.content.isEmpty && slot.running)
                    const Align(
                      alignment: Alignment.centerLeft,
                      child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                    )
                  else if (a.error)
                    Text(a.content, style: TextStyle(color: cs.error))
                  else if (a.content.isNotEmpty)
                    MarkdownView(a.content),
                  if (!slot.running && a.outputTokens > 0)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        '↑${a.inputTokens} ↓${a.outputTokens}',
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(color: cs.onSurfaceVariant),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
