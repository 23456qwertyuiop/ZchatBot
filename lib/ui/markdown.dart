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
        final code = (e.children ?? const []).whereType<md.Element>().firstOrNull;
        final cls = code?.attributes['class'] ?? '';
        final lang = cls.startsWith('language-') ? cls.substring(9) : '';
        return _CodeBlock(e.textContent.trimRight(), lang, _mono);
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

class _CodeBlock extends StatefulWidget {
  const _CodeBlock(this.code, this.lang, this.mono);
  final String code;
  final String lang;
  final TextStyle mono;

  @override
  State<_CodeBlock> createState() => _CodeBlockState();
}

class _CodeBlockState extends State<_CodeBlock> {
  bool _copied = false;

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.code));
    if (!mounted) return;
    setState(() => _copied = true);
    await Future<void>.delayed(const Duration(seconds: 2));
    if (mounted) setState(() => _copied = false);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final base = widget.mono.copyWith(fontSize: 13.5, height: 1.5, color: cs.onSurface);
    return Container(
      decoration: BoxDecoration(
        color: cs.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(16),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            color: cs.surfaceContainerHighest,
            padding: const EdgeInsets.fromLTRB(16, 2, 4, 2),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    widget.lang.isEmpty ? 'code' : widget.lang,
                    style: Theme.of(context).textTheme.labelMedium?.copyWith(color: cs.onSurfaceVariant),
                  ),
                ),
                TextButton.icon(
                  style: TextButton.styleFrom(
                    foregroundColor: cs.onSurfaceVariant,
                    visualDensity: VisualDensity.compact,
                  ),
                  onPressed: _copy,
                  icon: Icon(_copied ? Icons.check_rounded : Icons.content_copy_rounded, size: 16),
                  label: Text(_copied ? '已复制' : '复制'),
                ),
              ],
            ),
          ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
            child: Text.rich(
              TextSpan(style: base, children: highlightCode(widget.code, widget.lang, dark)),
            ),
          ),
        ],
      ),
    );
  }
}

// ------------------------------------------------------------- highlighting

const _keywords = {
  // C family, Java, JS/TS, Dart, Go, Rust, Swift, Kotlin, C#
  'abstract', 'as', 'async', 'await', 'break', 'case', 'catch', 'class', 'const', 'continue',
  'default', 'defer', 'do', 'else', 'enum', 'export', 'extends', 'extension', 'final', 'finally',
  'for', 'func', 'fn', 'fun', 'function', 'go', 'goto', 'if', 'impl', 'implements', 'import', 'in',
  'interface', 'is', 'late', 'let', 'match', 'mixin', 'mod', 'module', 'mut', 'namespace', 'new',
  'override', 'package', 'private', 'protected', 'pub', 'public', 'required', 'return', 'sealed',
  'select', 'static', 'struct', 'super', 'switch', 'this', 'throw', 'throws', 'trait', 'try',
  'type', 'typedef', 'typeof', 'use', 'val', 'var', 'void', 'when', 'where', 'while', 'with',
  'yield', 'chan', 'range', 'unsafe', 'readonly', 'declare', 'keyof', 'instanceof',
  'delete', 'of', 'from', 'operator', 'inline', 'virtual', 'template', 'typename',
  'using', 'guard', 'protocol', 'self', 'Self',
  // Python, Ruby, shell
  'and', 'or', 'not', 'def', 'del', 'elif', 'except', 'global', 'lambda', 'nonlocal', 'pass',
  'raise', 'assert', 'end', 'then', 'fi', 'esac', 'done', 'echo', 'local', 'unless', 'until',
  'begin', 'rescue', 'ensure', 'elsif', 'require',
  // SQL
  'SELECT', 'FROM', 'WHERE', 'INSERT', 'INTO', 'VALUES', 'UPDATE', 'SET', 'DELETE', 'CREATE',
  'TABLE', 'JOIN', 'LEFT', 'RIGHT', 'INNER', 'OUTER', 'ON', 'GROUP', 'BY', 'ORDER', 'LIMIT',
  'AND', 'OR', 'NOT', 'NULL', 'AS', 'DISTINCT', 'HAVING', 'PRIMARY', 'KEY', 'INDEX', 'DROP',
  'ALTER', 'UNION', 'CASE', 'WHEN', 'THEN', 'ELSE', 'END', 'IS', 'IN', 'LIKE',
  // literals
  'true', 'false', 'null', 'nil', 'None', 'True', 'False', 'undefined', 'NaN',
};

