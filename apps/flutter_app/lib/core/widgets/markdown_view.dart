import 'package:flutter/gestures.dart';
import 'package:flutter_math_fork/flutter_math.dart' show Math, MathStyle;
import 'package:markdown/markdown.dart' as md;
import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';

import 'code_block.dart';
import 'markdown_math.dart';

/// Renders GitHub-flavoured Markdown (headings, emphasis, links, lists, task
/// lists, block quotes, tables, inline code and highlighted code blocks) and
/// TeX math (`$...$`, `$$...$$`, `\(...\)`, `\[...\]`) as typeset formulas with
/// the app's Material theme. Wrap in a `SelectionArea` to make it selectable.
class MarkdownView extends StatefulWidget {
  const MarkdownView({super.key, required this.data, this.style});

  final String data;
  final TextStyle? style;

  @override
  State<MarkdownView> createState() => _MarkdownViewState();
}

class _MarkdownViewState extends State<MarkdownView> {
  late List<md.Node> _nodes = _parse(widget.data);
  List<TapGestureRecognizer> _recognizers = [];

  static List<md.Node> _parse(String data) => md.Document(
    extensionSet: md.ExtensionSet.gitHubFlavored,
    blockSyntaxes: mathBlockSyntaxes,
    inlineSyntaxes: mathInlineSyntaxes,
    encodeHtml: false,
  ).parse(data);

  @override
  void didUpdateWidget(MarkdownView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.data != widget.data) _nodes = _parse(widget.data);
  }

  @override
  void dispose() {
    for (final recognizer in _recognizers) {
      recognizer.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Recognizers from the previous build stay alive until that frame is gone.
    final previous = _recognizers;
    _recognizers = [];
    WidgetsBinding.instance.addPostFrameCallback((_) {
      for (final recognizer in previous) {
        recognizer.dispose();
      }
    });

    final theme = Theme.of(context);
    final base = widget.style ?? theme.textTheme.bodyLarge!.copyWith(height: 1.55);
    final builder = _MarkdownBuilder(theme: theme, base: base, recognizers: _recognizers);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: builder.blocks(_nodes));
  }
}

const _blockTags = {
  'p',
  'h1',
  'h2',
  'h3',
  'h4',
  'h5',
  'h6',
  'pre',
  'ul',
  'ol',
  'blockquote',
  'hr',
  'table',
  mathBlockTag,
};

Future<void> openExternalLink(String? href) async {
  final uri = href == null ? null : Uri.tryParse(href);
  // Only web links: never javascript:, file: or app-specific schemes from model output.
  if (uri == null || !(uri.scheme == 'http' || uri.scheme == 'https')) return;
  await launchUrl(uri, mode: LaunchMode.externalApplication);
}

class _MarkdownBuilder {
  _MarkdownBuilder({required this.theme, required this.base, required this.recognizers});

  final ThemeData theme;
  final TextStyle base;
  final List<TapGestureRecognizer> recognizers;

  ColorScheme get scheme => theme.colorScheme;

  List<Widget> blocks(List<md.Node> nodes, {int depth = 0, double spacing = 12}) {
    final widgets = <Widget>[];
    final inline = <md.Node>[];
    void flushInline() {
      if (inline.isEmpty) return;
      widgets.add(_text(List.of(inline), base));
      inline.clear();
    }

    for (final node in nodes) {
      if (node is md.Element && _blockTags.contains(node.tag)) {
        flushInline();
        widgets.add(_block(node, depth));
      } else {
        inline.add(node);
      }
    }
    flushInline();
    return [
      for (var i = 0; i < widgets.length; i++) ...[if (i > 0) SizedBox(height: spacing), widgets[i]],
    ];
  }

