import 'package:flutter_math_fork/flutter_math.dart' show Math;
import 'package:flutter_test/flutter_test.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:voice_assistant/core/theme/app_theme.dart';
import 'package:voice_assistant/core/widgets/markdown_math.dart';

import 'markdown_test.dart' show allText, pumpMarkdown;

List<md.Node> parse(String data) => md.Document(
  extensionSet: md.ExtensionSet.gitHubFlavored,
  blockSyntaxes: mathBlockSyntaxes,
  inlineSyntaxes: mathInlineSyntaxes,
  encodeHtml: false,
).parse(data);

/// Every element with [tag], depth first.
List<md.Element> elements(List<md.Node> nodes, String tag) => [
  for (final node in nodes.whereType<md.Element>()) ...[
    if (node.tag == tag) node,
    ...elements(node.children ?? const [], tag),
  ],
];

List<String> blockMath(String data) => [for (final e in elements(parse(data), mathBlockTag)) mathSource(e)];
List<String> inlineMath(String data) => [for (final e in elements(parse(data), mathTag)) mathSource(e)];

void main() {
  group('display math', () {
    test(r'a $$ line right after text becomes its own block', () {
      final nodes = parse('Hitunglah nilai dari:\n\$\$\\lim_{x \\to 3} \\frac{x^2 - 9}{x - 3}\$\$');
      expect(nodes.map((n) => (n as md.Element).tag), ['p', mathBlockTag]);
      expect(nodes.first.textContent, 'Hitunglah nilai dari:');
      expect(mathSource(nodes.last as md.Element), r'\lim_{x \to 3} \frac{x^2 - 9}{x - 3}');
    });

    test('spans several lines and keeps backslashes, underscores and stars', () {
      expect(blockMath('\$\$\n\\int_{0}^{2} (3x^2 - 2x) \\, dx\n= a_1 * b_2 \\\\\n\$\$'), [
        '\\int_{0}^{2} (3x^2 - 2x) \\, dx\n= a_1 * b_2 \\\\',
      ]);
    });

    test(r'\[ ... \] works like $$ ... $$', () {
      expect(blockMath('\\[\n\\frac{5}{2}\n\\]'), [r'\frac{5}{2}']);
      expect(blockMath(r'\[ x^2 \]'), ['x^2']);
    });

    test('works inside list items', () {
      expect(blockMath('1. Hitung:\n   \$\$x^2\$\$\n2. Lagi'), ['x^2']);
    });

    test('an unclosed block stays text', () {
      expect(blockMath('\$\$\nx^2\n\nmore text'), isEmpty);
      expect(blockMath('\$\$ x^2'), isEmpty);
    });
  });

  group('math within a line', () {
    test(r'$...$ and \(...\)', () {
      expect(inlineMath(r'Jadi hasilnya $2x^3 - 2x^2 + 5x + C$ dan \(\frac{5}{2}\).'), [
        '2x^3 - 2x^2 + 5x + C',
        r'\frac{5}{2}',
      ]);
    });

    test('underscores and stars inside are not emphasis', () {
      final nodes = parse(r'Nilai $x_1 * y_2$ dan $a_3 * b_4$.');
      expect(elements(nodes, 'em'), isEmpty);
      expect(inlineMath(r'Nilai $x_1 * y_2$ dan $a_3 * b_4$.'), ['x_1 * y_2', 'a_3 * b_4']);
    });

    test(r'$$...$$ inside a sentence is display math within the line', () {
      final math = elements(parse(r'maka $$x = 2$$ adalah jawabannya'), mathTag);
      expect(math.map(mathSource), ['x = 2']);
      expect(isDisplayMath(math.single), isTrue);
    });

    test('fractions, limits and integrals within a line are set at full size', () {
      expect(hasTallParts(r'\lim_{x \to 0} \frac{\sin(3x)}{2x}'), isTrue);
      expect(hasTallParts(r'\int_1^3 (3x^2 + 2) \, dx'), isTrue);
      expect(hasTallParts(r'\sum_{k=1}^n k'), isTrue);
      expect(hasTallParts(r'f(x) = 3x^4 - 5x^2'), isFalse);
      expect(hasTallParts(r'x \to \infty'), isFalse);
    });

    test('prices and code stay text', () {
      expect(inlineMath(r'Harganya $5 dan $10.'), isEmpty);
      expect(inlineMath(r'Biaya $ 5 $ saja'), isEmpty);
      expect(inlineMath(r'Jalankan `echo $HOME$` lalu selesai.'), isEmpty);
      expect(inlineMath('```\n\$\$x\$\$\n```'), isEmpty);
      expect(blockMath('```\n\$\$x\$\$\n```'), isEmpty);
    });
  });

  testWidgets('formulas are typeset, not shown as TeX source', (tester) async {
    await pumpMarkdown(tester, r'''
**Soal 1: Limit**
Hitunglah nilai dari:
$$\lim_{x \to 3} \frac{x^2 - 9}{x - 3}$$

Turunan dari $f(x) = \sin(2x)$ adalah $2\cos(2x)$.
''');
    expect(tester.takeException(), isNull);
    expect(find.byType(Math), findsNWidgets(3));
    final text = allText(tester);
    expect(text, contains('Hitunglah nilai dari:'));
    expect(text, isNot(contains(r'\frac')));
    expect(text, isNot(contains(r'$$')));
  });

  testWidgets('TeX the renderer cannot parse falls back to its source', (tester) async {
    await pumpMarkdown(tester, r'$$\notacommand{x}$$', theme: AppTheme.dark());
    expect(tester.takeException(), isNull);
    expect(allText(tester), contains(r'\notacommand{x}'));
  });
}
