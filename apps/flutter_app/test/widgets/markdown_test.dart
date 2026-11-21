import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:voice_assistant/core/theme/app_theme.dart';
import 'package:voice_assistant/core/widgets/code_block.dart';
import 'package:voice_assistant/core/widgets/markdown_view.dart';

Future<void> pumpMarkdown(WidgetTester tester, String data, {ThemeData? theme}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: theme ?? AppTheme.light(),
      home: Scaffold(
        body: SingleChildScrollView(child: MarkdownView(data: data)),
      ),
    ),
  );
}

/// All visible text, including rich-text spans.
String allText(WidgetTester tester) =>
    tester.widgetList<RichText>(find.byType(RichText)).map((w) => w.text.toPlainText()).join('\n');

void main() {
  testWidgets('renders headings, emphasis, lists, quotes and tables', (tester) async {
    await pumpMarkdown(tester, '''
# Plan

Some **bold** and *italic* text with `inline code` and a [link](https://example.com).

- first
- second
  1. nested

> quoted

| City | Days |
| --- | --- |
| Bandung | 2 |

- [x] done
- [ ] todo
''');
    final text = allText(tester);
    for (final expected in [
      'Plan',
      'bold',
      'italic',
      'inline code',
      'link',
      'first',
      'nested',
      'quoted',
      'Bandung',
      '☑ done',
      '☐ todo',
    ]) {
      expect(text, contains(expected));
    }
    expect(find.byType(Table), findsOneWidget);
    expect(find.text('•'), findsNWidgets(2)); // top-level bullets, task items aside
  });

  testWidgets('code blocks show the language, are highlighted and copyable', (tester) async {
    final copied = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied.add((call.arguments as Map)['text'] as String);
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));

    await pumpMarkdown(tester, '```dart\nvoid main() => print("hi");\n```');
    expect(find.byType(CodeBlock), findsOneWidget);
    expect(find.text('dart'), findsOneWidget);

    await tester.tap(find.text('Copy'));
    await tester.pump();
    expect(copied, ['void main() => print("hi");']);
  });

  test('highlighting colours tokens and falls back for unknown languages', () {
    const base = TextStyle(fontSize: 13);
    final dart = highlightCode('final x = 1;', 'dart', base: base, dark: false);
    final colours = <Color?>{};
    dart.visitChildren((span) {
      colours.add(span.style?.color);
      return true;
    });
    expect(colours.whereType<Color>(), isNotEmpty); // keyword/number spans got theme colours
    expect(dart.toPlainText(), 'final x = 1;');

    final unknown = highlightCode('anything', 'no-such-language', base: base, dark: true);
    expect(unknown.toPlainText(), 'anything');
    expect(unknown.children, isNull);
    // Aliases resolve: "py" -> python.
    expect(highlightCode('def f(): pass', 'py', base: base, dark: false).children, isNotNull);
  });

  testWidgets('renders in dark theme without errors', (tester) async {
    await pumpMarkdown(tester, '## Title\n\n```python\nprint(1)\n```', theme: AppTheme.dark());
    expect(tester.takeException(), isNull);
    expect(find.text('python'), findsOneWidget);
  });

  test('only http(s) links are opened', () async {
    // Unsupported schemes return before reaching the platform.
    await openExternalLink('javascript:alert(1)');
    await openExternalLink('file:///etc/passwd');
    await openExternalLink(null);
  });
}
