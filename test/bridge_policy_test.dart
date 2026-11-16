import 'package:flutter_test/flutter_test.dart';
import 'package:secure_shell_go/models/host.dart';
import 'package:secure_shell_go/models/host_ai_access.dart';
import 'package:secure_shell_go/services/bridge/bridge_policy.dart';
import 'package:secure_shell_go/services/bridge/bridge_tool_types.dart';

Host _host(
  HostAiAccess access, {
  bool terminal = false,
  List<String> allowed = const [],
}) => Host(
  id: 'id-1',
  label: 'web',
  hostname: 'web.example.com',
  port: 22,
  username: 'dev',
  authMethod: SshAuthMethod.password,
  aiAccess: access,
  aiTerminal: terminal,
  aiAllowedCommands: allowed,
);

enum _HostCase { none, off, readOnly, askToChange, askToChangeTerminal }

Host? _hostFor(_HostCase c) => switch (c) {
  _HostCase.none => null,
  // A hidden host keeps its stored terminal switch and list; they are inert.
  _HostCase.off => _host(HostAiAccess.off, terminal: true, allowed: ['ls']),
  _HostCase.readOnly => _host(
    HostAiAccess.readOnly,
    terminal: true,
    allowed: ['ls'],
  ),
  _HostCase.askToChange => _host(HostAiAccess.askToChange, allowed: ['ls']),
  _HostCase.askToChangeTerminal => _host(
    HostAiAccess.askToChange,
    terminal: true,
  ),
};

/// 1.6.0's `decideBridgeCall`, copied verbatim (minus the change rule, which
/// is not a read): every read decision must still match it.
BridgeDecision _decide160({
  required bool bridgeEnabled,
  required bool appLocked,
  required Host? host,
  required bool hostRequired,
  required BridgeToolKind kind,
}) {
  if (!bridgeEnabled) return BridgeRefusals.bridgeOff;
  if (appLocked) return BridgeRefusals.appLocked;
  if (kind != BridgeToolKind.read) throw StateError('not a read');
  if (host == null) {
    return hostRequired ? BridgeRefusals.hostNotAvailable : const BridgeAllow();
  }
  if (host.aiAccess == HostAiAccess.off) return BridgeRefusals.hostNotAvailable;
  return const BridgeAllow();
}

