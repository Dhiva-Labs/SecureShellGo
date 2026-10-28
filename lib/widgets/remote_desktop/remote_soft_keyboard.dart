import 'package:flutter/services.dart';

import '../../services/remote_desktop/remote_input_text.dart';

/// The on-screen keyboard for the remote desktop, as a text input that
/// shows nothing.
///
/// Nothing on screen is being edited, so there is no text field: this
/// attaches a [TextInputClient] straight to the platform, which is all it
/// takes to raise the keyboard, and turns what it reports into
/// [EditingChange]s for the viewer to type on the remote.
///
/// The client holds two spaces and nothing else, and is put back to that
/// after every change. That keeps the keyboard from composing: with no word
/// in progress there are no suggestions to accept or underlines to replace,
/// each key arrives as the single character it is. The padding is there so
/// that Backspace has something to delete, and shows up as a shorter text.
class RemoteSoftKeyboard with TextInputClient {
  RemoteSoftKeyboard({required this.onChange, this.onClosed});

  /// Called with each change the keyboard reports.
  final void Function(EditingChange change) onChange;

  /// Called when the platform closes the connection from its side.
  final void Function()? onClosed;

  static const String _padding = '  ';
  static const TextEditingValue _initial = TextEditingValue(
    text: _padding,
    selection: TextSelection.collapsed(offset: _padding.length),
  );

  TextInputConnection? _connection;

  bool get isAttached => _connection?.attached ?? false;

  /// Raises the keyboard.
  void show() {
    var connection = _connection;
    if (connection == null || !connection.attached) {
      connection = TextInput.attach(
        this,
        const TextInputConfiguration(
          // The keyboard that suppresses prediction and composition on the
          // widest range of Android keyboards, so each key arrives as it is.
          inputType: TextInputType.visiblePassword,
          autocorrect: false,
          enableSuggestions: false,
          enableIMEPersonalizedLearning: false,
          inputAction: TextInputAction.newline,
          textCapitalization: TextCapitalization.none,
        ),
      );
      _connection = connection;
    }
    connection
      ..setEditingState(_initial)
      ..show();
  }

  /// Puts the keyboard away.
  void hide() {
    _connection?.close();
    _connection = null;
  }

  void dispose() => hide();

  @override
  TextEditingValue? get currentTextEditingValue => _initial;

  @override
  AutofillScope? get currentAutofillScope => null;

  @override
  void updateEditingValue(TextEditingValue value) {
    final change = diffEditing(_padding, value.text);
    // Back to the padding first: whatever happens in the callback, the next
    // key is read against a clean slate.
    _connection?.setEditingState(_initial);
    if (!change.isEmpty) onChange(change);
  }

  @override
  void performAction(TextInputAction action) {
    // The Enter key: a multi-line input would have put a newline in the
    // text, but this one reports it as an action.
    onChange(const EditingChange(0, '\n'));
  }

  @override
  void performPrivateCommand(String action, Map<String, dynamic> data) {}

  @override
  void updateFloatingCursor(RawFloatingCursorPoint point) {}

  @override
  void showAutocorrectionPromptRect(int start, int end) {}

  @override
  void connectionClosed() {
    _connection = null;
    onClosed?.call();
  }
}
