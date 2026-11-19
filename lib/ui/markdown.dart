import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';

/// A small GitHub-flavoured Markdown renderer built on material_ui only.
/// Text is selectable when an ancestor [SelectionArea] exists.
class MarkdownView extends StatefulWidget {
  const MarkdownView(this.data, {super.key});
  final String data;

  @override
  State<MarkdownView> createState() => _MarkdownViewState();
}

const _inline = {'strong', 'b', 'em', 'i', 'del', 'code', 'a', 'br', 'img', 'span', 'sup', 'sub', 'input'};

class _MarkdownViewState extends State<MarkdownView> {
  final _recognizers = <TapGestureRecognizer>[];
  late TextTheme _text;
  late ColorScheme _cs;

  @override
  void dispose() {
    _clear();
    super.dispose();
  }

  void _clear() {
    for (final r in _recognizers) {
      r.dispose();
    }
    _recognizers.clear();
  }

  @override
  Widget build(BuildContext context) {
    _clear();
    _text = Theme.of(context).textTheme;
    _cs = Theme.of(context).colorScheme;
    final nodes = md.Document(
      extensionSet: md.ExtensionSet.gitHubFlavored,
      encodeHtml: false,
    ).parse(widget.data);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 12,
      children: _blocks(nodes),
    );
  }

  TextStyle get _body => _text.bodyLarge!.copyWith(height: 1.6);
  TextStyle get _mono => const TextStyle(fontFamily: 'monospace', fontFamilyFallback: ['Menlo', 'Roboto Mono', 'Courier']);

  List<Widget> _blocks(List<md.Node> nodes) {
    final out = <Widget>[];
    final run = <md.Node>[];
    void flush() {
      if (run.isEmpty) return;
      out.add(_paragraph(List.of(run), _body));
      run.clear();
    }

    for (final n in nodes) {
      if (n is md.Text || (n is md.Element && _inline.contains(n.tag))) {
        run.add(n);
      } else {
        flush();
        out.add(_block(n as md.Element));
      }
    }
    flush();
    return out;
  }

  Widget _block(md.Element e) {
    switch (e.tag) {
      case 'p':
        return _paragraph(e.children ?? const [], _body);
      case 'h1' || 'h2' || 'h3' || 'h4' || 'h5' || 'h6':
        final style = switch (e.tag) {
          'h1' => _text.headlineSmall,
          'h2' => _text.titleLarge,
          'h3' => _text.titleMedium,
          _ => _text.titleSmall,
        }!
            .copyWith(fontWeight: FontWeight.w600);
        return Padding(
          padding: const EdgeInsets.only(top: 4),
          child: _paragraph(e.children ?? const [], style),
        );
      case 'ul' || 'ol':
        final ordered = e.tag == 'ol';
        final start = int.tryParse(e.attributes['start'] ?? '') ?? 1;
        final items = (e.children ?? const []).whereType<md.Element>().toList();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 6,
          children: [
            for (var i = 0; i < items.length; i++)
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 28,
                    child: Text(ordered ? '${start + i}.' : '•',
                        style: _body.copyWith(color: _cs.onSurfaceVariant)),
                  ),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      spacing: 6,
                      children: _blocks(items[i].children ?? const []),
                    ),
                  ),
                ],
              ),
          ],
        );
      case 'pre':
        return _CodeBlock(e.textContent.trimRight(), _mono);
      case 'blockquote':
        return Container(
          padding: const EdgeInsets.only(left: 14),
          decoration: BoxDecoration(
            border: Border(left: BorderSide(color: _cs.outlineVariant, width: 3)),
          ),
          child: DefaultTextStyle.merge(
            style: TextStyle(color: _cs.onSurfaceVariant),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              spacing: 8,
              children: _blocks(e.children ?? const []),
            ),
          ),
        );
      case 'hr':
        return Divider(color: _cs.outlineVariant);
      case 'table':
        return _table(e);
      default:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 8,
          children: _blocks(e.children ?? const []),
        );
    }
  }

  Widget _paragraph(List<md.Node> nodes, TextStyle style) =>
      Text.rich(TextSpan(style: style, children: [for (final n in nodes) _span(n, style)]));

  InlineSpan _span(md.Node n, TextStyle s) {
    if (n is md.Text) return TextSpan(text: n.text);
    final e = n as md.Element;
    List<InlineSpan> kids(TextStyle st) => [for (final c in e.children ?? const <md.Node>[]) _span(c, st)];
    switch (e.tag) {
      case 'strong' || 'b':
        final st = s.copyWith(fontWeight: FontWeight.w600);
        return TextSpan(style: st, children: kids(st));
      case 'em' || 'i':
        final st = s.copyWith(fontStyle: FontStyle.italic);
        return TextSpan(style: st, children: kids(st));
      case 'del':
        final st = s.copyWith(decoration: TextDecoration.lineThrough);
        return TextSpan(style: st, children: kids(st));
      case 'code':
        return TextSpan(
          text: e.textContent,
          style: _mono.copyWith(
            fontSize: (s.fontSize ?? 16) * 0.9,
            backgroundColor: _cs.surfaceContainerHighest,
          ),
        );
      case 'a':
        final href = e.attributes['href'] ?? '';
        final r = TapGestureRecognizer()
          ..onTap = () => launchUrl(Uri.parse(href), mode: LaunchMode.externalApplication);
        _recognizers.add(r);
        final st = s.copyWith(color: _cs.primary, decoration: TextDecoration.underline, decorationColor: _cs.primary);
        return TextSpan(style: st, recognizer: r, children: kids(st));
      case 'br':
        return const TextSpan(text: '\n');
      case 'img':
        return TextSpan(text: e.attributes['alt'] ?? '');
      case 'input':
        return TextSpan(text: e.attributes['checked'] != null ? '☑ ' : '☐ ');
      default:
        return TextSpan(children: kids(s));
    }
  }

  Widget _table(md.Element e) {
    final rows = <md.Element>[];
    void collect(md.Element el) {
      for (final c in (el.children ?? const []).whereType<md.Element>()) {
        c.tag == 'tr' ? rows.add(c) : collect(c);
      }
    }

    collect(e);
    if (rows.isEmpty) return const SizedBox.shrink();
    final cols = rows.map((r) => r.children?.length ?? 0).reduce((a, b) => a > b ? a : b);
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Table(
        defaultColumnWidth: const IntrinsicColumnWidth(),
        border: TableBorder.all(color: _cs.outlineVariant, borderRadius: BorderRadius.circular(8)),
        children: [
          for (final r in rows)
            TableRow(
              decoration: r == rows.first ? BoxDecoration(color: _cs.surfaceContainerHigh) : null,
              children: [
                for (var i = 0; i < cols; i++)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    child: i < (r.children?.length ?? 0)
                        ? _paragraph((r.children![i] as md.Element).children ?? const [],
                            r == rows.first ? _body.copyWith(fontWeight: FontWeight.w600) : _body)
                        : const SizedBox.shrink(),
                  ),
              ],
            ),
        ],
      ),
    );
  }
}

class _CodeBlock extends StatelessWidget {
  const _CodeBlock(this.code, this.mono);
  final String code;
  final TextStyle mono;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: cs.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Stack(
        children: [
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(16, 14, 48, 14),
            child: Text(code, style: mono.copyWith(fontSize: 13.5, height: 1.5, color: cs.onSurface)),
          ),
          Positioned(
            top: 4,
            right: 4,
            child: IconButton(
              iconSize: 18,
              icon: const Icon(Icons.content_copy_rounded),
              color: cs.onSurfaceVariant,
              onPressed: () => Clipboard.setData(ClipboardData(text: code)),
            ),
          ),
        ],
      ),
    );
  }
}
