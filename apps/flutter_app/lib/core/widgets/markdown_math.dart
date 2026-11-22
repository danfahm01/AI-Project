import 'package:markdown/markdown.dart' as md;

/// TeX math in model replies, the way models write it:
///
/// * display math on its own lines: `$$ ... $$` or `\[ ... \]` (block element
///   [mathBlockTag]);
/// * math inside a sentence: `$...$`, `\(...\)`, and `$$...$$` or `\[...\]`
///   within a line (inline element [mathTag]; `display="true"` for the latter two).
///
/// Both run before Markdown's own syntax, so `_`, `*` and `\` inside the TeX are
/// not taken as emphasis or escapes. Code spans and code blocks stay code.
const mathTag = 'math';
const mathBlockTag = 'math-block';

/// The TeX source of a [mathTag] or [mathBlockTag] element.
String mathSource(md.Element element) => element.textContent;

/// Whether a [mathTag] element is display math written inside a line.
bool isDisplayMath(md.Element element) => element.attributes['display'] == 'true';

final _tallParts = RegExp(r'\\(frac|dfrac|lim|int|iint|oint|sum|prod|binom)(?![A-Za-z])');

/// Whether math within a line has parts that TeX sets at script size there
/// (fractions, limits, integral and sum bounds). On a phone those are too small
/// to read, so the app sets them at full size, as on their own line.
bool hasTallParts(String tex) => _tallParts.hasMatch(tex);

final mathBlockSyntaxes = <md.BlockSyntax>[const DisplayMathBlockSyntax()];
final mathInlineSyntaxes = <md.InlineSyntax>[
  _MathSyntax(r'\$\$([\s\S]+?)\$\$', display: true),
  _MathSyntax(r'\\\[([\s\S]+?)\\\]', display: true),
  _MathSyntax(r'\\\(([\s\S]+?)\\\)', display: false),
  // Like Pandoc: no space just inside the dollars and no digit right after the
  // closing one, so prices ("$5 and $10") stay text.
  _MathSyntax(r'\$(?![\s$])((?:\\.|[^$\\\n])+?)(?<!\s)\$(?!\d)', display: false),
];

class _MathSyntax extends md.InlineSyntax {
  _MathSyntax(super.pattern, {required this.display});

  final bool display;

  @override
  bool onMatch(md.InlineParser parser, Match match) {
    final tex = match[1]!.trim();
    if (tex.isEmpty) return false;
    final element = md.Element.text(mathTag, tex);
    if (display) element.attributes['display'] = 'true';
    parser.addNode(element);
    return true;
  }
}

/// Display math that starts a line with `$$` or `\[` and ends a line (the same
/// one or a later one) with `$$` or `\]`. Interrupts a paragraph, like a code fence.
class DisplayMathBlockSyntax extends md.BlockSyntax {
  const DisplayMathBlockSyntax();

  static final _opening = RegExp(r'^ {0,3}(\$\$|\\\[)(.*)$');

  @override
  RegExp get pattern => _opening;

  static String _closing(String opening) => opening == r'$$' ? r'$$' : r'\]';

  /// The TeX of the block starting at the current line and the number of lines
  /// it spans, or null when the current line does not start one.
  static (String, int)? _scan(md.BlockParser parser) {
    final match = _opening.firstMatch(parser.current.content);
    if (match == null) return null;
    final closing = _closing(match[1]!);
    final lines = <String>[];
    var rest = match[2]!;
    for (var offset = 0; ; offset++) {
      if (offset > 0) {
        final line = parser.peek(offset);
        // A blank line or the end of the reply before the closing delimiter:
        // not display math after all.
        if (line == null || line.isBlankLine) return null;
        rest = line.content;
      }
      final end = rest.indexOf(closing);
      if (end >= 0) {
        // Text after the closing delimiter: math within a line (inline syntax).
        if (rest.substring(end + closing.length).trim().isNotEmpty) return null;
        lines.add(rest.substring(0, end));
        final tex = lines.join('\n').trim();
        return tex.isEmpty ? null : (tex, offset + 1);
      }
      lines.add(rest);
    }
  }

  @override
  bool canParse(md.BlockParser parser) => _scan(parser) != null;

  @override
  md.Node? parse(md.BlockParser parser) {
    final (tex, lineCount) = _scan(parser)!;
    for (var i = 0; i < lineCount; i++) {
      parser.advance();
    }
    return md.Element.text(mathBlockTag, tex);
  }
}
