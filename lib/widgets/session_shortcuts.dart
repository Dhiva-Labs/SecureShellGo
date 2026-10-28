import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Goes to the host list for another session.
class NewSessionIntent extends Intent {
  const NewSessionIntent();
}

/// Brings the next (or, with [backwards], the previous) session tab to the
/// front.
class CycleSessionIntent extends Intent {
  const CycleSessionIntent({this.backwards = false});

  final bool backwards;
}

/// Switches the session between its terminal and its files, where they take
/// turns on screen.
class ToggleSessionFilesIntent extends Intent {
  const ToggleSessionFilesIntent();
}

/// Gives the terminal the whole width, or puts the files back beside it.
class ToggleTerminalFullWidthIntent extends Intent {
  const ToggleTerminalFullWidthIntent();
}

/// The session screen's keyboard shortcuts, for whoever has a keyboard.
///
/// Every one has Ctrl *and* Shift, or Ctrl and a key no shell reads, because
/// the terminal has the focus nearly all the time and a plain Ctrl chord
/// belongs to the program running in it — Ctrl+T transposes characters in
/// bash, Ctrl+E goes to the end of the line. These are the chords terminal
/// emulators already use for their tabs, so hands that know GNOME Terminal
/// or Windows Terminal already know them.
///
/// No Alt+digit or Ctrl+Alt+digit for "go to tab n": readline reads Alt+digit
/// as an argument, and on Windows Ctrl+Alt is AltGr — which is how a German
/// keyboard types `{` and `[`. No Ctrl+PgUp/Ctrl+PgDn either, though GNOME
/// Terminal uses them for tabs: vim and emacs bind them too, and a shortcut
/// here is taken from the shell before it can see it.
abstract final class SessionShortcuts {
  static const newSession =
      SingleActivator(LogicalKeyboardKey.keyT, control: true, shift: true);
  static const nextSession =
      SingleActivator(LogicalKeyboardKey.tab, control: true);
  static const previousSession =
      SingleActivator(LogicalKeyboardKey.tab, control: true, shift: true);
  static const toggleFiles =
      SingleActivator(LogicalKeyboardKey.keyE, control: true, shift: true);
  static const toggleFullWidth =
      SingleActivator(LogicalKeyboardKey.enter, control: true, shift: true);

  static const Map<ShortcutActivator, Intent> bindings = {
    newSession: NewSessionIntent(),
    nextSession: CycleSessionIntent(),
    previousSession: CycleSessionIntent(backwards: true),
    toggleFiles: ToggleSessionFilesIntent(),
    toggleFullWidth: ToggleTerminalFullWidthIntent(),
  };

  /// Runs the shortcut [event] completes, if any, through the [Actions]
  /// above [context].
  ///
  /// For a widget that sees keys before a [Shortcuts] above it can: the
  /// terminal handles every key it is given, so a chord meant for the screen
  /// has to be taken out on the way in. One whose action is disabled — the
  /// files toggle while both panes are on screen — is left for the shell.
  static KeyEventResult dispatch(BuildContext context, KeyEvent event) {
    for (final MapEntry(key: activator, value: intent) in bindings.entries) {
      if (!activator.accepts(event, HardwareKeyboard.instance)) continue;
      final action = Actions.maybeFind<Intent>(context, intent: intent);
      if (action == null || !action.isEnabled(intent)) {
        return KeyEventResult.ignored;
      }
      Actions.invoke(context, intent);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// `Ctrl+Shift+T`, for a tooltip.
  static String label(SingleActivator activator) {
    final key = switch (activator.trigger) {
      LogicalKeyboardKey.enter => 'Enter',
      LogicalKeyboardKey.tab => 'Tab',
      final other => other.keyLabel.toUpperCase(),
    };
    return [
      if (activator.control) 'Ctrl',
      if (activator.alt) 'Alt',
      if (activator.shift) 'Shift',
      key,
    ].join('+');
  }

  /// [text], with [activator]'s keys after it when a keyboard is in use.
  static String tooltip(
    String text,
    SingleActivator activator, {
    required bool keyboard,
  }) =>
      keyboard ? '$text (${label(activator)})' : text;
}
