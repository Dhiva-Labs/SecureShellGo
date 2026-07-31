import 'dart:async';
import 'dart:convert';

import 'remote_exec.dart';
import 'shell_quote.dart';
import 'ssh_service.dart';

/// One `.service` unit as `systemctl list-units` reports it.
class ServiceUnit {
  const ServiceUnit({
    required this.name,
    required this.load,
    required this.active,
    required this.sub,
    required this.description,
  });

  /// e.g. `nginx.service`.
  final String name;

  /// `loaded`, `not-found`, `masked`, `error`.
  final String load;

  /// `active`, `inactive`, `failed`, `activating`, `deactivating`.
  final String active;

  /// The finer state under [active] — `running`, `exited`, `dead`, `failed`.
  final String sub;

  final String description;

  /// The name without the `.service` suffix, for a less shouty list.
  String get shortName =>
      name.endsWith('.service') ? name.substring(0, name.length - 8) : name;

  bool get isRunning => active == 'active' && sub == 'running';

  bool get isFailed => active == 'failed' || sub == 'failed';
}

/// What can be done to a unit. Every one of these needs a confirmation dialog
/// naming the service — see `services_screen.dart`. The enum is only the
/// verb.
enum ServiceAction { start, stop, restart }

extension ServiceActionLabel on ServiceAction {
  String get verb => switch (this) {
        ServiceAction.start => 'Start',
        ServiceAction.stop => 'Stop',
        ServiceAction.restart => 'Restart',
      };

  String get command => switch (this) {
        ServiceAction.start => 'start',
        ServiceAction.stop => 'stop',
        ServiceAction.restart => 'restart',
      };
}

/// The exact commands, separate from execution so the quoting can be asserted.
class SystemdCommands {
  const SystemdCommands._();

  /// `--plain` drops the tree/bullet decoration, `--no-legend` drops the
  /// header and the "N loaded units listed" footer, and `--no-pager` stops
  /// systemd piping its own output through `less` — which, on a channel with
  /// no PTY, would otherwise hang waiting for a keypress that can never come.
  /// Together they leave exactly five columns and nothing else to parse.
  static const String listUnits =
      'systemctl list-units --type=service --no-pager --plain --no-legend';

  /// Whether this server has systemd at all. Run before [listUnits] so an
  /// init-less container or a BSD gets a clean "systemd not available on this
  /// server" instead of a shell error rendered as a list.
  static const String probe = 'command -v systemctl >/dev/null 2>&1';

  /// `systemctl <verb> <unit>`.
  ///
  /// The unit name is single-quoted even though it arrives from our own
  /// parse of `systemctl`'s output rather than from the user. That is the
  /// point: the output came from a machine we do not control, and a rule that
  /// only applies to input which "looks" untrusted is a rule that will
  /// eventually be applied wrongly. Everything that reaches a command string
  /// goes through [posixSingleQuote].
  static String action(ServiceAction action, String unit) =>
      'systemctl ${action.command} ${posixSingleQuote(unit)}';
}

/// Parses `systemctl list-units --plain --no-legend` output.
///
/// Five whitespace-separated columns, the fifth of which — the
/// description — contains spaces and so takes everything left on the line:
///
///   `nginx.service  loaded active running A high performance web server`
///
/// Pure and total: an unparseable line is skipped rather than throwing, so a
/// systemd version that adds a column at the end still lists every unit it
/// was going to, and one that adds a column in the *middle* degrades to a few
/// odd-looking descriptions instead of an exception.
List<ServiceUnit> parseServiceUnits(String output) {
  final units = <ServiceUnit>[];
  for (final raw in const LineSplitter().convert(output)) {
    // `--plain` should remove the leading bullet that marks a failed unit,
    // but it is stripped here anyway: the flag's behaviour has varied across
    // systemd versions and the cost of being wrong is a unit named `●`.
    final line = raw.replaceFirst(RegExp(r'^[\s●•*]+'), '').trimRight();
    if (line.isEmpty) continue;

    final fields = line.split(RegExp(r'\s+'));
    if (fields.length < 4) continue;

    final name = fields[0];
    // Anything that is not a unit name is not a row: the footer, a warning
    // systemd printed to stdout, a shell banner.
    if (!name.contains('.')) continue;

    units.add(
      ServiceUnit(
        name: name,
        load: fields[1],
        active: fields[2],
        sub: fields[3],
        description: fields.skip(4).join(' '),
      ),
    );
  }
  return units;
}

/// Raised when the server has no systemd. Carried as its own type so the
/// screen can show one calm sentence rather than an error box — this is a
/// normal property of a server, not a fault.
class SystemdUnavailable implements Exception {
  const SystemdUnavailable();

  static const String message = 'systemd is not available on this server.';

  @override
  String toString() => message;
}

/// Lists and controls systemd services over a session's existing transport.
class SystemdService {
  const SystemdService();

  /// Every `.service` unit systemd knows about.
  ///
  /// Throws [SystemdUnavailable] when there is no `systemctl`. No init.d
  /// fallback is attempted, on purpose: `/etc/init.d` scripts have no common
  /// status contract, so a list built from them would be a list of guesses,
  /// and offering start/stop against guesses is worse than offering nothing.
  Future<List<ServiceUnit>> list(SessionTransport transport) async {
    final probe = await RemoteExec.run(transport, SystemdCommands.probe);
    if (!probe.succeeded) throw const SystemdUnavailable();

    final result = await RemoteExec.run(transport, SystemdCommands.listUnits);
    // systemd on a non-systemd boot ("System has not been booted with
    // systemd as init system") exits non-zero and says so; that is the same
    // fact as having no systemctl at all, as far as this screen is concerned.
    if (!result.succeeded) {
      final stderr = result.stderr.toLowerCase();
      if (stderr.contains('has not been booted with systemd') ||
          stderr.contains('failed to connect to bus')) {
        throw const SystemdUnavailable();
      }
      throw monitorFailureFrom(result, 'Could not list services');
    }
    return parseServiceUnits(result.stdout);
  }

  /// Runs [action] against [unit].
  ///
  /// The caller is responsible for having confirmed with the user first — the
  /// dialog is not optional and is not here, because a service action is a
  /// UI-level decision with a UI-level warning about sudo attached to it.
  ///
  /// Throws [MonitorFailure], with [MonitorFailure.needsPrivilege] set when
  /// the refusal was polkit's or the kernel's rather than systemd's. Nothing
  /// here escalates: a user who needs root is told to use the terminal.
  Future<void> run(
    SessionTransport transport,
    ServiceAction action,
    String unit,
  ) async {
    final result = await RemoteExec.run(
      transport,
      SystemdCommands.action(action, unit),
      // Longer than a probe: a `restart` waits for the unit's own stop and
      // start timeouts, and a database that takes 20 s to shut down cleanly
      // has not failed.
      timeout: const Duration(seconds: 45),
    );
    if (!result.succeeded) {
      throw monitorFailureFrom(
        result,
        'Could not ${action.command} $unit',
      );
    }
  }
}
