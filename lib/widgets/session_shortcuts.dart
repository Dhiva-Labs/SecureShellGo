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

/// Ends the session in front, asking first if there is anything to lose —
/// the app bar's disconnect button, from the keyboard.
class CloseSessionIntent extends Intent {
  const CloseSessionIntent();
}

/// Puts the keyboard in the next (or, with [backwards], the previous) pane of
/// a split workspace that has a session in it.
class CyclePaneIntent extends Intent {
  const CyclePaneIntent({this.backwards = false});

  final bool backwards;
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
///
/// Ctrl+Shift+W closes, as it closes a tab in GNOME Terminal. Ctrl+Shift+N
/// and Ctrl+Shift+P step between the panes of a split, as they step between
/// Terminator's: letters rather than brackets, which a German keyboard has
/// only behind AltGr, and rather than Alt+arrows, which fish and tmux use.
/// Both are only taken while there is a second pane to go to.
///
/// On a Mac every Ctrl+Shift chord also answers to ⌘ in place of Ctrl, the
/// way the Mac's own apps are driven. The two on Tab do not: ⌘Tab is the
/// system's app switcher and never reaches an app, and Ctrl+Tab is what a
/// Mac's own Terminal steps through its tabs with anyway.
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
  static const closeSession =
      SingleActivator(LogicalKeyboardKey.keyW, control: true, shift: true);
  static const nextPane =
      SingleActivator(LogicalKeyboardKey.keyN, control: true, shift: true);
  static const previousPane =
      SingleActivator(LogicalKeyboardKey.keyP, control: true, shift: true);

  static const Map<ShortcutActivator, Intent> bindings = {
    newSession: NewSessionIntent(),
    nextSession: CycleSessionIntent(),
    previousSession: CycleSessionIntent(backwards: true),
    toggleFiles: ToggleSessionFilesIntent(),
    toggleFullWidth: ToggleTerminalFullWidthIntent(),
    closeSession: CloseSessionIntent(),
    nextPane: CyclePaneIntent(),
    previousPane: CyclePaneIntent(backwards: true),
  };

  /// [bindings], and on a Mac the same chords with ⌘ for Ctrl as well.
  static Map<ShortcutActivator, Intent> bindingsFor(TargetPlatform platform) =>
      platform == TargetPlatform.macOS ? _macBindings : bindings;

  static final Map<ShortcutActivator, Intent> _macBindings = {
    ...bindings,
    for (final MapEntry(key: activator, value: intent) in bindings.entries)
      if (_takesCommand(activator as SingleActivator))
        SingleActivator(
          activator.trigger,
          meta: true,
          shift: activator.shift,
          alt: activator.alt,
        ): intent,
  };

  /// Whether a Mac also answers [activator] with ⌘ for Ctrl. Not on Tab —
  /// see the class doc.
  static bool _takesCommand(SingleActivator activator) =>
      activator.control && activator.trigger != LogicalKeyboardKey.tab;

  /// Runs the shortcut [event] completes, if any, through the [Actions]
  /// above [context].
  ///
  /// For a widget that sees keys before a [Shortcuts] above it can: the
  /// terminal handles every key it is given, so a chord meant for the screen
  /// has to be taken out on the way in. One whose action is disabled — the
  /// files toggle while both panes are on screen — is left for the shell.
  static KeyEventResult dispatch(BuildContext context, KeyEvent event) {
    final platform = Theme.of(context).platform;
    for (final MapEntry(key: activator, value: intent)
        in bindingsFor(platform).entries) {
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

  /// `Ctrl+Shift+T`, for a tooltip — or `⇧⌘T` on a Mac, spelled the way the
  /// editor's menus spell theirs there, for a chord that takes ⌘.
  static String label(SingleActivator activator, {TargetPlatform? platform}) {
    final key = switch (activator.trigger) {
      LogicalKeyboardKey.enter => 'Enter',
      LogicalKeyboardKey.tab => 'Tab',
      final other => other.keyLabel.toUpperCase(),
    };
    if (platform == TargetPlatform.macOS && _takesCommand(activator)) {
      return '${activator.alt ? '⌥' : ''}${activator.shift ? '⇧' : ''}⌘$key';
    }
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
    TargetPlatform? platform,
  }) =>
      keyboard ? '$text (${label(activator, platform: platform)})' : text;
}
