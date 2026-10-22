import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/models/app_settings.dart';
import 'package:secure_shell_go/services/editor_indent.dart';
import 'package:secure_shell_go/services/syntax_highlighter.dart';
import 'package:secure_shell_go/theme.dart';
import 'package:secure_shell_go/widgets/code_editor_field.dart';

/// The gutter is painted beside the field, not built into it, so the two
/// line up only while they measure text the same way. They stopped doing so
/// twice over: Material 3's field style adds letter spacing the measuring
/// never saw, and the field scaled its text for the system font size while
/// the gutter did not. Each test holds what the editor measured against
/// where the field actually put the text.
void main() {
  final theme = AppTheme.terminalThemeFor(TerminalColorScheme.classic);

  Future<CodeEditorFieldState> pumpField(
    WidgetTester tester,
    String text, {
    required bool softWrap,
    double textScale = 1,
    IndentStyle indentStyle = const IndentStyle.spaces(4),
  }) async {
    final key = GlobalKey<CodeEditorFieldState>();
    final controller = EditorHighlightController(
      text: text,
      mode: plainTextMode,
      theme: theme,
    );
    final focusNode = FocusNode();
    addTearDown(controller.dispose);
    addTearDown(focusNode.dispose);
    await tester.pumpWidget(MaterialApp(
      // Material 3, as the app ships: its field style is where the stray
      // letter spacing came from.
      theme: AppTheme.dark,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler: TextScaler.linear(textScale),
        ),
        child: child!,
      ),
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: 400,
            height: 500,
            child: CodeEditorField(
              key: key,
              controller: controller,
              focusNode: focusNode,
              theme: theme,
              fontSize: 14,
              softWrap: softWrap,
              indentStyle: indentStyle,
            ),
          ),
        ),
      ),
    ));
    await tester.pump();
    return key.currentState!;
  }

  RenderEditable editable(WidgetTester tester) =>
      tester.state<EditableTextState>(find.byType(EditableText)).renderEditable;

  double caretTop(WidgetTester tester, int offset) => editable(tester)
      .getLocalRectForCaret(TextPosition(offset: offset))
      .top;

  double caretLeft(WidgetTester tester, int offset) => editable(tester)
      .getLocalRectForCaret(TextPosition(offset: offset))
      .left;

  /// Where the glyph at [offset] is drawn, which is not always where the
  /// caret beside it goes: letter spacing put the two half a stop apart.
  double glyphLeft(WidgetTester tester, int offset) => editable(tester)
      .getBoxesForSelection(
        TextSelection(baseOffset: offset, extentOffset: offset + 1),
      )
      .single
      .left;

  List<int> lineStarts(String text) => [
        0,
        for (var i = 0; i < text.length; i++)
          if (text[i] == '\n') i + 1,
      ];

  for (final scale in [1.0, 1.5]) {
    testWidgets('with wrapping off a long line stays one row (text ×$scale)',
        (tester) async {
      // Words, like code, so a too-narrow field would wrap between them.
      final line = List.filled(30, 'word').join(' ');
      await pumpField(tester, '$line\nend', softWrap: false, textScale: scale);

      expect(caretTop(tester, line.length), caretTop(tester, 0));
    });

    testWidgets('the gutter rows match the field rows (text ×$scale)',
        (tester) async {
      const text = 'one\ntwo\nthree\nfour';
      final state =
          await pumpField(tester, text, softWrap: false, textScale: scale);

      final starts = lineStarts(text);
      for (var i = 1; i < starts.length; i++) {
        expect(
          caretTop(tester, starts[i]) - caretTop(tester, 0),
          closeTo(i * state.rowHeight, 0.01),
          reason: 'line ${i + 1}',
        );
      }
    });

    testWidgets('wrapped lines are measured where the field wraps them '
        '(text ×$scale)', (tester) async {
      // At ×1 the field has room for 25 test-font glyphs a row, so the line
      // of 12-letter words fills rows exactly: any extra spacing per glyph
      // pushes a word to the next row, and the numbers below it drift.
      final text = [
        'short',
        List.filled(6, 'abcdefghijkl').join(' '),
        '',
        List.filled(20, 'if').join(' '),
        'end',
      ].join('\n');
      final state =
          await pumpField(tester, text, softWrap: true, textScale: scale);

      final heights = state.wrappedLineHeights!;
      final starts = lineStarts(text);
      var expected = 0.0;
      for (var i = 1; i < starts.length; i++) {
        expected += heights[i - 1];
        expect(
          caretTop(tester, starts[i]) - caretTop(tester, 0),
          closeTo(expected, 0.01),
          reason: 'line ${i + 1}',
        );
      }
      expect(heights[1], greaterThan(state.rowHeight),
          reason: 'the long line really does wrap');
    });
  }

  for (final size in [4, 8]) {
    testWidgets('a tab reaches the next stop of $size, caret and glyph alike',
        (tester) async {
      // A tab from column 0, from column 1 and from just short of a stop.
      final pad = ' ' * (size - 1);
      final text = '\tx\na\tx\n$pad\tx\nend';
      final state = await pumpField(tester, text,
          softWrap: false, indentStyle: IndentStyle.tabs(size));
      final cw = caretLeft(tester, text.indexOf('a') + 1) -
          caretLeft(tester, text.indexOf('a'));

      // Every `x` sits on the first stop, however far its tab had to go —
      // measured from the left edge, where the tab-less last line starts:
      // a tab first on its line once shifted the whole line, its own start
      // included.
      final edge = caretLeft(tester, text.indexOf('end'));
      final starts = lineStarts(text);
      for (var line = 0; line < 3; line++) {
        final x = text.indexOf('x', starts[line]);
        expect(caretLeft(tester, starts[line]), closeTo(edge, 0.01),
            reason: 'line start, line ${line + 1}');
        expect(caretLeft(tester, x) - edge, closeTo(size * cw, 0.01),
            reason: 'caret, line ${line + 1}');
        expect(glyphLeft(tester, x) - edge, closeTo(size * cw, 0.01),
            reason: 'drawn, line ${line + 1}');
        expect(
          caretTop(tester, starts[line + 1]) - caretTop(tester, starts[line]),
          closeTo(state.rowHeight, 0.01),
          reason: 'a tab does not make its row taller, line ${line + 1}',
        );
      }
    });
  }
}