  Widget _block(md.Element element, int depth) {
    final children = element.children ?? const <md.Node>[];
    return switch (element.tag) {
      'h1' => _text(children, _heading(1.45)),
      'h2' => _text(children, _heading(1.3)),
      'h3' => _text(children, _heading(1.15)),
      'h4' || 'h5' || 'h6' => _text(children, _heading(1.0)),
      'pre' => _codeBlock(element),
      'ul' || 'ol' => _list(element, depth),
      'blockquote' => Container(
        padding: const EdgeInsets.only(left: 14),
        decoration: BoxDecoration(
          border: Border(left: BorderSide(color: scheme.outlineVariant, width: 3)),
        ),
        child: DefaultTextStyle.merge(
          style: TextStyle(color: scheme.onSurfaceVariant),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: blocks(children, depth: depth),
          ),
        ),
      ),
      'hr' => const Divider(height: 16),
      'table' => _table(element),
      mathBlockTag => _displayMath(mathSource(element)),
      _ => _text(children, base),
    };
  }

  /// A formula on its own line: centred, and scrollable when wider than the reply.
  Widget _displayMath(String tex) => LayoutBuilder(
    builder: (context, constraints) => SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: ConstrainedBox(
        constraints: BoxConstraints(minWidth: constraints.maxWidth),
        child: Center(
          child: Padding(padding: const EdgeInsets.symmetric(vertical: 4), child: _math(tex, MathStyle.display, base)),
        ),
      ),
    ),
  );

  Widget _math(String tex, MathStyle mathStyle, TextStyle style) => Math.tex(
    tex,
    mathStyle: mathStyle,
    textStyle: style.copyWith(color: style.color ?? scheme.onSurface),
    // TeX the renderer cannot handle stays readable as its source.
    onErrorFallback: (_) => Text(tex, style: style.copyWith(fontFamily: monospaceFamily)),
  );

  TextStyle _heading(double scale) =>
      base.copyWith(fontSize: (base.fontSize ?? 16) * scale, fontWeight: FontWeight.w700, height: 1.3);

  Widget _text(List<md.Node> nodes, TextStyle style) =>
      Text.rich(TextSpan(style: style, children: _inlines(nodes, style)));

  List<InlineSpan> _inlines(List<md.Node> nodes, TextStyle style) => [
    for (final node in nodes) ..._inline(node, style),
  ];

  List<InlineSpan> _inline(md.Node node, TextStyle style) {
    if (node is md.Text) return [TextSpan(text: node.text, style: style)];
    if (node is! md.Element) return [TextSpan(text: node.textContent, style: style)];
    final children = node.children ?? const <md.Node>[];
    switch (node.tag) {
      case 'strong':
        return _inlines(children, style.copyWith(fontWeight: FontWeight.w700));
      case 'em':
        return _inlines(children, style.copyWith(fontStyle: FontStyle.italic));
      case 'del':
        return _inlines(children, style.copyWith(decoration: TextDecoration.lineThrough));
      case 'code':
        return [
          TextSpan(
            text: node.textContent,
            style: style.copyWith(
              fontFamily: monospaceFamily,
              fontFamilyFallback: monospaceFallback,
              fontSize: (style.fontSize ?? 16) * 0.9,
              backgroundColor: scheme.surfaceContainerHighest,
            ),
          ),
        ];
      case 'br':
        return [const TextSpan(text: '\n')];
      case 'a':
        return [_link(node.textContent, node.attributes['href'], style)];
      case 'img':
        final alt = node.attributes['alt'];
        return [_link(alt == null || alt.isEmpty ? 'image' : alt, node.attributes['src'], style)];
      case 'input': // GitHub task-list checkbox
        return [TextSpan(text: node.attributes.containsKey('checked') ? '☑ ' : '☐ ', style: style)];
      case mathTag:
        return [
          WidgetSpan(
            alignment: PlaceholderAlignment.baseline,
            baseline: TextBaseline.alphabetic,
            child: _math(
              mathSource(node),
              isDisplayMath(node) || hasTallParts(mathSource(node)) ? MathStyle.display : MathStyle.text,
              style,
            ),
          ),
        ];
      default:
        return _inlines(children, style);
    }
  }

  TextSpan _link(String text, String? href, TextStyle style) {
    final recognizer = TapGestureRecognizer()..onTap = () => openExternalLink(href);
    recognizers.add(recognizer);
    return TextSpan(
      text: text,
      recognizer: recognizer,
      mouseCursor: SystemMouseCursors.click,
      style: style.copyWith(color: scheme.primary, decoration: TextDecoration.underline),
    );
  }

  Widget _codeBlock(md.Element pre) {
    final code = pre.children?.whereType<md.Element>().where((e) => e.tag == 'code').firstOrNull;
    final source = (code ?? pre).textContent.replaceFirst(RegExp(r'\n$'), '');
    final className = code?.attributes['class'] ?? '';
    final language = className.startsWith('language-') ? className.substring('language-'.length) : null;
    return CodeBlock(code: source, language: language);
  }

  Widget _list(md.Element list, int depth) {
    final ordered = list.tag == 'ol';
    var number = int.tryParse(list.attributes['start'] ?? '') ?? 1;
    final items = <Widget>[];
    for (final item in (list.children ?? const <md.Node>[]).whereType<md.Element>()) {
      if (item.tag != 'li') continue;
      // Task-list items already start with a checkbox; GitHub shows no bullet.
      final isTask = item.attributes['class']?.contains('task-list-item') ?? false;
      final marker = ordered ? '${number++}.' : (isTask ? '' : (depth.isEven ? '•' : '◦'));
      items.add(
        Row(
          // The marker sits on the first line's baseline, also when a formula
          // makes that line taller.
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            SizedBox(
              width: ordered ? 28 : 18,
              child: Text(marker, style: base, textAlign: TextAlign.right),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: blocks(item.children ?? const [], depth: depth + 1, spacing: 6),
              ),
            ),
          ],
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < items.length; i++) ...[if (i > 0) const SizedBox(height: 6), items[i]],
      ],
    );
  }

  Widget _table(md.Element table) {
    final rows = <(bool, List<md.Element>)>[];
    for (final section in (table.children ?? const <md.Node>[]).whereType<md.Element>()) {
      for (final row in (section.children ?? const <md.Node>[]).whereType<md.Element>()) {
        if (row.tag != 'tr') continue;
        rows.add((section.tag == 'thead', (row.children ?? const <md.Node>[]).whereType<md.Element>().toList()));
      }
    }
    if (rows.isEmpty) return const SizedBox.shrink();
    final columns = rows.map((r) => r.$2.length).reduce((a, b) => a > b ? a : b);
    final header = base.copyWith(fontWeight: FontWeight.w700);

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Table(
        defaultColumnWidth: const IntrinsicColumnWidth(),
        border: TableBorder.all(color: scheme.outlineVariant, borderRadius: BorderRadius.circular(8)),
        children: [
          for (final (isHeader, cells) in rows)
            TableRow(
              decoration: isHeader ? BoxDecoration(color: scheme.surfaceContainerHigh) : null,
              children: [
                for (var i = 0; i < columns; i++)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 320),
                      child: i < cells.length
                          ? _text(cells[i].children ?? const [], isHeader ? header : base)
                          : const SizedBox.shrink(),
                    ),
                  ),
              ],
            ),
        ],
      ),
    );
  }
}
