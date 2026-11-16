import 'host.dart';
import 'host_ai_access.dart';

/// What the user did to a host's AI Bridge controls in one form or sheet,
/// kept so a save writes only what they changed.
///
/// A form is opened on a host as it was then; by the time Save is pressed the
/// stored host may have changed (un-shared in the checklist, stepped down,
/// its allowed list edited). Writing the whole form back would undo that, and
/// could raise what an assistant may do. So [applyTo] starts from the host as
/// the store holds it now and changes only the fields whose `*Chosen` flag is
/// set, i.e. the ones the user touched in THIS form.
///
/// Pure Dart. The values start from the host the form opened on and are
/// what the controls show; the flags start false.
class HostAiEdit {
  HostAiEdit.of(Host host)
    : shared = host.aiAccess != HostAiAccess.off,
      changes = host.aiMayRequestChanges,
      level = host.aiAccess,
      commands = List<String>.of(host.aiAllowedCommands),
      terminal = host.aiTerminal,
      desktop = host.aiDesktop;

  /// "Share with AI assistants": read access.
  bool shared;

  /// "Let the assistant request changes".
  bool changes;

  /// The allowed commands, as the editor holds them.
  List<String> commands;

  /// The one access level, for a form that offers a single level picker
  /// (off / read only / ask before each change / full control) instead of
  /// the share and change switches. When chosen it wins over both.
  HostAiAccess level;

  /// "Terminal": a terminal may be requested under ask-to-change.
  bool terminal;

  /// "Desktop": a desktop may be requested under ask-to-change.
  bool desktop;

  bool sharedChosen = false;
  bool changesChosen = false;
  bool levelChosen = false;
  bool commandsChosen = false;
  bool terminalChosen = false;
  bool desktopChosen = false;

  /// True when the user changed anything.
  bool get touched =>
      sharedChosen ||
      changesChosen ||
      levelChosen ||
      commandsChosen ||
      terminalChosen ||
      desktopChosen;

  void setShared(bool on) {
    shared = on;
    sharedChosen = true;
  }

  void setChanges(bool on) {
    changes = on;
    changesChosen = true;
  }

  void setCommands(List<String> list) {
    commands = List<String>.of(list);
    commandsChosen = true;
  }

  /// Sets the level outright. The only way an edit raises a host to
  /// [HostAiAccess.fullControl]: the share and change switches never do.
  void setLevel(HostAiAccess value) {
    level = value;
    levelChosen = true;
  }

  void setTerminal(bool on) {
    terminal = on;
    terminalChosen = true;
  }

  void setDesktop(bool on) {
    desktop = on;
    desktopChosen = true;
  }

  /// [stored] with this edit applied: the access level from the stored host
  /// unless the user changed it here; the allowed commands and terminal
  /// switch from the stored host unless the user changed them here.
  ///
  /// Access: sharing switched off here is off; switched on keeps the stored
  /// level, or is read-only when the stored host is off. The change switch
  /// here then moves a shared host between read-only and ask-to-change (a
  /// stored full-control host switched "on" keeps full control), and does
  /// nothing for a host that ends up off. A level set with [setLevel] wins
  /// over both switches. Un-sharing and stepping down leave the allowed
  /// commands, terminal and desktop settings stored but inert (see
  /// [Host.aiAllowedCommands]).
  Host applyTo(Host stored) {
    var access = stored.aiAccess;
    if (sharedChosen) {
      access = !shared
          ? HostAiAccess.off
          : (stored.aiAccess == HostAiAccess.off
                ? HostAiAccess.readOnly
                : stored.aiAccess);
    }
    if (changesChosen && access != HostAiAccess.off) {
      access = !changes
          ? HostAiAccess.readOnly
          : (access == HostAiAccess.fullControl
                ? HostAiAccess.fullControl
                : HostAiAccess.askToChange);
    }
    if (levelChosen) access = level;
    return stored.copyWith(
      aiAccess: access,
      aiAllowedCommands: commandsChosen ? commands : stored.aiAllowedCommands,
      aiTerminal: terminalChosen ? terminal : stored.aiTerminal,
      aiDesktop: desktopChosen ? desktop : stored.aiDesktop,
    );
  }

  /// A comparable summary, for a form's "has anything changed" check.
  Object get signature => (
    shared,
    changes,
    level,
    terminal,
    desktop,
    Object.hashAll(commands),
    commands.length,
  );
}
