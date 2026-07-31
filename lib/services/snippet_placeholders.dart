/// Pure parsing of `{name}` placeholders inside a snippet command.
///
/// `{{` and `}}` escape a literal brace, the same convention
/// `String.format`-style templates use — so a command that legitimately
/// needs a brace (`for i in {1..5}; do`, `awk '{print $1}'`) is not mistaken
/// for a placeholder. Kept free of Flutter imports, like the rest of
/// `services/`: the dialog that asks for values lives in
/// `widgets/snippet_placeholder_dialog.dart`, this is just the string logic
/// behind it.
library;

/// One piece of a parsed command: literal text to send as-is, or the name of
/// a value to ask the user for.
sealed class SnippetPart {
  const SnippetPart();
}

class SnippetLiteral extends SnippetPart {
  const SnippetLiteral(this.text);
  final String text;
}

class SnippetPlaceholder extends SnippetPart {
  const SnippetPlaceholder(this.name);
  final String name;
}

/// The result of [parseSnippetCommand]: [parts] in the order they appear in
/// the original command, ready to be rendered back into text via [render]
/// once every placeholder has a value.
class ParsedSnippetCommand {
  const ParsedSnippetCommand(this.parts);

  final List<SnippetPart> parts;

  /// Every placeholder name, in first-appearance order, listed once each —
  /// what the picker's dialog asks for, even when `{name}` is repeated.
  List<String> get placeholderNames {
    final seen = <String>{};
    final names = <String>[];
    for (final part in parts) {
      if (part case SnippetPlaceholder(:final name)) {
        if (seen.add(name)) names.add(name);
      }
    }
    return names;
  }

  bool get hasPlaceholders => placeholderNames.isNotEmpty;

  /// Substitutes every placeholder with its value from [values] (keyed by
  /// placeholder name). A name missing from [values] renders as an empty
  /// string rather than throwing — the caller is expected to have collected
  /// every name in [placeholderNames] already.
  String render(Map<String, String> values) {
    final buffer = StringBuffer();
    for (final part in parts) {
      switch (part) {
        case SnippetLiteral(:final text):
          buffer.write(text);
        case SnippetPlaceholder(:final name):
          buffer.write(values[name] ?? '');
      }
    }
    return buffer.toString();
  }
}

/// Parses [command] into literal text and `{name}` placeholders.
///
/// `{{`/`}}` render as a single literal `{`/`}`. `{}` (an empty name) and an
/// unterminated `{` with no matching `}` are both kept as literal text
/// rather than treated as a placeholder — a blank name has nothing to ask
/// for, and a dropped `{` would silently mangle whatever command this came
/// from.
ParsedSnippetCommand parseSnippetCommand(String command) {
  final parts = <SnippetPart>[];
  final literal = StringBuffer();
  var i = 0;

  void flushLiteral() {
    if (literal.isNotEmpty) {
      parts.add(SnippetLiteral(literal.toString()));
      literal.clear();
    }
  }

  while (i < command.length) {
    final ch = command[i];

    if (ch == '{' && i + 1 < command.length && command[i + 1] == '{') {
      literal.write('{');
      i += 2;
      continue;
    }
    if (ch == '}' && i + 1 < command.length && command[i + 1] == '}') {
      literal.write('}');
      i += 2;
      continue;
    }
    if (ch == '{') {
      final close = command.indexOf('}', i + 1);
      if (close == -1) {
        // No matching close brace: the rest of the string is literal.
        literal.write(command.substring(i));
        break;
      }
      final name = command.substring(i + 1, close).trim();
      if (name.isEmpty) {
        literal.write(command.substring(i, close + 1));
      } else {
        flushLiteral();
        parts.add(SnippetPlaceholder(name));
      }
      i = close + 1;
      continue;
    }

    literal.write(ch);
    i++;
  }

  flushLiteral();
  return ParsedSnippetCommand(parts);
}