void main() {
  group('decideBridgeCall, every combination', () {
    // The expected answer, written out as the brief reads, independently of
    // the implementation's own switch.
    BridgeDecision expected({
      required bool enabled,
      required bool locked,
      required _HostCase hostCase,
      required bool hostRequired,
      required BridgeToolKind kind,
      required bool grant,
      required bool listed,
      required bool owns,
    }) {
      if (!enabled) return BridgeRefusals.bridgeOff;
      if (locked) return BridgeRefusals.appLocked;
      if (kind == BridgeToolKind.terminalUse) {
        // Ownership before the host: another client's terminal and an
        // unknown id read alike whatever its host is.
        if (!owns) return BridgeRefusals.terminalNotAvailable;
        return switch (hostCase) {
          _HostCase.none || _HostCase.off => BridgeRefusals.hostNotAvailable,
          _HostCase.readOnly => BridgeRefusals.changesNotAllowed,
          _HostCase.askToChange => BridgeRefusals.terminalNotAllowed,
          // No card per call; the grant and the list play no part.
          _HostCase.askToChangeTerminal => const BridgeAllow(),
        };
      }
      if (kind == BridgeToolKind.read) {
        return _decide160(
          bridgeEnabled: enabled,
          appLocked: locked,
          host: _hostFor(hostCase),
          hostRequired: hostRequired,
          kind: kind,
        );
      }
      switch (hostCase) {
        case _HostCase.none:
        case _HostCase.off:
          return BridgeRefusals.hostNotAvailable;
        case _HostCase.readOnly:
          return BridgeRefusals.changesNotAllowed;
        case _HostCase.askToChange:
          if (kind == BridgeToolKind.terminal) {
            return BridgeRefusals.terminalNotAllowed;
          }
          return grant || listed
              ? const BridgeAllow()
              : const BridgeNeedsApproval();
        case _HostCase.askToChangeTerminal:
          if (kind == BridgeToolKind.terminal) {
            return const BridgeNeedsApproval();
          }
          return grant || listed
              ? const BridgeAllow()
              : const BridgeNeedsApproval();
      }
    }

    var count = 0;
    for (final enabled in [false, true]) {
      for (final locked in [false, true]) {
        for (final hostCase in _HostCase.values) {
          for (final hostRequired in [false, true]) {
            for (final kind in BridgeToolKind.values) {
              for (final grant in [false, true]) {
                for (final listed in [false, true]) {
                  for (final owns in [false, true]) {
                    count++;
                    test(
                      'enabled=$enabled locked=$locked host=${hostCase.name} '
                      'required=$hostRequired kind=${kind.name} '
                      'grant=$grant listed=$listed owns=$owns',
                      () {
                        final decision = decideBridgeCall(
                          bridgeEnabled: enabled,
                          appLocked: locked,
                          host: _hostFor(hostCase),
                          hostRequired: hostRequired,
                          kind: kind,
                          hasLiveGrant: grant,
                          matchesAllowedCommand: listed,
                          ownsLiveTerminal: owns,
                        );
                        expect(
                          decision,
                          expected(
                            enabled: enabled,
                            locked: locked,
                            hostCase: hostCase,
                            hostRequired: hostRequired,
                            kind: kind,
                            grant: grant,
                            listed: listed,
                            owns: owns,
                          ),
                        );
                      },
                    );
                  }
                }
              }
            }
          }
        }
      }
    }
    test('the table covers all ${2 * 2 * 5 * 2 * 4 * 2 * 2 * 2} cases', () {
      expect(count, 1280);
    });
  });

  group('read decisions are byte-identical to 1.6.0', () {
    test('for every host level, flag and switch', () {
      var compared = 0;
      for (final enabled in [false, true]) {
        for (final locked in [false, true]) {
          for (final hostCase in _HostCase.values) {
            for (final hostRequired in [false, true]) {
              for (final grant in [false, true]) {
                for (final (listed, owns) in [
                  (false, false),
                  (false, true),
                  (true, false),
                  (true, true),
                ]) {
                  final host = _hostFor(hostCase);
                  final now = decideBridgeCall(
                    bridgeEnabled: enabled,
                    appLocked: locked,
                    host: host,
                    hostRequired: hostRequired,
                    kind: BridgeToolKind.read,
                    hasLiveGrant: grant,
                    matchesAllowedCommand: listed,
                    ownsLiveTerminal: owns,
                  );
                  final then = _decide160(
                    bridgeEnabled: enabled,
                    appLocked: locked,
                    host: host,
                    hostRequired: hostRequired,
                    kind: BridgeToolKind.read,
                  );
                  expect(now, then);
                  if (now is BridgeRefuse) {
                    final old = then as BridgeRefuse;
                    expect(now.code.codeUnits, old.code.codeUnits);
                    expect(now.message.codeUnits, old.message.codeUnits);
                  }
                  compared++;
                }
              }
            }
          }
        }
      }
      expect(compared, 2 * 2 * 5 * 2 * 2 * 4);
    });

    test('the 1.6.0 refusal texts are unchanged', () {
      expect(BridgeRefusals.bridgeOff.code, 'bridge_off');
      expect(
        BridgeRefusals.bridgeOff.message,
        'The AI Bridge is switched off in SecureShell Go.',
      );
      expect(BridgeRefusals.appLocked.code, 'app_locked');
      expect(
        BridgeRefusals.appLocked.message,
        'SecureShell Go is locked. Ask the user to unlock it, then try again.',
      );
      expect(BridgeRefusals.hostNotAvailable.code, 'host_not_available');
      expect(
        BridgeRefusals.hostNotAvailable.message,
        'No host by that name is available to the AI Bridge. '
        'Call list_hosts to see the hosts you can use.',
      );
    });
  });

  group('decideBridgeCall, the rules that matter most', () {
    BridgeDecision decide(
      Host? host,
      BridgeToolKind kind, {
      bool grant = false,
      bool listed = false,
      bool locked = false,
      bool owns = true,
    }) => decideBridgeCall(
      bridgeEnabled: true,
      appLocked: locked,
      host: host,
      hostRequired: true,
      kind: kind,
      hasLiveGrant: grant,
      matchesAllowedCommand: listed,
      ownsLiveTerminal: owns,
    );

    test('an unknown host and a host with access off are refused '
        'identically, for every kind', () {
      for (final kind in BridgeToolKind.values) {
        final unknown = decide(null, kind) as BridgeRefuse;
        final hidden =
            decide(_host(HostAiAccess.off, terminal: true), kind, grant: true)
                as BridgeRefuse;
        expect(hidden.code.codeUnits, unknown.code.codeUnits);
        expect(hidden.message.codeUnits, unknown.message.codeUnits);
        expect(hidden, BridgeRefusals.hostNotAvailable);
        expect(hidden.message, isNot(contains('web')));
        expect(hidden.message.toLowerCase(), isNot(contains('access')));
      }
    });

    test('a change tool always needs a host, whatever hostRequired says', () {
      for (final kind in [BridgeToolKind.change, BridgeToolKind.terminal]) {
        expect(
          decideBridgeCall(
            bridgeEnabled: true,
            appLocked: false,
            host: null,
            hostRequired: false,
            kind: kind,
            hasLiveGrant: true,
            matchesAllowedCommand: true,
            ownsLiveTerminal: true,
          ),
          BridgeRefusals.hostNotAvailable,
        );
      }
    });

    test('a read-only host refuses changes and terminals, saying only that', () {
      final host = _host(HostAiAccess.readOnly, terminal: true, allowed: ['x']);
      for (final kind in [BridgeToolKind.change, BridgeToolKind.terminal]) {
        expect(
          decide(host, kind, grant: true, listed: true),
          BridgeRefusals.changesNotAllowed,
        );
      }
      final message = BridgeRefusals.changesNotAllowed.message;
      expect(BridgeRefusals.changesNotAllowed.code, 'changes_not_allowed');
      expect(message, contains('read-only'));
      expect(message, isNot(contains('web')));
      expect(message.toLowerCase(), isNot(contains('terminal')));
      expect(message.toLowerCase(), isNot(contains('allowed command')));
    });

    test('ask to change: allowed by list or grant, else approval', () {
      final host = _host(HostAiAccess.askToChange);
      expect(decide(host, BridgeToolKind.change), const BridgeNeedsApproval());
      expect(
        decide(host, BridgeToolKind.change, listed: true),
        const BridgeAllow(),
      );
      expect(
        decide(host, BridgeToolKind.change, grant: true),
        const BridgeAllow(),
      );
    });

    test('a terminal needs its switch, and always a yes', () {
      expect(
        decide(
          _host(HostAiAccess.askToChange),
          BridgeToolKind.terminal,
          grant: true,
          listed: true,
        ),
        BridgeRefusals.terminalNotAllowed,
      );
      final host = _host(HostAiAccess.askToChange, terminal: true);
      for (final grant in [false, true]) {
        for (final listed in [false, true]) {
          expect(
            decide(host, BridgeToolKind.terminal, grant: grant, listed: listed),
            const BridgeNeedsApproval(),
          );
        }
      }
    });

    test('a refusal never depends on the grant or the allowed list', () {
      for (final enabled in [false, true]) {
        for (final locked in [false, true]) {
          for (final hostCase in _HostCase.values) {
            for (final kind in BridgeToolKind.values) {
              for (final owns in [false, true]) {
                final answers = {
                  for (final grant in [false, true])
                    for (final listed in [false, true])
                      decideBridgeCall(
                        bridgeEnabled: enabled,
                        appLocked: locked,
                        host: _hostFor(hostCase),
                        hostRequired: true,
                        kind: kind,
                        hasLiveGrant: grant,
                        matchesAllowedCommand: listed,
                        ownsLiveTerminal: owns,
                      ),
                };
                final refusals = answers.whereType<BridgeRefuse>();
                if (refusals.isNotEmpty) expect(answers, hasLength(1));
              }
            }
          }
        }
      }
    });

    test('a locked app says so, and nothing more, even for a change', () {
      final decision =
          decide(
                _host(HostAiAccess.askToChange, terminal: true),
                BridgeToolKind.terminal,
                locked: true,
              )
              as BridgeRefuse;
      expect(decision, BridgeRefusals.appLocked);
    });

    test('a host passed to a tool that takes none is still held to access', () {
      expect(
        decideBridgeCall(
          bridgeEnabled: true,
          appLocked: false,
          host: _host(HostAiAccess.off),
          hostRequired: false,
          kind: BridgeToolKind.read,
          hasLiveGrant: false,
          matchesAllowedCommand: false,
          ownsLiveTerminal: false,
        ),
        BridgeRefusals.hostNotAvailable,
      );
    });

    test('all refusal codes are distinct', () {
      final codes = {
        BridgeRefusals.bridgeOff.code,
        BridgeRefusals.appLocked.code,
        BridgeRefusals.changesNotAllowed.code,
        BridgeRefusals.terminalNotAllowed.code,
        BridgeRefusals.hostNotAvailable.code,
        BridgeRefusals.terminalNotAvailable.code,
      };
      expect(codes, hasLength(6));
    });
  });

  group('decideBridgeCall, using an open terminal', () {
    BridgeDecision use(
      Host? host, {
      required bool owns,
      bool enabled = true,
      bool locked = false,
      bool grant = false,
      bool listed = false,
    }) => decideBridgeCall(
      bridgeEnabled: enabled,
      appLocked: locked,
      host: host,
      hostRequired: true,
      kind: BridgeToolKind.terminalUse,
      hasLiveGrant: grant,
      matchesAllowedCommand: listed,
      ownsLiveTerminal: owns,
    );

    final terminalHost = _host(HostAiAccess.askToChange, terminal: true);

    test('allowed without a card only for the caller\'s own live terminal '
        'on a host that still allows one', () {
      expect(use(terminalHost, owns: true), const BridgeAllow());
      expect(use(terminalHost, owns: false), BridgeRefusals.terminalNotAvailable);
    });

    test('never a card, whatever the grant and the list say', () {
      for (final hostCase in _HostCase.values) {
        for (final owns in [false, true]) {
          for (final grant in [false, true]) {
            for (final listed in [false, true]) {
              expect(
                use(
                  _hostFor(hostCase),
                  owns: owns,
                  grant: grant,
                  listed: listed,
                ),
                isNot(isA<BridgeNeedsApproval>()),
              );
            }
          }
        }
      }
    });

    test('a terminal the caller does not own reads the same for every host, '
        'so another client\'s terminal cannot be told from an unknown id', () {
      for (final hostCase in _HostCase.values) {
        final d = use(_hostFor(hostCase), owns: false) as BridgeRefuse;
        expect(d.code.codeUnits, BridgeRefusals.terminalNotAvailable.code.codeUnits);
        expect(
          d.message.codeUnits,
          BridgeRefusals.terminalNotAvailable.message.codeUnits,
        );
        expect(d.message, isNot(contains('web')));
      }
    });

    test('bridge off and locked come first, as for every kind', () {
      for (final owns in [false, true]) {
        expect(
          use(terminalHost, owns: owns, enabled: false),
          BridgeRefusals.bridgeOff,
        );
        expect(
          use(terminalHost, owns: owns, locked: true),
          BridgeRefusals.appLocked,
        );
      }
    });

    test('the host is held to the terminal rule on every call', () {
      expect(use(null, owns: true), BridgeRefusals.hostNotAvailable);
      expect(
        use(_host(HostAiAccess.off, terminal: true), owns: true),
        BridgeRefusals.hostNotAvailable,
      );
      expect(
        use(_host(HostAiAccess.readOnly, terminal: true), owns: true),
        BridgeRefusals.changesNotAllowed,
      );
      expect(
        use(_host(HostAiAccess.askToChange), owns: true),
        BridgeRefusals.terminalNotAllowed,
      );
    });

    test('owning a terminal changes nothing for the other kinds', () {
      for (final hostCase in _HostCase.values) {
        for (final kind in [
          BridgeToolKind.read,
          BridgeToolKind.change,
          BridgeToolKind.terminal,
        ]) {
          for (final hostRequired in [false, true]) {
            BridgeDecision d(bool owns) => decideBridgeCall(
              bridgeEnabled: true,
              appLocked: false,
              host: _hostFor(hostCase),
              hostRequired: hostRequired,
              kind: kind,
              hasLiveGrant: false,
              matchesAllowedCommand: false,
              ownsLiveTerminal: owns,
            );
            expect(d(true), d(false));
          }
        }
      }
    });

    test('the refusal text names no host and says what to do', () {
      final r = BridgeRefusals.terminalNotAvailable;
      expect(r.code, 'terminal_not_available');
      expect(r.message, contains('open_terminal'));
    });
  });

  group('bridgeCommandIsAllowed', () {
    final host = _host(
      HostAiAccess.askToChange,
      allowed: ['systemctl status nginx', 'df -h'],
    );

    test('exact text matches, after trimming the request', () {
      expect(bridgeCommandIsAllowed(host, 'df -h'), isTrue);
      expect(bridgeCommandIsAllowed(host, '  df -h\t'), isTrue);
      expect(bridgeCommandIsAllowed(host, 'systemctl status nginx'), isTrue);
    });

    test('nothing but exact equality matches', () {
      for (final near in [
        'df  -h',
        'DF -H',
        'df -h; rm -rf /',
        'df -h && true',
        'df',
        'df -hT',
        'systemctl status nginx\nreboot',
        'df -h',
        '',
        '   ',
      ]) {
        expect(bridgeCommandIsAllowed(host, near), isFalse, reason: near);
      }
    });

    test('the list is inert unless the host asks to change', () {
      for (final access in [HostAiAccess.off, HostAiAccess.readOnly]) {
        expect(
          bridgeCommandIsAllowed(_host(access, allowed: ['df -h']), 'df -h'),
          isFalse,
        );
      }
    });
  });

  group('bridgeSameServer', () {
    final base = _host(HostAiAccess.askToChange);

    test('the same host is the same server; an unrelated edit keeps it', () {
      expect(bridgeSameServer(base, base), true);
      expect(
        bridgeSameServer(
          base,
          base.copyWith(label: 'renamed', aiAllowedCommands: ['ls']),
        ),
        true,
      );
    });

    test('a new address, port, user, transport, jump host or id is another '
        'server', () {
      for (final other in [
        base.copyWith(hostname: 'elsewhere.example.com'),
        base.copyWith(port: 2222),
        base.copyWith(username: 'root'),
        base.copyWith(transport: HostTransport.mosh),
        base.withJumpHost('bastion'),
        base.copyWith(id: 'id-2'),
      ]) {
        expect(bridgeSameServer(base, other), false, reason: '$other');
        expect(bridgeSameServer(other, base), false);
      }
      final viaA = base.withJumpHost('a');
      expect(bridgeSameServer(viaA, viaA.withJumpHost('b')), false);
      expect(bridgeSameServer(viaA, viaA.withJumpHost(null)), false);
    });
  });
}
