import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:re_highlight/languages/bash.dart';
import 'package:re_highlight/languages/c.dart';
import 'package:re_highlight/languages/cpp.dart';
import 'package:re_highlight/languages/csharp.dart';
import 'package:re_highlight/languages/css.dart';
import 'package:re_highlight/languages/dart.dart';
import 'package:re_highlight/languages/diff.dart';
import 'package:re_highlight/languages/dockerfile.dart';
import 'package:re_highlight/languages/go.dart';
import 'package:re_highlight/languages/java.dart';
import 'package:re_highlight/languages/javascript.dart';
import 'package:re_highlight/languages/json.dart';
import 'package:re_highlight/languages/kotlin.dart';
import 'package:re_highlight/languages/markdown.dart';
import 'package:re_highlight/languages/php.dart';
import 'package:re_highlight/languages/plaintext.dart';
import 'package:re_highlight/languages/powershell.dart';
import 'package:re_highlight/languages/python.dart';
import 'package:re_highlight/languages/ruby.dart';
import 'package:re_highlight/languages/rust.dart';
import 'package:re_highlight/languages/shell.dart';
import 'package:re_highlight/languages/sql.dart';
import 'package:re_highlight/languages/swift.dart';
import 'package:re_highlight/languages/typescript.dart';
import 'package:re_highlight/languages/xml.dart';
import 'package:re_highlight/languages/yaml.dart';
import 'package:re_highlight/re_highlight.dart';
import 'package:re_highlight/styles/github-dark.dart';
import 'package:re_highlight/styles/github.dart';

import 'common_widgets.dart';

const monospaceFamily = 'monospace';
const monospaceFallback = ['Cascadia Mono', 'Consolas', 'Menlo', 'SF Mono', 'Roboto Mono', 'Courier New'];

final Highlight _highlighter = Highlight()
  ..registerLanguages({
    'bash': langBash,
    'c': langC,
    'cpp': langCpp,
    'csharp': langCsharp,
    'css': langCss,
    'dart': langDart,
    'diff': langDiff,
    'dockerfile': langDockerfile,
    'go': langGo,
    'java': langJava,
    'javascript': langJavascript,
    'json': langJson,
    'kotlin': langKotlin,
    'markdown': langMarkdown,
    'php': langPhp,
    'plaintext': langPlaintext,
    'powershell': langPowershell,
    'python': langPython,
    'ruby': langRuby,
    'rust': langRust,
    'shell': langShell,
    'sql': langSql,
    'swift': langSwift,
    'typescript': langTypescript,
    'xml': langXml,
    'yaml': langYaml,
  });

const _aliases = {
  'sh': 'bash',
  'zsh': 'bash',
  'console': 'shell',
  'js': 'javascript',
  'jsx': 'javascript',
  'mjs': 'javascript',
  'ts': 'typescript',
  'tsx': 'typescript',
  'py': 'python',
  'yml': 'yaml',
  'kt': 'kotlin',
  'c++': 'cpp',
  'cs': 'csharp',
  'html': 'xml',
  'svg': 'xml',
  'ps1': 'powershell',
  'pwsh': 'powershell',
  'rs': 'rust',
  'golang': 'go',
  'rb': 'ruby',
  'md': 'markdown',
  'jsonc': 'json',
  'text': 'plaintext',
  'txt': 'plaintext',
  'docker': 'dockerfile',
};

/// Token colours from the GitHub themes, without their page background.
final Map<String, TextStyle> _lightTokens = {...githubTheme}..remove('root');
final Map<String, TextStyle> _darkTokens = {...githubDarkTheme}..remove('root');

/// Syntax-highlights [code]; falls back to plain text for unknown languages.
TextSpan highlightCode(String code, String? language, {required TextStyle base, required bool dark}) {
  final requested = language?.toLowerCase().trim();
  final resolved = _aliases[requested] ?? requested;
  final plain = TextSpan(text: code, style: base);
  if (resolved == null || resolved.isEmpty || resolved == 'plaintext') return plain;
  try {
    final result = _highlighter.highlight(code: code, language: resolved);
    final renderer = TextSpanRenderer(base, dark ? _darkTokens : _lightTokens);
    result.render(renderer);
    final span = renderer.span;
    return span == null ? plain : TextSpan(style: base, children: [span]);
  } catch (_) {
    return plain; // unregistered language or highlighter failure
  }
}

class CodeBlock extends StatelessWidget {
  const CodeBlock({super.key, required this.code, this.language});

  final String code;
  final String? language;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;
    final base = TextStyle(
      fontFamily: monospaceFamily,
      fontFamilyFallback: monospaceFallback,
      fontSize: 13.5,
      height: 1.45,
      color: dark ? const Color(0xFFE6EDF3) : const Color(0xFF1F2328),
    );
    final label = (language == null || language!.isEmpty) ? 'code' : language!;

    return Container(
      decoration: BoxDecoration(
        color: dark ? const Color(0xFF161B22) : const Color(0xFFF6F8FA),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.6)),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.only(left: 14, right: 4),
            color: scheme.onSurface.withValues(alpha: 0.05),
            child: Row(
              children: [
                Expanded(
                  child: Text(label, style: theme.textTheme.labelMedium?.copyWith(color: scheme.onSurfaceVariant)),
                ),
                TextButton.icon(
                  style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
                  icon: const Icon(Icons.content_copy_rounded, size: 16),
                  label: const Text('Copy'),
                  onPressed: () async {
                    await Clipboard.setData(ClipboardData(text: code));
                    if (context.mounted) showInfoSnackBar(context, 'Code copied');
                  },
                ),
              ],
            ),
          ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.all(14),
            child: Text.rich(highlightCode(code, language, base: base, dark: dark), softWrap: false),
          ),
        ],
      ),
    );
  }
}