const _hashComments = {
  'python', 'py', 'sh', 'bash', 'shell', 'zsh', 'console', 'yaml', 'yml', 'toml', 'ruby', 'rb',
  'r', 'perl', 'makefile', 'make', 'dockerfile', 'ini', 'conf', 'powershell', 'ps1', 'nginx',
};
const _dashComments = {'sql', 'lua', 'haskell', 'hs'};
const _markupComments = {'html', 'xml', 'svg', 'vue', 'markdown', 'md'};

// Strings: triple-quoted, double, single and backtick literals.
const _stringPattern = r'"""[\s\S]*?"""|' r"'''[\s\S]*?'''|" r'"(?:\\.|[^"\\\n])*"|'
    r"'(?:\\.|[^'\\\n])*'|" r'`(?:\\.|[^`\\])*`';
const _numberPattern = r'\b(?:0[xX][0-9a-fA-F]+|\d[\d_]*(?:\.\d+)?(?:[eE][+-]?\d+)?)\b';
const _wordPattern = r'[A-Za-z_$][\w$]*';

/// A small, dependency-free highlighter good enough for chat answers.
List<TextSpan> highlightCode(String code, String lang, bool dark) {
  final l = lang.toLowerCase();
  final keyword = dark ? const Color(0xFFFF7B72) : const Color(0xFFCF222E);
  final string = dark ? const Color(0xFFA5D6FF) : const Color(0xFF0A3069);
  final number = dark ? const Color(0xFF79C0FF) : const Color(0xFF0550AE);
  final comment = dark ? const Color(0xFF8B949E) : const Color(0xFF6E7781);
  final function = dark ? const Color(0xFFD2A8FF) : const Color(0xFF8250DF);
  final type = dark ? const Color(0xFFFFA657) : const Color(0xFF953800);

  final hash = _hashComments.contains(l);
  final dash = _dashComments.contains(l);
  final comments = <String>[
    if (!hash && !dash) r'//[^\n]*',
    if (!hash) r'/\*[\s\S]*?\*/',
    if (hash) r'#[^\n]*',
    if (dash) r'--[^\n]*',
    if (_markupComments.contains(l)) r'<!--[\s\S]*?-->',
  ];
  final re = RegExp('(?<c>${comments.join('|')})|(?<s>$_stringPattern)|(?<n>$_numberPattern)|(?<w>$_wordPattern)');

  final out = <TextSpan>[];
  var last = 0;
  for (final m in re.allMatches(code)) {
    if (m.end == m.start) continue;
    if (m.start > last) out.add(TextSpan(text: code.substring(last, m.start)));
    final text = m.group(0)!;
    Color? color;
    var italic = false;
    if (m.namedGroup('c') != null) {
      color = comment;
      italic = true;
    } else if (m.namedGroup('s') != null) {
      color = string;
    } else if (m.namedGroup('n') != null) {
      color = number;
    } else if (_keywords.contains(text)) {
      color = keyword;
    } else if (m.end < code.length && code[m.end] == '(') {
      color = function;
    } else if (text.length > 1 && RegExp(r'^[A-Z]').hasMatch(text)) {
      color = type;
    }
    out.add(TextSpan(
      text: text,
      style: color == null ? null : TextStyle(color: color, fontStyle: italic ? FontStyle.italic : null),
    ));
    last = m.end;
  }
  if (last < code.length) out.add(TextSpan(text: code.substring(last)));
  return out;
}
